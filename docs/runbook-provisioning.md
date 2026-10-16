# Runbook — provisioning du cluster

Les commandes exactes, dans l'ordre, pour passer de trois VMs vierges à un cluster
complet, puis pour le détruire et le reconstruire. Les pièges rencontrés sont signalés là
où ils se produisent, et regroupés en fin de document.

> **Validation (KUB-75)** : ce runbook est terminé quand une personne qui ne l'a pas
> écrit le rejoue seule, du début à la fin. Noter ici qui l'a rejoué, quand, et ce qui
> a coincé.

Pourquoi la procédure a cette forme : le port 22 est fermé depuis Internet, le security
group n'est pas modifiable, et `ssm:SendCommand` est refusé. Ansible tourne donc **sur
`node-1`**, et Git sert de canal pour transférer les fichiers. Détail dans
[contraintes-et-outillage.md](contraintes-et-outillage.md), §1 et §4.

| Nœud | Instance | IP privée |
|---|---|---|
| `node-1` | i-082cacf2f59f8ddd4 | 10.0.0.80 (EIP 15.224.60.53) |
| `node-2` | i-0f11f75585a35e303 | 10.0.0.17 |
| `node-3` | i-03f48443ef76c0707 | 10.0.0.143 |

---

## Partie A — Poste de développement (une fois)

**A1. Outils**

```bash
brew install awscli
brew install --cask session-manager-plugin
```

> ⚠ Sans `session-manager-plugin`, `aws ssm start-session` crée la session côté AWS
> puis échoue à l'ouvrir, avec une erreur trompeuse qui parle de `TerminateSession`.

**A2. Profil AWS.** Ajouter à `~/.aws/config` :

```ini
[sso-session epitech]
sso_start_url = https://ssoins-66566efc3ab8cb5f.portal.eu-west-3.app.aws
sso_region = eu-west-3
sso_registration_scopes = sso:account:access

[profile kubequest2]
sso_session = epitech
sso_account_id = 434352151741
sso_role_name = kubequest2-student
region = eu-west-3
```

**A3. Connexion** (à refaire quand le jeton expire) :

```bash
aws sso login --profile kubequest2
aws sts get-caller-identity --profile kubequest2   # doit afficher le compte 434352151741
```

> ⚠ Sur le poste : **toujours** `--profile kubequest2`. Dans une session SSM :
> **jamais**, les identifiants viennent de l'instance.

---

## Partie B — Démarrer les nœuds (chaque jour)

Les VMs sont éteintes chaque soir par l'école.

```bash
aws ec2 start-instances --profile kubequest2 \
  --instance-ids i-082cacf2f59f8ddd4 i-0f11f75585a35e303 i-03f48443ef76c0707

# attendre que les trois soient « Online » (environ une minute)
aws ssm describe-instance-information --profile kubequest2 \
  --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus}' --output table
```

> ⚠ `TargetNotConnected` à l'ouverture d'une session : les VMs sont arrêtées, ou l'agent
> SSM n'est pas encore enregistré. Relancer la commande de vérification.

---

## Partie C — Préparer `node-1` (une fois par jeu de VMs)

**C1. Ouvrir une session et passer en `ec2-user`**

```bash
aws ssm start-session --profile kubequest2 --target i-082cacf2f59f8ddd4
```

Puis, dans la session :

```bash
sudo su - ec2-user
```

> ⚠ La session SSM démarre en `ssm-user`. Ansible, sa clé SSH et ses collections
> appartiennent à `ec2-user` : **toujours** faire `sudo su - ec2-user` avant de travailler.

**C2. Cloner le dépôt**

```bash
sudo dnf install -y git
git clone https://github.com/m1k0t0f667/kube.git ~/kube-infra
```

**C3. Installer les outils du control node**

```bash
sudo bash ~/kube-infra/ansible/bootstrap/node1-setup.sh
```

Le script installe `ansible-core`, `git`, `tmux`, `jq`, `k9s` et les collections Ansible,
génère la clé SSH `~/.ssh/id_ed25519`, fait quelques vérifications (arm64, pas de swap,
`/mnt/efs` monté, sortie Internet), puis **affiche la clé publique** et les commandes à
coller sur les workers.

> Lancer le script **depuis le clone** : il y lit `requirements.yml`. Lancé seul
> (`curl … | sudo bash`), il installe une copie de cette liste, à tenir à jour à la main.

**C4. Autoriser `node-1` sur chaque worker.** Ouvrir une session par worker, depuis le
poste :

```bash
aws ssm start-session --profile kubequest2 --target i-0f11f75585a35e303   # node-2
aws ssm start-session --profile kubequest2 --target i-03f48443ef76c0707   # node-3
```

Dans chaque session, coller les quatre commandes affichées par le script à l'étape C3.
Elles ont cette forme :

```bash
sudo install -d -m 700 -o ec2-user -g ec2-user /home/ec2-user/.ssh
echo '<CLE_PUBLIQUE>' | sudo tee -a /home/ec2-user/.ssh/authorized_keys >/dev/null
sudo chown ec2-user:ec2-user /home/ec2-user/.ssh/authorized_keys
sudo chmod 600 /home/ec2-user/.ssh/authorized_keys
```

---

## Partie D — Provisionner

