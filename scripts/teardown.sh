#!/usr/bin/env bash
# Full teardown. Destructive -- deletes the cluster and all state in it,
# and (optionally) stops/removes Jenkins. Nothing here costs money, so
# there's no financial urgency; this is purely for reclaiming local
# RAM/disk.
set -euo pipefail
cd "$(dirname "$0")/.."

read -r -p "This deletes the devsecops-platform kind cluster and all its workloads. Continue? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted."
  exit 1
fi

echo "==> Deleting kind cluster"
kind delete cluster --name devsecops-platform || true

echo "==> Stopping Jenkins (volumes preserved -- use 'docker-compose down -v' in docker/jenkins to also wipe job history)"
(cd docker/jenkins && docker-compose stop) || true

echo "==> Done."
