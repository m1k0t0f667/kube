# Architecture — LLD (détail) — v1

Adresses, ports, versions, volumes et ordre de déploiement. La vue d'ensemble est dans le
[HLD](hld.md), les droits AWS et leurs preuves dans
[contraintes-et-outillage.md](../contraintes-et-outillage.md).

Chaque élément porte un statut :

- **en place** : déployé par `ansible/site.yml`, vérifié sur le cluster AWS ;
- **prévu** : décidé (arbitrages J0, KUB-66), pas encore déployé ;
- **à définir** : pas encore décidé, le ticket concerné est indiqué.

Valeurs de référence : `ansible/inventory/hosts.yml` et `ansible/inventory/group_vars/all.yml`.
En cas d'écart, ce sont ces fichiers qui font foi.

---

## 1. Machines

Région `eu-west-3`, une seule AZ (`eu-west-3a`), un seul subnet. Instances `t4g.medium` :
arm64, 2 vCPU, 4096 MiB, 30 Go de disque non extensible. Amazon Linux 2023.

| Nœud | Instance | IP privée | IP publique | Rôle Kubernetes | Particularités |
|---|---|---|---|---|---|
| `node-1` | i-082cacf2f59f8ddd4 | 10.0.0.80 | 15.224.60.53 (EIP fixe) | control-plane + worker | taint control-plane retiré ; label `node-role.kubernetes.io/ingress=true` ; control node Ansible ; etcd |
| `node-2` | i-0f11f75585a35e303 | 10.0.0.17 | change à chaque démarrage | worker | — |
| `node-3` | i-03f48443ef76c0707 | 10.0.0.143 | change à chaque démarrage | worker | — |

Le nom de nœud Kubernetes est forcé à `node-N` par kubeadm (`nodeRegistration.name`), pour
que l'anti-affinité sur `kubernetes.io/hostname` soit lisible.

## 2. Réseau

| Plage | Valeur | Usage |
|---|---|---|
| VPC | 10.0.0.0/24 | IP des nœuds |
| Pods | 10.244.0.0/16 | IPAM Cilium `cluster-pool` |
| Services | 10.96.0.0/12 | ClusterIP |
| API server | 10.0.0.80:6443 | `controlPlaneEndpoint` ; SAN : 10.0.0.80, 15.224.60.53, `15.224.60.53.sslip.io` |

### Flux

| Source | Destination | Port | Usage | Statut |
|---|---|---|---|---|
| Internet | `node-1` | 80/tcp | hostPort Traefik : HTTP, redirection HTTPS, challenge Let's Encrypt | en place |
| Internet | `node-1` | 443/tcp | hostPort Traefik : HTTPS | en place |
| VPC | tout nœud | 30080/tcp, 30443/tcp | NodePort Traefik (exigence du sujet) | en place |
| `node-1` | `node-2`, `node-3` | 22/tcp | SSH d'Ansible | en place |
| VPC | `node-1` | 6443/tcp | API server | en place |
| nœuds | EFS | 2049/tcp | NFS chiffré en TLS (efs-utils) | en place |
| nœuds | Internet | 443/tcp | paquets, charts Helm, images, GitHub, Let's Encrypt, SSM | en place |
| Internet | tout nœud | 22, 6443 | **bloqué** par le security group, non modifiable | — |

Le poste de développement n'accède aux nœuds que par une session SSM sur `node-1`. Il n'y a
ni SSH depuis Internet, ni port-forwarding SSM.

## 3. Socle

| Composant | Version | Remarque | Statut |
|---|---|---|---|
| Kubernetes (kubeadm) | 1.33.4 | control-plane unique | en place |
| containerd | 2.2.7 | dépôt `amazonlinux`, `SystemdCgroup` | en place |
| Cilium | 1.20.2 | `kubeProxyReplacement: true` (kube-proxy non installé), Hubble + relay | en place |
| Helm | v4.3.0 | installé sur `node-1` | en place |
| Montage EFS | — | `/mnt/efs`, posé par l'école via `fstab` | en place |

## 4. Composants

### Déployés par Ansible

| Namespace | Composant | Chart | Version | Exposition | Statut |
|---|---|---|---|---|---|
| `kube-system` | Cilium | `cilium/cilium` | 1.20.2 | — | en place |
| `traefik` | Traefik | `traefik/traefik` | 41.6.0 (Traefik v3.7.13) | DaemonSet sur `node-1` | en place |
| `cert-manager` | cert-manager | `jetstack/cert-manager` | v1.21.2 | — | en place |
| `argocd` | ArgoCD | `argo/argo-cd` | 10.9.2 | `argocd.15.224.60.53.sslip.io` | en place |

