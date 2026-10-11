# ADR-014 — Secrets : Sealed Secrets

- **Statut :** Acceptée
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12)

## Contexte

Le sujet impose qu'aucun secret ne soit commité en clair dans Git, « use Sealed Secrets or
External Secrets (justified choice) ». Le `docker-compose` fourni contient déjà un `APP_KEY`
en clair, à régénérer.

- External Secrets synchronise des secrets depuis un coffre externe (AWS Secrets Manager,
  Vault…). `secretsmanager:*` et `ssm:PutParameter` ne font pas partie de nos droits, et
  Vault serait un composant stateful de plus, à desceller après chaque extinction
  nocturne.
- Le cluster est souvent détruit et reconstruit (`reset.yml` / `site.yml`).

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| **Sealed Secrets** | Aucun backend externe ; le `SealedSecret` chiffré se commite sans risque ; un seul contrôleur léger | La clé privée du contrôleur devient critique : la perdre rend tous les secrets illisibles |
| External Secrets + AWS Secrets Manager | Standard en production | Droits AWS absents |
| External Secrets + Vault | Très complet | Composant stateful, `unseal` après chaque extinction |

## Décision

**Sealed Secrets** (Bitnami). Les secrets sont chiffrés avec `kubeseal` sur le poste, et
seul le `SealedSecret` est commité. Le contrôleur les déchiffre dans le cluster.

La **clé privée du contrôleur est sauvegardée sur l'EFS** (`/mnt/efs/bootstrap/`, droits
`0700`, propriétaire root) et **restaurée par Ansible** avant l'installation du contrôleur
lors d'une reconstruction.

## Conséquences

- Les secrets : `APP_KEY`, `DB_PASSWORD`, `MYSQL_ROOT_PASSWORD`, identifiants du registry,
  secrets clients OIDC. Tout le reste va en ConfigMap (exigence du sujet).
- La procédure de sauvegarde et de restauration de la clé est à documenter et à tester :
  un cluster reconstruit sans elle ne peut plus rien déchiffrer.
- Une rotation de la clé impose de rechiffrer les secrets : à éviter avant la soutenance.

## En soutenance

**« Pourquoi Sealed Secrets et pas External Secrets ? »** External Secrets a besoin d'un coffre
externe, et nous n'avons ni droits sur AWS Secrets Manager ni envie d'opérer Vault. La
contrepartie est la clé privée du contrôleur : on la sauvegarde sur l'EFS et Ansible la
restaure à chaque reconstruction.
