# Fiches de décision d'architecture (ADR)

Un ADR (*Architecture Decision Record*) note **une** décision structurante, et surtout
**pourquoi** elle a été prise : le contexte, les options sérieusement envisagées, le choix,
et ce qu'il coûte. Le sujet demande trois fois un « justified choice » : ces fiches sont les
réponses préparées pour la soutenance (voir aussi J4-05, fiche des questions probables).

Les contraintes citées (C1 à C7) renvoient à
[`docs/contraintes-et-outillage.md`](../contraintes-et-outillage.md), où chacune est
prouvée par appel API. Les arbitrages (A1 à A8) renvoient à la fiche d'arbitrages
du 29/09/2026. Les schémas qui en découlent sont dans [`docs/architecture/`](../architecture/hld.md) (HLD et LLD).

## Index

| # | Décision | Catégorie | Statut |
|---|---|---|---|
| [001](ADR-001-pas-de-terraform.md) | Pas de Terraform | Provisioning | Proposée (Hadrien, KUB-65) |
| [002](ADR-002-provisioning-ansible-kubeadm.md) | Ansible + kubeadm, lancés depuis node-1 | Provisioning | Acceptée |
| [003](ADR-003-topologie-control-plane-unique.md) | Un seul control-plane, node-1 sans charge applicative | Architecture | Acceptée |
| [004](ADR-004-cni-cilium.md) | CNI : Cilium, sans kube-proxy | Réseau | Acceptée |
| [005](ADR-005-ingress-traefik.md) | Contrôleur d'ingress : Traefik | Exposition | Acceptée |
| [006](ADR-006-exposition-hostport.md) | Exposition en hostPort 80/443 + sslip.io (écart au sujet) | Exposition | Acceptée, à confirmer au FU |
| [007](ADR-007-tls-letsencrypt-ca-interne.md) | TLS : Let's Encrypt HTTP-01 + CA interne | Sécurité | Acceptée |
| [008](ADR-008-stockage-efs-local-path.md) | Stockage : EFS CSI en PV statiques + local-path | Stockage | Acceptée |
| [009](ADR-009-base-de-donnees-mysql.md) | Base de données : chart Bitnami MySQL, standalone, sur EFS | Application | Acceptée, sous condition J0-07 |
| [010](ADR-010-gitops-argocd.md) | GitOps : ArgoCD, deux dépôts, App-of-Apps | GitOps | Acceptée |
| [011](ADR-011-metriques-victoriametrics.md) | Métriques et alertes : VictoriaMetrics + Grafana | Observabilité | Acceptée |
| [012](ADR-012-logs-loki-alloy.md) | Logs : Loki + Alloy | Observabilité | Acceptée |
| [013](ADR-013-dashboard-headlamp.md) | Dashboard : Headlamp | Outillage | Acceptée |
| [014](ADR-014-secrets-sealed-secrets.md) | Secrets : Sealed Secrets | Sécurité | Acceptée |
| [015](ADR-015-identite-keycloak-dex.md) | Identité : Keycloak fédéré par dex | Sécurité | Acceptée |
| [016](ADR-016-registry-ghcr.md) | Registry privé : GHCR | CI/CD | Acceptée, à confirmer au FU |

Ce qui n'a **pas** d'ADR parce que le sujet l'impose sans alternative : Ansible,
dex, Loki, Kustomize, Helm pour l'application, ValidatingAdmissionPolicy (CEL),
cert-manager + Let's Encrypt, EFS pour la base. Seule la *manière* de les mettre en œuvre
fait l'objet d'une fiche quand elle comporte un choix.

## Écarts entre ces ADR et le reste de la doc

Le [README](../../README.md) et `contraintes-et-outillage.md` ont été écrits avant les
arbitrages du 29/09. **En cas de contradiction, l'ADR fait foi.** Points connus :

| Doc existante | Décision actée | ADR |
|---|---|---|
| kube-prometheus-stack (§2.2 #7, §3, §7) | VictoriaMetrics | 011 |
| 3 réplicas sur l'app (§2.4 #19, §6) | 2 réplicas sur node-2 et node-3 | 003 |

## Rédiger un nouvel ADR

1. Copier [`ADR-000-modele.md`](ADR-000-modele.md) en `ADR-NNN-titre-court.md` (numéro suivant).
2. Un ADR accepté ne se réécrit pas : si la décision change, on écrit un nouvel ADR et on
   passe l'ancien en « Remplacée par ADR-NNN ».
3. Chaque ADR est relu par quelqu'un qui ne l'a pas écrit, via la PR.
