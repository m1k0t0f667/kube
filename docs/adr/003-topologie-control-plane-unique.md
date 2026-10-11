# ADR-003 — Un seul control-plane, node-1 sans charge applicative

- **Statut :** Acceptée
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12), KUB-48 (J2-11) — arbitrage A3

## Contexte

Le sujet fournit kube-1 (control-plane + worker) et deux workers, « so that high
availability and affinity rules can be demonstrated ». Il demande plusieurs réplicas de
l'application sur des nœuds différents.

- Une seule EIP (`15.224.60.53`), sur node-1, **non déplaçable** : `AssociateAddress`,
  `AllocateAddress`, `CreateLoadBalancer` refusés (C7). Tout l'accès public passe par
  node-1.
- Une seule AZ, un seul subnet (C5).
- 3 × 4 Go de RAM, environ 9 Go utilisables après système et kubelet.
- Les workers n'ont pas d'IP publique fixe, mais leurs IP privées le sont.

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| Control-plane HA à 3 nœuds (etcd en quorum) | Tolère la perte d'un nœud | ~2 Go de RAM ; ne sauve rien, car l'accès public meurt avec node-1 (EIP immobile) |
| **Control-plane unique sur node-1** | Simple, économe | node-1 est un point de défaillance unique |
| App à 3 réplicas, node-1 schedulable | Plus de réplicas | En anti-affinité stricte, un réplica atterrit sur node-1, le nœud qu'il faut protéger |
| **App à 2 réplicas sur node-2 et node-3** | node-1 reste dédié au control-plane et à l'entrée | Pas de 3ᵉ réplica |

## Décision

- **Un seul control-plane, sur node-1.** Pas de HA du control-plane.
- **node-1 porte etcd, l'apiserver, l'ingress (Traefik) et les DaemonSets système, et rien
  d'autre.** Il reste schedulable pour l'ingress, mais aucune charge applicative ni
  composant stateful n'y tourne.
- **L'application tourne à 2 réplicas**, en anti-affinité stricte
  (`requiredDuringSchedulingIgnoredDuringExecution` sur `kubernetes.io/hostname`), donc
  forcément un sur node-2 et un sur node-3.
- La stratégie de reprise est la **reconstruction** : `site.yml` puis resynchronisation
  ArgoCD, les données persistantes étant sur l'EFS.

## Conséquences

- La redondance démontrée est celle de l'application (anti-affinité, rolling update,
  version fautive), qui est ce que le sujet note.
- Si node-1 tombe : les pods de node-2 et node-3 continuent, mais plus de scheduling, plus
  de `kubectl`, plus d'accès public. Écart assumé et documenté.
- Les composants lourds (base, métriques, logs, Keycloak) doivent cibler node-2 et node-3
  par `nodeSelector` ou affinité.

## En soutenance

**« Pourquoi pas de control-plane HA avec trois nœuds ? »** Le point d'entrée public est une
EIP fixée sur node-1 que personne ne peut déplacer, et aucun load balancer n'est autorisé :
un etcd en quorum garderait vivant un cluster que plus personne ne peut joindre, pour
2 Go de RAM. La HA démontrée est celle de l'application.
