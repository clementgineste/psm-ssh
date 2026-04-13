# psm-ssh

SSH wrapper pour CyberArk PSM for SSH (PSMP) avec récupération automatique
des credentials depuis KeePassXC.

## Pourquoi

CyberArk PSMP intercepte les connexions SSH avec un double prompt :

```
ssh vaultuser@targetuser@targethost@psmphost
  → Vault Password:    (CyberArk vault)
  → Password:          (compte cible)
```

Le PSMP utilise `keyboard-interactive`, donc `sshpass` ne marche pas. Ce
script utilise `expect` pour piloter l'auth, et tire les deux mots de passe
depuis KeePassXC via le **Secret Service API** — aucun secret en clair, aucun
mot de passe sur la cmdline.

## Dépendances

| Paquet              | Rôle                                       | Obligatoire |
|---------------------|--------------------------------------------|-------------|
| `expect`            | Pilotage de l'auth keyboard-interactive    | oui         |
| `libsecret-tools`   | `secret-tool` pour Secret Service API      | oui         |
| `openssh-client`    | Client SSH                                  | oui         |
| `keepassxc`         | Source des secrets + GUI                   | oui (GUI)   |
| `keepassxc-cli`     | Fallback si Secret Service indisponible    | optionnel   |

```bash
# Debian/Ubuntu
sudo apt install expect libsecret-tools openssh-client keepassxc

# RHEL/Fedora
sudo dnf install expect libsecret openssh-clients keepassxc
```

## Setup KeePassXC

1. Ouvrir KeePassXC → **Settings → Secret Service Integration** → cocher *Enable*
2. Dans la base, créer un groupe (par défaut `PSM/`)
3. **Settings de la base → Secret Service Integration** → exposer le groupe `PSM`
4. Créer les entrées :

```
PSM/
├── VaultPassword              ← Title="VaultPassword",  Password=<vault pwd>
├── admin@srv-prod01           ← Title="admin@srv-prod01", Password=<target pwd>
├── root@srv-prod02
└── admin@switch-core01
```

Le **Title** de l'entrée est ce que `secret-tool lookup Title "..."` cherche.
La base doit être **déverrouillée** dans le GUI pendant l'usage du script.

Vérification rapide :

```bash
secret-tool lookup Title VaultPassword     # doit afficher le mot de passe
```

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

| Variable           | Défaut                | Description                         |
|--------------------|-----------------------|-------------------------------------|
| `PSMP_HOST`        | `psmp.example.com`    | Hostname du proxy PSMP              |
| `VAULT_USER`       | `ton.vault.user`      | User CyberArk vault                 |
| `KDBX_PATH`        | `~/Passwords.kdbx`    | Base KeePassXC (pour le fallback)   |
| `KDBX_GROUP`       | `PSM`                 | Groupe contenant les entrées        |
| `VAULT_PASS_ENTRY` | `VaultPassword`       | Title de l'entrée vault password    |
| `SSH_OPTS`         | (voir script)         | Options ssh                         |
| `EXPECT_TIMEOUT`   | `30`                  | Timeout (s) pour les prompts        |
| `SESSION_TIMEOUT`  | `60`                  | (réservé)                           |

## Usage

```bash
psm admin@srv-prod01              # connexion standard
psm -d root@switch-core01         # debug : affiche tous les échanges expect
psm -p 2222 admin@srv-prod01      # port SSH custom
psm -v autre.user admin@host      # override du vault user
psm -l                            # liste les targets dans KeePassXC
psm -h                            # aide
```

## Flow

```
psm admin@srv-prod01
  │
  ├─ secret-tool lookup Title "VaultPassword"      → VAULT_PASS  (env)
  ├─ secret-tool lookup Title "admin@srv-prod01"   → TARGET_PASS (env)
  │   (fallback: keepassxc-cli si Secret Service KO)
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
- `unset` immédiat des variables après la fin d'`expect`.
- Aucun mot de passe écrit sur disque.
- Le binaire `secret-tool` parle au démon Secret Service via DBus, sans
  jamais exposer la base KeePassXC.

## Codes de sortie

| Code  | Cause                                         |
|-------|-----------------------------------------------|
| 0     | Session terminée normalement                  |
| 2     | Erreur d'usage (args, options)                |
| 3     | Récupération de mot de passe échouée          |
| 10–12 | Échec avant le prompt vault                   |
| 20–24 | Échec entre vault et target (incl. MFA)       |
| 30–32 | Échec après auth target                       |

## Limitations connues

- **MFA non supporté** : si le PSMP demande un OTP entre les deux prompts,
  le script abandonne avec un message clair (code 21).
- Les regex de prompt (`vault password`, `password`) sont génériques. Si
  ton PSMP utilise des libellés exotiques, lance avec `-d` pour voir les
  échanges bruts et adapte les `expect` dans le script.
- KeePassXC GUI doit rester ouvert et déverrouillé pendant l'usage.

## Licence

MIT
