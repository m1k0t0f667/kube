# ADR-009 — Base de données : chart Bitnami MySQL, standalone, sur EFS

- **Statut :** Acceptée, sous condition des vérifications de J0-07 (voir « Validation »)
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12), KUB-61 (J0-07) — arbitrage A8

## Contexte

Le sujet demande de « use the official chart for the database (helm) », avec un PV adossé
à l'EFS. L'application est un Laravel 8 qui tourne avec **MySQL 8** dans le
`docker-compose` fourni.

- Il n'existe pas de chart Helm « officiel » au sens de l'éditeur pour un MySQL simple :
  Oracle publie seulement `mysql-operator` / `mysql-innodbcluster`, qui déploie un cluster
  InnoDB (3 instances + MySQL Router).
- Le chart Bitnami MySQL est la référence de fait de l'écosystème Helm. Mais depuis 2025,
  Bitnami a déplacé ses images gratuites vers le dépôt `bitnamilegacy`, qui **ne reçoit
  plus de mises à jour** ; les images maintenues sont devenues payantes.
- Nœuds arm64 (C4), 4 Go de RAM chacun.
- La base est sur EFS, donc sur NFS (ADR-008) : InnoDB y fonctionne avec des limites.

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| **Chart Bitnami MySQL, `standalone`** | Chart de référence ; une seule instance ; persistance, probes, métriques, utilisateurs prêts à l'emploi | Images en `bitnamilegacy` sans mises à jour de sécurité |
| Oracle `mysql-innodbcluster` | Seul chart publié par l'éditeur | 3 instances + Router : ~1,5 Go de plus ; un cluster InnoDB sur NFS cumule les risques |
| Chart Bitnami MariaDB | Même chart, MariaDB compatible Laravel | Change le moteur par rapport au `docker-compose` (MySQL 8) : écart sans gain |
| Manifeste maison (StatefulSet + image `mysql:8.4` officielle) | Image officielle maintenue, arm64 | N'est pas un chart officiel : non conforme au sujet |

## Décision

**Chart Bitnami MySQL**, architecture **`standalone`** (une seule instance), MySQL 8.4 :

- Image `bitnamilegacy/mysql`, **épinglée par digest** pour garantir l'arm64 et la
  reproductibilité.
- Persistance sur le PV statique `efs-sc` `fs-038bf0f49474a6a1d:/mysql`, `Retain`, UID 1001
  (ADR-008). `innodb_flush_method` laissé par défaut (pas d'`O_DIRECT` sur NFS).
- Placement sur node-2 ou node-3, jamais sur node-1 (ADR-003).
- Mots de passe en Sealed Secrets (ADR-014).
- Migrations Laravel par un Job en hook Helm `pre-install,pre-upgrade`, pas au démarrage
  des réplicas.
- Sauvegarde : CronJob `mysqldump` quotidien vers `efs:/backups`, qui sert aussi de CronJob
  « besoin opérationnel réel » demandé par le sujet.

## Validation (à faire dans J0-07 avant le premier déploiement)

1. `docker manifest inspect bitnamilegacy/mysql:<tag>` montre une variante `arm64`.
2. Le pod démarre sur le PV EFS, et un `mysqlslap` court passe sans erreur de verrouillage.
3. Les données survivent à `kubectl delete pod` (J1-10).

**Repli si (1) échoue :** même chart, image `bitnamilegacy` la plus récente disponible en
arm64. **Si (2) échoue :** PV `local-path` sur node-2, avec le `mysqldump` vers EFS comme
garantie de durabilité ; on reste conforme à l'esprit du sujet (données sur EFS), écart à
documenter.

## Conséquences

- Dette de sécurité assumée : image figée sans mises à jour. Acceptable pour un projet
  d'école à base non exposée (Service `ClusterIP` uniquement), à dire franchement en
  soutenance avec ce qu'on ferait en production.
- Pas de réplication MySQL : la redondance notée est celle de l'application, pas de la base.
- MySQL sur NFS : écart à une vraie production, documenté.

## En soutenance

**« Pourquoi Bitnami et une instance unique ? »** C'est le chart de référence, et le sujet ne
demande pas de réplication de la base : un cluster InnoDB coûterait 1,5 Go de RAM pour une
redondance non notée. **« Et les images Bitnami gelées ? »** On le sait, l'image est
épinglée et la base n'est jamais exposée ; en production, on prendrait l'opérateur Oracle
ou un service managé, sur stockage bloc et non sur NFS.
