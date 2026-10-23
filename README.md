# DevSecOps CI/CD Platform

A production-style, fully free/open-source DevSecOps platform, built as a portfolio project and run entirely on a local machine: Jenkins (CI) → security gates (Gitleaks/Trivy/Checkov) → Argo CD (GitOps) → Argo Rollouts (canary delivery) → Prometheus/Alertmanager/Grafana (monitoring) → Vault (secrets). No paid services, no cloud resources, no always-on infrastructure beyond a local `kind` cluster.

**Status: all 9 phases complete.** Every claim in this README and the linked docs has been executed and verified at least once — see [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) for the phase-by-phase record (including the real bugs found and fixed along the way, not just what went right) and [docs/evidence/](docs/evidence/) for raw console output backing every specific claim below.

## The problem this solves

A small team shipping a service needs: automated testing and security gating before anything reaches production, a deployment mechanism that can't drift from what's declared in Git, a way to catch a bad release before it serves real traffic, visibility into whether the thing is actually healthy, and a way to inject secrets without hardcoding them — all without committing to paid tooling before knowing if the team even needs it. This project builds and verifies that full loop, end to end, on hardware modest enough (8 GB RAM) that the resource math itself had to be part of the design, not an afterthought.

## Documentation index

| Doc | What's in it |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System diagram, push-to-deploy sequence diagram, tool-by-tool responsibility table |
| [docs/SETUP.md](docs/SETUP.md) | Full install/bootstrap instructions, step by step |
| [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) | The phase-by-phase build log — every decision, every bug, every piece of evidence |
| [docs/PIPELINE_WALKTHROUGH.md](docs/PIPELINE_WALKTHROUGH.md) | Every Jenkinsfile stage explained |
| [docs/SECURITY.md](docs/SECURITY.md) | Tools, policies, every accepted finding with a reason, secrets handling |
| [docs/FAILURE_SCENARIOS.md](docs/FAILURE_SCENARIOS.md) | All 9 brief-required acceptance scenarios, each actually run |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Real issues hit during development and their fixes |
| [docs/COSTS_AND_LIMITATIONS.md](docs/COSTS_AND_LIMITATIONS.md) | Cost ($0), licensing, and consolidated known limitations |
| [docs/INTERVIEW_GUIDE.md](docs/INTERVIEW_GUIDE.md) | Tool rationale/alternatives/trade-offs, security boundaries, Q&A |
| [docs/DEMO_SCRIPT.md](docs/DEMO_SCRIPT.md) | ~7-minute live walkthrough script + resume bullet points |

## Quick start

```bash
make install && make test       # app only, no cluster needed
./scripts/bootstrap.sh          # everything else — see docs/SETUP.md for the manual steps this wraps
./scripts/validate.sh           # automated checks: tests, lint, helm lint, terraform validate, live cluster health
```

## Components (what's built, what's verified)

### CI (Jenkins)

Jenkins runs as a container with only `docker-cli` baked into it — every pipeline tool (Python, Gitleaks, Trivy, Checkov, Terraform) runs as its own short-lived sibling container via `docker run --volumes-from <jenkins-container>`, so Jenkins' own image stays small. Pipeline: checkout → deps (cached) → lint/format → unit tests → integration tests → coverage gate → Gitleaks → Trivy (deps) → `terraform fmt`/`validate` → Checkov (4 frameworks: Dockerfile/Kubernetes/Helm/Terraform, soft-fail) → build → Trivy (image, fails on CRITICAL) → CycloneDX SBOM → optional GHCR publish → build summary. Full detail: [docs/PIPELINE_WALKTHROUGH.md](docs/PIPELINE_WALKTHROUGH.md).

Verified repeatedly, including three deliberate failure runs (a broken test, a planted secret, a CVE-pinned dependency) that each correctly stopped the pipeline before an image could be built — see [docs/FAILURE_SCENARIOS.md](docs/FAILURE_SCENARIOS.md) Scenarios 2–4. GHCR publish is wired but not yet exercised (no `write:packages` token on the local `gh` CLI — [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) §4a); it falls back to "image stays local" gracefully.

```bash
cd docker/jenkins && cp .env.example .env && docker-compose up -d   # http://localhost:8080
```

### GitOps (Argo CD)

Argo CD manages `devsecops-dev` with full automation (auto-sync + selfHeal + prune) and `devsecops-staging` with no automated sync — promoting to staging means an explicit `argocd app sync devsecops-app-staging`, this project's dev→staging gate. Jenkins never touches the cluster. The `Application` objects are Terraform-managed, not static YAML (a real stale-duplicate cleanup — [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) §4g).

