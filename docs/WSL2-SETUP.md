# Installation complète de psm-ssh sur WSL2

Guide pas-à-pas pour setup psm-ssh sur WSL2 (Windows 10/11), avec gestion
persistante de `ssh-agent` et `gpg-agent`, et mode keepassxc-cli + GPG
(sans GUI).

Testé sur **Ubuntu 22.04 / 24.04** et **Fedora** sous WSL2. Les commandes
`apt` s'appliquent à Ubuntu/Debian ; remplacer par `dnf` pour Fedora.

---

## 1. Prérequis WSL2

### Activer systemd (WSL 0.67.6+)

systemd simplifie la gestion des services user (ssh-agent, gpg-agent).
Éditer `/etc/wsl.conf` dans ta distro :

```ini
[boot]
systemd=true

[interop]
enabled=true
appendWindowsPath=false
```

Puis depuis PowerShell (pas WSL) :

```powershell
wsl --shutdown
wsl
```

Vérifier : `systemctl status` doit répondre sans erreur.

### Synchronisation de l'heure

WSL2 peut dériver après une mise en veille, ce qui casse les tickets
Kerberos et les certificats TLS. Forcer une resync à chaque démarrage :

```bash
# Dans ~/.bashrc ou ~/.zshrc
alias wsl-time-sync='sudo hwclock -s'
```

Ou systemd unit (plus propre) — on passe, pas critique pour psm-ssh.

---

## 2. Installation des dépendances

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install -y \
    expect \
    openssh-client \
    keepassxc \
    gnupg2 \
    pinentry-curses
```

### Fedora

```bash
sudo dnf install -y \
    expect \
    openssh-clients \
    keepassxc \
    gnupg2 \
    pinentry
```

> **Pas besoin de `libsecret-tools` ni du GUI KeePassXC** sur WSL2 sans
> serveur X/Wayland — on utilise le mode keepassxc-cli + GPG.

Vérifier les versions :

```bash
expect -v
ssh -V
keepassxc-cli --version
gpg --version
```

---

## 3. Configuration ssh-agent persistant

WSL2 ferme le process parent à chaque terminal fermé → `ssh-agent` meurt
aussi. Trois options, par préférence :

### Option A — systemd user unit (recommandée, propre)

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/ssh-agent.service <<'EOF'
[Unit]
Description=SSH authentication agent

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a $SSH_AUTH_SOCK

[Install]
WantedBy=default.target
EOF

systemctl --user enable --now ssh-agent
```

Puis exporter la variable dans `~/.bashrc` (ou `~/.zshrc`) :

```bash
export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"
```

Reload le shell, puis :

```bash
ssh-add ~/.ssh/id_rsa          # ou la clé que tu utilises pour le PSMP
ssh-add -l                     # doit lister la clé
```

