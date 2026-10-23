# Security

This document consolidates the security posture built up across Phases 1–7. It links to the actual evidence rather than re-describing it, and is explicit about what's accepted-and-why versus actually fixed, per this project's rule against silently papering over findings.

## 1. Scope and threat model

This is a local portfolio demo, not a production system handling real user data or real traffic. The threat model is scoped accordingly:

- **In scope**: supply-chain hygiene (dependency/image scanning, SBOM), secret-leak prevention, least-privilege Kubernetes workload configuration, network segmentation between workloads, and a CI pipeline that actually gates on these things rather than just reporting on them.
- **Out of scope**: defending against a sophisticated external attacker, multi-tenant isolation, compliance frameworks (SOC2/PCI/etc.), and anything requiring a real production network boundary (this cluster has no public ingress at all).
- **Everything runs locally** — there is no cloud attack surface. The only externally-reachable thing is the public GitHub repository itself (source code and CI/CD configuration, no secrets).

## 2. Tools and what each owns

| Tool | Owns | Where it runs |
|---|---|---|
| **Gitleaks** | Secret detection in git history (not the working tree — see §4) | Jenkins `Secret scan` stage |
| **Trivy** | Dependency vulnerabilities (`fs`), container image vulnerabilities (`image`), SBOM generation | Jenkins `Dependency vulnerability scan` / `Image vulnerability scan` / `SBOM generation` stages |
| **Checkov** | IaC misconfiguration: Dockerfiles, Kubernetes manifests, Helm charts, Terraform | Jenkins `IaC security scan` stage (soft-fail — reports, doesn't block) |
| **Kubernetes NetworkPolicy** | Pod-to-pod network segmentation | `helm/devsecops-app/templates/networkpolicy.yaml`, enforced by this kind cluster's CNI (see §6) |
| **Pod/container `securityContext`** | Non-root execution, read-only root filesystems, dropped capabilities, no privilege escalation | Every workload manifest in `helm/`, `monitoring/` |
| **RBAC / `automountServiceAccountToken`** | Least-privilege API access | Every ServiceAccount in `monitoring/`, `helm/devsecops-app/templates/serviceaccount.yaml` |

No overlap by design: each tool owns a distinct surface, so a finding only ever shows up in one place.

## 3. Policies and thresholds (with rationale)

| Policy | Value | Why |
|---|---|---|
| Coverage gate | 80% statement coverage on `app/` | Catches real regressions without chasing diminishing returns toward 100% on a small demo app. Configurable via the `COVERAGE_THRESHOLD` pipeline parameter — see `Jenkinsfile`. |
| Image vulnerability gate | Fails the build on **CRITICAL** findings; HIGH is reported but not blocking | A demo app with no real user data doesn't need a zero-HIGH-finding bar, which would make the pipeline red on base-image noise outside this project's control. Configurable via `MAX_IMAGE_SEVERITY`. |
| Secret scan gate | Any detected secret fails the build (`--exit-code 1`) | No tunable threshold makes sense for secrets — any real leak is a hard stop. |
| IaC scan | Soft-fail (reports, never blocks) | Checkov's K8s/Terraform check set includes many checks that are either not applicable to a single-node local demo (NetworkPolicy enforcement checks, HPA-adjacent checks) or in direct tension with a tool's actual job (node-exporter needs `hostPID`/`hostNetwork`). Blocking the pipeline on those would mean either disabling individual checks (fragile, and the brief explicitly says never disable checks just to pass) or chasing checkmarks that don't reflect real risk. Soft-fail + the accepted-findings catalog below is the honest alternative. |

## 4. A genuine gap closed, and a genuine false alarm caused by closing it

The secret-scan stage originally used `gitleaks detect --no-git`, which scans the **working tree**, including gitignored files. The very first real run of it flagged the local-only Jenkins admin password sitting in `docker/jenkins/.env` — a file that was never committed and never could be (it's gitignored). Fixed by dropping `--no-git`: gitleaks now scans **git history**, which is the actually-correct thing to gate a commit on. Full story in `docs/IMPLEMENTATION_PLAN.md` §4a.

## 5. Accepted findings catalog

Every finding below was evaluated and deliberately not fixed, with a reason — not silently ignored. Evidence for each is in `docs/evidence/`.

| Finding | Where | Why accepted |
|---|---|---|
| `CKV_K8S_43` Image should use digest | App + monitoring workloads | No image in this project is currently pulled from a real registry (GHCR publish is wired in Jenkins but not yet exercised — see §7). Digest pinning is meaningless until there's a real immutable reference to pin. Will become a real fix once GHCR publish is exercised. |
| `CKV_K8S_15` Pull policy should be `Always` | App + monitoring workloads | Same reason — `Always` would just fail to pull on every environment this project currently has, all of which load local/public images without a private registry round-trip. |
| `CKV_K8S_40` Containers should run as a high UID | App (UID 999), node-exporter (UID 65534, after Phase 7) | UID 999 is Debian's own `useradd --system` allocation for the app image, not an arbitrary choice; 65534 (`nobody`) is node-exporter's own upstream default. Neither corresponds to anything a "higher" number would improve for this deployment. |
| `CKV_K8S_17`/`CKV_K8S_19` node-exporter shares host PID/network namespace | `monitoring/node-exporter/daemonset.yaml` | Inherent to what node-exporter is — reading host-level CPU/memory/filesystem metrics requires it. Not a misconfiguration; it's the tool's entire purpose. |
| `CKV_K8S_38` Prometheus's ServiceAccount token is mounted | `monitoring/prometheus/deployment.yaml` | Prometheus genuinely needs it — `kubernetes_sd_configs` service discovery calls the Kubernetes API directly. (Every *other* monitoring component that didn't need this was fixed in Phase 7 — see `docs/IMPLEMENTATION_PLAN.md` §4f.) |
| `CKV_K8S_35` Grafana admin password as an env var, not a file | `monitoring/grafana/deployment.yaml` | Grafana supports both; switching to the file-based pattern is a real, low-risk improvement that simply wasn't prioritized — it doesn't reduce risk much given the Secret is already the source either way (see §8 on where the real risk is: Terraform state, not this). |
| `CKV2_K8S_6` Monitoring pods lack an associated NetworkPolicy | All of `monitoring/` | Prometheus/Alertmanager need broad reach across namespaces to scrape and deliver webhooks; writing a precise per-component NetworkPolicy set for cluster-wide observability infra is real, valuable future work, scoped out here the same way Ingress/HPA/PDB were in Phase 3 — see that phase's reasoning for the general principle. |
| `CKV_DOCKER_8` Jenkins' own image runs as root | `docker/jenkins/Dockerfile` | Documented in the Dockerfile itself: the mounted Colima Docker socket is only accessible to root inside that container, and it's a single-user local CI sandbox, not a multi-tenant install. |

## 6. A real correction mid-project: NetworkPolicy enforcement

Phase 3 assumed kind's default CNI (kindnet) doesn't enforce `NetworkPolicy`, based on general kindnet history. Phase 5 disproved this empirically: Argo Rollouts' cross-namespace health probe was silently blocked until an explicit `namespaceSelector` rule was added. This CNI **does** enforce `NetworkPolicy` on this kind version. Both `values.yaml`'s and `networkpolicy.yaml`'s comments were corrected in place rather than left wrong — see `docs/IMPLEMENTATION_PLAN.md` §4d.

## 7. Secrets handling

| Secret | How it's created | Where it lives |
|---|---|---|
| Jenkins admin password | Generated locally (`openssl rand`), written to `docker/jenkins/.env` | Gitignored; never committed, never logged (confirmed by §4's gitleaks finding, which was the proof it stayed local) |
| Grafana admin password | Phase 6: one-off `openssl rand` + `kubectl create secret`. Phase 7: replaced with Terraform's `random_password` + `kubernetes_secret` | Terraform state (`terraform/environments/local/terraform.tfstate`), gitignored. **Known tradeoff**: the local backend stores state, and therefore this password, in plaintext on disk. Acceptable for a local demo credential with no real-world consequence; not acceptable practice for a real secret — a real deployment would use a remote backend with encryption at rest, or (better) Vault-issued dynamic credentials, which is exactly what Phase 8 demonstrates as the contrast. |
| GHCR push token | Not created — this project doesn't have one yet | The existing `gh` CLI token lacks `write:packages`; documented in `docs/IMPLEMENTATION_PLAN.md` §4a as a manual step for the user, never requested in chat. |
| App-level secrets | None exist — the app has no secrets today | `helm/devsecops-app` has no `Secret` resource; noted in `docs/IMPLEMENTATION_PLAN.md` §4b as deliberately deferred to Phase 8 rather than wiring up an unused Secret just to demonstrate the pattern in isolation. |

## 8. Known limitations

- **Offline/point-in-time vulnerability data.** Trivy's DB is downloaded at scan time but reflects whatever was published as of that moment — a scan from yesterday can miss a CVE disclosed today. Every scan run archived in `docs/evidence/` carries its own timestamp for this reason.
- **No remote state locking.** Terraform's local backend (§7) has no collaboration or locking support — fine for one developer, not for a team. Documented as a deliberate scope limit in `terraform/environments/local/versions.tf`.
- **In-memory, per-pod alert storage.** The app's `/webhooks/alerts` endpoint (this project's free local Alertmanager receiver) stores alerts in memory, per-pod — with more than one replica, only the pod that happened to receive the webhook has the record. Found and documented for real in Phase 6 (`docs/evidence/phase6-alert-firing-transcript.md`); not fixed, since this endpoint is explicitly a demo/debugging aid, not a claimed source of truth.
- **No image signing/provenance (cosign, SLSA, etc.)** — scanning catches known vulnerabilities, not tampering or supply-chain provenance. Scoped out as a real, valuable extension this one-person project didn't get to, not something assumed unnecessary.

## 9. Where to look for evidence

All raw scan output, console logs, and transcripts referenced above live in `docs/evidence/`, named `phaseN-*`. `docs/IMPLEMENTATION_PLAN.md` is the phase-by-phase narrative; this document is the cross-phase summary.
