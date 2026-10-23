# Interview guide

Why each tool is here, what else was considered, the real trade-offs made, how each piece actually fails, where the security boundaries are, and how to talk about any of it under questioning. Everything here maps to something actually built and verified in this repo — see `docs/IMPLEMENTATION_PLAN.md` for the phase-by-phase evidence behind every claim.

## Tool-by-tool: why, alternatives, trade-offs

### Jenkins (CI)
**Why**: explicitly requested (demonstrate Jenkins expertise), and its plugin ecosystem/Groovy DSL are still extremely common in real orgs, especially ones that pre-date GitHub Actions.
**Alternatives considered**: GitHub Actions (simpler, no self-hosting, but wouldn't demonstrate Jenkins), GitLab CI (similar trade-off), Tekton (Kubernetes-native but heavier to stand up for a CI-only need).
**Trade-off taken**: ran it as a Docker container with only `docker-cli` installed, orchestrating every tool as a sibling container — lighter than installing Python/trivy/checkov/terraform directly in the Jenkins image, at the cost of a docker-outside-of-docker path-sharing mechanism (`--volumes-from`) that's non-obvious if you haven't seen it before.
**Failure mode**: a plain top-level Groovy `def` variable doesn't survive across declarative stages (hit this twice — see `docs/PIPELINE_WALKTHROUGH.md`). Also: no GitHub webhook is possible since Jenkins is on localhost; polling is the real fallback, not a corner someone cut.

### Argo CD (CD / GitOps)
**Why**: the de facto standard for Kubernetes GitOps; demonstrates the CI/CD separation the brief explicitly asks for (Jenkins builds, Argo CD deploys, never the same tool doing both).
**Alternatives considered**: Flux (comparable, less common in job postings), plain `kubectl apply` from CI (rejected — that's exactly the anti-pattern GitOps exists to avoid: no drift detection, no single source of truth).
**Trade-off taken**: single-repo GitOps (app source and deploy config in one repo, separated by directory) instead of two repos — justified for a one-person project (`docs/IMPLEMENTATION_PLAN.md` §4c), the brief explicitly allows this "if justified."
**Failure mode**: a resource co-managed by Argo CD and something else (Terraform, in this project's real case) causes a perpetual, harmless-but-noisy drift tug-of-war unless one side explicitly ignores the field the other owns.

### Argo Rollouts (progressive delivery)
**Why**: canary releases with automated health-gated promotion, not just a rolling update — demonstrates the difference between "Kubernetes accepted the manifest" and "the new version is actually healthy."
**Alternatives considered**: Flagger (comparable capability, tighter default integration with service meshes this project doesn't have), bare Deployment + manual verification (rejected — doesn't demonstrate automated rollback).
**Trade-off taken**: canary only, no traffic-routing plugin (Istio/nginx/ALB) — `setWeight` approximates traffic split by replica *ratio* behind one shared Service, not real weighted traffic splitting. Blue-green wasn't built (documented as a scoped-out extension, not attempted and glossed over).
**Failure mode**: on a fresh `Rollout` creation, canary steps are skipped entirely (nothing to canary against yet) — the first deploy always goes straight to 100%. A stuck step (bad readiness probe) sits forever without `progressDeadlineSeconds`/`progressDeadlineAbort` configured.

### Prometheus / Alertmanager / Grafana (monitoring)
**Why**: the standard metrics/alerting stack; demonstrates real alert-rule authoring and verification, not just dashboards.
**Alternatives considered**: kube-prometheus-stack (the Operator-based Helm chart most tutorials use) — rejected for this specific machine: its default footprint didn't fit alongside everything else already running on an 8 GB host (`docs/IMPLEMENTATION_PLAN.md` §1). Datadog/New Relic (rejected — not free).
**Trade-off taken**: hand-rolled plain Deployments, annotation-based Prometheus discovery instead of ServiceMonitor CRDs, no per-pod/cAdvisor resource metrics (would need kubelet TLS access — same gotcha that made Phase 3 defer `metrics-server`).
**Failure mode**: `sum(up{...}) == 0` *looks* correct and parses fine but never matches once a target fully vanishes from service discovery (empty vector, not a literal 0) — `absent(up{...} == 1)` is the correct idiom. Found by actually firing the alert, not by reviewing the rule.

### Vault (secrets)
**Why**: demonstrates dynamic, identity-based secret access (Kubernetes auth method) as the alternative to static Secrets — the brief's explicit ask for "separation between app config and secrets" and "least-privilege access."
**Alternatives considered**: Sealed Secrets / SOPS (encrypt-in-git patterns, don't demonstrate dynamic issuance), AWS Secrets Manager / cloud KMS (rejected — this project has zero cloud resources by design).
**Trade-off taken**: dev mode, explicitly and repeatedly labeled as non-production — real deployments need HA mode, a real storage backend, proper unseal, and TLS, none of which dev mode provides.
**Failure mode**: three, all root-caused by reading the actual entrypoint script rather than guessing (`docs/TROUBLESHOOTING.md`) — an unwritable config path, a capability needed for `setcap`, and a privilege-drop step that only happens when the entrypoint detects it's running as root.

### Terraform (bootstrap)
**Why**: demonstrates IaC discipline (plan/review workflow, state, modules) applied to something real rather than padded in for its own sake.
**Alternatives considered**: Pulumi (comparable, less common in job postings), Ansible (imperative, worse fit for declarative resource management), plain `kubectl apply` scripts (rejected — no plan/diff, no state tracking).
**Trade-off taken**: scoped deliberately narrow — bootstraps the Argo CD `Application` CRs and Vault's internal config (mount/policy/role/secret/audit device) and the Grafana Secret, but does **not** manage the kind cluster itself (already running, heavily populated, recreating it via Terraform would be pure risk) or anything Argo CD/Vault then manage ongoing. This boundary is the single most important thing to be able to explain clearly (see the Security boundaries section below).
**Failure mode**: a ternary between two differently-shaped Terraform object types doesn't type-check (HCL requires both conditional branches to share a shape) — fixed with `count`-based resource selection instead of a type-level workaround. Also: a resource genuinely co-managed by two tools needs `lifecycle.ignore_changes` on the specific field the other tool owns, or you get permanent, harmless drift noise.

### Trivy / Gitleaks / Checkov (security scanning)
**Why**: each owns a distinct, non-overlapping surface — dependency/image vulnerabilities, secrets, IaC misconfiguration — rather than three tools doing the same job three ways.
**Alternatives considered**: Snyk (comparable to Trivy, not free at the tier this would need), TruffleHog (comparable to Gitleaks), tfsec (comparable to Checkov, narrower scope — Checkov also covers Dockerfile/K8s/Helm in one tool).
**Trade-off taken**: checkov runs soft-fail (reports, never blocks) — deliberate, because its full Kubernetes/Terraform check set includes items genuinely not applicable to a single-node local demo (NetworkPolicy-enforcement-adjacent checks, HPA-adjacent checks) or in direct tension with a tool's actual job (node-exporter needing `hostPID`/`hostNetwork`). Blocking on those would mean disabling individual checks, which the brief explicitly forbids doing "just to make the pipeline pass."
**Failure mode (real, not hypothetical)**: Gitleaks ships a built-in allowlist for AWS's own famous example key — a "secret detection" test fixture using that exact value silently passes. Also: Gitleaks here is git-history-aware by design, so deleting a leaked secret in a later commit does **not** stop it being flagged — only `.gitleaksignore` (after manual review) or rewriting history actually resolves it.

## Security boundaries (the question to be ready for: "what's actually protecting what, here?")

- **CI never touches the cluster.** Jenkins builds and scans; only Argo CD applies Kubernetes changes. This means a compromised or buggy CI run can't directly mutate production state — the worst it can do is publish a bad image, which still needs a Git change (reconciled by Argo CD) to actually deploy.
- **The app has zero Kubernetes API access.** `automountServiceAccountToken: false` on the main container; only the Vault-fetching initContainer gets a (scoped, audience-limited, 600-second) ServiceAccount token, via its own projected volume, not the pod-wide setting.
- **Vault's Kubernetes auth role is scoped to one ServiceAccount in one namespace**, with a read-only policy on exactly one secret path and a 300-second token TTL. A compromised app pod in a different namespace, or a different ServiceAccount in the same namespace, cannot authenticate as this role.
- **NetworkPolicy segments the app's namespace** — only same-namespace traffic plus three explicitly-named cross-namespace callers (Argo Rollouts' analysis, Prometheus/Alertmanager, Vault) can reach it, and only on the specific ports they need. This is real enforcement on this cluster, confirmed empirically, not a policy that merely exists on paper (`docs/IMPLEMENTATION_PLAN.md` §4d).
- **Terraform's blast radius is deliberately small**: it can create/modify Argo CD `Application` objects and Vault's config, and one Kubernetes Secret. It cannot touch anything Argo CD then deploys from Git — that boundary is enforced by what resources exist in `terraform/`, not by any runtime permission check, which is itself worth being honest about as a limitation, not a hard guarantee.
- **What's explicitly *not* hardened**: Vault dev mode (no TLS, single in-memory unseal key, loses config on restart), Jenkins' container runs as root (documented reason: the mounted Docker socket needs it, and it's a single-user local sandbox), Terraform state holds the Grafana password in plaintext on local disk (no encryption at rest for the local backend).

## Likely interview questions and answers

**"Walk me through what happens when you push code."**
CI (Jenkins) checks out, lints, tests, scans (secrets/deps/IaC), builds, scans the image, generates an SBOM, and optionally publishes. It never touches the cluster. Separately, Argo CD polls Git and reconciles whatever `helm/devsecops-app` plus the active values file currently describes — if that's changed, it syncs; Argo Rollouts then runs the canary steps for that change. Two independent loops, deliberately.

**"Why Jenkins and not GitHub Actions?"**
The brief wanted Jenkins expertise demonstrated specifically. In a real retro I'd note GitHub Actions would mean no self-hosting, no webhook-vs-polling problem (this repo's Jenkins can't receive webhooks since it's on localhost), and tighter GitHub integration — but wouldn't show Jenkinsfile/Groovy/plugin-ecosystem skills.

**"What happens if a deploy is bad?"**
The canary's readiness probe and AnalysisTemplate both gate promotion; if either fails, `progressDeadlineAbort` reverts to the last healthy ReplicaSet automatically. Verified for real with a continuous availability probe during an actual bad release: 180/180 successful responses against the main Service throughout.

**"How do you handle secrets?"**
Two tiers, deliberately contrasted: static secrets (Jenkins/Grafana admin passwords) generated once and stored in a gitignored `.env` or Terraform state — acceptable for local-demo credentials, explicitly documented as not acceptable practice for anything real. And Vault-issued dynamic secrets: the app authenticates via its own Kubernetes identity, gets a policy-scoped token with a 5-minute TTL, and no static Vault credential exists anywhere in the repo.

**"What's the biggest limitation of this setup?"**
Depends what's being probed for, but the most honest answer: Vault dev mode and the local Terraform backend are both explicitly non-production — and more subtly, the in-memory per-pod alert-webhook store means with more than one app replica, only one pod ever sees a given Alertmanager delivery. Found that one by actually running the scenario with 2 replicas, not by inspection.

**"How would you productionize this?"**
Real registry with signed/digest-pinned images (GHCR publish is wired but not yet exercised — missing a `write:packages` token), Vault in HA mode with a real backend and TLS, a remote Terraform backend with state locking, centralized logging (nothing aggregates logs today, only metrics), and either a service mesh or an ingress controller with a traffic-management plugin for genuinely weighted canary traffic rather than the replica-ratio approximation used here.

**"Tell me about a bug you found and how you debugged it."**
Pick any of: the NetworkPolicy enforcement correction (empirical same-namespace-vs-cross-namespace curl test), the three Vault entrypoint crashes (read the actual script each time instead of guessing flags), or the `AppUnavailable` alert silently going dark (confirmed via direct Prometheus query that an empty vector doesn't satisfy `== 0`). All three follow the same pattern: observe the actual failure, don't assume the obvious cause, verify the fix.
