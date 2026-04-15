# psm-ssh

SSH wrapper pour CyberArk PSM for SSH (PSMP) avec récupération automatique
des credentials depuis KeePassXC.

## Pourquoi

CyberArk PSMP intercepte les connexions SSH avec un ou deux prompts :

```
ssh vaultuser@targetuser@targethost@psmphost
  → Vault Password:    (CyberArk vault — absent si auth par clé SSH)
  → Password:          (compte cible)
```

Le PSMP utilise `keyboard-interactive`, donc `sshpass` ne marche pas. Ce
script utilise `expect` pour piloter l'auth, et tire les mots de passe
depuis KeePassXC — aucun secret en clair, aucun mot de passe sur la cmdline.

**Deux modes d'auth vault** sont supportés :
- **Clé SSH** (recommandé) : si l'agent SSH a des clés chargées, l'auth vault
  est transparente. Seul le password target est nécessaire.
- **Password** : le script récupère aussi le vault password depuis KeePassXC.

**Deux backends de credentials** sont supportés :
- **Secret Service API** (`secret-tool`) : KeePassXC GUI déverrouillé avec
  intégration Secret Service activée.
- **keepassxc-cli + GPG** : master password chiffré par GPG, déchiffré via
  `gpg-agent` (cache la passphrase). Pas besoin de GUI.

Au moins un des deux backends doit être disponible.

## Dépendances

| Paquet              | Rôle                                       | Obligatoire |
|---------------------|--------------------------------------------|-------------|
| `expect`            | Pilotage de l'auth keyboard-interactive    | oui         |
| `openssh-client`    | Client SSH                                  | oui         |
| `libsecret-tools`   | `secret-tool` pour Secret Service API      | un des deux |
| `keepassxc-cli`     | Accès CLI à la base KeePassXC              | un des deux |
| `gpg`               | Déchiffrement du master password           | pour mode GPG |
| `keepassxc`         | GUI + Secret Service                       | pour mode GUI |

```bash
# Debian/Ubuntu — mode GUI (Secret Service)
sudo apt install expect openssh-client libsecret-tools keepassxc

# Debian/Ubuntu — mode CLI (GPG)
sudo apt install expect openssh-client keepassxc2 gnupg

# RHEL/Fedora — mode GUI
sudo dnf install expect openssh-clients libsecret keepassxc

# RHEL/Fedora — mode CLI (GPG)
sudo dnf install expect openssh-clients keepassxc gnupg2
```

## Setup

### Mode Secret Service (GUI)

1. Ouvrir KeePassXC → **Settings → Secret Service Integration** → cocher *Enable*
2. Dans la base, créer un groupe (par défaut `PSM/`)
3. **Settings de la base → Secret Service Integration** → exposer le groupe `PSM`
4. Créer les entrées (voir structure ci-dessous)

La base doit être **déverrouillée** dans le GUI pendant l'usage du script.

Vérification rapide :

```bash
secret-tool lookup Title admin@srv-prod01     # doit afficher le mot de passe target
```

### Mode GPG + keepassxc-cli (sans GUI)

1. Créer la base KeePassXC et les entrées (voir structure ci-dessous)
2. Chiffrer le master password de la base avec GPG :

```bash
echo -n "ton-master-password" | gpg --encrypt --recipient ton@email.com -o ~/.psm-master.gpg
```

3. Vérifier que `gpg-agent` fonctionne et cache la passphrase :

```bash
gpg -qd ~/.psm-master.gpg | keepassxc-cli show -qsa Password ~/Passwords.kdbx PSM/admin@srv-prod01
```

La première invocation demande la passphrase GPG. Les suivantes utilisent le
cache `gpg-agent` (configurable via `~/.gnupg/gpg-agent.conf`).

### Structure des entrées KeePassXC

