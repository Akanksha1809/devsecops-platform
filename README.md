# DevSecOps CI/CD Platform

A production-style, fully free/open-source CI/CD platform built as a portfolio project: Jenkins → security gates → Argo CD → Argo Rollouts → Prometheus/Grafana, running locally on `kind`. No paid services, no always-on cloud resources.

**Status: Phase 6 of 9 complete.** See [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) for the full phase plan, environment constraints (this is built and tested on an 8 GB RAM machine — that ceiling shapes several design choices), and what's verified vs. not yet built. This README will grow a full architecture/setup/troubleshooting section as later phases land; it does not yet document components that don't exist.

## What exists right now (Phases 1–6 — verified)

### Monitoring (Prometheus, Alertmanager, Grafana)

Hand-rolled plain Deployments (`monitoring/`) — not the Prometheus Operator/kube-prometheus-stack chart, deliberately, to fit this machine's RAM budget (all 5 components added ~0 measurable change to available cluster memory). Annotation-based Prometheus discovery, not ServiceMonitor CRDs. Alertmanager routes to the app's own new `/webhooks/alerts` endpoint — a free, local notification receiver reusing existing infrastructure instead of standing up another component.

A real alert was fired end-to-end, not just configured: `AppUnavailable` went `pending` → `firing` when dev was genuinely scaled to 0 via Git, Alertmanager got `connection refused` delivering to the now-0-replica app, retried automatically, and succeeded once the app came back — captured with the real payload in [docs/evidence/phase6-alert-firing-transcript.md](docs/evidence/phase6-alert-firing-transcript.md). That run also caught a real bug in the original alert expression (`sum(up{...}) == 0` never matches once a target vanishes entirely from service discovery — fixed to `absent(up{...} == 1)`) and a real limitation (the webhook receiver's in-memory store is per-pod, so only one of two replicas saw the delivery).

```bash
kubectl apply -f argocd/application-monitoring.yaml
kubectl -n monitoring create secret generic grafana-admin-credentials --from-literal=admin-password=CHANGE_ME
kubectl -n monitoring port-forward svc/grafana 3000:3000   # dashboard: DevSecOps Platform — App & Cluster
```

### Progressive delivery (Argo Rollouts)

The app is now an Argo Rollouts `Rollout` (canary), not a plain Deployment: `setWeight 25 → pause → analysis → setWeight 50 → pause → setWeight 100`, gated by an `AnalysisTemplate` that probes a canary-only Service's `/ready` endpoint — real verification, not "Kubernetes accepted the manifest." Both the good and bad paths were run for real:

- **Good release:** full canary progression to `Healthy`, 3/3 analysis probes passed. [docs/evidence/phase5-good-canary-rollout.txt](docs/evidence/phase5-good-canary-rollout.txt)
- **Bad release:** a deliberately unhealthy version was caught by the canary pod's own readiness probe before the analysis even ran, the Rollout auto-aborted via `progressDeadlineAbort`, and a continuous probe against the main Service — started *before* the bad release was pushed — recorded **180/180 successful responses** across the whole sequence. [docs/evidence/phase5-availability-during-abort.txt](docs/evidence/phase5-availability-during-abort.txt)

Two real bugs surfaced and fixed along the way, both documented in [docs/IMPLEMENTATION_PLAN.md §4d](docs/IMPLEMENTATION_PLAN.md): kind's CNI turned out to **enforce** NetworkPolicy after all (correcting Phase 3), and a shared (not per-revision) ConfigMap let a bad config value leak into a freshly-scaled-up *stable* pod after the abort.

### GitOps (Argo CD)

Argo CD (`argocd/`) manages `devsecops-dev` with full automation (auto-sync + selfHeal + prune) and `devsecops-staging` with no automated sync at all — promoting to staging means an explicit `argocd app sync devsecops-app-staging`, which is this project's dev→staging promotion gate. Jenkins never touches the cluster; Argo CD is the only thing that applies Kubernetes changes, reconciling from the `helm/devsecops-app` path in this same repo.

Actually demonstrated, not just configured: a manual `kubectl scale --replicas=5` on dev's Rollout was detected as drift and self-healed back to the Git-declared replica count within 5 seconds — transcript in [docs/evidence/phase4-drift-selfheal-transcript.md](docs/evidence/phase4-drift-selfheal-transcript.md) (captured when the workload was still a plain Deployment; Phase 5 switched it to a Rollout, selfHeal behaves the same way). The CI→GitOps handoff (Jenkins auto-bumping the image tag in Git after a publish) isn't wired yet — it depends on the still-deferred GHCR publish from Phase 2.

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side
kubectl apply -f argocd/application-dev.yaml -f argocd/application-staging.yaml
argocd app sync devsecops-app-staging   # explicit promotion, dev auto-syncs on its own
```

### Kubernetes (kind + Helm)

A dedicated single-node kind cluster (`kubernetes/kind-config.yaml`, cluster name `devsecops-platform` — separate from any other kind cluster on the machine) runs the app via the Helm chart in `helm/devsecops-app/`, with separate `values-dev.yaml`/`values-staging.yaml` overlays (namespace, replica count). Security posture actually verified by `kubectl exec`, not just declared: runs as UID 999 (non-root), root filesystem is genuinely read-only, no ServiceAccount token mounted. A NetworkPolicy is included and checkov-validated but **not enforced** — kind's default CNI doesn't implement NetworkPolicy; see IMPLEMENTATION_PLAN.md §4b. No Ingress, HPA, or PDB yet — each is deliberately deferred with a documented reason, not silently skipped.

As of Phase 4, Argo CD (below) owns the actual deploys — `helm install` directly is still useful for local iteration before pushing, but the cluster's dev/staging namespaces are now reconciled from Git, not from a developer's local `helm install`.

```bash
kind create cluster --config kubernetes/kind-config.yaml
kind load docker-image devsecops-platform-app:dev --name devsecops-platform
kubectl -n devsecops-dev port-forward svc/devsecops-app 8000:8000   # see §4b for why port-forward, not the NodePort
```

### CI (Jenkins)

Jenkins runs as a container (`docker/jenkins/`) that only has `docker-cli` baked into it — every pipeline tool (python, gitleaks, trivy, checkov) runs as its own short-lived sibling container reached via `docker run --volumes-from <jenkins-container>`, so Jenkins' own image stays small. The `Jenkinsfile` pipeline: checkout → install deps (cached) → lint/format → unit tests → integration tests → coverage + threshold gate → gitleaks → trivy (deps) → checkov (IaC, soft-fail) → build image → trivy (image, fails on CRITICAL) → CycloneDX SBOM → optional GHCR publish → build summary.

This has actually been run: build #3 of `devsecops-platform-pipeline` finished green with 18/18 tests, 97.79% coverage, 0 leaks, 0 CRITICAL vulnerabilities, and a real SBOM — evidence archived at [docs/evidence/](docs/evidence/). GHCR publish is wired but not yet exercised (needs a PAT with `write:packages`, which the existing `gh` token doesn't have — see IMPLEMENTATION_PLAN.md §4a); it falls back to "image stays local" gracefully when that credential is missing.

```bash
cd docker/jenkins
cp .env.example .env   # set JENKINS_ADMIN_PASSWORD
docker-compose up -d
# UI at http://localhost:8080
```

### App (Phase 1)

- `app/` — a FastAPI service (`devsecops-platform-app`) with:
  - `GET /health` (liveness), `GET /ready` (readiness — can be forced unhealthy via `APP_SIMULATE_UNHEALTHY=true`, used later for rollout-failure demos)
  - `GET /metrics` (Prometheus text format: request count + latency histogram by method/path/status)
  - `GET/POST/PATCH/DELETE /api/v1/tasks` — a small in-memory CRUD API with Pydantic validation and proper 404/422 handling
  - structured JSON logging for the app's own logger (uvicorn's own access/error logs are **not** JSON-formatted — known limitation, documented, not hidden)
  - configuration entirely via `APP_*` environment variables
- `tests/` — 15 pytest tests, 98% statement coverage on `app/`
- `Dockerfile` — multi-stage, non-root user, pinned base image tag, `HEALTHCHECK`, no `latest` tags
- A Day-0 Trivy scan of the built image is archived at `docs/evidence/phase1-trivy-baseline.txt` — real findings in the base image/transitive Python deps (not fabricated), to be acted on when the security-gate phase (Phase 7) wires scanning into the pipeline with an actual severity policy.

All of the above has actually been run: `pytest` passes, the image builds, and the running container was curl-tested for every endpoint above (200/201/404/422/503 paths) and confirmed to run as a non-root user.

## Running it locally

```bash
# Python path (requires python3.12)
make install
make test
make run        # http://localhost:8000

# Docker path
make build
make run-image   # http://localhost:8000
```

## Not built yet

Terraform, Vault, and the 9 acceptance scenarios from the brief — tracked phase-by-phase in [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md).
