# DevSecOps CI/CD Platform

A production-style, fully free/open-source CI/CD platform built as a portfolio project: Jenkins → security gates → Argo CD → Argo Rollouts → Prometheus/Grafana, running locally on `kind`. No paid services, no always-on cloud resources.

**Status: Phase 1 of 9 complete.** See [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) for the full phase plan, environment constraints (this is built and tested on an 8 GB RAM machine — that ceiling shapes several design choices), and what's verified vs. not yet built. This README will grow a full architecture/setup/troubleshooting section as later phases land; it does not yet document components that don't exist.

## What exists right now (Phase 1 — verified)

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

Jenkins pipeline, Kubernetes manifests, Argo CD/Rollouts, monitoring stack, Terraform, Vault, and the 9 acceptance scenarios from the brief — tracked phase-by-phase in [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md).
