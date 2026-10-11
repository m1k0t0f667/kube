# Disponibilité arm64 des images (J0-07)

Les nœuds sont des `t4g.medium` (Graviton, **arm64**, contrainte C4) : chaque image doit
exister en `linux/arm64`, sinon le pod reste en `ImagePullBackOff` ou `exec format error`.

**Relevé du 2026-10-11** (KUB-61), en lisant le manifeste multi-architecture de chaque
image directement dans son registry (API `v2/<image>/manifests/<tag>`), sans rien
télécharger.

## Résultat : tout est OK

| Composant | Image vérifiée | arm64 | Remarque |
|---|---|---|---|
| Cilium | `quay.io/cilium/cilium:v1.20.2` | ✅ | Déjà en place sur AWS |
| Traefik | `docker.io/library/traefik:v3.7.13` | ✅ | Déjà en place sur AWS |
| cert-manager | `quay.io/jetstack/cert-manager-controller:v1.21.2` | ✅ | Déjà en place sur AWS |
| ArgoCD | `quay.io/argoproj/argocd` | ✅ | |
| EFS CSI driver | `public.ecr.aws/efs-csi-driver/amazon/aws-efs-csi-driver:v3.5.1` | ✅ | |
| local-path-provisioner | `docker.io/rancher/local-path-provisioner` | ✅ | |
| VictoriaMetrics | `victoriametrics/victoria-metrics`, `vmagent`, `vmalert`, `operator` | ✅ | |
| Grafana | `docker.io/grafana/grafana` | ✅ | |
| node-exporter | `quay.io/prometheus/node-exporter` | ✅ | |
| kube-state-metrics | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.15.0` | ✅ | |
| Loki | `docker.io/grafana/loki` | ✅ | |
| Alloy | `docker.io/grafana/alloy` | ✅ | |
| Headlamp | `ghcr.io/headlamp-k8s/headlamp` | ✅ | |
| Sealed Secrets | `docker.io/bitnami/sealed-secrets-controller` | ✅ | Maintenu par le projet Sealed Secrets, pas concerné par le gel Bitnami |
| Keycloak | `quay.io/keycloak/keycloak` | ✅ | |
| PostgreSQL (base de Keycloak) | `docker.io/library/postgres:17` | ✅ | Image officielle |
| dex | `ghcr.io/dexidp/dex` | ✅ | |
| **MySQL (chart Bitnami)** | `docker.io/bitnamilegacy/mysql:8.4.5-debian-12-r0` | ✅ | **Gelée** : voir ci-dessous |
| Base de l'image applicative | `php:8.2-apache`, `php:8.2-fpm-alpine` | ✅ | À construire en `linux/arm64` en CI |

Aucun KO, donc aucune alternative à prévoir pour l'architecture.

## Le cas MySQL

- `docker.io/bitnami/mysql` **n'a plus de tag `latest`** : les images gratuites Bitnami ont
  été déplacées vers `bitnamilegacy`.
- `bitnamilegacy/mysql` existe bien en arm64, mais sa **dernière mise à jour date du
  13/08/2025**. La dernière version 8.4 disponible est **8.4.5** (`8.4.5-debian-12-r0`).
  Elle ne recevra plus de correctifs.
- Pour comparaison, l'image officielle `mysql:8.4` (arm64 aussi) a été mise à jour le
  29/09/2026.

Décision : [ADR-009](adr/ADR-009-base-de-donnees-mysql.md).

### Test de MySQL sur l'EFS (2026-10-11)

Pod temporaire `bitnamilegacy/mysql:8.4.5-debian-12-r0` sur node-2, données dans
`/mnt/efs/mysql-test` monté en `hostPath`. Le pilote EFS CSI n'est pas encore installé,
mais le stockage testé est le même : l'EFS en NFS+TLS, monté par le `fstab`.

| Étape | Résultat |
|---|---|
| Initialisation de la base sur l'EFS, puis `mysqladmin ping` | ✅ `mysqld is alive` |
| Charge : `mysqlslap`, 10 clients, 500 requêtes, 3 itérations | ✅ 1,35 s en moyenne (min 1,31, max 1,39), aucune erreur de verrouillage |
| Écriture d'une ligne, suppression du pod, recréation, relecture | ✅ la ligne est toujours là |
| Nettoyage | Pod et répertoire de test supprimés |

`mysqlslap` doit être lancé avec `--no-defaults -h127.0.0.1 --protocol=TCP` : le
`my.cnf` de l'image Bitnami contient une option `default_character_set` que cet outil
refuse. Ce n'est pas lié à l'EFS.

**Conclusion : InnoDB fonctionne sur l'EFS.** Le repli `local-path` de l'ADR-009 n'est pas
nécessaire. La preuve de persistance définitive, avec le vrai PVC, reste à faire dans J1-10
(KUB-35).

## Refaire la vérification

Pour une nouvelle image, depuis n'importe quel poste :

```bash
docker manifest inspect <image>:<tag> | grep -A1 '"architecture"'
```

Ou sans Docker, en interrogeant le registry (exemple Docker Hub) :

```bash
TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/traefik:pull" | sed -E 's/.*"token":"([^"]+)".*/\1/')
curl -s -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
  https://registry-1.docker.io/v2/library/traefik/manifests/v3.7.13 | grep -o '"architecture":"[^"]*"'
```
