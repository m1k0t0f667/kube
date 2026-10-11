# ADR-010 — GitOps : ArgoCD, deux dépôts, App-of-Apps

- **Statut :** Acceptée
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12), KUB-49 (J2-12)

## Contexte

Le sujet impose un dépôt GitOps de manifestes Kustomize réconciliés par un opérateur
(« ArgoCD or FluxCD, justified choice »), et **deux dépôts séparés** : infrastructure et
application. La démo doit montrer une nouvelle version déployée par l'opérateur, avec son
statut **sync et health**. L'opérateur doit aussi être couvert par l'OIDC.

- Aucun accès au port 6443 depuis nos postes (C2) : une interface web derrière l'ingress
  est le seul moyen de montrer l'état du cluster sans session SSM.
- Budget RAM serré.

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| **ArgoCD** | Interface web qui montre sync et health en direct ; OIDC natif ; pattern App-of-Apps | ~500 Mo de RAM |
| FluxCD | Plus léger, très « Kubernetes natif » | Pas d'interface officielle : la démo se fait en `kubectl`, injoignable depuis nos postes |

## Décision

- **ArgoCD**, chart `10.9.2`, **amorcé par Ansible** (dernier rôle de `site.yml`), puis
  géré par lui-même depuis Git.
- **Deux dépôts** : `kube-infra` (cluster, composants, observabilité, sécurité) et
  `kube-app` (application convertie). Deux `Application` racines, deux cycles de vie.
- **App-of-Apps** : une Application racine par dépôt, qui déclare les autres. Manifestes en
  Kustomize (`base/` + `overlays/`), l'application packagée en chart Helm.
- dex embarqué d'ArgoCD **désactivé** : ArgoCD utilise notre dex (ADR-015).
- Exposé sur `argocd.15.224.60.53.sslip.io`, TLS terminé par Traefik
  (`server.insecure: true` pour éviter une boucle de redirection).
- Notifications désactivées (RAM).

## Conséquences

- Aucun `kubectl apply` manuel sur ce qui est géré par ArgoCD : tout changement passe par un
  commit. Une ressource créée à la main est une dérive.
- Ce qu'Ansible installe avant ArgoCD (Cilium, Traefik, cert-manager) reste géré par
  Ansible : la frontière est à tenir et à documenter.
- La démo « nouvelle version » est un commit qui change le tag d'image dans `kube-app`.
- Le dépôt actuel (`m1k0t0f667/kube`) devient `kube-infra` ; le dépôt `kube-app` reste à
  créer.

## En soutenance

**« Pourquoi ArgoCD et pas Flux ? »** Le sujet demande de *montrer* le sync et le health : ArgoCD
l'affiche dans une interface accessible en HTTPS et en OIDC, alors que Flux se démontre en
`kubectl`, que nos postes ne peuvent pas joindre.
