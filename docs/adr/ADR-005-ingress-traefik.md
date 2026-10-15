# ADR-005 — Contrôleur d'ingress : Traefik

- **Statut :** Acceptée
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12), KUB-36 (J1-11) — arbitrage A2

## Contexte

Le sujet demande d'exposer les applications « through Ingress or Gateway API », en citant
Nginx, Traefik ou Envoy Gateway, avec un choix justifié. Le premier rôle Ansible utilisait
ingress-nginx.

- Le projet Kubernetes a **retiré ingress-nginx en mars 2026** : plus de correctifs de
  sécurité, alors que des failles critiques continuent de sortir (CVE-2026-42945
  « NGINX Rift », mai 2026).
- Le contrôleur doit tourner en hostPort 80/443 (ADR-006) et servir le challenge HTTP-01
  de cert-manager (ADR-007).
- Toutes les images doivent exister en arm64.

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| ingress-nginx | Rôle déjà écrit ; très documenté | **Fin de vie** depuis mars 2026 : indéfendable devant un jury |
| **Traefik (Ingress)** | Maintenu, cité par le sujet ; image arm64 ; CRD `Middleware` (redirection HTTPS) ; compatible cert-manager | Réécriture du rôle (une demi-journée) |
| Gateway API (Traefik ou Envoy Gateway) | L'avenir de l'exposition dans Kubernetes | Support cert-manager et des outils OIDC (Helm charts d'ArgoCD, Grafana, Headlamp) encore centré sur `Ingress` : risque sur le chemin critique |

## Décision

**Traefik**, chart `41.6.0` (Traefik v3.7.13), déployé par le rôle Ansible `traefik` :

- DaemonSet en hostPort 80/443 sur le seul nœud étiqueté
  `node-role.kubernetes.io/ingress=true` (node-1).
- IngressClass `traefik`, par défaut.
- Redirection HTTP → HTTPS par le middleware `traefik/redirect-https`, activée **Ingress
  par Ingress** par annotation. Pas de redirection globale : le challenge HTTP-01 doit
  pouvoir répondre en clair sur le port 80.
- On reste sur des ressources `Ingress` standard, pas sur les CRD `IngressRoute`, pour
  garder des manifestes portables.

## Conséquences

- Le rôle désinstalle ingress-nginx s'il est encore présent (migration sans effet sur un
  cluster neuf).
- Le rôle vérifie lui-même que le hostPort et le NodePort répondent après déploiement.
- Validé le 11/10/2026 (KUB-36) : une page de test sur `test.15.224.60.53.sslip.io`
  répond en 200 depuis Internet, servie par un pod situé sur node-3.
- Le `traefik` du `docker-compose` de l'application disparaît : son rôle est repris par cet
  ingress.

## En soutenance

**« Pourquoi Traefik et pas ingress-nginx ? »** ingress-nginx n'est plus maintenu depuis mars
2026, et on ne met pas en production un composant exposé à Internet sans correctifs.
**« Et Gateway API ? »** C'est l'avenir, mais cert-manager et les charts des outils OIDC
reposent encore sur `Ingress` : on n'a pas voulu prendre ce risque sur le chemin critique.
