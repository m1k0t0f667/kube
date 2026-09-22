# Cluster local — banc d'essai des rôles Ansible

Trois VM Lima/QEMU sous **Amazon Linux 2023 arm64**, la même distribution et la même
architecture que les VM de l'école. Les rôles de `site.yml` s'y exécutent **sans une
seule branche conditionnelle**.

Objectif : itérer sur les rôles et prouver leur idempotence sans dépendre des sessions
SSM ni des horaires d'allumage du compte AWS.

## Correspondance avec AWS

| | AWS | Local |
|---|---|---|
| Distribution | Amazon Linux 2023 | **identique** |
| Architecture | arm64 (t4g.medium) | **identique** |
| vCPU | 2 | **identique** |
| Disque | 30 Go | **identique** |
| `containerd` | dépôt `amazonlinux` | **identique** |
| RAM | 4096 Mio | 3072 Mio (contrainte des 16 Go de l'hôte) |
| Noyau | 6.18 (AMI EC2) | 6.1 (image KVM) |
| Réseau | VPC 10.0.0.0/24 | user-v2 192.168.104.0/24 |
| Stockage partagé | Amazon EFS | export NFS depuis node-1 |
| Accès | session SSM, Ansible sur node-1 | SSH direct, Ansible sur l'hôte |

Les deux dernières lignes sont les seules divergences structurelles. Le montage
`/mnt/efs` est en NFSv4 des deux côtés, avec les **mêmes options client**
(`_netdev,hard,noresvport`) : le rôle `efs` ne voit aucune différence.

## Pièges rencontrés, et pourquoi la configuration est ainsi

- **`vmType` doit rester `qemu`.** L'image `al2023-kvm-*` ne démarre pas sous Apple
  Virtualization Framework : la VM tourne mais `sshd` ne monte jamais. Testé avec et
  sans réseau secondaire, même résultat. Sous QEMU, SSH répond en moins de 10 s.
- **Réseau `lima: user-v2`.** C'est le seul réseau Lima qui permette le VM-à-VM sans
  `socket_vmnet` ni droits root sur l'hôte. Sans lui, chaque VM voit `192.168.5.15`
  et aucune ne peut joindre les autres.
- **Disque à 30 GiB minimum.** L'image AL2023 fait 25 Gio et Lima ne sait pas rétrécir
  un disque ; toute valeur inférieure fait échouer la création.
- **Export NFS en `insecure`.** Amazon EFS accepte les ports source non privilégiés,
  un serveur NFS standard non. Sans cette option, le `noresvport` côté client — celui
  que le `fstab` de l'école utilise — est rejeté.
- **Les IP sont dynamiques.** `node-1` n'obtient pas toujours `.1`. L'inventaire est
  donc **généré** par `inventory.sh`, jamais écrit à la main.

## Accéder aux services depuis macOS

Le réseau des VM (`192.168.104.0/24`) n'est pas joignable depuis l'hôte.

**kubectl** — l'API server a une socket en écoute, Lima la redirige :

```bash
./local/kubeconfig.sh
export KUBECONFIG=$PWD/local/kubeconfig
kubectl get nodes
```

**Les services HTTP/HTTPS** — via un tunnel SSH :

```bash
./local/expose.sh
curl http://demo.127.0.0.1.sslip.io:8080/
```

`*.127.0.0.1.sslip.io` résout vers `127.0.0.1` : le schéma d'accès est donc
**identique à AWS**, aux ports près.

| | AWS | Local |
|---|---|---|
| Domaine | `argocd.15.224.60.53.sslip.io` | `argocd.127.0.0.1.sslip.io` |
| Ports | 80 / 443 | 8080 / 8443 |

Deux raisons aux ports non privilégiés : sur macOS le 80 est souvent déjà pris
(OrbStack l'occupait ici), et Lima ne redirige pas les ports privilégiés.

### Pourquoi un tunnel SSH et pas les portForwards de Lima

**Cilium implémente `hostPort` entièrement en eBPF.** Aucune socket n'est en
écoute sur le port 80 du nœud — `ss -tlnp` ne montre rien — alors que le port
répond en HTTP 200. Lima détecte les ports à rediriger en surveillant les
sockets du invité : il ne peut donc rien voir. Un tunnel SSH fonctionne parce
que la connexion part de l'intérieur du invité, là où eBPF l'intercepte.

## Utilisation

```bash
./local/up.sh                                              # crée les 3 VM + l'inventaire
ansible-playbook -i inventory/local.yml local/efs-server.yml   # émule l'EFS
ansible-playbook -i inventory/local.yml playbooks/connectivity.yml
ansible-playbook -i inventory/local.yml site.yml --tags socle
```

Test d'idempotence — le second passage doit afficher `changed=0` partout :

```bash
ansible-playbook -i inventory/local.yml site.yml --tags socle
```

Repartir de zéro :

```bash
./local/down.sh          # détruit
./local/down.sh --stop   # arrête seulement
```

## Résultats mesurés

```
reset.yml → site.yml        3 nœuds Ready, 23 pods Running
2ᵉ passage de site.yml      changed=0 sur les 3 nœuds
DNS / Service / pod-to-pod  OK, routage Cilium inter-nœuds
anti-affinité 3 replicas    1 pod par nœud
UI ArgoCD depuis macOS      HTTP 200, certificat signé par kube-internal-ca
```

### Composants déployés

| Namespace | Contenu |
|---|---|
| `kube-system` | Cilium (eBPF, kube-proxy remplacé), CoreDNS, etcd, apiserver, scheduler, controller-manager, Hubble |
| `ingress-nginx` | Ingress NGINX, DaemonSet hostPort 80/443 sur node-1 |
| `cert-manager` | cert-manager + issuers `selfsigned` et `internal-ca` |
| `argocd` | ArgoCD (dex embarqué et notifications désactivés) |

Accès : `https://argocd.127.0.0.1.sslip.io:8443/`, identifiant `admin`, mot de
passe dans le secret `argocd-initial-admin-secret` (affiché en fin de `site.yml`).

### Bugs que seul le cycle teardown/rebuild a révélés

- **`/etc/kubernetes` absent après `reset.yml`** — le premier passage fonctionnait
  car le paquet `kubeadm` créait le répertoire ; la reconstruction échouait.
  Aurait cassé la démo live de provisioning en soutenance.
- **Tâche morte dans `common`** écrivant `/etc/kubernetes/kubelet-gc.conf` : le
  kubelet lit `/var/lib/kubelet/config.yaml`, ce fichier n'avait aucun effet.
- **Home construit en `/home/{{ ansible_user }}`** : faux dès que le home diverge
  du nom d'utilisateur. Remplacé par un `getent`.
- **Taint `control-plane:NoSchedule` non levé** : avec 3 nœuds seulement,
  l'Ingress en `hostPort` et l'exigence #19 (3 replicas en anti-affinité stricte)
  sont infaisables si node-1 n'est pas schedulable.
- **`reset.yml` ne nettoyait pas Cilium** : interfaces `cilium_*` et état résiduels.
- **Précédence Ansible : `inventory/group_vars/` écrase les `vars` d'un fichier
  d'inventaire.** Un défaut `acme_enabled: true` posé dans `group_vars/all.yml`
  annulait silencieusement la surcharge locale `false` — le cluster local a créé
  un compte Let's Encrypt pour rien. Les variables qui diffèrent entre
  environnements sont désormais définies **uniquement** dans les inventaires.
- **`hostPort` ne fonctionne pas avec Cilium par défaut.** Le pod ingress tourne,
  le DaemonSet est sain, mais le port 80 du nœud refuse la connexion. Il faut
  `kubeProxyReplacement: true` (ou le chaînage CNI `portmap`, qui restreint les
  fonctions L7). Toute l'exigence #3 du sujet repose sur `hostPort` : à savoir
  avant de déployer l'Ingress sur AWS.

## Empreinte

3 × 3 Gio alloués, mais **2,6 Go réellement consommés** par les trois QEMU avec le
cluster complet en marche (allocation paresseuse) — node-1 utilise ~900 Mo sur 2965.
Les disques sont creux : ~2,4 Go par VM. L'empreinte réelle est donc très inférieure
aux 9 Gio nominaux.
