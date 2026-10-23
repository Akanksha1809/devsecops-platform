# Portfolio demo script (~7 minutes)

A walkthrough script for presenting this project live, in interview or portfolio-review settings. Each beat names exactly what to run/show and what to say about it.

## 1. The pitch (30s)

"This is a full DevSecOps platform — Jenkins for CI, Argo CD/Rollouts for GitOps and progressive delivery, Prometheus/Grafana/Alertmanager for monitoring, Vault for secrets — built entirely free, running locally on kind on an 8 GB laptop. Every component is real and verified; I'm going to show you the actual pipeline run and a real rollback, not slides."

## 2. The app (30s)

```bash
kubectl -n devsecops-dev port-forward svc/devsecops-app 8000:8000 &
curl -s http://localhost:8000/ | jq
curl -s http://localhost:8000/health
```

"Small FastAPI service — health/readiness endpoints, Prometheus metrics, a CRUD API. Nothing fancy; the point is the platform around it."

## 3. CI in Jenkins (2 min)

Open the Jenkins UI (`http://localhost:8080`), show `devsecops-platform-pipeline`'s stage view for a recent green build.

"Every stage runs as its own sibling container — Jenkins itself only has `docker-cli` installed. Lint, unit tests, integration tests, coverage gate, then three separate security scanners: Gitleaks for secrets, Trivy for dependency and image vulnerabilities, Checkov for IaC — across Dockerfiles, Kubernetes manifests, the Helm chart, and Terraform, four frameworks in one pass. Then build, scan the image, generate an SBOM."

Point at `docs/FAILURE_SCENARIOS.md` Scenario 3/4 evidence if asked "does it actually catch things?" — "Yes — I deliberately committed a fake credential and a dependency with a known CVE to verify the gates actually fail, not just that they're configured."

## 4. GitOps and a live rollback (2 min)

```bash
kubectl argo rollouts get rollout devsecops-app -n devsecops-dev --watch
```

In another terminal, trigger a real bad release:

```bash
# edit helm/devsecops-app/values-dev.yaml: simulateUnhealthy: true, bump app.version
git add -A && git commit -m "demo: bad release" && git push
argocd app sync devsecops-app-dev
```

"Watch the canary step — it never gets past 25% because the new pods fail their readiness probe. After the configured deadline, it aborts automatically and the old version keeps serving the whole time." (Have `docs/evidence/phase5-availability-during-abort.txt` open to show the 180/180 real probe results if asked to prove zero downtime.)

Revert:

```bash
git revert HEAD && git push
argocd app sync devsecops-app-dev
```

## 5. Monitoring and a real alert (1.5 min)

Open Grafana (`http://localhost:3000`), the "DevSecOps Platform — App & Cluster" dashboard.

"Request rate, error ratio, p95 latency, ready-pod count, node memory — all real Prometheus queries against real scrape targets." Show the Alertmanager UI or `docs/evidence/phase6-alert-firing-transcript.md`: "I fired this for real — scaled the app to 0 via Git, watched the alert go pending then firing, watched Alertmanager fail to deliver because the webhook receiver *was* the now-0-replica app, then succeed once it came back. Found a real bug in the alert expression doing this, too."

## 6. Secrets (1 min)

```bash
kubectl -n devsecops-dev logs <pod> -c vault-secret-fetch
kubectl -n devsecops-dev exec <pod> -c devsecops-app -- ls /var/run/secrets/kubernetes.io/
```

"The initContainer authenticates to Vault using its own Kubernetes identity — no static token anywhere in this repo — fetches a secret, and the main app container, which has zero Kubernetes API access of its own, reads it from a shared volume. That `ls` returning 'No such file or directory' is the proof."

## 7. Close (30s)

"Everything here — the pipeline failures, the rollback, the alert, the secret fetch — is in `docs/evidence/` with real console output, not described from memory. Happy to dig into any piece."

---

# Resume bullet points

Based only on what's actually built and verified in this repo — nothing here describes planned-but-unbuilt work.

- Built a free, fully self-hosted DevSecOps platform (Jenkins, Argo CD, Argo Rollouts, Prometheus/Grafana/Alertmanager, Vault, Terraform) on a resource-constrained (8 GB RAM) local Kubernetes cluster, with every component's design decision documented against that constraint.
- Designed a Jenkins pipeline running fully containerized tools via docker-outside-of-docker, with four integrated security scanners (Gitleaks, Trivy ×2, Checkov) spanning secrets, dependencies, container images, and IaC (Dockerfile/Kubernetes/Helm/Terraform) in a single run; verified all four gates by deliberately triggering and confirming each one fails correctly.
- Implemented GitOps continuous delivery with Argo CD, including a canary progressive-delivery strategy via Argo Rollouts with automated health-gated promotion and abort/rollback — verified a real bad release aborts automatically with zero measured downtime (180/180 successful health probes during the incident).
- Built a Prometheus/Alertmanager/Grafana monitoring stack from scratch (no Operator) with custom alert rules; found and fixed a real alerting-logic bug (an alert expression that silently stopped firing once its target left service discovery) by actually triggering the alert rather than only reviewing the rule.
- Implemented dynamic secret injection via HashiCorp Vault's Kubernetes auth method, with the application container itself retaining zero Kubernetes API access — verified directly, not just configured.
- Used Terraform to bootstrap GitOps and secrets-management configuration with a deliberately scoped boundary against Argo CD's own reconciliation, documenting and resolving a real multi-tool resource-ownership conflict.
- Diagnosed and fixed real infrastructure bugs under pressure, including Kubernetes NetworkPolicy enforcement behavior that contradicted initial assumptions, Docker Compose project-naming collisions that affected unrelated projects, and container entrypoint-script failures root-caused by reading the actual source rather than guessing flags.
