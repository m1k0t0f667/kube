# ADR-011 — Métriques et alertes : VictoriaMetrics + Grafana

- **Statut :** Acceptée — remplace le choix kube-prometheus-stack du README
- **Date :** 2026-10-11
- **Tickets :** KUB-66 (J0-12), KUB-39 (J2-02), KUB-40 (J2-03) — arbitrage A4

## Contexte

Le sujet demande une stack qui **collecte, visualise et alerte** sur les métriques système
et applicatives (« kube-prometheus or VictoriaMetrics, justified choice »).

- Budget RAM : environ 9 Go utilisables sur 12. L'estimation initiale avec
  kube-prometheus-stack et Harbor arrivait à ~7 Go de charges, « sans marge ».
- Le guide de l'école prévoit une bascule vers des instances à 2 Go en cas de manque de
  capacité AWS : la marge peut fondre sans prévenir.
- Les métriques vont sur disque local (ADR-008), 30 Go par nœud non extensibles.

## Options envisagées

| Option | Pour | Contre |
|---|---|---|
| kube-prometheus-stack | Standard de fait ; très documenté | Prometheus ~2 Go de RAM ; stockage plus volumineux |
| **victoria-metrics-k8s-stack** | Plusieurs fois moins de RAM et de disque ; reprend les CRD `ServiceMonitor` et `PrometheusRule` ; PromQL compatible (MetricsQL) ; Alertmanager et Grafana inclus | Moins répandu |

## Décision

**victoria-metrics-k8s-stack** : VMSingle, VMAgent, VMAlert, Alertmanager, Grafana,
node-exporter, kube-state-metrics.

- Rétention **7 jours**, sur `local-path`, sur node-2 ou node-3.
- Règles d'alerte en `PrometheusRule` (converties automatiquement par l'opérateur), donc
  versionnées dans Git.
- Grafana exposé en HTTPS, authentifié par OIDC (ADR-015), dashboards provisionnés en
  ConfigMap.

## Conséquences

- Les dashboards et règles écrits pour Prometheus restent utilisables tels quels.
- Au moins une alerte doit réellement se déclencher en démo (nœud indisponible, mémoire
  au-dessus de 85 %, disque bas, sauvegarde absente depuis 26 h).
- Si les mesures sur AWS montrent une marge confortable, on peut revenir à
  kube-prometheus-stack : ce serait un nouvel ADR.

## En soutenance

**« Pourquoi VictoriaMetrics ? »** Pour les mêmes fonctions et les mêmes CRD que Prometheus,
pour une fraction de la mémoire, sur des nœuds à 4 Go qui peuvent passer à 2 Go sans
préavis.
