# ADR-004 — CNI : Cilium, sans kube-proxy

- **Statut :** Acceptée
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12) — arbitrage A6

## Contexte

Le CNI fournit le réseau des pods entre les trois nœuds. Le sujet ne l'impose pas. Deux
besoins pèsent :

- L'ingress écoute en **hostPort** 80/443 (ADR-006). Le CNI doit le supporter.
- Le bonus « renforcement du réseau » demande des NetworkPolicies.

Cilium était déjà installé et validé en local, sur le même OS (Amazon Linux 2023) et la même
architecture (arm64) qu'AWS.

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| **Cilium** | eBPF ; NetworkPolicies L3-L7 ; Hubble pour visualiser les flux en démo ; remplace kube-proxy | Plus gourmand en RAM par nœud ; hostPort uniquement avec `kubeProxyReplacement` |
| Calico | NetworkPolicies matures, plus léger | Pas d'observabilité réseau équivalente à Hubble ; travail à refaire |
| Flannel | Le plus simple | Aucune NetworkPolicy : le bonus réseau devient impossible |

## Décision

**Cilium**, version `1.20.2`, avec :

- `kubeProxyReplacement: true` : obligatoire pour que le hostPort fonctionne (vérifié : sans
  lui, le pod ingress tourne mais le port 80 du nœud refuse la connexion). kube-proxy n'est
  donc pas installé (`skipPhases` dans la config kubeadm).
- Hubble et Hubble Relay activés, l'interface web désactivée pour l'instant (~100 Mo).
- Un seul réplica de l'opérateur (un seul control-plane, ADR-003).

## Conséquences

- Le hostPort est implémenté en eBPF dans le noyau : **`ss` ne montre aucun processus sur
  80/443**, et un autre programme peut s'y lier sans erreur sans jamais recevoir le trafic
  externe. Constaté lors du test des ports (KUB-57). À savoir pour le débogage.
- Les NetworkPolicies du bonus réseau sont disponibles sans composant de plus.
- Consommation RAM à mesurer avec `kubectl top` sur AWS : si elle coince, le repli est
  Calico, au prix d'un autre mécanisme pour le hostPort (chaînage `portmap`).

## En soutenance

**« Pourquoi Cilium ? »** Il fait fonctionner le hostPort sans kube-proxy, il apporte les
NetworkPolicies du bonus et Hubble pour montrer les flux. Il était déjà validé sur notre
architecture arm64, et on a mesuré son coût mémoire.
