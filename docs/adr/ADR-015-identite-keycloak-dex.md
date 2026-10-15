# ADR-015 — Identité : Keycloak fédéré par dex

- **Statut :** Acceptée
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12), KUB-10 (J3-01), KUB-18 (J3-04)

## Contexte

Le sujet impose une authentification **OIDC via dex**, couvrant **tous** les outils
(Grafana, dashboard, ArgoCD, `kubectl`…) et l'**API Kubernetes**, contre un fournisseur
d'identité (IdP) **que nous déployons dans le cluster**, avec un choix justifié. C'est le
point le plus évalué.

- dex est un **broker** OIDC : il fédère des sources d'identité, mais ne gère pas
  vraiment d'utilisateurs ni de groupes.
- L'apiserver n'accepte qu'un issuer OIDC joignable en HTTPS avec un certificat reconnu,
  alors que cet issuer tourne *dans* le cluster : risque de démarrage circulaire.
- Le port 6443 n'est pas joignable depuis nos postes (C2).

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| **Keycloak** | IdP complet : realms, groupes, mappers de claims, MFA ; le plus répandu et cité par le sujet | ~1 Go de RAM avec sa base |
| Authentik | Moderne, plus léger que Keycloak | Moins répandu, mappers de groupes moins directs |
| LDAP (OpenLDAP) + connecteur LDAP de dex | Léger | Annuaire à administrer en LDIF, pas d'interface |
| Utilisateurs statiques de dex | Aucun composant de plus | Pas un IdP déployé : non conforme |

## Décision

- **Keycloak** est la source de vérité des utilisateurs et des groupes (un realm `kube`,
  groupes `kube-admins`, `kube-devs`, `kube-viewers`).
- **dex** fédère Keycloak (`connector: oidc`) et est **le seul issuer OIDC** déclaré à
  l'apiserver et à chaque outil. Un seul point d'intégration.
- Base de Keycloak : PostgreSQL sur PV `efs-sc` (pas la base H2 embarquée, qui perd les
  realms au redémarrage).
- **Séquencement** pour éviter le démarrage circulaire : cluster nu → Traefik →
  cert-manager → certificat Let's Encrypt de dex → Keycloak → dex → **puis** ajout des
  flags `--oidc-*` à l'apiserver par Ansible. Un kubeconfig `cluster-admin` hors OIDC est
  conservé en secours.
- Groupes Keycloak reliés à des `ClusterRoleBinding` / `RoleBinding` (RBAC par groupe).

## Conséquences

- Couverture OIDC à câbler outil par outil : apiserver + `kubectl` (`kubelogin`), ArgoCD,
  Grafana, Headlamp. Comptes locaux désactivés quand c'est possible.
- La démo `kubectl` en OIDC se fait **depuis node-1** (port 6443 injoignable depuis nos
  postes).
- dex et Keycloak dépendent de l'EIP de node-1 et du certificat Let's Encrypt : si le
  HTTPS tombe, l'authentification tombe. Le kubeconfig de secours n'est pas optionnel.

## En soutenance

**« Pourquoi Keycloak derrière dex, et pas dex seul ? »** dex est un broker, pas un annuaire :
le sujet demande un IdP déployé par nos soins, Keycloak gère les utilisateurs et les
groupes, dex les présente à tous les outils sous un seul issuer. **« Comment évitez-vous que
l'apiserver dépende de dex au démarrage ? »** On n'ajoute les flags OIDC qu'une fois dex
joignable en HTTPS, et on garde un accès admin hors OIDC.
