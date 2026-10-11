# ADR-001 — Pas de Terraform

**Statut :** proposé

## Contexte

Le manuel d'équipe prévoyait Terraform pour ce qui vit hors de Kubernetes : règles
réseau AWS, EFS, génération de l'inventaire Ansible, et configuration du realm Keycloak.
Le sujet, lui, n'impose qu'Ansible.

L'infrastructure AWS est **fournie par l'école** : 3 VMs, le security group, l'EFS et
l'IP publique de `node-1` existent déjà. Les droits du rôle `kubequest2-student` ont été
vérifiés appel par appel le 2026-09-21 (`docs/contraintes-et-outillage.md`, §1 et §2) :

- **Aucune création possible** : `iam:*`, `s3:*` et `efs:*` refusés, ainsi que
  `ec2:CreateSecurityGroup`, `AuthorizeSecurityGroupIngress`, `CreateVolume`,
  `ModifyVolume` et `AssociateAddress`.
- **Testé** : `terraform plan` passe, mais `terraform apply` échoue sur **100 %** des
  ressources créables, y compris l'Access Point EFS et le rôle IAM du driver CSI.
- **Pas de state distant** : sans S3, le `tfstate` n'aurait nulle part où vivre en
  commun.

## Options

1. **Terraform pour AWS et Keycloak**, comme prévu dans le manuel.
2. **Terraform pour Keycloak seulement**, via le provider Keycloak.
3. **Pas de Terraform** : Ansible pour les nœuds, GitOps pour tout ce qui vit dans le
   cluster, y compris Keycloak.

## Décision

**Option 3 : pas de Terraform.**

- **Côté AWS**, Terraform n'aurait rien à créer ni à modifier. Il se limiterait à lire
  des ressources qu'on ne contrôle pas, ce que l'inventaire statique d'Ansible fait déjà :
  les IP privées sont fixes.
- **Côté Keycloak**, Keycloak tourne dans le cluster. Son realm est décrit dans Git et
  appliqué par ArgoCD, comme le reste de la plateforme. Garder Terraform pour ce seul
  usage ajouterait un outil, un state à stocker sans S3, et une étape `apply` manuelle,
  hors du chemin « tout passe par Git ».

Le gain attendu d'un outil d'IaC — un état déclaratif, reproductible, qui montre ses
changements avant de les appliquer — est obtenu autrement : playbooks Ansible
idempotents avec un cycle `reset.yml` → `site.yml` reproductible, et diff ArgoCD avant
chaque synchronisation.

## Conséquences

- **Infra** : `ansible-playbook site.yml` suffit à monter un cluster à partir des VMs
  vierges. L'inventaire `inventory/hosts.yml` reste écrit à la main.
- **Stockage** : les volumes EFS sont des PV statiques, puisque rien ne peut être créé côté
  AWS.
- **Identité** : le realm Keycloak devient un fichier versionné dans `kube-infra`. L'outil
  qui l'applique (import natif du realm ou keycloak-config-cli) est à choisir dans l'ADR
  Identité.
- **Documentation** : le manuel d'équipe doit être aligné. Il mentionne Terraform dans le
  schéma d'architecture, la stack technique (« décidé »), le jalon J1
  (`terraform apply` puis `ansible-playbook site.yml`) et la table des montées de version.
- **Soutenance** : à la question « pourquoi pas Terraform ? », la réponse est chiffrée :
  `apply` refusé sur 100 % des ressources, faute de droits de création.