A manual `kubectl scale --replicas=5` was detected as drift and self-healed back to the Git-declared count within 5 seconds — [docs/evidence/phase4-drift-selfheal-transcript.md](docs/evidence/phase4-drift-selfheal-transcript.md).

### Progressive delivery (Argo Rollouts)

The app is an Argo Rollouts canary, not a plain Deployment: `setWeight 25 → pause → analysis → setWeight 50 → pause → setWeight 100`, gated by an `AnalysisTemplate` probing a canary-only Service. Both paths run for real:

- **Good release**: full progression to `Healthy`, 3/3 analysis probes passed — [docs/evidence/phase5-good-canary-rollout.txt](docs/evidence/phase5-good-canary-rollout.txt)
- **Bad release**: caught by the canary's own readiness probe, auto-aborted via `progressDeadlineAbort`, **180/180** continuous availability probes succeeded throughout — [docs/evidence/phase5-availability-during-abort.txt](docs/evidence/phase5-availability-during-abort.txt)

### Kubernetes (kind + Helm)

A dedicated single-node kind cluster runs the app via `helm/devsecops-app/`, with dev/staging value overlays. Security posture verified by `kubectl exec`, not just declared: non-root UID, genuinely read-only root filesystem, no unnecessary ServiceAccount tokens. Ingress/HPA/PDB deliberately deferred, each with a documented reason — [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) §4b.

### Monitoring (Prometheus, Alertmanager, Grafana)

Hand-rolled plain Deployments — not the Operator-based kube-prometheus-stack chart, to fit this machine's RAM budget. A real alert fired end-to-end: `AppUnavailable` went `pending → firing` on a genuine GitOps-declared failure, Alertmanager retried through a real delivery failure and succeeded once the app recovered — [docs/evidence/phase6-alert-firing-transcript.md](docs/evidence/phase6-alert-firing-transcript.md). Found and fixed a real alert-expression bug in the process.

```bash
kubectl -n monitoring port-forward svc/grafana 3000:3000   # "DevSecOps Platform — App & Cluster" dashboard
```

### Secrets (Vault)

Dev mode, explicitly not production. The app's initContainer authenticates via its own Kubernetes identity (no static Vault token anywhere in this repo), fetches one secret, and the main app container — verified to have zero Kubernetes API access of its own — reads it from a shared volume. Three real pod crashes were diagnosed by reading the actual entrypoint script, not guessing flags — [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) §4g.

### Security & Terraform bootstrap

[docs/SECURITY.md](docs/SECURITY.md) consolidates every finding across every phase. Terraform bootstraps the Argo CD `Application` objects, Vault's internal config, and the Grafana Secret — never the cluster itself or anything Argo CD/Vault manage ongoing. A real multi-tool-ownership conflict with Argo CD was found and fixed (`lifecycle.ignore_changes`); `terraform plan` is clean afterward.

```bash
cd terraform/environments/local && terraform init && terraform plan && terraform apply
```

### The app

A small FastAPI service (`app/`): `/health`, `/ready` (can be forced unhealthy via `APP_SIMULATE_UNHEALTHY=true`, used for the rollout-failure demos), `/metrics` (Prometheus format), a CRUD `/api/v1/tasks` API, and `/webhooks/alerts` (the free local Alertmanager receiver). 23 tests, ~99% coverage. Multi-stage Dockerfile, non-root, `HEALTHCHECK`, no floating deployment tags.

## Simulating failures

See [docs/FAILURE_SCENARIOS.md](docs/FAILURE_SCENARIOS.md) for all 9 scenarios with exact commands, expected vs. actual results, and cleanup steps.

## Known limitations, costs, and licensing

See [docs/COSTS_AND_LIMITATIONS.md](docs/COSTS_AND_LIMITATIONS.md). Short version: $0 cost, everything free/open-source, no cloud resources ever created; the main limitations are Vault/Terraform-state being explicitly non-production-grade, no centralized logging, and a real Colima NodePort quirk on this specific machine (workaround documented).

## Screenshots

Not yet captured — this project prioritized real, scripted, reproducible verification (console logs, curl output, `kubectl` state) over screenshots, since every piece of evidence in `docs/evidence/` can be independently reproduced by re-running the same commands. Grafana/Argo CD/Argo Rollouts UI screenshots would be a reasonable addition for a more visual portfolio presentation — noted under Future enhancements.

## Future enhancements

- Exercise the GHCR publish path for real (needs a `write:packages` token)
- Image signing/provenance (cosign, SLSA)
- A remote Terraform backend with state locking
- Centralized logging (Loki or similar)
- Per-component NetworkPolicies for the monitoring stack
- Vault in HA mode with a real storage backend, as a deliberate contrast to the dev-mode setup here
- UI screenshots for a more visual presentation

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
