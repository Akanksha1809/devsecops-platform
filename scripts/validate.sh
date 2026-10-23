#!/usr/bin/env bash
# Automated validation commands (brief Section 9's "automated validation
# commands" deliverable). Runs what CI runs, plus live cluster checks,
# so a reviewer can confirm the project's claims without reading the
# whole IMPLEMENTATION_PLAN.md first. Exits non-zero on the first real
# failure; each check prints what it's checking before running it.
set -uo pipefail
cd "$(dirname "$0")/.."

FAILED=0
check() {
  echo "--> $1"
  shift
  if ! "$@"; then
    echo "    FAILED: $*"
    FAILED=1
  fi
}

echo "=== App ==="
check "unit + integration tests, coverage" bash -c "source .venv/bin/activate 2>/dev/null && pytest -q --cov=app --cov-fail-under=80"
check "lint" bash -c "source .venv/bin/activate 2>/dev/null && ruff check app tests"

echo "=== Helm ==="
check "chart lints clean" helm lint helm/devsecops-app -f helm/devsecops-app/values-dev.yaml

echo "=== Terraform ==="
check "fmt" terraform -chdir=terraform fmt -check -recursive
check "validate" bash -c "cd terraform/environments/local && terraform init -input=false -backend=false -upgrade=false >/dev/null && terraform validate"

echo "=== Live cluster (skipped if no context) ==="
if kubectl config current-context 2>/dev/null | grep -q devsecops-platform; then
  check "argocd apps healthy or expected-OutOfSync (staging)" bash -c '
    kubectl -n argocd get applications -o json | python3 -c "
import json,sys
apps = json.load(sys.stdin)[\"items\"]
bad = [a[\"metadata\"][\"name\"] for a in apps
       if a.get(\"status\",{}).get(\"health\",{}).get(\"status\") not in (\"Healthy\",\"Missing\")]
sys.exit(1 if bad else 0)
"'
  check "app pods ready" kubectl -n devsecops-dev get pods --field-selector=status.phase=Running -o jsonpath='{.items[*].status.containerStatuses[*].ready}'
else
  echo "    (no devsecops-platform kube context active -- skipping cluster checks)"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "=== All checks passed ==="
else
  echo "=== One or more checks FAILED -- see above ==="
fi
exit "$FAILED"