Sur `node-1`, en `ec2-user`.

**D1. Ouvrir un `tmux`**

```bash
tmux new -s kube
```

> ⚠ Indispensable : une session SSM qui tombe tue le playbook en cours. Pour reprendre
> après une déconnexion : rouvrir une session, `sudo su - ec2-user`, puis
> `tmux attach -t kube`.

**D2. Vérifier les nœuds**

```bash
cd ~/kube-infra/ansible
git pull
ansible-playbook playbooks/connectivity.yml
```

Doit passer entièrement : les trois nœuds répondent, sont en arm64, ont la mémoire
attendue, l'EFS est monté et Internet est joignable.

**D3. Monter le cluster**

```bash
ansible-playbook site.yml
```

`ansible.cfg` désigne déjà `inventory/hosts.yml` : pas besoin de `-i`. Étapes, dans
l'ordre : socle des trois nœuds, control plane, workers, Cilium, Traefik, cert-manager,
ArgoCD. Le playbook vérifie lui-même que le port 80, le NodePort 30080 et la redirection
HTTPS répondent, puis affiche l'URL et le mot de passe d'ArgoCD.

Pour rejouer une seule étape : `ansible-playbook site.yml --tags <tag>`, avec `socle`,
`control-plane`, `workers`, `cni`, `ingress`, `pki` ou `gitops`.

---

## Partie E — Vérifier

Sur `node-1`, en `ec2-user` :

```bash
kubectl get nodes                                    # 3 nœuds Ready
kubectl get pods -A | grep -vE 'Running|Completed'   # seulement l'en-tête
helm list -A                                         # cilium, traefik, cert-manager, argocd
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief   # OK
curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.80:30080/    # 404 : NodePort
kubectl -n argocd get certificate                    # READY True
```

Depuis le poste, ou n'importe quelle machine sur Internet :

```bash
curl -sI http://argocd.15.224.60.53.sslip.io/ | head -1    # 301 vers https
curl -skI https://argocd.15.224.60.53.sslip.io/ | head -1  # 200
```

> ⚠ `kubectl` ne fonctionne **que depuis `node-1`** : le port 6443 est fermé depuis
> Internet, et SSM ne permet pas de redirection de port.

---

## Partie F — Détruire et reconstruire

Sur `node-1`, en `ec2-user`, dans `tmux` :

```bash
cd ~/kube-infra/ansible
git pull
ansible-playbook reset.yml -e confirm=oui \
  && ansible-playbook playbooks/connectivity.yml \
  && ansible-playbook site.yml
```

`reset.yml` remet les trois nœuds dans leur état d'avant kubeadm et nettoie Cilium. Il
**ne touche pas à `/mnt/efs`** : les données persistantes survivent. Sans
`-e confirm=oui`, il refuse de se lancer.

> ⚠ Si `reset.yml` échoue sur `/var/run/cilium` avec
> `Operation not permitted: 'io.pressure'`, la copie locale est antérieure au correctif.
> Faire `git pull`, ou débloquer à la main : `sudo umount -l /run/cilium/cgroupv2`.

---

## Partie G — Après une extinction du soir

Les IP privées et l'EIP ne changent pas : l'inventaire reste valide. Après la partie B :

```bash
sudo su - ec2-user
cd ~/kube-infra/ansible
ansible-playbook playbooks/restart-check.yml
```

Le playbook vérifie que `containerd` et `kubelet` tournent, remonte l'EFS s'il manque,
attend les trois nœuds `Ready` et liste les pods qui ne sont pas sains.

---

## Pièges rencontrés

| Symptôme | Cause | Solution |
|---|---|---|
| `start-session` échoue sur `TerminateSession` | `session-manager-plugin` absent du poste | `brew install --cask session-manager-plugin` |
| `TargetNotConnected` | VMs arrêtées, ou agent SSM pas encore prêt | Partie B, attendre « Online » |
| Ansible ne trouve pas la clé SSH ou les collections | Session restée en `ssm-user` | `sudo su - ec2-user` |
| Les rôles Helm échouent : module `kubernetes.core` introuvable | Ancienne version de `node1-setup.sh` lancée par `curl … \| sudo bash` : sa liste de secours oubliait la collection | Corrigé. Sinon : `ansible-galaxy collection install -r ~/kube-infra/ansible/requirements.yml` en `ec2-user` |
| Playbook interrompu en plein milieu | Session SSM coupée hors `tmux` | Toujours travailler dans `tmux` (D1) |
| `ls: cannot open directory '/mnt/efs/…': Permission denied` | Les répertoires EFS appartiennent aux UID des applications | `sudo ls` |
| `reset.yml` : `rmtree failed … 'io.pressure'` | cgroup2 de Cilium encore monté | `git pull` (corrigé), sinon `sudo umount -l /run/cilium/cgroupv2` |
| `kubectl` injoignable depuis le poste | 6443 fermé, pas de redirection SSM | Travailler depuis `node-1` |
| Avertissement de certificat dans le navigateur | Let's Encrypt est sur le serveur **staging** | Voulu pendant le développement. Pour la soutenance, changer `acme_server` dans `inventory/hosts.yml` pour l'URL de production. Quota : 50 certificats par domaine et par semaine, donc ne pas reconstruire en boucle une fois en production |
