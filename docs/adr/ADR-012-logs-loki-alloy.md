# ADR-012 — Logs : Loki + Alloy

- **Statut :** Acceptée
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12), KUB-42 (J2-05)

## Contexte

Le sujet impose **Loki** pour collecter et visualiser les logs. Le choix porte sur le
collecteur qui lit les logs des pods sur chaque nœud, et sur le mode de déploiement de Loki.

- Promtail, le collecteur historique de Loki, est **déprécié** (fin de support en 2026),
  remplacé par Grafana Alloy.
- Les logs vont sur disque local (ADR-008).
- Budget RAM serré.

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| Promtail | Simple, très documenté | Déprécié |
| **Grafana Alloy** | Successeur officiel ; un seul agent pour logs et, si besoin, métriques | Configuration en langage River, à apprendre |
| Fluent Bit | Léger, polyvalent | Un écosystème de plus, intégration Loki moins directe |
| Loki en mode microservices | Scalable | Inutile à cette échelle, plusieurs pods |
| **Loki en mode mono-binaire, stockage `filesystem`** | Un seul pod, peu de RAM | Pas de haute disponibilité des logs |

## Décision

- **Loki** en mode mono-binaire (`SingleBinary`), stockage `filesystem` sur `local-path`,
  sur node-2 ou node-3, rétention **7 jours** (`retention_period: 168h`).
- **Grafana Alloy** en DaemonSet sur les trois nœuds, qui envoie les logs des pods avec
  leurs labels Kubernetes (namespace, pod, `app.kubernetes.io/*`).
- Datasource Loki dans le même Grafana que les métriques (ADR-011).

## Conséquences

- Corrélation métriques / logs dans une seule interface, utile en démo.
- La recherche par namespace et par label repose sur des labels normalisés : c'est aussi
  une bonne pratique exigée par le sujet.
- Perte des logs d'un nœud si son disque est perdu : acceptable, ils ne sont pas une donnée
  métier.

## En soutenance

**« Pourquoi Alloy et pas Promtail ? »** Promtail est déprécié ; Alloy est son remplaçant
officiel. **« Pourquoi un Loki mono-binaire ? »** Trois nœuds et une rétention de 7 jours ne
justifient pas les microservices.
