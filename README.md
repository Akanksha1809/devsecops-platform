# DevSecOps CI/CD Platform

A production-style, fully free/open-source CI/CD platform built as a portfolio project: Jenkins → security gates → Argo CD → Argo Rollouts → Prometheus/Grafana, running locally on `kind`. No paid services, no always-on cloud resources.

**Status: Phase 3 of 9 complete.** See [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) for the full phase plan, environment constraints (this is built and tested on an 8 GB RAM machine — that ceiling shapes several design choices), and what's verified vs. not yet built. This README will grow a full architecture/setup/troubleshooting section as later phases land; it does not yet document components that don't exist.

## What exists right now (Phases 1–3 — verified)

### Kubernetes (kind + Helm)

A dedicated single-node kind cluster (`kubernetes/kind-config.yaml`, cluster name `devsecops-platform` — separate from any other kind cluster on the machine) runs the app via the Helm chart in `helm/devsecops-app/`, with separate `values-dev.yaml`/`values-staging.yaml` overlays (namespace, replica count). Security posture actually verified by `kubectl exec`, not just declared: runs as UID 999 (non-root), root filesystem is genuinely read-only, no ServiceAccount token mounted. A NetworkPolicy is included and checkov-validated but **not enforced** — kind's default CNI doesn't implement NetworkPolicy; see IMPLEMENTATION_PLAN.md §4b. No Ingress, HPA, or PDB yet — each is deliberately deferred with a documented reason, not silently skipped.

```bash
kind create cluster --config kubernetes/kind-config.yaml
kind load docker-image devsecops-platform-app:dev --name devsecops-platform
helm install devsecops-app helm/devsecops-app -n devsecops-dev -f helm/devsecops-app/values-dev.yaml --create-namespace
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

Argo CD/Rollouts, monitoring stack, Terraform, Vault, and the 9 acceptance scenarios from the brief — tracked phase-by-phase in [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md).
