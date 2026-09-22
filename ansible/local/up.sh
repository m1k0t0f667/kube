#!/usr/bin/env bash
# Crée les trois VM du cluster local à partir du gabarit unique.
#   ./local/up.sh
set -euo pipefail
cd "$(dirname "$0")/.."

for n in node-1 node-2 node-3; do
  if limactl list "$n" --format '{{.Name}}' >/dev/null 2>&1; then
    echo "==> $n existe déjà, démarrage si nécessaire"
    limactl start "$n" --tty=false >/dev/null 2>&1 || true
  else
    echo "==> création de $n"
    # node-1 porte les redirections de ports vers l'hôte
    tpl=local/lima-node.yaml
    [[ "$n" == "node-1" ]] && tpl=local/lima-node-1.yaml
    limactl start --name="$n" --tty=false "$tpl"
  fi
done

echo
limactl list
echo
./local/inventory.sh
