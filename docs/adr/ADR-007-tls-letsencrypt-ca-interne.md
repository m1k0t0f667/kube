# ADR-007 — TLS : Let's Encrypt HTTP-01 + CA interne

- **Statut :** Acceptée
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12), KUB-57 (J0-03), KUB-37 (J1-12)

## Contexte

Le sujet impose de servir tous les points d'accès exposés en HTTPS, « TLS via cert-manager
and Let's Encrypt ». Il reste à choisir le type de challenge et à traiter le TLS interne
(trafic qui ne sort jamais du cluster).

- Le test des ports (KUB-57, 11/10/2026) montre que le **port 80 est joignable depuis
  Internet** : le challenge HTTP-01 peut aboutir.
- Pas de DNS administrable : `route53:*` refusé, noms en `sslip.io`. Le challenge DNS-01
  est impossible.
- Quota Let's Encrypt production : 50 certificats par domaine et par semaine, vite épuisé
  par des reconstructions répétées.
- dex sera l'issuer OIDC déclaré à l'apiserver : son certificat doit être reconnu sans
  injecter de CA maison dans l'apiserver.

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| **Let's Encrypt HTTP-01** | Certificats reconnus par les navigateurs ; port 80 ouvert | Quota production |
| Let's Encrypt DNS-01 | Wildcard possible | Impossible : pas de DNS administrable |
| CA interne seule | Aucun quota | Navigateurs en alerte ; non conforme au sujet |
| Vault (moteur PKI) | Référence en production | Composant stateful à desceller après chaque extinction nocturne |

## Décision

Deux `ClusterIssuer` cert-manager (`v1.21.2`), deux périmètres :

- **`letsencrypt`** (ACME, HTTP-01, ingressClass `traefik`) pour **tout ce qui est exposé**.
  Serveur **staging** pendant tout le développement, bascule en production en fin de
  projet seulement (variable `acme_server` de l'inventaire).
- **`internal-ca`** (CA racine auto-signée, ECDSA P-256, 5 ans) pour **ce qui ne sort jamais
  du cluster** : TLS MySQL, webhooks, scraping des métriques.

Chaque Ingress demande son certificat par l'annotation `cert-manager.io/cluster-issuer`.

## Conséquences

- Les certificats staging ne sont pas reconnus par les navigateurs : avertissement attendu
  jusqu'à la bascule production, à prévoir avant la soutenance.
- La validation réelle de la chaîne se fait dans KUB-37, avec l'Ingress d'ArgoCD comme
  premier certificat.
- La rotation automatique vient de cert-manager (renouvellement aux 2/3 de la durée de
  vie), quel que soit l'émetteur. Ce n'est pas un argument pour la CA interne.
- La PKI du cluster lui-même (CA de l'apiserver et d'etcd) est générée par kubeadm, valable
  1 an : sujet distinct, à traiter dans la doc de montée de version.

## En soutenance

**« Pourquoi deux autorités de certification ? »** Let's Encrypt pour ce qu'un navigateur
ou l'apiserver doit croire sans configuration, la CA interne pour ce qui ne sort jamais du
cluster, sans quota. **« Pourquoi HTTP-01 ? »** On n'a pas la main sur le DNS, et on a
vérifié que le port 80 est joignable depuis Internet.
