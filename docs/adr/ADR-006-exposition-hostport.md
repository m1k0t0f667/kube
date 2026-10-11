# ADR-006 — Exposition en hostPort 80/443 + sslip.io (écart au sujet)

- **Statut :** Acceptée — validation de l'écart par le suiveur à noter (KUB-68)
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12), KUB-57 (J0-03), KUB-36 (J1-11) — arbitrage A1

## Contexte

Le sujet écrit : « Exposure relies on an Ingress controller **reachable through NodePort**,
resolved via sslip.io (or nip.io) ». Or :

- Le security group n'ouvre que **80 et 443** depuis Internet, et il n'est pas modifiable
  (C1). La plage NodePort (30000-32767) n'est pas joignable de l'extérieur.
- Let's Encrypt valide les certificats par le challenge HTTP-01, qui appelle **le port 80**.
  Sans écoute sur 80, pas de certificat Let's Encrypt, donc pas de HTTPS valide, que le
  sujet exige.
- Aucun load balancer n'est autorisé (`elbv2:CreateLoadBalancer` refusé).
- node-1 porte une EIP fixe (`15.224.60.53`) qui survit aux extinctions nocturnes.

**Test du 11/10/2026 (KUB-57)**, depuis un poste hors AWS : les ports 80 et 443 de
`15.224.60.53` répondent, `15.224.60.53.sslip.io` résout correctement, et une page de test
derrière l'ingress répond en 200 (KUB-36).

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| NodePort seul (lettre du sujet) | Conforme au texte | Injoignable depuis Internet ; HTTP-01 impossible |
| Service LoadBalancer | Standard sur un cloud | Aucun load balancer autorisé : resterait `Pending` |
| `hostNetwork: true` | Écoute directe sur 80/443 | Le pod partage toute la pile réseau du nœud : surface d'attaque plus large |
| **hostPort 80/443 sur node-1, NodePort conservé en plus** | Seule option joignable depuis Internet ; HTTP-01 fonctionne ; le NodePort reste disponible | node-1 est le seul point d'entrée (déjà le cas avec l'EIP) |

## Décision

- Le DaemonSet Traefik publie **hostPort 80 et 443** sur node-1 : c'est l'entrée publique.
- Le Service Traefik reste de type **NodePort** (30080/30443), pour respecter le sujet.
  Ce NodePort n'est joignable que depuis l'intérieur du VPC.
- Noms d'hôtes en `*.15.224.60.53.sslip.io` (par exemple `argocd.15.224.60.53.sslip.io`).

## Conséquences

- Les deux chemins aboutissent au même Traefik. Le trafic reste du HTTP ou du HTTPS dans
  les deux cas : NodePort et hostPort sont des **ports d'entrée**, pas des protocoles.
- Le trafic entre pods ne passe ni par l'un ni par l'autre : il utilise les Services
  `ClusterIP` et le réseau Cilium.
- Tous les noms publics et les certificats dépendent de l'EIP de node-1 (ADR-003).
- `kubectl` depuis un poste de dev reste impossible (port 6443 fermé) : la démo `kubectl`
  OIDC se fait depuis node-1.

## En soutenance

**« Le sujet demande un NodePort, pourquoi un hostPort ? »** Le security group de l'école
n'ouvre que 80 et 443, et Let's Encrypt valide sur le port 80 : un NodePort seul ne
serait joignable par personne et n'aurait jamais de certificat. On garde le NodePort
demandé, et on ajoute le hostPort qui rend le cluster réellement joignable, test à l'appui.