```
PSM/
├── VaultPassword              ← Title="VaultPassword",  Password=<vault pwd>  (optionnel si clé SSH)
├── admin@srv-prod01           ← Title="admin@srv-prod01", compte de service spécifique
├── admin@10.2.2.3             ← Title="admin@10.2.2.3",    compte de service par IP
├── root@srv-prod02
└── john.doe                  ← Title="john.doe",         compte LDAP, même mot de passe partout
```

L'entrée `VaultPassword` est **optionnelle** si tu utilises l'auth vault par clé SSH.

**Convention de lookup** (spécifique avant générique) :
1. `user@ip` — si le hostname a été résolu en IP
2. `user@hostname` — nom original
3. `user` — compte LDAP/AD partagé entre plusieurs serveurs

Le premier match gagne. Pour les comptes LDAP où le même mot de passe marche sur
tous les serveurs, crée une seule entrée nommée par l'user (`john.doe`) — pas
besoin de la dupliquer pour chaque host.

## Installation

```bash
git clone https://github.com/clementgineste/psm-ssh.git
cd psm-ssh
chmod +x psm
sudo install -m 755 psm /usr/local/bin/psm
```

Ou simplement ajouter le repo au `PATH`.

## Configuration

Éditer le bloc `CONFIG` en haut de `psm` ou utiliser des variables d'environnement
(par exemple dans `~/.bashrc`) :

```bash
export PSMP_HOST="psmp.mon-entreprise.com"
export VAULT_USER="prenom.nom"
export KDBX_GROUP="PSM"
export VAULT_PASS_ENTRY="VaultPassword"
```

Variables supportées :

| Variable           | Défaut                | Description                              |
|--------------------|-----------------------|------------------------------------------|
| `PSMP_HOST`        | `psmp.example.com`    | Hostname du proxy PSMP                   |
| `VAULT_USER`       | `ton.vault.user`      | User CyberArk vault                      |
| `KDBX_PATH`        | `~/Passwords.kdbx`    | Base KeePassXC                           |
| `KDBX_GROUP`       | `PSM`                 | Groupe contenant les entrées             |
| `VAULT_PASS_ENTRY` | `VaultPassword`       | Title de l'entrée vault password         |
| `GPG_MASTER_FILE`  | `~/.psm-master.gpg`   | Master password KeePassXC chiffré en GPG |
| `SSH_OPTS`         | (voir script)         | Options ssh                              |
| `EXPECT_TIMEOUT`   | `30`                  | Timeout (s) pour les prompts             |

## Usage

```bash
psm admin@srv-prod01              # connexion standard
psm -d root@switch-core01         # debug : affiche tous les échanges expect
psm -p 2222 admin@srv-prod01      # port SSH custom
psm -v autre.user admin@host      # override du vault user
psm -l                            # liste les targets dans KeePassXC
psm -h                            # aide
```

**Auto-sudo** : les prompts `[sudo] password for ...:` sont automatiquement
remplis avec le target password pendant la session interactive.

## Résolution hostname

Le script résout automatiquement les hostnames avant de les passer au PSMP,
dans cet ordre :

1. **`~/.ssh/config`** — `Host srv-prod01` / `HostName 10.2.2.2` (instantané)
2. **`/etc/hosts` + DNS** — résolution système avec timeout de 2s
3. **Aucun match** — le hostname est passé tel quel au PSMP

Le lookup KeePassXC essaie d'abord le nom original (`app@srv-prod01`), puis
le nom résolu (`app@10.2.2.2`). Les deux conventions de nommage fonctionnent.

Le timeout DNS court (2s) évite les blocages sur les hostnames non résolvables
depuis le poste client — le PSMP a son propre DNS interne pour la résolution finale.

## Flow

### Mode clé SSH + GPG (sans GUI)

