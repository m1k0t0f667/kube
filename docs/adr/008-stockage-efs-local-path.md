# ADR-008 — Stockage : EFS CSI en PV statiques + local-path

- **Statut :** Acceptée
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12), KUB-58 (J0-04) — arbitrage A7

## Contexte

Le sujet impose un PersistentVolume adossé à l'**EFS partagé** pour la base de données. Les
autres composants stateful (métriques, logs, Keycloak) ont aussi besoin de stockage.

- EFS est du **NFS** : latence de 2 à 10 ms par opération, verrouillage POSIX fragile.
- La documentation de Prometheus exclut nommément EFS (« NFS filesystems (including AWS's
  EFS) are not supported ») : risque de corruption du WAL. Loki et VictoriaMetrics ont le
  même profil d'écriture.
- `efs:CreateAccessPoint` est refusé (C3) : le provisioning dynamique du driver EFS CSI
  (`provisioningMode: efs-ap`) est impossible.
- L'EFS est déjà monté sur chaque nœud par le `fstab`, en NFS+TLS (`/mnt/efs`), vérifié
  (KUB-58). Il est plafonné à **20 Go** pour le groupe, au-delà il passe en lecture seule.
- Le disque local fait **30 Go par nœud, non extensible** (C6).

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| Tout sur EFS (nfs-subdir-external-provisioner) | Une seule StorageClass, pods mobiles | Corruption probable des bases de séries temporelles ; NFS sans TLS |
| **EFS CSI en PV statiques + local-path** | Chaque composant sur le stockage adapté ; aucun droit AWS nécessaire ; TLS de l'EFS conservé | Deux StorageClasses ; PV à déclarer à la main ; pods local-path épinglés à leur nœud |
| PV `nfs` natif vers le mount target | Aucun driver | NFS en clair sur le port 2049 |
| PV `hostPath` sur `/mnt/efs` | Réutilise le montage TLS, très robuste | Peu élégant ; repli seulement |

## Décision

Deux StorageClasses, choisies par une règle simple : **le composant fait-il des `fsync`
continus sur de petits blocs ?** Si oui, disque local ; sinon, EFS.

| StorageClass | Mécanisme | Composants |
|---|---|---|
| `efs-sc` | aws-efs-csi-driver, **PV statiques** par sous-répertoire (`fs-038bf0f49474a6a1d:/mysql`), `reclaimPolicy: Retain` | MySQL (imposé), sauvegardes `mysqldump`, base de Keycloak, clé Sealed Secrets (`/bootstrap`) |
| `local-path` | local-path-provisioner (Rancher) | VictoriaMetrics, Loki, Grafana |

Les droits UNIX que les Access Points auraient posés le sont par le rôle Ansible `efs`.

Replis, dans l'ordre, si le driver CSI refuse le montage statique : PV `hostPath` sur
`/mnt/efs/<dir>` (chiffré), puis PV `nfs` natif (non chiffré, à documenter).

## Conséquences

- Budget EFS sur 20 Go : MySQL (~2 Go) + sauvegardes (rétention calée sur le quota) +
  Keycloak (~0,5 Go). Une alerte sur l'occupation est nécessaire.
- Budget local par nœud : ~15 Go disponibles après l'OS et les images. Rétention de
  7 jours et limite de taille pour les métriques et les logs ; `imageGCHighThresholdPercent`
  à 75 sur le kubelet.
- Les pods en `local-path` ne changent pas de nœud : un nœud perdu, ses métriques et ses
  logs sont perdus. Acceptable, ces données sont reconstructibles.
- Le stockage partagé n'est **pas** de la redondance : MySQL reste mono-instance (ADR-009).
- À faire : local-path-provisioner n'est pas encore déployé. Les répertoires `harbor` et
  `harbor-pg` du rôle `efs` sont devenus inutiles avec GHCR (ADR-016).

## En soutenance

**« Pourquoi pas tout sur EFS ? »** Parce que les bases de séries temporelles se corrompent sur
NFS, la doc de Prometheus le dit noir sur blanc. EFS sert à ce qui doit survivre à un nœud
(la base, les sauvegardes), le disque local à ce qui écrit beaucoup et se reconstruit.
**« Pourquoi des PV statiques ? »** Le compte ne peut pas créer d'Access Point.
