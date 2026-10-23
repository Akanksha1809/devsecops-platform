# Setup

Tested on: Apple Silicon Mac, macOS 15, Docker via Colima, 8 GB RAM. See `docs/IMPLEMENTATION_PLAN.md` §1 for the exact resource math this project was built against — if you have less than ~2 GB of headroom free in whatever runs your containers, stop something first (this doc's teardown commands) before bringing more of the stack up.

## Prerequisites

- Docker (this project was built against Colima on macOS; Docker Desktop or native Linux Docker should work identically for everything except the Colima-specific quirks noted in `docs/TROUBLESHOOTING.md`)
- `kubectl`, `kind`, `helm`, `terraform` (>= 1.5), the `argocd` CLI, `kubectl-argo-rollouts` plugin
- `git`, `gh` (optional, used to create/push the GitHub repo)
- Python 3.12 (for local app development outside Docker)

Nothing above requires a paid account or license. See `docs/COSTS_AND_LIMITATIONS.md`.

## 1. Clone and verify the app locally (no cluster needed)

```bash
make install
make test      # 23 tests, ~99% coverage
make run       # http://localhost:8000
```

## 2. Create the kind cluster

```bash
kind create cluster --config kubernetes/kind-config.yaml
docker build -t devsecops-platform-app:dev .
kind load docker-image devsecops-platform-app:dev --name devsecops-platform
```

## 3. Install Argo CD and Argo Rollouts

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side
kubectl -n argocd scale deployment argocd-dex-server argocd-applicationset-controller argocd-notifications-controller --replicas=0
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml --server-side
```

Get the initial Argo CD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## 4. Bootstrap everything else with Terraform

This creates the Argo CD `Application` objects for dev/staging/monitoring/vault, and the Grafana admin Secret. From this point on, Argo CD reconciles the actual workloads — this step runs once (or whenever you deliberately change the bootstrap config itself).

```bash
cd terraform/environments/local
terraform init
terraform plan
terraform apply
```

Argo CD will then sync `devsecops-dev`, `monitoring`, and `vault` automatically. `devsecops-app-staging` will show `OutOfSync` until you explicitly promote it — see below.

## 5. Bootstrap Vault's own configuration

Vault dev mode generates a new root token on every pod start — it's never a fixed value and never committed. Fetch it fresh:

```bash
kubectl -n vault port-forward svc/vault 18200:8200 &
export VAULT_ADDR=http://localhost:18200
export VAULT_TOKEN=$(kubectl -n vault logs deployment/vault --tail=50 | grep "Root Token:" | awk '{print $NF}')
cd terraform/environments/local
terraform apply   # the same apply from step 4 also creates Vault's mount/secret/role/audit device
```

## 6. Promote to staging (the GitOps promotion gate)

```bash
argocd login localhost:8080 --username admin --password <from step 3> --insecure
argocd app sync devsecops-app-staging
```

## 7. Run Jenkins (only when actively building — see the RAM note below)

```bash
cd docker/jenkins
cp .env.example .env   # set JENKINS_ADMIN_PASSWORD yourself
docker-compose up -d
```

UI at `http://localhost:8080`. The pipeline job polls GitHub every 5 minutes (no webhook — Jenkins is on localhost, GitHub can't reach it). Trigger a build manually from the UI, or:

```bash
curl -u admin:<password> -X POST "http://localhost:8080/job/devsecops-platform-pipeline/buildWithParameters?PUBLISH_IMAGE=false"
```

**Stop it when you're done building** — this project treats Jenkins as ephemeral, not always-on, specifically because of the RAM budget (`docs/IMPLEMENTATION_PLAN.md` §1):

```bash
docker-compose stop
```

## Accessing things

| What | How |
|---|---|
| App | `kubectl -n devsecops-dev port-forward svc/devsecops-app 8000:8000` — **not** the NodePort, which hits a real Colima port-forwarding bug; see `docs/TROUBLESHOOTING.md` |
| Argo CD UI | `kubectl -n argocd port-forward svc/argocd-server 8080:443` → `https://localhost:8080` |
| Grafana | `kubectl -n monitoring port-forward svc/grafana 3000:3000` — admin password from the Secret Terraform created in step 4 |
| Prometheus | `kubectl -n monitoring port-forward svc/prometheus 9090:9090` |
| Vault | `kubectl -n vault port-forward svc/vault 8200:8200` |
| Jenkins | `http://localhost:8080` while the container is running |

## Full teardown

```bash
kind delete cluster --name devsecops-platform
cd docker/jenkins && docker-compose down -v
```

This deletes everything — the cluster, all its workloads, Jenkins' persisted job history. Nothing here costs money, so there's no cleanup urgency beyond reclaiming local RAM/disk.
