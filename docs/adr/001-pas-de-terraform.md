# ADR-001 — Pas de Terraform

- **Statut :** Acceptée
- **Date :** 2026-10-11
- **Tickets :** KUB-65 (J0-11), KUB-66 (J0-12)

## Contexte

Le sujet impose Ansible pour provisionner le cluster (« torn down and rebuilt
reproducibly »). Terraform est souvent associé à Ansible : Terraform crée
l'infrastructure, Ansible la configure. La question est de savoir s'il a une place ici.

Les faits, vérifiés par appel API (contraintes C1 à C3, C7) :

- L'infrastructure est **fournie par l'école** : 3 instances EC2, VPC, subnet, security
  group, EFS, EIP. Nous n'avons rien à créer.
- Le rôle `kubequest2-student` n'a **aucun droit de création** : ni EC2, ni security group,
  ni volume, ni IAM, ni S3, ni EFS Access Point (C3). `AssociateAddress`,
  `ModifyVolume`, `CreateLoadBalancer` sont refusés.
- `s3:*` est refusé : pas de backend distant pour héberger un `tfstate` partagé.
- Les droits de **lecture** sont incomplets (`efs:DescribeFileSystems`, `iam:*` refusés) :
  un `terraform plan` sur des ressources importées échouerait au rafraîchissement.

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| Terraform pour l'infra AWS + Ansible pour le cluster | Pratique standard de l'industrie | Rien à créer ; `plan` et `apply` échouent faute de droits ; pas de state partagé possible |
| Terraform en `import` seul, pour documenter l'existant | Décrit l'infra en code | Lecture refusée sur EFS et IAM ; un state local par personne ; aucun point noté |
| **Ansible seul** | Imposé par le sujet ; aucun droit AWS nécessaire ; un seul outil à apprendre | L'infrastructure AWS n'est pas décrite en code |

## Décision

**Pas de Terraform.** Tout le provisioning passe par Ansible (ADR-002). L'infrastructure
AWS fournie est décrite comme une donnée d'entrée, dans `ansible/inventory/` (IP privées,
EIP, identifiant EFS) et dans `docs/contraintes-et-outillage.md`.

## Conséquences

- Un seul outil de provisioning, celui que le sujet note.
- La reproductibilité notée est celle du **cluster** : elle repose sur l'idempotence des
  rôles et sur le couple `site.yml` / `reset.yml`.
- Les seules ressources AWS qu'on aurait voulu créer (Access Points EFS) sont remplacées
  par des sous-répertoires et des droits UNIX posés par le rôle Ansible `efs` (ADR-008).
- Si l'école ouvrait des droits de création, la question se reposerait : ce serait un
  nouvel ADR.

## En soutenance

**« Pourquoi pas de Terraform ? »** L'infrastructure est fournie, pas créée par nous, et le
compte n'a aucun droit de création : Terraform n'aurait rien à gérer et échouerait au
`plan`. La reproductibilité demandée est celle du cluster, et elle est dans les playbooks.
