# ADR-002 — Ansible + kubeadm, lancés depuis node-1

- **Statut :** Acceptée
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12)

## Contexte

Le sujet impose Ansible et demande, en soutenance, de montrer « la responsabilité de
chaque composant » du cluster. Il faut choisir une distribution Kubernetes et l'endroit
d'où Ansible s'exécute.

- Port 22 fermé depuis Internet, security group non modifiable, aucune key pair (C1).
- Accès aux VM par SSM uniquement, sans port-forwarding ni `SendCommand` (C2).
- Les nœuds se joignent entre eux sur tous les ports (règle `self` du security group).
- Instances `t4g.medium` : arm64, 2 vCPU, 4 Go de RAM (C4).

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| **kubeadm** | Outil de référence ; chaque composant (etcd, apiserver, scheduler, kubelet) est visible et configurable ; flags OIDC de l'apiserver accessibles | Plus de travail d'installation |
| k3s | Léger, installation en une commande | Composants fusionnés dans un binaire : moins démonstratif ; s'éloigne d'un cluster standard |
| RKE2 | Durci par défaut | Même opacité que k3s, plus lourd |
| Ansible depuis un poste de dev | Usage classique | Impossible : pas de SSH entrant (C1) ni de tunnel SSM (C2) |
| **Ansible depuis node-1** | Seul nœud joignable par SSM et capable de joindre les deux autres en SSH intra-VPC | node-1 cumule les rôles (ADR-003) |

## Décision

- **kubeadm**, piloté par des rôles Ansible : `common`, `containerd`, `efs`,
  `control-plane`, `worker`, `cni`, `traefik`, `cert-manager`, `argocd`.
- **node-1 est le control node Ansible** (`ansible_connection: local`), et joint node-2 et
  node-3 en SSH par leurs IP privées fixes.
- `reset.yml` détruit le cluster, `site.yml` le reconstruit.
- Ansible s'arrête à l'amorçage d'ArgoCD : tout le reste est déployé par GitOps (ADR-010).

## Conséquences

- La démo « provisionner un cluster neuf » se fait depuis une session SSM sur node-1,
  dans `tmux` pour survivre à une coupure de session.
- Git est le seul canal de transfert de fichiers vers node-1 : `git push` depuis le poste,
  `git pull` sur node-1.
- La clé SSH de node-1 doit être déposée une fois à la main sur node-2 et node-3 via SSM
  (`ansible/bootstrap/`). C'est l'unique étape manuelle, à documenter.
- Toute image utilisée doit exister en arm64 (C4).

## En soutenance

**« Pourquoi kubeadm et pas k3s ? »** kubeadm monte un cluster standard dont on voit chaque
composant, ce que la soutenance demande d'expliquer, et il donne accès aux flags OIDC de
l'apiserver. **« Pourquoi Ansible tourne sur le cluster ? »** Parce qu'aucun SSH ni tunnel
n'entre depuis l'extérieur : node-1 est le seul point d'où l'on atteint les trois nœuds.
