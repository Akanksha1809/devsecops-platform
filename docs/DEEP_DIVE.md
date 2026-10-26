# Deep dive: understanding this project end to end

This document exists so you can read it once and genuinely understand every piece of this project — not just what exists, but why it exists, how it fits together, and what actually happened when it was built (including the mistakes). The other docs in `docs/` are references you reach for when you need one specific thing; this one is meant to be read start to finish.

## Table of contents

1. [The elevator pitch, and the one constraint that shaped everything](#1-the-elevator-pitch-and-the-one-constraint-that-shaped-everything)
2. [Repository map](#2-repository-map)
3. [The application](#3-the-application)
4. [Containerizing it](#4-containerizing-it)
5. [CI: Jenkins](#5-ci-jenkins)
6. [Kubernetes & Helm: how the app actually runs](#6-kubernetes--helm-how-the-app-actually-runs)
7. [GitOps: Argo CD](#7-gitops-argo-cd)
8. [Progressive delivery: Argo Rollouts](#8-progressive-delivery-argo-rollouts)
9. [Monitoring: Prometheus, Alertmanager, Grafana](#9-monitoring-prometheus-alertmanager-grafana)
10. [Secrets: Vault](#10-secrets-vault)
11. [Terraform: the bootstrap layer](#11-terraform-the-bootstrap-layer)
12. [Security tooling: Gitleaks, Trivy, Checkov](#12-security-tooling-gitleaks-trivy-checkov)
13. [The demo and the 9 acceptance scenarios](#13-the-demo-and-the-9-acceptance-scenarios)
14. [Every real bug found during this project](#14-every-real-bug-found-during-this-project)
15. [Operating it day to day](#15-operating-it-day-to-day)
16. [What's not done, and why](#16-whats-not-done-and-why)
17. [Where to go from here](#17-where-to-go-from-here)

---

## 1. The elevator pitch, and the one constraint that shaped everything

This is a full DevSecOps platform — the whole loop from "developer pushes code" to "it's running in production, monitored, with secrets injected securely" — built entirely free, entirely local, on an **8 GB RAM MacBook Air**. That RAM number isn't trivia; it's the single design constraint that explains almost every non-obvious decision in this repo:

- Why Jenkins runs as a container you start only to build, then stop (not always-on).
- Why the monitoring stack is hand-rolled plain Deployments instead of the much more common kube-prometheus-stack Helm chart (its default footprint didn't fit).
- Why Vault runs in dev mode instead of a more realistic HA setup.
- Why several Kubernetes features the brief asked about (Ingress, HorizontalPodAutoscaler, PodDisruptionBudget) were deliberately left out, each with a documented reason rather than silently skipped.

The loop this project actually builds and *verifies* (not just configures):

1. You push code to GitHub.
2. Jenkins notices (by polling — more on why below), runs tests, runs three different security scanners, builds a container image, scans that image, generates a software bill of materials.
3. Separately, Argo CD watches the same GitHub repo and reconciles the Kubernetes cluster to match whatever's declared in a Helm chart — it never runs anything Jenkins tells it to; it just watches Git.
4. Argo Rollouts manages *how* a new version rolls out — gradually, with automated health checks, with the ability to abort and never promote a bad version to 100% of traffic.
5. Prometheus scrapes metrics from everything; Alertmanager fires alerts; Grafana visualizes it.
6. Vault issues the application a secret dynamically, based on the pod's own Kubernetes identity — no password sitting in a config file anywhere.

Every one of those six steps has been *run for real* at least once, usually several times, with the console output saved in `docs/evidence/`. That's the core discipline of this whole project: nothing is claimed to work without having actually been executed and watched.

---

## 2. Repository map

```
app/                  The FastAPI service itself
tests/                Its test suite
Dockerfile            Multi-stage build for the app image
docker/jenkins/       Jenkins' own Dockerfile + docker-compose setup
Jenkinsfile           The CI pipeline definition
helm/devsecops-app/   The Helm chart that deploys the app to Kubernetes
kubernetes/           The kind cluster's own config (just one file)
argocd/               (now empty — see §7, this was a real cleanup)
monitoring/           Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics manifests
vault/                Vault's own Deployment manifest
terraform/            Bootstraps Argo CD Applications + Vault's internal config + a Secret
security/fixtures/    Disposable test fixtures for security-scanner demos (kept empty normally)
scripts/              bootstrap.sh / validate.sh / teardown.sh
docs/                 Everything else — see §17 for what's in each file
docs/evidence/        Raw console output/logs proving specific claims, named phaseN-*
docs/demo/            The recorded demo GIF/cast + screenshots
```

A few things are worth knowing about *why* it's laid out this way:

- **`app/`, `helm/`, and the GitOps config all live in one repo**, not split into separate "application repo" and "deploy repo" the way some GitOps guides suggest. That split is justified when multiple teams need separate access control or release cadences; for a one-person project it would just be friction. Documented explicitly, not a default nobody thought about.
- **There's no `argocd/` content anymore.** Early on (Phase 4), this project had static `argocd/application-*.yaml` files that you'd `kubectl apply`. Phase 7 moved that responsibility into Terraform, which builds the same `Application` objects natively in HCL. The old YAML files became dead, misleading duplicates — nothing read them anymore — and were deleted once that was noticed. This is a real, if small, example of technical debt caught and removed mid-project rather than left to rot.

---

## 3. The application

`app/main.py` is a small FastAPI service. It exists to have *something real* for every other layer of this platform to deploy, monitor, scan, and inject secrets into — the app itself is intentionally simple.

**Endpoints:**

| Route | Purpose |
|---|---|
| `GET /` | Name/version/git-sha — useful to confirm which build is actually running |
| `GET /health` | Liveness — "is the process even up" |
| `GET /ready` | Readiness — "can it serve real traffic." Honors `APP_SIMULATE_UNHEALTHY=true`, which forces a 503. This one env var is what every "deliberately bad release" demo in this project uses to simulate a real failure. |
| `GET /metrics` | Prometheus text format — request counts and latency histograms, by method/path/status |
| `GET/POST/PATCH/DELETE /api/v1/tasks` | A small in-memory CRUD API, mostly there to give the metrics/tests something to exercise |
| `POST /webhooks/alerts` + `GET /webhooks/alerts` | A free, local Alertmanager receiver — see §9 |

A few design choices worth understanding:

- **Config entirely via `APP_*` environment variables** (`app/config.py`, using `pydantic-settings`), never hardcoded. This is what lets the Helm chart's `values-dev.yaml`/`values-staging.yaml` change behavior without touching code.
- **Structured JSON logging** for the app's own logger (`app/logging_config.py`) — but uvicorn's own access/error logs are *not* JSON-formatted. That's a known, documented gap, not an oversight: uvicorn configures its own logging separately, and fixing it fully wasn't worth the effort for a demo app with no log aggregation anyway (see §16).
- **The in-memory `TaskStore` and `AlertStore`** (`app/routers/tasks.py`, `app/routers/webhooks.py`) are deliberately not backed by a real database. This had a real consequence worth knowing: with more than one replica, the alert-webhook store is *per-pod* — if Alertmanager's delivery lands on pod A, pod B's `/webhooks/alerts` has nothing. This was discovered for real while testing the monitoring alert scenario (§13), not predicted in advance, and is documented rather than silently accepted.

**Tests**: 23 tests, ~99% coverage, split into `tests/test_health.py`, `test_tasks.py`, `test_webhooks.py` (unit-style, fast, isolated) and `tests/test_integration.py` (marked `@pytest.mark.integration`, multi-step workflows — e.g., create a task, update it, confirm the metrics counter actually incremented). The Jenkinsfile runs these as two separate stages specifically so a reviewer can see unit vs. integration pass/fail independently.

---

## 4. Containerizing it

`Dockerfile` is a multi-stage build:

```
Stage 1 (builder): python:3.12-slim, creates a venv, installs requirements.txt into it
Stage 2 (runtime):  fresh python:3.12-slim, copies only the venv + app code from stage 1
```

Why multi-stage: the final image never contains pip's cache, build tooling, or anything only needed to *install* dependencies — just the venv and the app.

**Security choices, each deliberate:**
- Runs as a non-root `app` user (UID 999 — this is Debian's own `useradd --system` allocation, not a number picked for any particular reason; this becomes relevant later when checkov flags it as "not high enough" and the finding is documented as accepted rather than fixed, since 999 doesn't correspond to anything a higher number would improve here).
- `HEALTHCHECK` instruction present (used by plain `docker run`; Kubernetes ignores it and uses its own probes instead — see §6).
- Base image pinned to a specific tag, never `latest`.
- No secrets, no build args with sensitive values, nothing baked into a layer that shouldn't be there.

---

## 5. CI: Jenkins

This is the first place a genuinely non-obvious architectural choice shows up, so it's worth understanding the mechanism before the stages.

### The docker-outside-of-docker pattern

Jenkins itself runs as a container (`docker/jenkins/Dockerfile`) with **only `docker-cli` installed** — no Python, no trivy, no checkov, no terraform. Every pipeline stage that needs a tool runs that tool as its own short-lived *sibling* container, via:

```groovy
sh "docker run --rm --volumes-from $(hostname) -w \"\${WORKSPACE}\" <image> <command>"
```

`$(hostname)` resolves, inside the Jenkins container, to that container's own ID. `--volumes-from <that id>` means the sibling container gets access to exactly the same volumes Jenkins itself has mounted — including the workspace where the code was checked out — without needing a bind mount or any host-path translation. This is the standard trick for solving "my CI container needs to run other containers and share files with them" without installing a daemon-in-a-daemon.

Why this matters: it means adding a new tool to the pipeline never means rebuilding Jenkins' own image, and Jenkins' image stays small (better for the RAM budget).

### Running Jenkins at all: why it's a container, not installed natively

Installing Jenkins natively would need Java on the host. Running it as a Docker container (`jenkins/jenkins:lts-jdk17` as the base) sidesteps that entirely, and fits this project's broader pattern of "everything through Docker/Kubernetes, host installs kept minimal."

### The pipeline, stage by stage (`Jenkinsfile`)

1. **Checkout** — also computes `env.SHORT_SHA`/`env.IMAGE_TAG` here (not earlier) because of a real bug: the top-level `environment{}` block evaluates *before* checkout runs, so reading `env.GIT_COMMIT` there was always null. Fixed by moving the computation into the Checkout stage's own `script{}` block.
2. **Install deps** — into a shared `devsecops-platform-pip-cache` Docker volume, reused across stages and builds. This is *real* caching (wheels aren't re-downloaded) but not *full* dependency caching (packages still get re-installed into each fresh container) — documented honestly as "practical, not complete."
3. **Lint & format** — `ruff check` + `ruff format --check`.
4. **Unit tests**, **Integration tests** — two separate stages, two separate JUnit reports.
5. **Coverage** — HTML report published.
6. **Quality gate: coverage threshold** — fails the build if coverage drops below 80% (a configurable pipeline parameter, default chosen to "catch real regressions without chasing diminishing returns toward 100% on a small demo app" — documented rationale, not an arbitrary number).
7. **Secret scan (Gitleaks)** — see §12.
8. **Dependency vulnerability scan (Trivy, fs mode)** — see §12.
9. **Terraform fmt & validate**.
10. **IaC security scan (Checkov)** — scans the *whole repo* in one pass, and picks up **four separate frameworks**: Dockerfile, Kubernetes, Helm (it actually renders the chart correctly — a real open question going in, since Helm templates have `{{ }}` syntax that isn't valid YAML on its own, confirmed resolved), and Terraform. Runs soft-fail (reports, never blocks) — see §12 for why.
11. **Build image**.
12. **Image vulnerability scan (Trivy, image mode)** — fails on CRITICAL by default, HIGH is informational. This asymmetry with the dependency scan (which blocks on HIGH too) is deliberate: at the *image* stage there's genuinely nothing else downstream still able to catch it, so the threshold reflects "how bad does it have to be to justify blocking a release," not "how bad does it have to be to justify flagging it."
13. **SBOM generation** — CycloneDX format, archived as a build artifact.
14. **Publish image** — gated behind a `PUBLISH_IMAGE` boolean parameter (default `false`). If enabled, tries to `docker login ghcr.io` using a Jenkins credential; if that credential doesn't exist, catches the failure and logs a graceful "staying local-only" message instead of crashing. **This has never actually been exercised for real** — the `gh` CLI token on this machine lacks the `write:packages` scope needed, and getting one requires the user's own GitHub account action, which was never requested of them in chat (credentials are never asked for in chat, full stop).
15. **Build summary** — writes and archives a markdown summary (commit, build number, image tag, which gates were configured how, pass/fail).

### Triggering: why polling, not a webhook

Jenkins runs on `localhost`. GitHub's servers cannot reach `localhost` to deliver a webhook. The pipeline job polls every 5 minutes (`H/5 * * * *`) instead — documented explicitly as the real, practical alternative, not glossed over as if webhooks "just work."

### A bug class that bit this pipeline twice

Plain top-level Groovy `def` variables (declared outside the `pipeline{}` block, not using `env.*`) do not reliably survive from one declarative stage into a function called from a later stage, under Jenkins' CPS (continuation-passing-style) execution model. This caused two separate real build failures — `JENKINS_CID` first, then (after fixing that) `PIP_CACHE_VOLUME` hit the exact same class of bug. Both were fixed the same way: resolve the value fresh each time in shell (`$(hostname)`) rather than caching it in a shared Groovy variable, or inline it as a literal.

---

## 6. Kubernetes & Helm: how the app actually runs

### The cluster

A single-node `kind` cluster (`kubernetes/kind-config.yaml`), named `devsecops-platform`. Single-node, not multi-node, specifically to roughly halve the memory footprint versus a more "realistic" multi-node setup — on this machine, that trade-off was worth it.

### The Helm chart (`helm/devsecops-app/`)

```
Chart.yaml              Standard chart metadata
values.yaml              Base defaults, heavily commented with WHY for every non-obvious choice
values-dev.yaml           dev overlay: 2 replicas, DEBUG log level
values-staging.yaml       staging overlay: different namespace, different NodePort
templates/
  rollout.yaml             The actual workload — an Argo Rollouts Rollout, not a plain Deployment
  service.yaml              The main Service
  canary-services.yaml      Two more Services (canary-only, stable-only) for Argo Rollouts' analysis
  canary-analysis.yaml      The AnalysisTemplate that gates canary promotion
  configmap.yaml             Non-secret app config
  serviceaccount.yaml         The app's own ServiceAccount
  networkpolicy.yaml          Pod-to-pod network segmentation rules
  _helpers.tpl                Shared label/naming templates
  NOTES.txt                   Printed after `helm install`
```

### Why a Rollout, not a Deployment

Argo Rollouts is a drop-in replacement for the `apps/v1 Deployment` kind — same pod template, same selector, but with a `strategy.canary` block that defines *steps* instead of a plain rolling update. This project's canary strategy:

```
setWeight: 25 → pause 10s → run analysis → setWeight: 50 → pause 10s → setWeight: 100
```

No traffic-routing plugin (Istio, nginx, ALB) is installed, so `setWeight` is an *approximation* via replica ratio behind the one shared Service — with `replicaCount: 2` and `setWeight: 25`, you don't get a clean 25%; you get whatever rounds to the nearest replica count. This is explicitly why dev was bumped to 4 replicas during the canary-specific demo in Phase 5 (4 divides cleanly into 25/50/100%) and then scaled back to 2 afterward once that demo was done.

### Why two extra Services exist

`canaryService`/`stableService` in the Rollout spec point at two Services (`canary-services.yaml`) that Argo Rollouts manages the selector of at runtime, injecting a `rollouts-pod-template-hash` label so each Service only ever points at canary-only or stable-only pods. **Their only purpose is to give the AnalysisTemplate something precise to probe** — they're not part of normal user traffic, which still goes through the one shared Service.

### How a release actually gets verified before promotion

`canary-analysis.yaml` defines an `AnalysisTemplate` that does an HTTP GET against the canary-only Service's `/ready` endpoint, three times, five seconds apart, and fails the whole analysis the moment one of those checks doesn't return exactly `{"status": "ready"}`. This is the mechanism that makes "the rollout aborted" mean something real rather than "Kubernetes accepted the YAML."

In practice (see §13, Scenario 6), the canary pod's own Kubernetes-level `readinessProbe` usually catches a bad release *before* the AnalysisTemplate even gets a chance to run — because a pod that's never Ready never contributes meaningfully to the weighted step. The AnalysisTemplate is still real defense-in-depth, not redundant: it's what would catch an app that's technically "Ready" by Kubernetes' definition but still behaviorally wrong.

### `progressDeadlineSeconds` / `progressDeadlineAbort`

If a step doesn't complete within 60 seconds, the Rollout is automatically aborted and reverted to the last stable ReplicaSet — `progressDeadlineAbort: true` is what makes this an *abort*, not just a status flag. Without it, a stuck canary (e.g., a pod that never becomes Ready) would just sit there forever.

### Security posture, verified not declared

```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 999
  seccompProfile: { type: RuntimeDefault }
containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: ["ALL"] }
serviceAccount:
  automountServiceAccountToken: false
```

Every one of these was *checked* inside a real running pod with `kubectl exec`, not just declared and trusted:
- `id` inside the container confirmed `uid=999`.
- `touch /test-write` outside `/tmp` confirmed "Read-only file system."
- `ls /var/run/secrets/kubernetes.io/` confirmed "No such file or directory" (no ServiceAccount token mounted on the main container — see §10 for why this matters for Vault).

### NetworkPolicy: a real correction mid-project

`networkpolicy.yaml` restricts the app's pods to receiving traffic only from: other pods in the same namespace, the `argo-rollouts` namespace (for canary analysis probes), and the `monitoring` namespace (for Prometheus scraping and Alertmanager's webhook delivery). Egress is restricted to DNS plus the `vault` namespace on port 8200.

Here's the real story worth knowing: **Phase 3 assumed kind's default CNI (kindnet) doesn't enforce `NetworkPolicy` at all**, based on general kindnet history. Phase 5 disproved this the hard way — Argo Rollouts' AnalysisRun, calling from the `argo-rollouts` namespace, got silently blocked (connections just timed out, no explicit rejection) until an explicit `namespaceSelector` rule was added. The fix was proven with a two-sided test: same-namespace curl succeeded instantly, cross-namespace curl from the exact same pod template timed out every time. Both this document and the chart's own comments were corrected in place rather than left wrong — **this CNI does enforce NetworkPolicy on this specific kind version**.

### What's deliberately *not* here

- **No Ingress.** No ingress controller is installed; access is via `kubectl port-forward`. Adding one would be another always-on component competing for the same RAM budget, for a benefit (host-based routing) this single-app demo doesn't need.
- **No HorizontalPodAutoscaler.** Needs `metrics-server`, which on kind needs a `--kubelet-insecure-tls` patch to work at all because kind's kubelet serving certs aren't verifiable by default — a real, documented gotcha, not a reason to fake an HPA that wouldn't actually scale anything.
- **No PodDisruptionBudget.** On a single-node cluster, the one node is simultaneously the entire control plane and the only place pods could be evicted from — a PDB would protect against nothing real here.

---

## 7. GitOps: Argo CD

Argo CD is the *only* thing that ever applies changes to the running Kubernetes cluster. Jenkins builds and scans; it never runs `kubectl apply` or `helm upgrade`. This separation is the whole point of GitOps: a single, auditable path from "what's declared in Git" to "what's actually running," with no other write path to drift from it.

### Two Applications, two very different sync policies

- **`devsecops-app-dev`**: `syncPolicy.automated` with `prune: true, selfHeal: true`. Every push to `main` that touches the Helm chart or `values-dev.yaml` gets applied automatically. `selfHeal` means a manual `kubectl` change gets *reverted* automatically, too — proven for real in Phase 4: a `kubectl scale --replicas=5` was detected as drift and reverted to the Git-declared count within 5 seconds, fast enough to be the controller's resource watch catching it, not the periodic ~3-minute reconciliation sweep.
- **`devsecops-app-staging`**: no `syncPolicy.automated` at all. Promoting to staging means an explicit `argocd app sync devsecops-app-staging` — this project's deliberate promotion gate between dev and staging, proven for real: staging sat at `OutOfSync`/`Missing` until that explicit command, then came up `Synced`/`Healthy` with the correct (different) replica count, using the *same already-built image*, no rebuild triggered.

### Where the `Application` objects themselves live

Not as static YAML files anymore — as of Phase 7, they're built by Terraform (§11). This repo used to have `argocd/application-*.yaml` files for `kubectl apply`, but once Terraform started managing those same objects natively in HCL, the YAML files became dead duplicates that nothing read, and were deleted.

### What Argo CD does *not* do

It doesn't decide *how* a new version rolls out — that's Argo Rollouts' job (§8). It doesn't manage its own installation or Vault's internal configuration — that's Terraform's job (§11). Each tool's boundary is deliberately narrow.

---

## 8. Progressive delivery: Argo Rollouts

Covered in detail in §6 (the chart mechanics) — this section is about the *controller* itself. Argo Rollouts is installed cluster-wide (`kubectl apply -n argo-rollouts -f .../install.yaml`), and its one job is watching `Rollout` objects and executing their `strategy.canary.steps` — creating the canary ReplicaSet, adjusting weights, running AnalysisRuns, and deciding promote-vs-abort.

### `kubectl argo rollouts get rollout ... --watch`

This is the single most useful command for understanding what this project demonstrates — a live, continuously-updating view of exactly which step a rollout is on, what weight it's at, and the health of every ReplicaSet involved. The recorded demo (`docs/demo/demo.gif`) is built entirely around watching this command react in real time to a bad release being pushed.

### What "canary" means here specifically, and its real limitation

Without a traffic-routing plugin (Istio/nginx/ALB — none installed), `setWeight` is approximated by **replica count ratio** behind one shared Service, not actual weighted traffic splitting at the network layer. This is explicitly documented as the trade-off made to keep the RAM budget sane — a real production canary setup would want actual traffic-layer weighting.

---

## 9. Monitoring: Prometheus, Alertmanager, Grafana

### Why hand-rolled, not kube-prometheus-stack

kube-prometheus-stack (the Prometheus Operator + CRDs + ServiceMonitors pattern most tutorials use) is the "normal" way to do this. Its default resource footprint didn't fit this machine's budget on top of everything else already running. Instead: plain Deployments (`monitoring/prometheus/deployment.yaml`, etc.), no Operator, no CRDs.

### How Prometheus finds things to scrape

Not ServiceMonitors — **annotation-based discovery**. The app's pod template carries:

```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "8000"
prometheus.io/path: "/metrics"
```

and Prometheus's `kubernetes_sd_configs` scrape job (`monitoring/prometheus/configmap.yaml`) is configured to look for exactly these annotations on pods, relabeling the discovered target's address/path accordingly. This is the standard pre-Operator pattern, chosen deliberately for this project's scope.

### kube-state-metrics: vendored, not hand-written

Its RBAC rule set (read-only `list`/`watch` across most core/apps/batch/rbac resource types) is extensive enough that hand-writing it risked getting a permission subtly wrong. Instead, `monitoring/kube-state-metrics/manifests.yaml` is a near-verbatim copy of the official upstream v2.13.0 "standard" example manifests (`kubectl apply -k github.com/kubernetes/kube-state-metrics/examples/standard?ref=v2.13.0`), with only resource requests/limits added on top (upstream ships none).

### The alert rules, and a real bug in one of them

`monitoring/prometheus/rules-configmap.yaml` defines six alerts: `AppUnavailable`, `HighErrorRate`, `HighLatency`, `RolloutDegraded`, `NodeMemoryPressure`, `NodeCPUPressure`. Every metric name used was *queried directly against the live Prometheus* before being written into a rule — including discovering that `rollout_info_replicas_unavailable` (Argo Rollouts' own metric) was the right way to detect a failed rollout, since kube-state-metrics doesn't model the `Rollout` CRD the way it models a plain Deployment.

The real bug: the first version of `AppUnavailable` was `sum(up{...}) == 0`. This looks correct and parses fine, but **only catches a target that's present in service discovery and failing to scrape** — not a target that's vanished from service discovery entirely (e.g. scaled to 0 replicas), which produces an *empty vector* that never satisfies `== 0`. Caught by actually firing the alert: it went `pending`, then silently disappeared instead of reaching `firing`. Confirmed via direct query (`sum(...)==0` → empty result; `absent(up{...}==1)` → `1`) and fixed to the latter — the correct idiom for "this thing is either down or completely gone."

### Alertmanager's receiver: the app itself

`monitoring/alertmanager/configmap.yaml` routes every alert to `http://devsecops-app.devsecops-dev.svc:8000/webhooks/alerts` — the app's own endpoint (§3). This is this project's free, local stand-in for a real notification service (Slack, PagerDuty, etc.), and it was tested to the point of genuinely breaking: when `AppUnavailable` fired because the app was scaled to 0, Alertmanager's *delivery* failed too (`connection refused` — the receiver *was* the 0-replica app), retried automatically per its own backoff, and succeeded once the app came back, delivering both the `firing` and the later `resolved` notification.

### Grafana

One dashboard (`monitoring/grafana/dashboard-configmap.yaml`, provisioned automatically, not clicked together by hand): request rate by status, 5xx error ratio, p95 latency, ready-pod count, node memory available. All five panels query real Prometheus data — see the screenshot in the README, where the error-ratio panel genuinely shows a spike from a real CPU-contention incident hit while recording the demo (§13), not staged data.

---

## 10. Secrets: Vault

This is the part of the project most worth understanding deeply, because it demonstrates a fundamentally different *kind* of secret than everything else in this repo.

### The contrast this section exists to make

Every other credential in this project (Jenkins' admin password, Grafana's admin password) is **static**: generated once, handed to a `.env` file or a Kubernetes Secret, valid until someone manually rotates it. Vault demonstrates the alternative: a secret issued **dynamically**, tied to the requester's own identity, with a short expiry.

### How the app actually gets a secret, step by step

1. The app's Rollout has an `initContainer` (`vault-secret-fetch`, defined in `helm/devsecops-app/templates/rollout.yaml`) that runs *before* the main app container starts.
2. That initContainer — and **only** that initContainer — gets a Kubernetes ServiceAccount token, via its own `projected` volume (audience-scoped, 600-second expiry). The main app container's pod-wide `automountServiceAccountToken` stays `false`, so it never gets a token at all. This is a meaningfully tighter design than just flipping the pod-wide setting, which was the first thing tried and rejected once it became clear it would also hand a token to the main container.
3. The initContainer runs `vault write auth/kubernetes/login role=devsecops-app jwt=@<that token>` — Vault's Kubernetes auth method validates this token by calling the Kubernetes API's `TokenReview` endpoint. Vault's own pod does this using *its own* identity (bound to the `system:auth-delegator` ClusterRole in `vault/deployment.yaml`), not a separately-managed static reviewer credential.
4. Vault checks: is this JWT really from the `devsecops-app` ServiceAccount, in the `devsecops-dev` namespace specifically (`vault_kubernetes_auth_backend_role` in `terraform/environments/local/vault.tf`)? If yes, it issues a Vault token scoped to exactly one policy (`devsecops-app-read`, which grants `read` on exactly one path), good for 300 seconds.
5. The initContainer uses that Vault token to `vault kv get` the one secret, writes the result to a shared `emptyDir` volume.
6. The main app container — which, again, has zero Kubernetes API access of its own — reads the secret from that shared volume.

This whole chain was verified manually with a throwaway test pod *before* it was wired into the real Rollout, specifically to isolate "does the Vault-side config work at all" from "does the app-specific wiring work" — a debugging discipline worth noticing, not just the end result.

### Why Vault is dev mode, and what that actually means

`vault/deployment.yaml` runs `vault server -dev`. Dev mode: auto-unseals with a single in-memory key, has no TLS, stores everything in memory (the KV mount, the secret, the auth config, the policy, the role, the audit device — all of it — lost on every pod restart), and prints a **freshly-generated root token to its own startup logs every time it starts** (`VAULT_DEV_ROOT_TOKEN_ID` is deliberately left unset, so this token is never a fixed, committable value). This is explicitly and repeatedly labeled as non-production throughout the repo — a real deployment needs HA mode, a real storage backend, proper unseal, and TLS.

### Three real crashes, and how each was actually diagnosed

Getting Vault running under this project's security-hardened pod spec (`capabilities.drop: ["ALL"]`, non-root) took three separate real crash-loop cycles, each diagnosed by **reading the actual `docker-entrypoint.sh` script** (`docker run --entrypoint cat hashicorp/vault:1.18 /usr/local/bin/docker-entrypoint.sh`), not by guessing flags:

1. `VAULT_LOCAL_CONFIG` was set, which makes the entrypoint write `/vault/config/local.json` — a path that wasn't writable. Fixed by removing the env var (dev mode doesn't need it).
2. The entrypoint's `setcap cap_ipc_lock=+ep` (for mlock, which dev mode doesn't even need) failed because `CAP_SETFCAP` was dropped. Fixed with `SKIP_SETCAP=true` — confirmed as a real, documented escape hatch by reading the script, not assumed.
3. `su-exec vault "$@"` (the entrypoint's root→non-root privilege drop) failed with `setgroups: Operation not permitted` under the same dropped capabilities. The script only attempts this transition when it detects `id -u` equals 0 — so the fix was to set `runAsUser: 100`/`runAsGroup: 1000` directly (the image's own built-in `vault` user), skipping the transition entirely rather than trying to grant back just enough capability to make `su-exec` work.

### Audit logging

A file audit device is enabled (`vault_audit` resource in `terraform/environments/local/vault.tf`), writing to the same `emptyDir` mounted at `/vault/audit`. Every login and secret read is logged — with sensitive values HMAC-hashed, not plaintext, confirmed by reading a real captured log entry.

---

## 11. Terraform: the bootstrap layer

### The boundary, which is the single most important thing to understand about Terraform's role here

Terraform does **not** manage the kind cluster itself (already running, heavily populated by the time Terraform was introduced in Phase 7 — recreating it would be pure risk for no benefit). It does **not** manage anything Argo CD or Vault then handle ongoing. What it *does* manage:

- The three (now four, with Vault added in Phase 8) Argo CD `Application` objects — the bootstrap trigger that tells Argo CD *what to watch*, not the resources Argo CD then applies from Git.
- Vault's internal configuration — the KV mount, the one demo secret, the Kubernetes auth method, the policy, the role, the audit device.
- The Grafana admin Secret (`random_password` + `kubernetes_secret`), replacing what was originally a one-off `openssl rand | kubectl create secret` command from Phase 6.
- The `monitoring` namespace specifically — not left to Argo CD's `CreateNamespace=true` sync option, because the Grafana Secret needs to exist in it and that ordering needed to be explicit.

### A real HCL type error

The reusable module (`terraform/modules/argocd-application`) needs to build two differently-shaped `Application` sources — a Helm-chart source (for the app) and a plain-directory source (for monitoring/vault). The first attempt tried to pick between them with a ternary inside a `merge()` call. `terraform validate` correctly rejected it: HCL's object type system requires both branches of a conditional to share the same shape, and `{helm = {...}}` and `{directory = {...}}` genuinely don't. Fixed with two separate `kubernetes_manifest` resources selected via `count`, not a type-level workaround.

### A real multi-tool-ownership conflict

After the first successful `terraform apply`, a second `terraform plan` showed a change that was never made by hand: Argo CD's `CreateNamespace=true` sync option had stamped an `argocd.argoproj.io/tracking-id` annotation onto the Terraform-managed `monitoring` namespace. Terraform, legitimately owning that resource, wanted to remove it; Argo CD would just re-add it on its next sync. Neither tool is wrong — they're both correctly managing the piece they're responsible for, and happen to overlap on one field. Fixed with `lifecycle { ignore_changes = [metadata[0].annotations] }`, the standard pattern for exactly this situation. `terraform plan` is clean (no changes) with the fix in place — verified, not assumed.

### Migrating already-existing resources into Terraform

By the time Terraform was introduced, the 3 original Argo CD Applications already existed (created by hand in earlier phases). `kubernetes_manifest` import is a known pain point in the Kubernetes Terraform provider, so rather than fight it: confirmed no finalizers were set on the Applications (meaning deleting them wouldn't cascade-delete the actual pods/services they describe), deleted them, and let `terraform apply` recreate them cleanly. The `monitoring` namespace, by contrast, *was* imported (plain namespaces import fine) rather than deleted, since deleting and recreating a namespace would have been needlessly disruptive to what was running inside it.

---

## 12. Security tooling: Gitleaks, Trivy, Checkov

Each tool owns a distinct, non-overlapping surface:

| Tool | Catches | Runs as |
|---|---|---|
| Gitleaks | Secrets committed to git history | Jenkins stage 7 |
| Trivy (fs mode) | Known-vulnerable dependencies | Jenkins stage 8 |
| Trivy (image mode) | Known-vulnerable packages in the built container image | Jenkins stage 12 |
| Checkov | Misconfigured Dockerfile/Kubernetes/Helm/Terraform | Jenkins stage 10 (soft-fail) |

### Gitleaks is git-history-aware, deliberately — and that has a real consequence

The Secret scan stage runs `gitleaks detect --source=.` **without** `--no-git`, meaning it scans *commit history*, not the working tree. This was chosen specifically because an earlier version (`--no-git`) scanned the full working tree including gitignored files, and flagged a local-only `.env` file that was never committed and never could be — a false alarm from scanning the wrong surface.

The real consequence of the git-history-aware design, discovered while recording the Scenario 3 demo (§13): **deleting a secret from a file in a later commit does not remove it from history.** A disposable test fixture (a fake AWS key) was deleted in a follow-up commit, and the pipeline *still* failed at the same gate — because the commit that introduced it is permanently part of history. This is the scanner working exactly as designed, applied to a case where that design is inconvenient. The fix is `.gitleaksignore` (at the repo root): an allowlist of specific, manually-reviewed fingerprints, not a way to silence the scanner broadly, and a far less disruptive fix than rewriting published git history.

### A genuinely surprising Gitleaks finding

The very first fixture attempt for the secret-detection demo used AWS's own famous published example key (`AKIAIOSFODNN7EXAMPLE`, the one you see in roughly every AWS tutorial ever written). The pipeline **passed when it should have failed**. Confirmed directly (running `gitleaks detect` against just that one fixture file, outside Jenkins entirely): Gitleaks ships a **built-in allowlist for that exact value**, precisely because it's used so ubiquitously in documentation that flagging it everywhere would be pure noise for every Gitleaks user on earth. A second attempt with a low-entropy fake secret (all the same character) also didn't trigger, for an unrelated reason — it didn't meet the generic-secret rule's entropy threshold. A properly randomized (still entirely fake) value finally worked.

### Why Checkov is soft-fail, not blocking

Checkov's full Kubernetes/Terraform check set includes items that are either genuinely not applicable to a single-node local demo (NetworkPolicy-enforcement-adjacent checks, HPA-adjacent checks) or in direct tension with a tool's actual job (node-exporter legitimately needs `hostPID`/`hostNetwork` to read host-level metrics — that's not a misconfiguration, it's the tool's entire purpose). Blocking the pipeline on those would mean either disabling individual checks (which this project's own rules explicitly forbid doing "just to make the pipeline pass") or chasing checkmarks that don't reflect real risk. Soft-fail plus a documented accepted-findings catalog (`docs/SECURITY.md` §5) is the honest alternative.

### Real fixes applied from real findings (not everything was accepted)

When Checkov ran against the monitoring stack for the first time (it hadn't existed yet the last time Checkov ran, which was itself a finding worth knowing — see §14), it surfaced several *cheap, genuinely beneficial* fixes that were applied rather than accepted: `automountServiceAccountToken: false` on Alertmanager/Grafana/node-exporter (none of them call the Kubernetes API — Prometheus genuinely does, so its token stays); a redundant `hostPort` removed from node-exporter (meaningless once `hostNetwork: true` already puts it on the host network); missing liveness/readiness probes added; node-exporter's already-true-at-runtime non-root UID (confirmed via `kubectl exec ... id` → `uid=65534(nobody)`) made explicit in the manifest so Kubernetes itself enforces it, not just Checkov's static check. A follow-up Checkov run confirmed the fix worked: findings dropped from 40 to 29 on the same repo otherwise unchanged.

---

## 13. The demo and the 9 acceptance scenarios

### The recorded demo (`docs/demo/demo.gif` and `.cast`)

Recorded with `asciinema` (a terminal-session recorder, not screen capture) wrapped around a real script that executes genuine commands against the live cluster — no narration track, no staged output. It walks through `docs/DEMO_SCRIPT.md`: app health, Argo CD application status, the current (healthy) canary state, triggering a real `argocd app sync` on a deliberately bad release pushed to Git, watching `kubectl argo rollouts get rollout --watch` react in real time as the rollout aborts, confirming the app never returned anything but `200` throughout, and verifying the Vault secret chain end to end.

Getting this recording right surfaced two more real bugs worth knowing, independent of anything about the platform itself:
- `git log` invoked `less` as a pager under the pty `asciinema` creates for headless recording, and with no real terminal attached, `less` hung forever waiting for input. Fixed with `export GIT_PAGER=cat PAGER=cat`.
- `timeout 70 <command>` — a line meant to bound how long the live-watch step ran — silently did nothing, because `timeout` is a GNU coreutils command not present on macOS by default. The watch step was skipped entirely in the first recording attempt (caught by comparing the transcript against what was expected, not assumed to be fine). Fixed with a `background-process + sleep + kill` pattern instead.

Mid-recording, there was also a genuine, unrelated infrastructure incident: another project's kind cluster on the same machine spiked to 200%+ CPU, pushing this project's own cluster over 400% combined on a 4-CPU VM — severe enough that this project's own app started failing its own liveness probes from sheer CPU starvation, nothing to do with a bug in this repo. Diagnosed with `docker stats`, resolved by stopping the other project's container (with explicit permission, and documented as something to restart afterward, not silently left down).

### The 9 scenarios (full detail in `docs/FAILURE_SCENARIOS.md`)

| # | Scenario | What was actually done | Result |
|---|---|---|---|
| 1 | Successful release | Bumped `app.version`, synced | Full canary progression to `Healthy`, 3/3 analysis probes passed |
| 2 | Test failure | Committed a deliberately failing test | Pipeline stopped at Unit tests; 12 later stages skipped; deployment untouched |
| 3 | Secret detection | Committed a fake credential | Caught (after the AWS-example-key and git-history findings above), fixed with `.gitleaksignore` |
| 4 | Vulnerable dependency | Pinned `PyYAML==5.3` (2 real CRITICAL CVEs) | Caught by Trivy, build failed before image/publish stages ran |
| 5 | Kubernetes drift | `kubectl scale --replicas=5` directly | Detected and self-healed within 5 seconds |
| 6 | Unhealthy release | Deployed with `simulateUnhealthy: true` | Caught by the canary's own readiness probe before analysis even ran; aborted via `progressDeadlineAbort`; 180/180 continuous health probes succeeded throughout |
| 7 | Monitoring alert | Scaled dev to 0 via Git | `AppUnavailable` fired for real (after fixing the `absent()` bug, §9), Alertmanager retried through a genuine delivery failure and succeeded |
| 8 | Environment promotion | `argocd app sync devsecops-app-staging` | Staging came up healthy from the already-built image, no rebuild |
| 9 | Reproducible recovery | Real incidents from this project's own history (below) | All recovered from, documented |

Scenario 9 deliberately uses *real* incidents from this project's own development rather than staging a fake one — arguably more convincing, and certainly more honest. See §14 for the full list.

---

## 14. Every real bug found during this project

This is worth reading as its own section, because it's the single best evidence that this project was actually built and run, not assembled from a template. In rough chronological order:

1. **Docker Compose project-name collision** destroyed an unrelated project's Jenkins container, because both lived in a directory literally named `jenkins` and Compose derives a default project name from the directory. Recovered fully (confirmed the data volume was untouched, recreated under the correct project name). Fixed going forward with an explicit `name:` in `docker-compose.yml`.
2. **Two Jenkins Groovy CPS scoping bugs** (`JENKINS_CID`, then `PIP_CACHE_VOLUME`) — plain top-level `def` variables don't survive across declarative pipeline stages.
3. **`env.GIT_COMMIT` read too early** — the top-level `environment{}` block evaluates before Checkout runs.
4. **Colima's `/tmp` is not mirrored into its VM** — only home-directory paths are. A file written to `/tmp/foo` on macOS and bind-mounted into a container resolves to the VM's own unrelated `/tmp/foo`.
5. **Checkov crashed with a spurious `FileNotFoundError`** when scanning a bind-mounted directory on this specific Colima setup, even though the file was readable from the host. Worked around with `docker cp` instead of a bind mount.
6. **NodePort access on kind is broken on this Colima setup** — TCP connects, then nothing, ever, while the identical request succeeds instantly from inside the node container. `kubectl port-forward` became the documented access path throughout the project.
7. **kindnet *does* enforce NetworkPolicy** on this specific kind version, contradicting the initial (Phase 3) assumption based on general kindnet history. Found when Argo Rollouts' cross-namespace analysis probe was silently blocked.
8. **A shared (not per-revision) ConfigMap** let a bad config value leak into a freshly-scaled-up *stable* pod after a canary abort — the fix for the canary didn't retroactively fix a pod already running under the old value.
9. **`sum(up{...}) == 0` doesn't catch a target that's vanished from service discovery** — an empty vector never satisfies `== 0`. Fixed to `absent(up{...} == 1)`.
10. **The in-memory alert-webhook store is per-pod** — with 2 replicas, only one pod ever saw a given Alertmanager delivery.
11. **A Terraform HCL type error** — a ternary between two differently-shaped object types doesn't type-check.
12. **A real Argo CD/Terraform ownership conflict** on a namespace annotation.
13. **Three separate Vault entrypoint crashes**, each diagnosed by reading the actual script.
14. **The Jenkins pipeline went stale** — it hadn't run since Phase 2, so every "this is CI-validated" claim for `helm/`, `kubernetes/`, `monitoring/`, `terraform/` was aspirational until re-run in Phase 7.
15. **Gitleaks allowlists AWS's famous example key**, and is git-history-aware in a way that outlives a file's deletion.
16. **`git log`'s pager hangs a headless `asciinema` recording**, and **macOS has no `timeout` command by default**.
17. **Real host CPU contention from an unrelated project** caused this project's own app to fail its own liveness probes — collateral damage, not a regression.

Every one of these is documented in detail (root cause, how it was actually confirmed, the fix) in `docs/IMPLEMENTATION_PLAN.md` and/or `docs/TROUBLESHOOTING.md`.

---

## 15. Operating it day to day

```bash
# First time / full bootstrap
./scripts/bootstrap.sh          # kind cluster, Argo CD, Argo Rollouts, Terraform apply
# ... then the Vault-specific apply (needs a freshly-fetched root token, see docs/SETUP.md)

# Day to day
make test                        # app tests only, no cluster needed
./scripts/validate.sh            # tests, lint, helm lint, terraform validate, live cluster health
kubectl -n devsecops-dev port-forward svc/devsecops-app 8000:8000
kubectl argo rollouts get rollout devsecops-app -n devsecops-dev --watch
kubectl -n monitoring port-forward svc/grafana 3000:3000

# Running CI
cd docker/jenkins && docker-compose up -d     # start
# ... trigger a build, watch it, ...
docker-compose stop                            # stop again -- Jenkins is ephemeral by design here

# Full teardown
./scripts/teardown.sh
```

Full detail, including every manual step and why, is in `docs/SETUP.md`.

---

## 16. What's not done, and why

Stated plainly, not buried:

- **GHCR image publish has never been exercised for real.** Wired in the pipeline, falls back gracefully, but the `gh` CLI token on this machine lacks `write:packages` and getting one needs the user's own action.
- **No centralized logging.** Prometheus gives metrics, not logs. `kubectl logs` is the only log access.
- **Vault and the local Terraform backend are both explicitly non-production.** Dev-mode Vault loses all config on restart; Terraform state (including the Grafana password, in plaintext) lives unencrypted on local disk.
- **No image signing/provenance** (cosign, SLSA) — vulnerability scanning catches known CVEs, not tampering.
- **No remote NodePort access on this Colima setup** — a real, reproducible local quirk, worked around via port-forward everywhere.
- **Ingress, HPA, PodDisruptionBudget** were deliberately scoped out, each with a specific reason (§6), not silently skipped.

Full detail: `docs/COSTS_AND_LIMITATIONS.md`.

---

## 17. Where to go from here

| If you want... | Read |
|---|---|
| The phase-by-phase build log, in full, with every finding | `docs/IMPLEMENTATION_PLAN.md` |
| System + sequence diagrams | `docs/ARCHITECTURE.md` |
| Exact setup/bootstrap commands | `docs/SETUP.md` |
| Every Jenkins stage explained | `docs/PIPELINE_WALKTHROUGH.md` |
| The full security posture, policies, and accepted-findings catalog | `docs/SECURITY.md` |
| All 9 acceptance scenarios with real evidence | `docs/FAILURE_SCENARIOS.md` |
| A troubleshooting reference for real issues hit | `docs/TROUBLESHOOTING.md` |
| Cost/licensing and a consolidated limitations list | `docs/COSTS_AND_LIMITATIONS.md` |
| Interview-style Q&A, tool rationale, alternatives considered | `docs/INTERVIEW_GUIDE.md` |
| A timed live-demo script + resume bullets | `docs/DEMO_SCRIPT.md` |
| Raw console output backing a specific claim | `docs/evidence/phaseN-*` |
