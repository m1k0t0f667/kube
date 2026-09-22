# KUBE — *Sailing through the clouds*

Analyse du sujet, stack retenue (avec justifications), livrables documentaires et
chiffrage de charge.

> **Résumé** : déployer un cluster Kubernetes complet sur 3 VM AWS, provisionné par
> Ansible, exposé en HTTPS, authentifié en OIDC, piloté en GitOps, observable, et y
> porter une application Laravel/MySQL aujourd'hui décrite en `docker-compose`.
>
> **Charge totale estimée : ~114,5 j/h** (28,5 formation + 69,5 réalisation + 16,5 documentation),
> ~126 j/h avec les bonus. Détail en [§7](#7-chiffrage-de-la-charge-jh).

---

## 1. L'application à porter

| Élément | Valeur |
|---|---|
| Framework | Laravel 8 (PHP `^7.3\|^8.0\|^8.2`) |
| Image | `php:8.2.8-apache`, `pdo_mysql`, `composer install` au build |
| Fonctionnel | `GET /` → `Counter::sum('count')` rendu dans `welcome.blade.php` |
| Base | MySQL 8, 5 migrations, 2 seeders (`CounterSeeder`, `DatabaseSeeder`) |
| Tests | PHPUnit — `tests/Feature/CounterTest.php` |
| Config | 100 % par variables d'env (`APP_KEY`, `DB_*`) → mappable Secret/ConfigMap sans refacto |
| Compose actuel | `traefik` + `app` + `db` (volume `db_data`) |

**Conséquences directes :**

1. L'app est *stateless* — elle scale horizontalement sans session sticky. Les replicas
   multiples + anti-affinité demandés par le sujet passent sans adaptation du code.
2. `APP_KEY` et `DB_PASSWORD` → **Secret** ; `APP_ENV`, `DB_HOST`, `DB_PORT`,
   `DB_DATABASE` → **ConfigMap**. Conformité immédiate à l'exigence « secrets vs config ».
3. Les migrations doivent sortir du conteneur applicatif : **Helm hook `pre-install,pre-upgrade`**
   (Job `php artisan migrate --force`). Sinon N replicas migrent en parallèle.
4. `composer install` au build + `p7zip`/`git` → image ~800 Mo. Cible du bonus « lightweight
   images » : build multi-stage (composer dans un stage jetable, `--no-dev`,
   `php:8.2-fpm-alpine` + nginx) → ~150 Mo.
5. `APP_KEY` est **en clair dans le `docker-compose.yaml`** livré. À régénérer et à ne
   jamais recommiter (cf. Sealed Secrets, §3).
6. Le `traefik` du compose disparaît : son rôle est repris par l'Ingress Controller du cluster.

---

## 2. Cartographie exigence → solution

Légende : **[I]** = imposé par le sujet · **[J]** = choix libre à justifier en soutenance.

### 2.1 Socle

| # | Exigence | Solution retenue | Justification |
|---|---|---|---|
| 1 | **[I]** Provisionner le cluster avec Ansible, reconstructible | `kubeadm` piloté par rôles Ansible (`common`, `containerd`, `control-plane`, `worker`, `cni`) + `reset.yml` de teardown | `kubeadm` est l'outil de référence : il *montre* les composants (etcd, apiserver, kubelet), ce que la soutenance exige (« responsabilité de chaque composant »). k3s/RKE2 masqueraient tout et rendraient le flag OIDC de l'apiserver moins démonstratif. Inventaire statique + connexion via SSM. |
| 1b | *Terraform en complément ?* | **Écarté** | **L'infrastructure est fournie, pas provisionnée par nous** : VM, EFS, VPC et IAM Identity Center sont livrés par l'école — Terraform déclare ce qu'on crée, et il n'y a presque rien à créer. Le sujet impose Ansible et rien d'autre : Terraform ne coche aucune case notée, ajoute un `tfstate` à héberger, et risque d'échouer au `plan` faute de droits IAM en lecture sur un compte géré par l'école. Coût ~3-4 j/h pour zéro point. **Seul périmètre légitime** — Access Points EFS et rôle IAM du driver EFS CSI, soit 3 ressources : une tâche Ansible avec l'`aws` CLI suffit, sans state à gérer. Pour démontrer de la maturité IaC, le gain noté est ailleurs : l'idempotence réelle des playbooks et un teardown/rebuild propre (« torn down and rebuilt reproducibly »). |
| 2 | CNI | **Cilium** (ou Flannel si on veut le minimum) | Cilium apporte les NetworkPolicies eBPF utiles au bonus « renforcement réseau » et Hubble pour la démo. Flannel = repli si le temps manque. |
| 3 | **[I]** Exposition Ingress ou Gateway API | **Ingress NGINX**, `DaemonSet` + `hostPort: 80/443` sur `kube-1` | Le sujet impose NodePort/sslip.io. **Piège** : Let's Encrypt HTTP-01 frappe le **port 80**, hors plage NodePort (30000-32767). `hostPort` sur le nœud à IP publique stable résout le problème sans load balancer. Gateway API écarté : plus élégant mais l'écosystème cert-manager/OIDC y est moins mûr — risque non nécessaire. |
| 4 | Résolution DNS | `sslip.io` — `app.<IP_PUBLIQUE_KUBE1>.sslip.io` | Imposé de fait, pas de DNS wildcard fourni. L'IP publique de `kube-1` survit aux extinctions nocturnes → certificats TLS valides d'un jour sur l'autre. |
| 5 | **[I]** HTTPS partout | **cert-manager** + `ClusterIssuer` Let's Encrypt (HTTP-01), `Certificate` par Ingress | Imposé. Utiliser **staging** pendant tout le dev (quota prod = 50 certs/semaine/domaine, vite atteint en cluster jetable), bascule prod en fin de projet. |
| 5b | **[J]** PKI interne (TLS intra-cluster) | Second `ClusterIssuer` de type **CA** (`SelfSigned` → CA racine → issuer) + **trust-manager** pour distribuer le bundle | **Deux issuers, deux périmètres.** `letsencrypt-prod` pour tout ce qui est exposé (le navigateur doit faire confiance, et l'apiserver doit valider l'issuer OIDC de dex sans qu'on lui injecte une CA maison). `internal-ca` pour tout ce qui ne sort jamais du cluster : TLS MySQL, webhooks, scraping Prometheus, mTLS. Bénéfice réel : **aucun quota ACME**, là où un cluster reconstruit souvent épuise vite les 50 certs/semaine (cf. risque 2). Attention au contresens : la rotation automatique n'est **pas** l'argument — cert-manager renouvelle déjà seul à 2/3 de la durée de vie. trust-manager évite de recopier le bundle CA à la main dans chaque namespace. |
| 5c | *Vault (moteur PKI) ?* | **Écarté** | La bonne réponse en production, un piège ici : un composant stateful de plus à opérer et sauvegarder, et surtout **à desceller (`unseal`) après chaque extinction nocturne** des VM. Le coût d'exploitation quotidien dépasse le gain. |
| 5d | PKI du cluster lui-même | Générée par `kubeadm` (CA apiserver, CA etcd, front-proxy), validité 1 an, `kubeadm certs renew` | À ne pas confondre avec les deux issuers ci-dessus. Alimente directement le bonus « documentation de la montée de version ». |

### 2.2 Outillage cluster

| # | Exigence | Solution retenue | Justification |
|---|---|---|---|
| 6 | **[J]** Dashboard | **Headlamp** | Supporte nativement l'OIDC (`oidc-client-id`/`oidc-issuer-url` en flags) alors que kubernetes-dashboard impose un contournement par token. Le sujet demande que *tous* les outils soient couverts par l'OIDC : Headlamp fait gagner du temps. Extensible par plugins, UI moderne. |
| — | *Rancher ?* | **Écarté** | Rancher est un *gestionnaire de clusters*, pas un dashboard : il embarque sa propre couche d'auth, son propre ingress, son propre modèle RBAC — qui entreraient en conflit frontal avec dex/Keycloak et l'admission native exigés. Coût RAM ~2-3 Go sur des VM de TP. À citer en soutenance comme alternative évaluée et rejetée pour périmètre. |
| 7 | **[J]** Monitoring + alerting | **kube-prometheus-stack** (Prometheus Operator, Grafana, Alertmanager, node-exporter, kube-state-metrics) | Un seul chart couvre collecte + visualisation + alerting (les 3 verbes du sujet). CRDs `ServiceMonitor`/`PrometheusRule` = configuration déclarative, donc GitOps-compatible. VictoriaMetrics est plus sobre en RAM mais son écosystème d'alerting demande plus de câblage manuel. |
| 8 | **[I]** Logging | **Loki** (mono-binaire, mode `filesystem`) + **Grafana Alloy** comme collecteur | Loki imposé. Alloy remplace Promtail (déprécié fin 2025) et unifie logs + métriques. Datasource Grafana partagée avec Prometheus → corrélation métrique/log en démo. |
| 9 | **[J]** Opérateur GitOps | **ArgoCD** | UI de réconciliation lisible → indispensable pour *montrer* le sync et le health en soutenance (le sujet l'exige explicitement). FluxCD est excellent mais sans UI, la démo se fait en `kubectl` et convainc moins. Bonus : ArgoCD parle OIDC nativement (dex embarqué, qu'on remplacera par notre dex). |
| 10 | **[I]** Manifestes en Kustomize | `base/` + `overlays/` par composant, pattern **App-of-Apps** ArgoCD | Imposé. L'App-of-Apps rend le cluster reconstructible en un `kubectl apply` unique après le bootstrap Ansible. |
| 11 | **[I]** Registry privé authentifié | **Harbor** si la RAM le permet, sinon **Zot** | **Exigence imposée, pas une option** (« publish your application image to a private authenticated registry »). Harbor apporte l'auth OIDC, les robot accounts pour le CI et **Trivy intégré** → le bonus « sécurité des artefacts Helm » devient gratuit. Contrepartie : ~8 pods, 1,5-2 Go. Zot = 1 pod, ~100 Mo, auth OCI, mais ni scan ni OIDC. `distribution/registry` + `htpasswd` = repli minimal, au prix d'une entorse à « l'OIDC couvre tous les outils ». **Arbitrage à faire tôt, selon la taille des instances** (cf. risque 8). Pull par `imagePullSecrets`. |

### 2.3 Identité et sécurité

| # | Exigence | Solution retenue | Justification |
|---|---|---|---|
| 12 | **[I]** OIDC via dex, **[J]** IdP auto-hébergé | **Keycloak** (IdP, source de vérité) ← fédéré par **dex** (broker OIDC unique) | Le sujet impose dex et laisse l'IdP libre. Keycloak est le seul IdP auto-hébergeable réellement complet (realms, groupes, mappers de claims, fédération, MFA) et c'est celui qui est cité. Architecture : Keycloak détient les users/groupes → dex fédère Keycloak en `connector: oidc` → dex est le **seul** `--oidc-issuer-url` déclaré à l'API server et le seul client configuré dans chaque outil. Un seul point d'intégration à maintenir. |
| 13 | **[I]** Couverture OIDC de *tous* les outils | ArgoCD (`oidc.config`), Grafana (`auth.generic_oauth`), Headlamp (flags OIDC), Harbor (auth OIDC), `kubectl` (`kubelogin` / `kubectl oidc-login`), **API server** (`--oidc-issuer-url`, `--oidc-client-id`, `--oidc-groups-claim`) | C'est le point le plus noté et le plus long. L'API server est le plus délicat (voir §5, risque 1). Mapper les groupes Keycloak → `ClusterRoleBinding` (ex. `kube-admins`, `kube-devs`) couvre aussi le bonus RBAC. |
| 14 | **[I]** Admission policy native (CEL) | `ValidatingAdmissionPolicy` + `ValidatingAdmissionPolicyBinding` — 3 politiques : (a) `requests`/`limits` CPU+RAM obligatoires, (b) labels `app.kubernetes.io/*` obligatoires, (c) images issues du registry privé uniquement | Imposé « native » : **ni Kyverno ni Gatekeeper**. GA depuis k8s 1.30. Se teste en 10 s en démo (`kubectl apply` d'un pod sans limits → refus). Prévoir des `matchConditions` excluant `kube-system` pour ne pas casser le cluster. |
| 15 | **[I]** Aucun secret en clair dans Git | **Sealed Secrets** (Bitnami) | External Secrets supposerait un backend externe (Vault/AWS SM) → une brique de plus à opérer et à sécuriser. Sealed Secrets chiffre avec une clé publique, le contrôleur déchiffre dans le cluster : le `SealedSecret` est commitable sans risque. **Attention** : sauvegarder la clé privée du contrôleur, sinon un cluster reconstruit ne sait plus déchiffrer (à traiter dans le playbook Ansible). |
| 16 | **[I]** Secrets vs ConfigMaps | Secret : `APP_KEY`, `DB_PASSWORD`, `MYSQL_ROOT_PASSWORD`, credentials registry, client secrets OIDC. ConfigMap : `APP_ENV`, `APP_DEBUG`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `LOG_CHANNEL` | Découpage direct depuis le `docker-compose.yaml` existant. |

### 2.4 Bonnes pratiques d'exploitation

| # | Exigence | Solution retenue | Justification |
|---|---|---|---|
| 17 | **[I]** Requests / limits | Valeurs dans `values.yaml` du chart + `LimitRange` par namespace, **rendues obligatoires par la VAP (#14)** | La politique d'admission transforme la bonne pratique en garantie. |
| 18 | **[I]** Labels normalisés | `app.kubernetes.io/{name,instance,version,component,part-of,managed-by}` sur toutes les ressources, via `commonLabels` Kustomize et les helpers Helm | Recommandations officielles Kubernetes, contrôlées par la VAP. |
| 19 | **[I]** Redondance + anti-affinité | `replicas: 3` sur l'app + `podAntiAffinity` `requiredDuringScheduling` sur `kubernetes.io/hostname` | `required` (et non `preferred`) pour *prouver* en démo que deux replicas ne peuvent pas atterrir sur le même nœud. 2 workers ⇒ plafonner à 2-3 replicas. |
| 20 | **[I]** Stockage persistant sur EFS | **aws-efs-csi-driver** + `StorageClass` EFS + Access Point dédié, PVC pour MySQL | Imposé. **Réserve technique à assumer en soutenance** : EFS est du NFS, et MySQL/InnoDB sur NFS a des limites de verrouillage et des performances médiocres. Acceptable dans le cadre du TP (le sujet l'impose) ; à documenter comme écart volontaire vis-à-vis d'une prod réelle, où l'on utiliserait EBS/`local-path` + réplication. |
| 21 | **[J]** Base de données | Chart officiel **Bitnami MySQL** (architecture `standalone`) | Le sujet impose « le chart officiel pour la base ». Standalone suffit : pas de réplication demandée, et 2 workers ne justifient pas un cluster MySQL. |
| 22 | **[I]** CronJob à besoin réel | `mysqldump` quotidien → PVC EFS `backups/`, rétention 7 jours, **+ `PrometheusRule` alertant si le backup n'a pas tourné en 26 h** | Répond littéralement à « volume backup ». L'alerte associée relie le CronJob à la stack de monitoring et enrichit la démo. |
| 23 | **[I]** Deux repos GitOps séparés | `kube-infra` (cluster, composants, observabilité, sécurité) et `kube-app` (application convertie) | Imposé. Deux `Application` ArgoCD distinctes, deux cycles de vie, deux jeux de droits. |

### 2.5 Démonstration

| # | Exigence | Solution retenue |
|---|---|---|
| 24 | **[I]** Provisioning d'un cluster neuf en live | `ansible-playbook site.yml` (~10-15 min) ; prévoir une capture vidéo de secours + un cluster déjà prêt en parallèle. |
| 25 | **[I]** Nouvelle version déployée *par GitOps* | Commit du tag d'image dans `kube-app` → ArgoCD réconcilie. **Pas** de `kubectl apply` manuel. |
| 26 | **[I]** Rollout progressif sans coupure | `RollingUpdate` `maxUnavailable: 0` / `maxSurge: 1` + `readinessProbe` sur `/` + `PodDisruptionBudget` |
| 27 | **[I]** Version fautive qui ne prend pas la main | Tag `v-broken` avec readiness probe pointant vers une route inexistante → les nouveaux pods restent `0/1 Ready`, l'ancienne version continue de servir. Preuve : `kubectl get pods` + boucle `curl` en 200 permanent. |
| 28 | **[I]** Preuves OIDC / HTTPS / admission | (a) login Keycloak sur Grafana + `kubectl` sans kubeconfig admin ; (b) `curl -v` montrant le certificat LE valide ; (c) `kubectl apply` d'un pod non conforme → message de refus de la VAP. |

### 2.6 Bonus

| Bonus | Solution | Coût |
|---|---|---|
| Multi-tenancy Prometheus/Loki | `kube-rbac-proxy` en sidecar | 2 j/h |
| Sécurité des artefacts Helm | Trivy (déjà dans Harbor) + `helm lint` en CI | 1 j/h (quasi offert) |
| RBAC fin | Groupes Keycloak → Roles/ClusterRoles (dev = lecture seule sur son namespace) | 2 j/h |
| Renforcement réseau | NetworkPolicies Cilium (deny-all + allow explicite) | 2 j/h |
| Images légères | Build multi-stage (§1.4) | 1,5 j/h |
| Zéro-downtime prouvé | `vegeta`/`hey` pendant le rollout, rapport 100 % HTTP 200 | 1 j/h |
| Doc de montée de version | Runbook `kubeadm upgrade` + `drain`/`uncordon` | 1,5 j/h |
| **Total bonus** | | **~11 j/h** |

---

## 3. Architecture cible

```
                        Internet
                            │  HTTPS (443) / HTTP-01 (80)
                            ▼
              ┌─────────────────────────────┐
              │  kube-1  (IP publique fixe) │  control-plane + worker
              │  ─────────────────────────  │
              │  Ingress NGINX (hostPort)   │
              │  etcd · apiserver           │  --oidc-issuer-url=https://dex...
              │  scheduler · controller-mgr │
              └──────────────┬──────────────┘
                             │ réseau privé VPC (IP privées stables)
              ┌──────────────┴──────────────┐
              ▼                             ▼
       ┌────────────┐               ┌────────────┐
       │   kube-2   │               │   kube-3   │   workers
       │  worker    │               │  worker    │   (IP publiques volatiles
       └─────┬──────┘               └──────┬─────┘    → ne rien y accrocher)
             └───────────┬─────────────────┘
                         ▼
              Amazon EFS  (NFS partagé, via aws-efs-csi-driver)
                  └── PV MySQL · PV backups

Workloads
─────────
 identité      Keycloak ──fédération──▶ dex ──OIDC──▶ apiserver, kubectl,
                                                      ArgoCD, Grafana,
                                                      Headlamp, Harbor
 gitops        ArgoCD ──▶ repo kube-infra (kustomize)
                      └─▶ repo kube-app   (kustomize → chart Helm)
 observabilité Prometheus · Alertmanager · Grafana · Loki · Alloy
 sécurité      cert-manager · Sealed Secrets · ValidatingAdmissionPolicy
 registry      Harbor (images applicatives, pull par imagePullSecrets)
 application   Deployment app ×3 (anti-affinité) · Service · Ingress TLS
               MySQL (chart Bitnami) · PVC EFS · CronJob mysqldump
```

**Flux OIDC** : `utilisateur → dex (issuer unique) → Keycloak (IdP) → id_token
(claims email + groups) → consommé par l'API server et par chaque outil`.
Un seul issuer à déclarer, un seul point de défaillance à surveiller.

### Découpage des dépôts

```
kube-infra/                          kube-app/
├── ansible/                         ├── chart/            # chart Helm de l'app
│   ├── inventory/                   │   ├── Chart.yaml    #   dépendance: mysql (Bitnami)
│   ├── roles/                       │   ├── values.yaml
│   │   ├── common/                  │   └── templates/
│   │   ├── containerd/              │       ├── deployment.yaml
│   │   ├── control-plane/           │       ├── service.yaml
│   │   ├── worker/                  │       ├── ingress.yaml
│   │   ├── cni/                     │       ├── configmap.yaml
│   │   └── bootstrap-argocd/        │       ├── sealedsecret.yaml
│   ├── site.yml                     │       ├── job-migrate.yaml   # hook Helm
│   └── reset.yml                    │       ├── cronjob-backup.yaml
├── clusters/prod/                   │       └── pdb.yaml
│   └── app-of-apps.yaml             ├── k8s/
├── components/                      │   ├── base/
│   ├── ingress-nginx/               │   └── overlays/{staging,prod}/
│   ├── cert-manager/                ├── .github/workflows/
│   ├── argocd/                      │   └── build-push.yml   # build → Harbor → bump tag
│   ├── keycloak/                    └── docs/
│   ├── dex/
│   ├── kube-prometheus-stack/
│   ├── loki/
│   ├── headlamp/
│   ├── harbor/
│   ├── sealed-secrets/
│   ├── efs-csi/
│   └── admission-policies/
└── docs/
```

---

## 4. Livrables documentaires

Le sujet est explicite : *« Documentation is mandatory, especially the cluster
provisioning, the container setup steps and the commands. »* Sept documents,
répartis sur les deux dépôts.

> **Prérequis transverse** : [`docs/contraintes-et-outillage.md`](docs/contraintes-et-outillage.md)
> — relevé des droits AWS réellement accordés (vérifiés par appel API) et, exigence par
> exigence, la manière de faire compatible. Il corrige trois points de ce README
> (connexion Ansible, périmètre Terraform, type d'instance) et fixe la stratégie de
> stockage des composants stateful. À lire avant D2, D3 et D6.

| # | Document | Dépôt | Contenu | Charge |
|---|---|---|---|---|
| D1 | `README.md` racine × 2 | les deux | Objet du dépôt, prérequis, démarrage rapide, arborescence, index des docs | 2 j/h |
| D2 | `docs/provisioning.md` | infra | **Le plus important.** Accès SSM, inventaire, rôles Ansible commentés un par un, exécution, vérification, teardown, reconstruction, dépannage | 3 j/h |
| D3 | `docs/architecture.md` | infra | Schémas (réseau, flux OIDC, flux GitOps), rôle et responsabilité de chaque composant, **tableau des choix justifiés + alternatives écartées** (support direct de la soutenance) | 2,5 j/h |
| D4 | `docs/gitops.md` | les deux | App-of-Apps, convention de branches, cycle commit → sync → health, procédure de rollback | 1,5 j/h |
| D5 | `docs/security.md` | infra | Chaîne OIDC de bout en bout, configuration client par outil, cycle de vie Sealed Secrets (**dont sauvegarde/restauration de la clé privée**), **les deux chaînes de certification (ACME publique / CA interne) et leur périmètre**, politiques d'admission et leur test, matrice RBAC | 2,5 j/h |
| D6 | `docs/operations.md` | infra | Runbooks : redémarrage après extinction nocturne, montée de version du cluster (`drain`/`upgrade`/`uncordon`), backup et **restauration vérifiée**, renouvellement des certificats, incidents fréquents | 2 j/h |
| D7 | `docs/demo.md` + support | infra | Script minuté de la soutenance, commandes copiables, plan B si le réseau lâche, répétition | 3 j/h |
| | **Total documentation** | | | **16,5 j/h** |

**Règles de rédaction** : toute commande est copiable et testée ; tout schéma est en
Mermaid (versionné, diffable) ; chaque décision technique porte sa justification *et*
l'alternative écartée ; la doc s'écrit **au fil de l'eau**, pas la dernière semaine —
c'est le poste qui saute systématiquement sous pression, et c'est un poste noté.

---

## 5. Risques identifiés

| # | Risque | Impact | Mitigation |
|---|---|---|---|
| 1 | **Démarrage circulaire de l'OIDC** : l'API server exige `--oidc-issuer-url` joignable en TLS valide, mais dex tourne *dans* le cluster derrière l'ingress et cert-manager | Bloquant, plusieurs jours perdus | Séquencer : cluster nu → ingress → cert-manager → certificat obtenu → Keycloak → dex → **puis** patch du manifeste statique de l'apiserver par Ansible et redémarrage. Garder en permanence un kubeconfig `cluster-admin` de secours hors OIDC. |
| 2 | **Quota Let's Encrypt prod** (50 certs/domaine/semaine) épuisé par les reconstructions répétées | Perte du HTTPS en démo | `ClusterIssuer` staging pendant tout le développement ; bascule prod uniquement en fin de projet. |
| 3 | **Extinction nocturne** des VM | Cluster cassé chaque matin | Rendre le redémarrage idempotent dès le début : `kubelet` et `containerd` en `enabled`, pas de dépendance aux IP publiques des workers, playbook `restart-check.yml`. Traité dans D6. |
| 4 | **MySQL sur EFS/NFS** : verrouillage InnoDB et latence | Instabilité de la base | Access Point EFS avec UID/GID corrects, `innodb_flush_method` adapté, tests de charge tôt. Écart assumé et documenté (§2.4 #20). |
| 5 | **VAP trop stricte** bloquant les composants système | Cluster inutilisable | `matchConditions` excluant les namespaces système ; déployer d'abord en `validationActions: [Warn]`, passer en `Deny` après observation. |
| 6 | **Perte de la clé Sealed Secrets** lors d'une reconstruction | Tous les secrets illisibles | Export de la clé dans le playbook, restauration automatique au bootstrap. Procédure dans D5. |
| 7 | **Sous-estimation de la couverture OIDC** (6 intégrations distinctes) | Poste le plus noté, le plus long | 6 j/h budgétés, à attaquer en semaine 2-3, pas en dernier. |
| 8 | **Budget RAM des instances insuffisant** pour l'ensemble des composants | Éviction de pods, cluster instable, arbitrages en urgence | **À vérifier dès le premier jour.** Ordre de grandeur : Prometheus ~2 Go, Harbor ~2 Go, Keycloak ~1 Go, app + MySQL ~1 Go, ArgoCD ~500 Mo, Loki ~500 Mo, divers ~500 Mo → **~7 Go de workloads**. Sur 3× `t3.medium` (12 Go bruts, ~9 utilisables après système et kubelet) cela passe, mais sans marge. En dessous, remplacer Harbor par Zot (#11) et Prometheus par VictoriaMetrics. |

---

## 6. Séquencement conseillé

| Phase | Contenu | Charge | Jalon |
|---|---|---|---|
| 0 | Formation (§7.1) — en partie parallélisable avec la phase 1 | 28 j/h | L'équipe sait lire un manifeste et écrire un rôle Ansible |
| 1 | Accès AWS/SSM, EFS monté, cluster kubeadm par Ansible, CNI | 12 j/h | `kubectl get nodes` = 3 Ready, reconstructible |
| 2 | Ingress + cert-manager + sslip.io + HTTPS | 5 j/h | Une URL publique en HTTPS valide |
| 3 | ArgoCD + repo infra + App-of-Apps | 4 j/h | Le cluster se pilote par commit |
| 4 | **Keycloak + dex + couverture OIDC complète** | 10 j/h | `kubectl` et tous les outils authentifient via Keycloak |
| 5 | Observabilité (Prometheus, Grafana, Loki, alertes) | 6,5 j/h | Dashboards + une alerte qui se déclenche |
| 6 | Harbor, Sealed Secrets, VAP, EFS CSI | 9 j/h | Pipeline d'image privée + secrets chiffrés + admission active |
| 7 | Chart Helm de l'app, MySQL, repo GitOps app | 10 j/h | App en ligne, HTTPS, 3 replicas anti-affinés |
| 8 | Bonnes pratiques, CronJob backup, rollout progressif, version fautive | 7,5 j/h | Démo de rollout sûr rejouable |
| 9 | Documentation (§4) | 16 j/h | 7 documents livrés |
| 10 | Bonus (§2.6) | 11 j/h | Optionnel |
| 11 | Répétition, durcissement, marge | 4 j/h | Soutenance prête |

> La phase 4 est le chemin critique. Toute dérive s'y propage intégralement.

---

## 7. Chiffrage de la charge (j/h)

**Hypothèses** : équipe partant de **zéro sur AWS et Kubernetes**, Docker de niveau
basique. Un j/h = 1 journée-homme de 7 h productives. Estimation à effort
constant, hors temps d'attente.

### 7.1 Formation — 28,5 j/h

| Sujet | Charge | Justification |
|---|---|---|
| AWS : IAM Identity Center, SSM Session Manager, VPC, EFS | 2 | Périmètre étroit : pas de console AWS à maîtriser, juste s'y connecter et monter un EFS. |
| Linux serveur + Ansible (inventaire, rôles, idempotence) | 3 | Ansible s'apprend vite, l'idempotence beaucoup moins. |
| **Kubernetes — fondamentaux** : Pod, Deployment, Service, Ingress, ConfigMap/Secret, PV/PVC, probes, resources, RBAC, affinité | **8** | Le poste le plus lourd et incompressible. Le delta « Docker basique → Kubernetes » est le vrai coût du projet. |
| Helm (templating, values, hooks, dépendances) | 2 | |
| Kustomize + principes GitOps + ArgoCD | 3 | Le modèle déclaratif/réconciliation demande un vrai changement de réflexe. |
| OAuth2 / OIDC / JWT, dex, Keycloak | 3 | Conceptuellement le point le plus abstrait de tout le projet. |
| Prometheus (PromQL), Grafana, Loki (LogQL) | 3 | |
| TLS, PKI, ACME, cert-manager (dont chaîne de confiance d'une CA privée) | 2 | |
| Sealed Secrets | 1 | |
| CEL + ValidatingAdmissionPolicy | 1,5 | Syntaxe CEL peu familière, documentation encore mince. |
| **Sous-total** | **28,5** | |

*Levier* : ~8 j/h de cette formation sont récupérables si un membre de l'équipe a
déjà pratiqué Kubernetes.

### 7.2 Réalisation — 69,5 j/h

| Lot | Charge |
|---|---|
| Accès AWS, SSM, montage EFS, préparation des VM | 2 |
| **Ansible : provisioning kubeadm complet, idempotent, teardown/rebuild** | **8** |
| CNI + validation réseau | 2 |
| Ingress NGINX + hostPort + sslip.io | 2 |
| cert-manager + Let's Encrypt (HTTP-01 via hostPort) | 3 |
| PKI interne : `ClusterIssuer` CA + trust-manager + TLS intra-cluster | 1,5 |
| Harbor + imagePullSecrets + push d'image | 3 |
| ArgoCD + repo infra kustomize + App-of-Apps | 4 |
| Headlamp + intégration OIDC | 2 |
| kube-prometheus-stack + dashboards + règles d'alerte | 4 |
| Loki + Alloy + datasource Grafana | 2,5 |
| Keycloak (déploiement, persistance, realm, groupes) | 4 |
| **dex + câblage OIDC : apiserver, kubectl, ArgoCD, Grafana, Headlamp, Harbor** | **6** |
| Sealed Secrets + migration de tous les secrets | 2 |
| ValidatingAdmissionPolicy (3 politiques + tests) | 2 |
| EFS CSI driver + StorageClass + PV/PVC | 2 |
| **Chart Helm de l'application** (templates, values, hooks migration) | **4** |
| Chart MySQL Bitnami + init base + seeders | 2 |
| Repo GitOps app + Application ArgoCD + sync/health | 2 |
| Labels, requests/limits, replicas, anti-affinité sur tout le parc | 2 |
| CronJob backup + rétention + alerte associée | 1,5 |
| CI build/push image + bump de tag | 2 |
| Rollout progressif + version fautive + preuve de non-bascule | 2 |
| **Intégration, debug, durcissement** (aléas, reprises, reconstructions) | **6** |
| **Sous-total** | **69,5** |

### 7.3 Documentation — 16,5 j/h

Détail par document en [§4](#4-livrables-documentaires).

### 7.4 Synthèse

| Poste | Charge |
|---|---|
| Formation | 28,5 j/h |
| Réalisation | 69,5 j/h |
| Documentation | 16,5 j/h |
| **Total périmètre obligatoire** | **114,5 j/h** |
| Bonus (optionnel) | +11 j/h |
| **Total avec bonus** | **~126 j/h** |

### 7.5 Traduction en calendrier

| Taille d'équipe | Durée (périmètre obligatoire) | Commentaire |
|---|---|---|
| 3 personnes | ~7,5 semaines à temps plein | Confortable, bonus atteignables |
| 4 personnes | **~5,5 semaines à temps plein** | Cadence recommandée |
| 4 personnes à mi-temps | ~11 semaines | Cadence réaliste en cursus |

**Réserves sur l'estimation :**

- La parallélisation est **imparfaite** : les phases 1 → 2 → 4 sont strictement
  séquentielles (pas d'OIDC sans TLS, pas de TLS sans ingress, pas d'ingress sans
  cluster). Au-delà de 4 personnes, le rendement marginal chute.
- Les 6 j/h d'« intégration/debug » sont un **plancher**, pas une marge de confort.
  Sur un cluster éteint chaque nuit et reconstruit souvent, ils peuvent doubler.
- Si l'équipe dispose déjà d'une expérience Kubernetes, retirer ~8 j/h de formation
  et ~5 j/h de réalisation (moins de tâtonnement) → **~99 j/h**.
- Chiffrage **hors** temps d'attente (provisioning AWS, propagation DNS, émission
  des certificats), qui n'est pas du travail mais consomme du calendrier.

---

## 8. Points de vigilance pour la soutenance

Le sujet répète trois fois « justified choice ». Chaque brique doit avoir sa réponse
prête — **le tableau §2 est la réponse**, et le document D3 en est le support.

À savoir défendre sans hésiter :

1. **Pourquoi Ingress NGINX plutôt que Gateway API ?** → maturité de l'écosystème
   cert-manager/OIDC ; Gateway API est l'avenir mais aurait ajouté du risque sur un
   chemin critique.
2. **Pourquoi ArgoCD plutôt que FluxCD ?** → l'exigence de *montrer* sync et health.
3. **Pourquoi Keycloak derrière dex plutôt que dex seul ?** → dex est un *broker*, pas
   un magasin d'utilisateurs ; le sujet demande un IdP déployé par nos soins.
4. **Pourquoi Headlamp et pas Rancher ?** → périmètre (dashboard vs gestionnaire de
   clusters) et conflit avec l'auth et l'admission natives exigées.
5. **Pourquoi Sealed Secrets plutôt qu'External Secrets ?** → pas de backend externe à
   opérer ; contrepartie assumée : la clé privée devient un actif critique à sauvegarder.
6. **Pourquoi deux autorités de certification ?** → périmètres disjoints : ACME pour l'exposé
   (confiance du navigateur, pas de CA maison à injecter dans l'apiserver), CA interne pour
   l'intra-cluster (aucun quota, révocation immédiate). Et savoir dire que la rotation
   automatique vient de cert-manager, pas du choix de CA.
7. **Pourquoi pas Terraform ?** → l'infrastructure est fournie, pas créée ; le sujet impose
   Ansible ; la reproductibilité notée est celle du cluster, et elle est dans les playbooks.
8. **Pourquoi MySQL sur EFS malgré les limites de NFS ?** → imposé par le sujet ; écart
   documenté, et l'on saurait dire ce qu'on ferait en production.
