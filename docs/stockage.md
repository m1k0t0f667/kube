# Stockage persistant

Deux StorageClasses, posées par le rôle Ansible `storage` (choix : [ADR-008](adr/ADR-008-stockage-efs-local-path.md)).

| StorageClass | Où vont les données | Survit à | Pour |
|---|---|---|---|
| `efs-sc` | EFS `fs-038bf0f49474a6a1d`, un sous-répertoire par PV, monté en TLS | la suppression du pod, la perte d'un nœud, une reconstruction du cluster | MySQL, sauvegardes, base de Keycloak |
| `local-path` | `/opt/local-path-provisioner` sur le disque du nœud | la suppression du pod | métriques, logs |

## Utiliser un volume EFS

Pas de création automatique : le compte n'a pas le droit de créer d'Access Point
([contraintes §6](contraintes-et-outillage.md)). Les PV existent d'avance, un par
répertoire, et sont déclarés dans `efs_static_volumes` (`ansible/inventory/group_vars/all.yml`) :

| PV | Répertoire EFS | Taille indicative |
|---|---|---|
| `efs-mysql` | `/mysql` | 5Gi |
| `efs-backups` | `/backups` | 5Gi |
| `efs-keycloak-pg` | `/keycloak-pg` | 1Gi |

Un PVC EFS **nomme toujours son PV** avec `volumeName`. Sans cela, Kubernetes peut lui
attribuer le PV d'un autre composant de taille suffisante.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-data
spec:
  storageClassName: efs-sc
  volumeName: efs-mysql
  accessModes: [ReadWriteMany]
  resources:
    requests: { storage: 5Gi }
```

Les PV sont en `Retain` : supprimer le PVC ne supprime pas les données. Pour rattacher un
nouveau PVC au même PV, il faut d'abord libérer le PV
(`kubectl patch pv efs-mysql -p '{"spec":{"claimRef":null}}'`).

Ajouter un composant sur l'EFS : créer son répertoire dans le rôle `efs`, ajouter une
ligne à `efs_static_volumes`, rejouer `ansible-playbook site.yml --tags socle,storage`.

## Utiliser un volume local

Un PVC ordinaire en `local-path`. Le volume est créé sur le nœud où le pod est placé, et le
pod y reste ensuite épinglé.

```yaml
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources:
    requests: { storage: 2Gi }
```

## Preuve de persistance

Le test est un playbook : n'importe qui peut le rejouer, il supprime tout ce qu'il crée.

```bash
# sur node-1, en ec2-user
cd ~/kube-infra/ansible
ansible-playbook playbooks/storage-check.yml
```

Ce qu'il fait :

1. Un pod sur `node-2` écrit un jeton aléatoire dans un volume EFS et dans un volume local-path.
2. Le pod est supprimé.
3. Un nouveau pod relit les deux fichiers.
4. Un pod sur `node-3` relit le fichier EFS.
5. Namespace, PVC, PV et répertoire de test sont supprimés, même en cas d'échec.

### Résultat du 16/10/2026 (KUB-34, KUB-35)

Jeton tiré : `wcpgjqqkh3dx`.

| Vérification | Résultat |
|---|---|
| Le PVC EFS se lie au PV statique | ✅ `Bound` sur `efs-storage-check` |
| Après suppression de l'écrivain, `lecteur` (node-2) relit le fichier EFS | ✅ `wcpgjqqkh3dx` |
| Après suppression de l'écrivain, `lecteur` (node-2) relit le fichier local-path | ✅ `wcpgjqqkh3dx` |
| `lecteur-autre-noeud` (node-3) relit le fichier EFS | ✅ `wcpgjqqkh3dx` |
| Nettoyage | ✅ namespace `storage-check` absent après le test |

```
NAME                          STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
persistentvolumeclaim/efs     Bound    efs-storage-check                          1Gi        RWX            efs-sc
persistentvolumeclaim/local   Bound    pvc-3a7e034d-721c-4c0d-af6a-43b7e35fc701   64Mi       RWO            local-path

NAME                      READY   STATUS    RESTARTS   AGE   IP             NODE
pod/lecteur               1/1     Running   0          6s    10.244.2.18    node-2
pod/lecteur-autre-noeud   1/1     Running   0          6s    10.244.0.254   node-3
```

`PLAY RECAP` : `ok=17 changed=11 failed=0`.
