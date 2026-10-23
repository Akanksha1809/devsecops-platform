#!/usr/bin/env bash
# Brings up the whole platform from nothing: kind cluster, Argo CD,
# Argo Rollouts, then the Terraform bootstrap (Argo CD Applications +
# Vault config + Grafana secret). Every command here is lifted directly
# from docs/SETUP.md, which this script exists to make copy-paste-free,
# not to introduce new steps.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Creating kind cluster"
kind create cluster --config kubernetes/kind-config.yaml

echo "==> Building and loading the app image"
docker build -t devsecops-platform-app:dev .
kind load docker-image devsecops-platform-app:dev --name devsecops-platform

echo "==> Installing Argo CD (non-HA, server-side apply)"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side
kubectl -n argocd scale deployment argocd-dex-server argocd-applicationset-controller argocd-notifications-controller --replicas=0 || true
kubectl -n argocd wait --for=condition=Available deployment/argocd-server deployment/argocd-repo-server deployment/argocd-redis --timeout=180s

echo "==> Installing Argo Rollouts"
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml --server-side
kubectl -n argo-rollouts wait --for=condition=Available deployment/argo-rollouts --timeout=90s

echo "==> Terraform bootstrap: Argo CD Applications + Grafana secret"
(cd terraform/environments/local && terraform init -input=false && terraform apply -auto-approve)

cat <<'EOF'

==> Core bootstrap complete.

Argo CD admin password:
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

Vault needs its own apply once it's synced and running (its root token
is regenerated on every pod start, so this can't be scripted blindly):
  kubectl -n vault port-forward svc/vault 18200:8200 &
  export VAULT_ADDR=http://localhost:18200
  export VAULT_TOKEN=$(kubectl -n vault logs deployment/vault --tail=50 | grep "Root Token:" | awk '{print $NF}')
  (cd terraform/environments/local && terraform apply)

See docs/SETUP.md for accessing each component.
EOF
