# ADR-013 — Dashboard : Headlamp

- **Statut :** Acceptée
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12)

## Contexte

Le sujet demande « a user-friendly dashboard to access and manage the containers
(kubernetes-dashboard or Headlamp, justified choice) », couvert par l'OIDC comme tous les
outils déployés.

- Aucun accès au port 6443 depuis nos postes (C2) : le dashboard est exposé par l'ingress
  et devient l'outil principal pour voir le cluster depuis un navigateur.
- kubernetes-dashboard est passé sous la gouvernance SIG UI avec peu d'activité, et
  Headlamp est désormais un projet Kubernetes SIG UI.

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| **Headlamp** | OIDC natif (`-oidc-client-id`, `-oidc-idp-issuer-url`) ; projet SIG UI actif ; extensible par plugins | Moins connu |
| kubernetes-dashboard | Historique, connu | Pas d'OIDC natif : connexion par token, ou un proxy OIDC à ajouter devant |
| Rancher | Très complet | Gestionnaire de clusters, pas un dashboard : sa propre authentification, son propre RBAC, ~2-3 Go de RAM, en conflit avec dex et l'admission native |

## Décision

**Headlamp**, exposé sur `headlamp.15.224.60.53.sslip.io` en HTTPS, connecté à dex en OIDC.
Les droits de l'utilisateur dans Headlamp sont ceux de son groupe Keycloak, appliqués par
le RBAC Kubernetes (Headlamp transmet le jeton à l'apiserver).

## Conséquences

- Pas de proxy OIDC supplémentaire à maintenir.
- Le RBAC par groupe (J3-04) se voit directement dans le dashboard : un compte lecteur voit
  les pods sans pouvoir les supprimer.
- L'apiserver doit accepter les jetons de dex (flags OIDC, ADR-015) pour que Headlamp
  fonctionne en OIDC.

## En soutenance

**« Pourquoi Headlamp ? »** Il parle OIDC nativement, ce que le sujet exige pour tous les
outils, alors que kubernetes-dashboard demande un contournement. **« Et Rancher ? »** C'est un
gestionnaire de clusters avec sa propre authentification, qui entrerait en conflit avec dex
et le RBAC natif.
