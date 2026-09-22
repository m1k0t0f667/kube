#!/usr/bin/env bash
# Expose l'Ingress du cluster local sur l'hôte macOS.
#
# Pourquoi un tunnel SSH et pas les portForwards de Lima :
# Cilium implémente hostPort entièrement en eBPF — aucune socket n'est en écoute
# sur le port 80 du nœud, alors que le port répond. Lima détecte les ports à
# rediriger en surveillant les sockets du invité : il ne voit donc rien.
# Un tunnel SSH fonctionne parce que la connexion part de l'intérieur du invité,
# là où le programme eBPF l'intercepte.
#
# Ports hôte non privilégiés : 80 et 443 sont souvent déjà pris sur macOS
# (OrbStack, Docker Desktop…).
#
#   ./local/expose.sh          ouvre les tunnels
#   ./local/expose.sh --stop   les ferme
set -euo pipefail

HTTP_PORT=8080
HTTPS_PORT=8443
PIDFILE="${TMPDIR:-/tmp}/lima-kube-expose.pid"

stop() {
  [[ -f $PIDFILE ]] && { kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; }
  echo "tunnels fermés"
}

[[ "${1:-}" == "--stop" ]] && { stop; exit 0; }

stop >/dev/null 2>&1 || true

node_ip=$(limactl shell node-1 -- bash -c \
  "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null)

# --format=config produit un bloc ssh_config ; --format=args contient des
# guillemets qui ne survivent pas au découpage du shell.
cfg="${TMPDIR:-/tmp}/lima-node-1.ssh_config"
limactl show-ssh --format=config node-1 2>/dev/null > "$cfg"

ssh -F "$cfg" -N -f -o ExitOnForwardFailure=yes \
    -L "${HTTP_PORT}:${node_ip}:80" \
    -L "${HTTPS_PORT}:${node_ip}:443" \
    lima-node-1

pgrep -f "${HTTP_PORT}:${node_ip}:80" > "$PIDFILE" 2>/dev/null || true

cat <<BANNER
Ingress exposé (node-1 = ${node_ip})

  http://<hôte>.127.0.0.1.sslip.io:${HTTP_PORT}/
  https://<hôte>.127.0.0.1.sslip.io:${HTTPS_PORT}/

Équivalent AWS : http(s)://<hôte>.15.224.60.53.sslip.io/  (ports 80/443)
Fermer : ./local/expose.sh --stop
BANNER
