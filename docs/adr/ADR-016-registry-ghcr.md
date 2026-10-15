# ADR-016 — Registry privé : GHCR

- **Statut :** Acceptée — réponse du suiveur à noter (KUB-68)
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12), KUB-45 (J2-08) — arbitrage A5

## Contexte

Le sujet impose de « publish your application image to a private authenticated registry,
and pull images from it ». Il **n'impose pas** que ce registry tourne dans le cluster.

- Harbor dans le cluster : ~2 Go de RAM (environ 8 pods) et ~5 Go d'images sur l'EFS,
  plafonné à 20 Go pour le groupe (au-delà, lecture seule).
- Le code et la CI sont sur GitHub ; les runners GitHub construisent l'image arm64.
- `ecr:*` est refusé sur le compte AWS.

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| Harbor (dans le cluster) | OIDC, robot accounts, scan Trivy intégré | ~2 Go de RAM, ~5 Go d'EFS ; un composant stateful de plus |
| Zot (dans le cluster) | 1 pod, ~100 Mo ; registry OCI authentifié | Ni scan ni OIDC ; stockage EFS à prévoir |
| **GHCR en privé** | Zéro RAM, zéro EFS ; la CI GitHub s'y authentifie avec son `GITHUB_TOKEN` ; images multi-arch | Hors cluster ; pas couvert par notre OIDC (authentification GitHub) |
| Amazon ECR | Registry AWS | `ecr:*` refusé |

## Décision

**GitHub Container Registry, paquet privé.**

- La CI (GitHub Actions) construit l'image `linux/arm64` et la pousse sur
  `ghcr.io/<organisation>/kube-app` avec un tag de version, authentifiée par
  `GITHUB_TOKEN`.
- Le cluster tire l'image par un `imagePullSecret` (jeton GitHub en lecture seule sur les
  paquets), stocké en Sealed Secret (ADR-014).
- La ValidatingAdmissionPolicy n'autorise que les images de ce registry pour l'application.
- **Repli : Zot** dans le cluster, si le suiveur exige un registry hébergé chez nous.

## Conséquences

- Libère ~2 Go de RAM et ~5 Go d'EFS par rapport à Harbor.
- Le scan d'images n'est plus intégré : il passe en CI (Trivy en GitHub Action), ce qui
  couvre aussi le bonus « sécurité des artefacts ».
- Le registry n'est pas derrière notre OIDC : à dire en soutenance. L'accès y est quand
  même authentifié et limité par les permissions GitHub.
- Les répertoires EFS `harbor` et `harbor-pg` ont été retirés du rôle `efs` (KUB-76).

## En soutenance

**« Pourquoi un registry hors du cluster ? »** Le sujet demande un registry privé et
authentifié, pas un registry hébergé dans le cluster. GHCR remplit l'exigence sans prendre
2 Go de RAM sur des nœuds qui en ont 4, et notre CI est déjà sur GitHub.
