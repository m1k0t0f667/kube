#!/usr/bin/env bash
# Détruit les trois VM. --stop pour seulement les arrêter.
#   ./local/down.sh [--stop]
set -euo pipefail

for n in node-1 node-2 node-3; do
  limactl list "$n" --format '{{.Name}}' >/dev/null 2>&1 || continue
  if [[ "${1:-}" == "--stop" ]]; then
    echo "==> arrêt de $n"; limactl stop -f "$n" >/dev/null 2>&1 || true
  else
    echo "==> suppression de $n"; limactl delete -f "$n" >/dev/null 2>&1 || true
  fi
done
limactl list
