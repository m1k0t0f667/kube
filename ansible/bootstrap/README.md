# Bootstrap — du poste de dev au control node

Ansible ne peut pas tourner depuis un poste de développement : le port 22 est fermé
depuis Internet, le security group n'est pas modifiable et aucune key pair n'existe
sur le compte. **node-1 est le control node.**

Voir `docs/contraintes-et-outillage.md` §1 (C1, C2) et §4 pour le détail.

Cette procédure est à faire **une seule fois**. Elle est manuelle par conception :
`ssm:SendCommand` et `ec2-instance-connect:SendSSHPublicKey` sont tous deux refusés,
il n'existe aucun moyen de pousser une clé sans ouvrir une session par nœud.

---

## 0. Prérequis sur le poste de dev

```bash
aws sso login --profile kubequest2
brew install --cask session-manager-plugin
```

Sans le plugin, `start-session` crée la session côté AWS puis échoue à l'ouvrir, en
affichant une erreur trompeuse sur `TerminateSession` (droit refusé).

**Sur le poste : toujours `--profile kubequest2`. Dans une session SSM : jamais**
(les identifiants viennent d'IMDS).

## 1. Démarrer les nœuds

```bash
aws ec2 start-instances --profile kubequest2 \
  --instance-ids i-082cacf2f59f8ddd4 i-0f11f75585a35e303 i-03f48443ef76c0707

# attendre que l'agent SSM s'enregistre (~1 min)
aws ssm describe-instance-information --profile kubequest2 \
  --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus}' --output table
```

## 2. Préparer node-1 en control node

```bash
aws ssm start-session --profile kubequest2 --target i-082cacf2f59f8ddd4
```

Puis, dans la session :

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/kube-infra/main/ansible/bootstrap/node1-setup.sh | sudo bash
```

Ou, tant que le dépôt n'est pas publié, copier-coller le contenu de `node1-setup.sh`.

Le script installe `ansible-core`, les collections de `requirements.yml`, `git`,
`tmux`, `k9s`, génère une paire de clés ed25519 pour `ec2-user` et affiche la clé
publique à déposer sur les workers.

## 3. Autoriser node-1 sur les workers

Le script précédent a affiché une ligne commençant par `ssh-ed25519 AAAA...`.

Pour **chaque** worker — `i-0f11f75585a35e303` (node-2) et `i-03f48443ef76c0707` (node-3) :

```bash
aws ssm start-session --profile kubequest2 --target <instance-id>
```

Puis coller, en remplaçant `<CLE_PUBLIQUE>` :

```bash
sudo install -d -m 700 -o ec2-user -g ec2-user /home/ec2-user/.ssh
echo '<CLE_PUBLIQUE>' | sudo tee -a /home/ec2-user/.ssh/authorized_keys >/dev/null
sudo chown ec2-user:ec2-user /home/ec2-user/.ssh/authorized_keys
sudo chmod 600 /home/ec2-user/.ssh/authorized_keys
```

## 4. Vérifier la connectivité

Depuis node-1 :

```bash
cd ~/kube-infra/ansible
ansible-playbook playbooks/connectivity.yml
```

Le playbook vérifie les trois nœuds, l'architecture arm64, l'absence de swap,
le montage `/mnt/efs` et la sortie Internet. Il doit passer intégralement avant
de lancer `site.yml`.

## 5. Provisionner

```bash
tmux new -s kube          # indispensable : une session SSM qui tombe tue le playbook
ansible-playbook site.yml
```

`tmux attach -t kube` pour reprendre après une déconnexion.

---

## Boucle de travail quotidienne

Sans `s3:*` ni `ssm:SendCommand`, **Git est le canal de transfert de fichiers** :

```
poste de dev :  git commit && git push
node-1       :  git pull && ansible-playbook site.yml
```

## Après une extinction nocturne

Les IP privées sont fixes, l'EIP de node-1 aussi : l'inventaire reste valide.
Les IP publiques de node-2 et node-3 changent, mais rien ne doit en dépendre.

```bash
aws ec2 start-instances --profile kubequest2 --instance-ids <les trois>
# puis, depuis node-1 :
ansible-playbook playbooks/restart-check.yml
```
