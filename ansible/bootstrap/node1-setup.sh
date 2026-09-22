#!/usr/bin/env bash
# Prépare node-1 en control node Ansible.
# À exécuter EN ROOT dans une session SSM sur i-082cacf2f59f8ddd4.
# Idempotent : réexécutable sans effet de bord.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "à lancer en root (sudo bash)"; exit 1; }

echo "==> Paquets"
dnf install -y ansible-core git tmux jq

echo "==> Collections Ansible (absentes d'ansible-core)"
req="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/../requirements.yml"
if [[ -f $req ]]; then
  sudo -u ec2-user ansible-galaxy collection install -r "$req"
else
  sudo -u ec2-user ansible-galaxy collection install ansible.posix community.general ansible.utils
fi

echo "==> k9s (arm64)"
if ! command -v k9s >/dev/null; then
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/k9s.tar.gz" \
    https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_arm64.tar.gz
  tar -xzf "$tmp/k9s.tar.gz" -C "$tmp" k9s
  install -m 0755 "$tmp/k9s" /usr/local/bin/k9s
  rm -rf "$tmp"
fi

echo "==> Clé SSH du control node"
key=/home/ec2-user/.ssh/id_ed25519
install -d -m 700 -o ec2-user -g ec2-user /home/ec2-user/.ssh
if [[ ! -f $key ]]; then
  sudo -u ec2-user ssh-keygen -t ed25519 -N '' -C "ansible-control-node-1" -f "$key"
fi

echo "==> Vérifications"
printf '  arch     : %s\n' "$(uname -m)"
printf '  swap     : %s\n' "$(swapon --show --noheadings || echo 'aucun (attendu)')"
printf '  /mnt/efs : %s\n' "$(findmnt -n -o SOURCE,FSTYPE /mnt/efs 2>/dev/null || echo 'NON MONTÉ — bloquant')"
printf '  egress   : %s\n' "$(curl -fsS -m 5 -o /dev/null -w '%{http_code}' https://registry.k8s.io/ || echo 'KO')"

cat <<BANNER

──────────────────────────────────────────────────────────────────────────────
 Clé publique à déposer sur node-2 (i-0f11f75585a35e303)
 et node-3 (i-03f48443ef76c0707), via une session SSM sur chacun.

$(cat "$key.pub")

 Sur chaque worker, coller :

   sudo install -d -m 700 -o ec2-user -g ec2-user /home/ec2-user/.ssh
   echo '$(cat "$key.pub")' | sudo tee -a /home/ec2-user/.ssh/authorized_keys >/dev/null
   sudo chown ec2-user:ec2-user /home/ec2-user/.ssh/authorized_keys
   sudo chmod 600 /home/ec2-user/.ssh/authorized_keys

 Puis, depuis node-1 :  ansible-playbook playbooks/connectivity.yml
──────────────────────────────────────────────────────────────────────────────
BANNER
