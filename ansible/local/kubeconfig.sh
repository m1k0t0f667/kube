#!/usr/bin/env bash
# Récupère le kubeconfig du cluster local et l'adapte à macOS.
#
# Lima redirige automatiquement les ports que l'invité écoute sur 0.0.0.0 :
# l'API server de node-1 est donc déjà joignable sur 127.0.0.1:6443 depuis l'hôte.
#
# Le certificat de l'API server ne porte que 10.96.0.1 et l'IP interne du nœud.
# Plutôt que de le régénérer, on garde 127.0.0.1 comme adresse de connexion et
# on indique à kubectl de vérifier le certificat contre le nom réel du serveur
# (tls-server-name). Aucune modification du cluster n'est nécessaire.
#
#   ./local/kubeconfig.sh && export KUBECONFIG=$PWD/local/kubeconfig
set -euo pipefail
cd "$(dirname "$0")/.."

out=local/kubeconfig
node_ip=$(limactl shell node-1 -- bash -c \
  "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null)

limactl shell node-1 -- sudo cat /etc/kubernetes/admin.conf 2>/dev/null > "$out"
chmod 600 "$out"

KUBECONFIG="$out" kubectl config set-cluster kubernetes \
  --server="https://127.0.0.1:6443" \
  --tls-server-name="$node_ip" >/dev/null

echo "==> $out   (API $node_ip via 127.0.0.1:6443)"
echo "    export KUBECONFIG=$PWD/$out"
echo
KUBECONFIG="$out" kubectl get nodes