```
psm admin@srv-prod01
  │
  ├─ ssh-agent a des clés → vault password non requis
  ├─ gpg -qd ~/.psm-master.gpg
  │    → keepassxc-cli show ... "PSM/admin@srv-prod01" → TARGET_PASS (env)
  │
  ├─ expect:
  │    spawn ssh ton.vault.user@admin@srv-prod01@psmp.example.com
  │    [banner masqué, vault auth par clé SSH]
  │    "Password:"              → envoie TARGET_PASS
  │    interact (auto-sudo sur prompts [sudo])
  │
  └─ shell interactif sur srv-prod01
```

### Mode clé SSH + Secret Service (GUI)

```
psm admin@srv-prod01
  │
  ├─ ssh-agent a des clés → vault password non requis
  ├─ secret-tool lookup Title "admin@srv-prod01"   → TARGET_PASS (env)
  │
  ├─ expect:
  │    spawn ssh ton.vault.user@admin@srv-prod01@psmp.example.com
  │    [banner masqué, vault auth par clé SSH]
  │    "Password:"       → envoie TARGET_PASS
  │    interact
  │
  └─ shell interactif sur srv-prod01
```

### Mode password (vault + target)

```
psm admin@srv-prod01
  │
  ├─ ssh-agent sans clé → fetch vault password
  ├─ fetch "VaultPassword"                         → VAULT_PASS  (env)
  ├─ fetch "admin@srv-prod01"                      → TARGET_PASS (env)
  │   (source: secret-tool → keepassxc-cli+GPG → keepassxc-cli interactif)
  │
  ├─ expect:
  │    spawn ssh ton.vault.user@admin@srv-prod01@psmp.example.com
  │    [banner masqué]
  │    "Vault Password:" → envoie VAULT_PASS
  │    "Password:"       → envoie TARGET_PASS
  │    interact
  │
  └─ shell interactif sur srv-prod01
```

## Sécurité

- Les mots de passe transitent par variables d'environnement vers `expect`
  (`$env(VAULT_PASS)`, `$env(TARGET_PASS)`) — jamais sur la ligne de commande,
  donc invisibles dans `ps`, `/proc/*/cmdline`, et l'historique shell.
- `unset` immédiat des variables après la fin d'`expect`, y compris en cas
  d'erreur (pattern `|| rc=$?`).
- Aucun mot de passe écrit sur disque. Le fichier expect temporaire ne
  contient que des références `$env(...)`, pas de valeurs.
- En mode Secret Service, `secret-tool` parle au démon via DBus, sans
  jamais exposer la base KeePassXC.
- En mode GPG, seul le master password chiffré est sur disque. Le
  déchiffrement passe par `gpg-agent` (cache limité dans le temps).
- **Mode debug (`-d`)** : un avertissement est affiché car `exp_internal`
  expose les mots de passe en clair dans la sortie. Ne pas utiliser en prod.
- **Auto-sudo** : le target password est envoyé automatiquement sur
  les prompts `[sudo]` pendant la session interactive.

## Codes de sortie

| Code  | Cause                                         |
|-------|-----------------------------------------------|
| 0     | Session terminée normalement                  |
| 2     | Erreur d'usage (args, options)                |
| 3     | Récupération de mot de passe échouée          |
| 10    | Vault password requis mais non disponible     |
| 11    | Timeout en attendant un prompt                |
| 12    | Connexion fermée (eof)                        |
| 13    | Permission refusée (clé SSH rejetée)          |
| 20–24 | Échec entre vault et target (incl. MFA)       |
| 30–32 | Échec après auth target                       |

## Limitations connues

- **MFA non supporté** : si le PSMP demande un OTP entre les deux prompts,
  le script abandonne avec un message clair (code 21).
- Les regex de prompt (`vault password`, `password`) sont génériques. Si
  ton PSMP utilise des libellés exotiques, lance avec `-d` pour voir les
  échanges bruts et adapte les `expect` dans le script.
- L'auto-sudo ne matche que le format `[sudo] password for ...:`.
  Les prompts sudo custom ou les prompts `su` ne sont pas interceptés.
- La résolution hostname ne gère pas IPv6 explicitement.

## Licence

MIT