La clé reste chargée jusqu'au reboot WSL2. Pour la recharger auto au boot,
voir [`keychain`](https://www.funtoo.org/Keychain) ou un ExecStartPost
sur l'unit systemd.

### Option B — démarrage dans `~/.bashrc` (simple, pas de systemd)

```bash
# Dans ~/.bashrc
if ! pgrep -u "$USER" ssh-agent >/dev/null; then
    eval "$(ssh-agent -s)" >/dev/null
fi
if [[ -z "${SSH_AUTH_SOCK:-}" ]] || ! ssh-add -l >/dev/null 2>&1; then
    export SSH_AUTH_SOCK=$(find /tmp/ssh-* -user "$USER" -name agent.\* 2>/dev/null | head -1)
    ssh-add ~/.ssh/id_rsa 2>/dev/null
fi
```

Fragile quand plusieurs terminaux s'ouvrent en parallèle, mais suffit
pour un usage simple.

### Option C — bridger avec le ssh-agent Windows

Via [`npiperelay`](https://github.com/jstarks/npiperelay) + `socat`. Plus
complexe mais unifie les clés entre Windows (OpenSSH natif) et WSL.
À creuser si tu utilises déjà `ssh-agent` côté Windows.

### Vérifier

```bash
ssh-add -l
# Doit afficher : 4096 SHA256:... (RSA)
```

---

## 4. Configuration gpg-agent

gpg-agent cache la passphrase de ta clé GPG après la première saisie, pour
que `gpg -qd ~/.psm-master.gpg` soit silencieux aux appels suivants.

### Définir le pinentry en mode terminal

WSL2 n'a pas de GUI → le pinentry par défaut (GTK/Qt) ne marche pas.
Utiliser `pinentry-curses` (ncurses) :

```bash
mkdir -p ~/.gnupg
chmod 700 ~/.gnupg

cat > ~/.gnupg/gpg-agent.conf <<'EOF'
pinentry-program /usr/bin/pinentry-curses
default-cache-ttl 28800          # 8h
max-cache-ttl 86400              # 24h max
EOF

chmod 600 ~/.gnupg/gpg-agent.conf
```

> Fedora : le binaire est `/usr/bin/pinentry` ou `/usr/bin/pinentry-tty`.
> `which pinentry-curses || which pinentry` pour vérifier.

### Configurer le GPG_TTY

gpg-agent a besoin de connaître le TTY courant pour afficher le pinentry.
Ajouter dans `~/.bashrc` :

```bash
export GPG_TTY=$(tty)
```

### Forcer le reload de l'agent

```bash
gpg-connect-agent reloadagent /bye
```

### Test

```bash
# Crée un fichier test chiffré avec ta clé
echo "test" | gpg --encrypt --recipient ton@email.com -o /tmp/test.gpg

# Déchiffre (prompt la passphrase la première fois)
gpg -qd /tmp/test.gpg

# Re-déchiffre immédiatement (doit être silencieux, cache hit)
gpg -qd /tmp/test.gpg

rm /tmp/test.gpg
```

Si le prompt ne s'affiche pas ou que `gpg-agent` râle sur le TTY, vérifier
`echo $GPG_TTY` et re-exporter.

---

## 5. Création de la clé GPG

Si tu n'as pas encore de clé GPG personnelle :

```bash
gpg --full-generate-key
```

Choix recommandés :
- Type : `(1) RSA and RSA`
- Taille : `4096`
- Expiration : `0` (jamais) ou `2y` selon ta politique
- Nom : ton nom
- Email : ton email (utilisé comme `--recipient`)
- Passphrase : **robuste** (c'est la seule chose qui protège ta base KeePassXC via chiffrement GPG)

Vérifier :

```bash
gpg --list-secret-keys
```

Noter l'email associé à la clé — il sera utilisé comme `--recipient`.

### Backup de la clé (important)

```bash
mkdir -p ~/gpg-backup && chmod 700 ~/gpg-backup
gpg --export-secret-keys --armor ton@email.com > ~/gpg-backup/private.key
gpg --export --armor ton@email.com > ~/gpg-backup/public.key
gpg --export-ownertrust > ~/gpg-backup/ownertrust.txt
```

Stocker en lieu sûr (pas sur le poste pro, pas dans un repo git).

---

## 6. Setup KeePassXC (mode CLI sans GUI)

### Créer une base KeePassXC

Depuis WSL2, `keepassxc-cli` peut créer une base :

```bash
keepassxc-cli db-create ~/Passwords.kdbx --set-password
# Taper le master password deux fois
```

Ou depuis le GUI KeePassXC sur Windows, puis copier le `.kdbx` dans
`~/` côté WSL2 (évite les problèmes de lock).

### Créer le groupe PSM

```bash
keepassxc-cli mkdir ~/Passwords.kdbx PSM
# Taper le master password
```

### Ajouter des entrées

```bash
# Entrée target (compte de service sur un serveur)
keepassxc-cli add -p ~/Passwords.kdbx "PSM/admin@srv-prod01"
# Taper le master password, puis le mot de passe du compte

# Entrée LDAP (compte perso, même password partout)
keepassxc-cli add -p ~/Passwords.kdbx "PSM/john.doe"

# Entrée vault (si mode password, optionnel en mode clé SSH)
keepassxc-cli add -p ~/Passwords.kdbx "PSM/VaultPassword"
```

### Vérifier

```bash
keepassxc-cli ls ~/Passwords.kdbx PSM
# Doit lister : admin@srv-prod01, john.doe, VaultPassword, ...
```

---

## 7. Chiffrer le master password KeePassXC avec GPG

C'est le fichier que `psm` déchiffrera automatiquement via `gpg-agent`.

```bash
# Saisir le master password (suit le -n pour pas de newline parasite)
echo -n "TON_MASTER_PASSWORD_KEEPASSXC" | \
    gpg --encrypt --recipient ton@email.com -o ~/.psm-master.gpg

chmod 600 ~/.psm-master.gpg
```

Test du pipeline complet :

```bash
gpg -qd ~/.psm-master.gpg | \
    keepassxc-cli show -qsa Password ~/Passwords.kdbx PSM/admin@srv-prod01
# Doit afficher le mot de passe target, sans prompt
```

Premier appel : prompt pinentry-curses pour la passphrase GPG. Suivants :
silencieux (cache gpg-agent).

---

## 8. Installation de psm-ssh

```bash
cd ~
git clone https://github.com/clementgineste/psm-ssh.git
cd psm-ssh
chmod +x psm

# Option 1 : installer dans /usr/local/bin (système)
sudo install -m 755 psm /usr/local/bin/psm

# Option 2 : ajouter au PATH (user)
echo 'export PATH="$HOME/psm-ssh:$PATH"' >> ~/.bashrc
```

### Activer les hooks git (si tu contribues)

```bash
cd ~/psm-ssh
git config core.hooksPath .githooks
cp .githooks/patterns.example .githooks/patterns.local
$EDITOR .githooks/patterns.local
```

---

## 9. Configuration

Créer le fichier de config utilisateur :

```bash
mkdir -p ~/.config/psm
cp ~/psm-ssh/config.example ~/.config/psm/config
$EDITOR ~/.config/psm/config
```

Variables à remplir avec tes vraies valeurs :

```bash
PSMP_HOST="ton-psmp.ton-entreprise.com"
VAULT_USER="ton.vault.user"
KDBX_PATH="$HOME/Passwords.kdbx"
KDBX_GROUP="PSM"
VAULT_PASS_ENTRY="VaultPassword"
GPG_MASTER_FILE="$HOME/.psm-master.gpg"
LDAP_USER="john.doe"             # ton user LDAP perso si applicable
```

### Clé SSH pour le vault CyberArk

Le PSMP accepte une auth par clé SSH pour le vault user (si configuré
côté CyberArk). Ajouter la clé publique dans ton compte CyberArk via le
Password Vault Web Access (PVWA), puis :

```bash
ssh-add ~/.ssh/id_rsa       # si pas déjà chargée via Option A
```

Sans clé chargée, `psm` bascule en mode password (demande le vault
password dans KeePassXC).

---

## 10. Test

```bash
# Mode debug — trace complète pour diagnostiquer
psm -d admin@srv-prod01
```

Sortie attendue :

```
[DBG]  Résolution hostname : ssh -G srv-prod01
[INFO] Cible : admin @ srv-prod01 (via ton-psmp.ton-entreprise.com:22)
[DBG]  Vérification ssh-agent
[INFO] Mode clé SSH (agent actif, clés chargées)
[DBG]  Fetch target password pour 'admin@srv-prod01'
[DBG]  Déchiffrement du master password via GPG (/home/user/.psm-master.gpg)
[DBG]  Mot de passe récupéré via keepassxc-cli + GPG pour 'admin@srv-prod01'
[DBG]  Target password OK (entrée KeePassXC : admin@srv-prod01)
[DBG]  Spawn: ssh -p 22 ... ton.vault.user@admin@srv-prod01@ton-psmp.ton-entreprise.com
[WARN] Mode debug : les mots de passe seront visibles dans la sortie expect
...
# → shell interactif sur srv-prod01
```

---

## 11. Troubleshooting

### `ssh-add -l` → "Could not open a connection to your authentication agent"

`SSH_AUTH_SOCK` pas exporté. Relance le shell ou `source ~/.bashrc`.

### `gpg: decryption failed: No secret key`

Le `--recipient` lors du chiffrement ne correspond pas à une clé secrète
que tu possèdes. `gpg --list-secret-keys` pour vérifier, puis rechiffrer.

### `Keyboard interactive authentication failed`

Possibles causes :
- Mauvais target password dans KeePassXC
- Compte locked côté target
- PSMP demande MFA (non supporté, voir limitations)

Lancer en `-d` et regarder les échanges expect pour identifier à quelle
étape ça coince.

### `gpg: cannot open tty: No such device or address`

`GPG_TTY` pas exporté. Ajouter `export GPG_TTY=$(tty)` dans `~/.bashrc`
et `gpg-connect-agent reloadagent /bye`.

### `keepassxc-cli: command not found`

Sur certaines Fedora, le binaire est dans un path non-standard. `dnf list
--installed | grep keepassxc` puis `which keepassxc-cli` pour localiser.

### Les DNS lookups prennent 30+ secondes

WSL2 hérite parfois de résolveurs DNS cassés depuis Windows. Check
`/etc/resolv.conf`. Fix temporaire :

```bash
sudo tee /etc/resolv.conf > /dev/null <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
```

Et dans `/etc/wsl.conf` :

```ini
[network]
generateResolvConf=false
```

### psm ferme immédiatement sans erreur

Typiquement dû à `set -euo pipefail` qui tue le script silencieusement sur
une commande qui échoue. Lancer en `-d` et observer la dernière ligne de
debug affichée pour localiser l'étape fautive.

### `gpg: can't connect to the agent: IPC connect call failed`

gpg-agent pas démarré. `gpg-connect-agent reloadagent /bye` ou
`systemctl --user restart gpg-agent` si systemd-based.

---

## 12. Bonus : alias et intégration shell

### Autocomplétion des targets

Depuis la liste des entrées KeePassXC :

```bash
_psm_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local entries
    entries=$(gpg -qd ~/.psm-master.gpg 2>/dev/null | \
              keepassxc-cli ls -q ~/Passwords.kdbx PSM 2>/dev/null | \
              grep '@')
    COMPREPLY=( $(compgen -W "$entries" -- "$cur") )
}
complete -F _psm_complete psm
```

À sourcer depuis `~/.bashrc`. L'autocomplétion demandera la passphrase GPG
une fois, puis fera cache.

### Raccourci pour les targets fréquents

```bash
alias psmprod='psm admin@srv-prod01'
```

### Ouvrir plusieurs sessions en parallèle

Chaque `psm` crée un process indépendant. Aucune contention sur KeePassXC
tant que tu ne modifies pas la base. Plusieurs targets simultanés
fonctionnent sans souci.
