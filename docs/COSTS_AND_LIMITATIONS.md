# Costs, licensing, and known limitations

## Cost: $0

Everything in this project runs locally and is free/open-source:

| Component | License | Cost |
|---|---|---|
| Jenkins | MIT | Free, self-hosted |
| Argo CD, Argo Rollouts | Apache 2.0 | Free, self-hosted |
| Prometheus, Alertmanager | Apache 2.0 | Free, self-hosted |
| Grafana | AGPLv3 (OSS edition) | Free, self-hosted |
| HashiCorp Vault | BUSL-1.1 (OSS use permitted) | Free, self-hosted (dev mode here) |
| Trivy, Gitleaks, Checkov | Apache 2.0 / MIT | Free |
| kind, kubectl, Helm, Terraform (OSS) | Apache 2.0 / MPL 2.0 | Free |
| GitHub (this repo) | — | Free (public repo) |
| GHCR (if/when exercised) | — | Free within GitHub's free tier for a personal account |

No cloud provider resources are created by anything in this repo. `terraform/` only ever targets the local kind cluster; there is no cloud provider block anywhere, and `terraform apply` never reaches outside `localhost`.

## Licensing notes

- **Vault's BUSL license**: HashiCorp's Business Source License permits free self-hosted use (which is exactly what this project does); it restricts offering Vault *as a competing managed service*, which doesn't apply here.
- **Grafana AGPLv3**: self-hosting and modifying for internal use is unrestricted; AGPL's network-use clause matters if you *distribute a modified version as a service to others*, which this project doesn't do.

## Hardware this was actually built and verified on

Apple M1, 8 GB RAM, Colima VM at 4 CPU / 5 GiB. This is the single biggest constraint on the architecture — see `docs/IMPLEMENTATION_PLAN.md` §1 for the full resource table and the running commentary throughout that document on what got trimmed, deferred, or made ephemeral (Jenkins) specifically because of it. If you have more RAM available, kube-prometheus-stack (the Operator-based chart most tutorials use) and an always-on Jenkins would both be reasonable choices this project deliberately avoided.

## Known limitations (consolidated — see `docs/SECURITY.md` §8 for the security-specific subset)

- **GHCR publish is wired but not exercised.** The existing `gh` CLI token lacks `write:packages`. The pipeline's publish stage gracefully no-ops to "image stays local" when the credential is absent — see `docs/IMPLEMENTATION_PLAN.md` §4a.
- **No remote Terraform state.** Local backend only — fine for one developer, not for a team (`docs/SECURITY.md` §8).
- **No centralized logging.** Prometheus provides metrics, not logs; there's no Loki/ELK here. The app's own structured JSON logging exists but isn't aggregated anywhere beyond `kubectl logs`.
- **Vault dev mode loses all configuration on pod restart** — not a production secrets manager, explicitly labeled as such everywhere it appears.
- **NodePort access is broken on this specific Colima setup** (TCP connects, never delivers data — a real, reproducible Colima quirk, not a bug in this project's manifests). `kubectl port-forward` is the documented workaround throughout.
- **In-memory, per-pod webhook/alert storage** in the app's `/webhooks/alerts` endpoint — a demo aid, not a reliable alert history.
- **No image signing or provenance** (cosign/SLSA) — vulnerability scanning only, no tamper-evidence.
- **Single-node kind cluster** means no real node-failure tolerance demo, and several brief-requested resources (HPA, PodDisruptionBudget, a real Ingress controller) were deliberately scoped out as meaningless or not-worth-the-RAM on this topology — see `docs/IMPLEMENTATION_PLAN.md` §4b for the itemized reasoning on each.
