# ansible/ — provisionnement du cluster

**Ce playbook s'exécute depuis node-1, pas depuis un poste de développement.**
Le port 22 est fermé depuis Internet et le security group n'est pas modifiable :
il n'existe aucun chemin SSH entrant. Voir [`bootstrap/README.md`](bootstrap/README.md)
pour la mise en place, et `docs/contraintes-et-outillage.md` pour les preuves.

```
ansible.cfg              connexion SSH, become, pipelining
requirements.yml         collections (absentes d'ansible-core)
inventory/hosts.yml      3 nœuds, IP privées fixes, node-1 en connection: local
group_vars/all.yml       versions, CIDR, EIP, EFS — les constantes de l'infra
bootstrap/               procédure SSM → control node (une seule fois)
playbooks/
  connectivity.yml       pré-vol : arm64, RAM, EFS, egress, CIDR
  restart-check.yml      reprise après extinction nocturne
site.yml                 provisionnement complet
reset.yml                teardown (préserve /mnt/efs)
roles/
  common                 swap, sysctl, modules, kubeadm/kubelet/kubectl
  containerd             runtime + SystemdCgroup
  efs                    arborescence et droits (remplace les Access Points)
  control-plane          kubeadm init, kubeconfig de secours sur EFS, untaint
  worker                 kubeadm join
  cni                    Helm + Cilium (eBPF, Hubble, remplace kube-proxy)
  ingress-nginx          DaemonSet hostPort 80/443 sur le nœud d'entrée
  cert-manager           issuers internal-ca + letsencrypt (AWS uniquement)
  argocd                 amorçage GitOps, Ingress TLS
```

## Utilisation

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/connectivity.yml     # doit passer intégralement
tmux new -s kube
ansible-playbook site.yml
```

`tmux` n'est pas un confort : une session SSM qui tombe tue le playbook en cours.

## État de validation

Validé de bout en bout sur le cluster local (voir `local/README.md`) :

| | Résultat |
|---|---|
| `site.yml` sur 3 nœuds neufs | 3 nœuds `Ready`, 23 pods `Running` |
| UI ArgoCD en HTTPS | 200, certificat signé par la CA interne |
| Idempotence (2ᵉ passage) | `changed=0` sur les 3 nœuds |
| Cycle `reset.yml` → `site.yml` | reproductible, EFS préservé |
| DNS, Service ClusterIP, pod-to-pod inter-nœuds | OK |
| Anti-affinité stricte sur 3 replicas | 1 pod par nœud |

Versions épinglées et vérifiées, toutes en arm64 : Kubernetes **1.33.4**,
containerd **2.2.7** (dépôt `amazonlinux`), Cilium **1.20.2**, Helm **v4.3.0**,
ingress-nginx **4.15.1**, cert-manager **v1.21.2**, ArgoCD **10.9.2**.

## Reste à faire

- Dépôts GitOps `kube-infra` / `kube-app` et App-of-Apps : tout le reste
  (Keycloak, dex, Harbor, monitoring, application) passe par ArgoCD, plus par Ansible
- Patch OIDC de l'apiserver (`roles/control-plane`, exigence #13) — après que dex
  réponde en TLS valide, jamais avant : voir risque #1 du README racine
- Rejouer sur les VM AWS avec `inventory/hosts.yml`
