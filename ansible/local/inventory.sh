#!/usr/bin/env bash
# Génère inventory/local.yml depuis l'état réel des VM Lima.
# Les IP user-v2 (192.168.104.x) sont attribuées dynamiquement : ce fichier
# est donc régénéré à chaque création de VM, jamais édité à la main.
set -euo pipefail
cd "$(dirname "$0")/.."

out=inventory/local.yml
key="$HOME/.lima/_config/user"

node_ip() {  # IP joignable par les autres VM
  limactl shell "$1" bash -c \
    "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | grep -v '^192.168.5.15$' | head -1" 2>/dev/null
}
ssh_port() { limactl list "$1" --format '{{.SSHLocalPort}}'; }
ssh_user() { limactl shell "$1" whoami 2>/dev/null; }

u=$(ssh_user node-1)

{
  echo "---"
  echo "# GÉNÉRÉ par local/inventory.sh — ne pas éditer."
  echo "# Cluster local Lima/QEMU. Équivalent de inventory/hosts.yml pour AWS."
  echo "all:"
  echo "  vars:"
  echo "    ansible_user: $u"
  echo "    ansible_ssh_private_key_file: $key"
  echo "    ansible_ssh_common_args: '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'"
  echo "    vpc_cidr: 192.168.104.0/24"
  echo "    min_node_ram_mb: 2800"
  echo "    ingress_domain: 127.0.0.1.sslip.io"
  echo "    acme_enabled: false"
  echo "    ingress_cluster_issuer: internal-ca"
  echo "  children:"
  echo "    control_plane:"
  echo "      hosts:"
  echo "        node-1:"
  echo "          ansible_host: 127.0.0.1"
  echo "          ansible_port: $(ssh_port node-1)"
  echo "          node_ip: $(node_ip node-1)"
  echo "    workers:"
  echo "      hosts:"
  for n in node-2 node-3; do
    echo "        $n:"
    echo "          ansible_host: 127.0.0.1"
    echo "          ansible_port: $(ssh_port "$n")"
    echo "          node_ip: $(node_ip "$n")"
  done
} > "$out"

echo "==> $out"
cat "$out"