### Déployés par ArgoCD

Décidés aux arbitrages J0, pas encore déployés. Namespaces, versions et noms d'hôte : à
définir dans leurs tickets.

| Composant | Rôle | Stockage | Statut |
|---|---|---|---|
| Keycloak + dex | identité, OIDC | EFS | prévu |
| VictoriaMetrics + Grafana | métriques, alertes | local-path | prévu |
| Loki + Alloy | logs | local-path | prévu |
| Headlamp | dashboard | — | prévu |
| Sealed Secrets | secrets dans Git | clé sauvegardée sur EFS | prévu |
| ValidatingAdmissionPolicy | contrôle d'admission | — | prévu |
| Application + base de données | charge de travail | EFS | prévu, moteur de base **à définir** (J0-07, KUB-61) |

## 5. Exposition

| Élément | Valeur |
|---|---|
| Domaine | `<service>.15.224.60.53.sslip.io` |
| Entrypoint `web` | conteneur 8000 → hostPort 80, NodePort 30080 |
| Entrypoint `websecure` | conteneur 8443 → hostPort 443, NodePort 30443 |
| IngressClass | `traefik`, classe par défaut |
| Redirection HTTP → HTTPS | middleware `traefik/redirect-https`, activé Ingress par Ingress avec l'annotation `traefik.ingress.kubernetes.io/router.middlewares: traefik-redirect-https@kubernetescrd` |
| Mise à jour du DaemonSet | `maxSurge: 0`, `maxUnavailable: 1` : le hostPort empêche deux pods côte à côte |

Un Ingress exposé publiquement porte deux annotations : le middleware de redirection et
`cert-manager.io/cluster-issuer: letsencrypt`.

## 6. Certificats

| ClusterIssuer | Usage | Statut |
|---|---|---|
| `selfsigned` | signe la CA interne | en place |
| `internal-ca` | TLS de ce qui ne sort pas du cluster | en place |
| `letsencrypt` | tout ce qui est exposé publiquement, challenge HTTP-01 sur la classe `traefik` | en place, serveur **staging** |

Le passage au serveur Let's Encrypt de production se fait dans `acme_server` de
`inventory/hosts.yml`. Quota : 50 certificats par domaine et par semaine.

## 7. Stockage

| Données | Support | Emplacement | Statut |
|---|---|---|---|
| etcd | disque local de `node-1` | `/var/lib/etcd` | en place |
| Base de données de l'app | EFS, PV statique | `/mnt/efs/mysql` (UID 1001) | répertoire en place, moteur à définir |
| Sauvegardes | EFS, PV statique | `/mnt/efs/backups` (UID 1001) | répertoire en place |
| Base de Keycloak | EFS, PV statique | `/mnt/efs/keycloak-pg` (UID 1001) | répertoire en place |
| Clé Sealed Secrets, kubeconfig de secours | EFS | `/mnt/efs/bootstrap` (root, 0700) | répertoire en place |
| Métriques, logs | local-path | disque de chaque nœud | prévu |

EFS : `fs-038bf0f49474a6a1d`. Les répertoires sont créés et leurs droits posés par le
rôle Ansible `efs`, qui remplace les Access Points que le compte ne peut pas créer.

**Écarts à traiter** (relevés pendant la rédaction, non corrigés) :

- Le rôle `efs` crée encore `harbor/` et `harbor-pg/`, alors que le registry retenu est
  GHCR.
- Le répertoire `mysql/` suppose MySQL, alors que le moteur de base n'est pas tranché
  (KUB-61).

## 8. Ordre de déploiement

`ansible-playbook site.yml`, lancé depuis `node-1` :

| Étape | Tag | Cible | Rôles |
|---|---|---|---|
| 1. Socle | `socle` | 3 nœuds | `common`, `containerd`, `efs` |
| 2. Control plane | `control-plane` | `node-1` | `control-plane` |
| 3. Workers | `workers` | `node-2`, `node-3` | `worker` |
| 4. Réseau | `cni` | `node-1` | `cni` (Cilium) |
| 5. Entrée | `ingress` | `node-1` | `traefik` |
| 6. PKI | `pki` | `node-1` | `cert-manager` |
| 7. GitOps | `gitops` | `node-1` | `argocd` |

Ensuite, ArgoCD prend le relais avec le pattern App-of-Apps (prévu). Teardown :
`ansible-playbook reset.yml -e confirm=oui`, qui préserve `/mnt/efs`.
