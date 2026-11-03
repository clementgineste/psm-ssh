# psm-ssh

SSH wrapper for CyberArk PSM for SSH (PSMP) that retrieves credentials
automatically from KeePassXC.

## Why

CyberArk PSMP intercepts SSH connections with one or two prompts:

```
ssh vaultuser@targetuser@targethost@psmphost
  → Vault Password:    (CyberArk vault — skipped with SSH key auth)
  → Password:          (target account)
```

The PSMP uses `keyboard-interactive`, so `sshpass` does not work. This
script drives the authentication with `expect` and pulls the passwords from
KeePassXC: no plaintext secret, no password on the command line.

**Two vault auth modes** are supported:
- **SSH key** (recommended): if the SSH agent has keys loaded, vault auth is
  transparent. Only the target password is needed.
- **Password**: the script also retrieves the vault password from KeePassXC.

**Two credential backends** are supported:
- **Secret Service API** (`secret-tool`): KeePassXC GUI unlocked, with
  Secret Service integration enabled.
- **keepassxc-cli + GPG**: master password encrypted with GPG, decrypted
  through `gpg-agent` (which caches the passphrase). No GUI needed.

At least one of the two backends must be available.

## Dependencies

| Package             | Role                                        | Required        |
|---------------------|---------------------------------------------|-----------------|
| `expect`            | Drives the keyboard-interactive auth        | yes             |
| `openssh-client`    | SSH client                                  | yes             |
| `libsecret-tools`   | `secret-tool` for the Secret Service API    | one of the two  |
| `keepassxc-cli`     | CLI access to the KeePassXC database        | one of the two  |
| `gpg`               | Decrypts the master password                | for GPG mode    |
| `keepassxc`         | GUI + Secret Service                        | for GUI mode    |

```bash
# Debian/Ubuntu — GUI mode (Secret Service)
sudo apt install expect openssh-client libsecret-tools keepassxc

# Debian/Ubuntu — CLI mode (GPG)
sudo apt install expect openssh-client keepassxc gnupg

# RHEL/Fedora — GUI mode
sudo dnf install expect openssh-clients libsecret keepassxc

# RHEL/Fedora — CLI mode (GPG)
sudo dnf install expect openssh-clients keepassxc gnupg2
```

## Setup

### Secret Service mode (GUI)

1. Open KeePassXC → **Settings → Secret Service Integration** → check *Enable*
2. In the database, create a group (`PSM/` by default)
3. **Database settings → Secret Service Integration** → expose the `PSM` group
4. Create the entries (see the structure below)

The database must stay **unlocked** in the GUI while you use the script.

Quick check:

```bash
secret-tool lookup Title admin@srv-prod01     # must print the target password
```

### GPG + keepassxc-cli mode (no GUI)

1. Create the KeePassXC database and the entries (see the structure below)
2. Encrypt the database master password with GPG (the prompt keeps it out of
   your shell history):

```bash
printf 'KeePassXC master password: '; read -rs pw; echo
printf '%s' "$pw" | gpg --encrypt --recipient you@example.com -o ~/.psm-master.gpg
unset pw
```

3. Check that `gpg-agent` works and caches the passphrase:

```bash
gpg -qd ~/.psm-master.gpg | keepassxc-cli show -qsa Password ~/Passwords.kdbx PSM/admin@srv-prod01
```

The first call asks for the GPG passphrase. The following ones use the
`gpg-agent` cache (configurable in `~/.gnupg/gpg-agent.conf`).

### KeePassXC entry layout

```
PSM/
├── VaultPassword              ← Title="VaultPassword",    Password=<vault pwd>  (optional with an SSH key)
├── admin@srv-prod01           ← Title="admin@srv-prod01", host-specific service account
├── admin@10.2.2.3             ← Title="admin@10.2.2.3",   service account by IP
├── root@srv-prod02
└── john.doe                   ← Title="john.doe",         LDAP account, same password everywhere
```

The `VaultPassword` entry is **optional** if you use SSH key vault auth.

**Lookup convention** — the order depends on whether the user is listed in `LDAP_USER`:

**Service account** (user **not** in `LDAP_USER`) — specific before generic:
1. `user@ip` — if the hostname was resolved to an IP
2. `user@hostname` — original name
3. `user` — fallback

**LDAP/AD account** (user in `LDAP_USER`) — generic before specific:
1. `user` — single entry shared by all servers
2. `user@ip` — fallback
3. `user@hostname` — fallback

The first match wins. For LDAP accounts whose password is the same on every
server, create a single entry named after the user (`john.doe`) and list it
in `LDAP_USER`: a single KeePassXC lookup is then enough for each connection.

## Installation

For **WSL2** (full setup with ssh-agent, gpg-agent and KeePassXC CLI), see
[`docs/WSL2-SETUP.md`](docs/WSL2-SETUP.md), a step-by-step guide.

Other environments:

```bash
git clone https://github.com/clementgineste/psm-ssh.git
cd psm-ssh
chmod +x psm
sudo install -m 755 psm /usr/local/bin/psm
```

Or just add the repo to your `PATH`.

### Git hooks (contributors)

```bash
git config core.hooksPath .githooks
cp .githooks/patterns.example .githooks/patterns.local
$EDITOR .githooks/patterns.local   # add your internal patterns (hostnames, IPs, user IDs)
```

Two hooks are provided in `.githooks/`:
- **`pre-commit`**: blocks commits that contain internal strings (patterns
  defined in `patterns.local`, which is gitignored).
- **`commit-msg`**: enforces the [Conventional Commits](https://www.conventionalcommits.org/)
  format (`feat:`, `fix:`, `docs:`, etc.).

`patterns.local` is gitignored: it holds your sensitive patterns (internal
domains, ID formats, etc.) and must never be committed. The `pre-commit`
hook does nothing until this file exists.

### Bash completion

```bash
# In ~/.bashrc
source ~/psm-ssh/completions/psm.bash
```

Completes hostnames from `~/.ssh/config`:

```
$ psm srv<TAB><TAB>
srv-prod01  srv-prod02  srv-staging
$ psm admin@srv<TAB><TAB>
admin@srv-prod01  admin@srv-prod02  admin@srv-staging
```

For `psm cp`, it completes local paths (descending into subdirectories) as
well as hostnames for the remote side, including after global flags
(`psm -p 2222 cp ...`):

```
$ psm cp ./work/<TAB><TAB>
build/     deploy.sh
$ psm cp ./work/deploy.sh srv<TAB><TAB>
srv-prod01  srv-prod02  srv-staging
```

Path completion uses bash-completion's `_filedir` when it is installed, and
falls back to `compgen -f` otherwise.

## Configuration

Three ways to configure psm, in order of preference:

### 1. Config file (recommended — survives `git pull`)

The script looks for, in this order:
- `$PSM_CONFIG` if set
- `~/.config/psm/config`
- `~/.psmrc`

An example is provided in the repo: [`config.example`](config.example).

```bash
mkdir -p ~/.config/psm
cp config.example ~/.config/psm/config
$EDITOR ~/.config/psm/config
```

The file is sourced as bash: plain `VAR="value"` syntax.

### 2. Environment variables (one-off override)

```bash
export PSMP_HOST="psmp.example.com"
export VAULT_USER="first.last"
export LDAP_USER="john.doe"
```

Or for a single run: `VAULT_USER=other.user psm admin@srv`.

**Precedence**: by default the config file overrides the environment
(`VAR="..."`). To let the environment win for some keys, use the conditional
form in the config file:

```bash
# ~/.config/psm/config
: "${VAULT_USER:=first.last}"   # the VAULT_USER env var wins if set
```

### 3. Editing the script directly

The `CONFIG` block at the top of `psm`. Avoid it: your changes conflict with
the next `git pull`.

### Per-host `PSMP_HOST` override (via `~/.ssh/config`)

If part of your fleet goes through a different PSMP, you can override
`PSMP_HOST` per host (or per pattern) with the standard `SetEnv` directive:

```sshconfig
# All hosts whose name starts with LC use the "secure" PSMP
Host LC*
    SetEnv PSM_PSMP_HOST=psmp-secure.example.com

# A specific host
Host srv-prod42
    HostName 10.9.8.7
    User admin
    SetEnv PSM_PSMP_HOST=psmp-prod.example.com
```

The script reads the value through `ssh -G` (the same way it reads `HostName`
and `User`). The ssh config override always wins over the psm config and the
environment.

### Supported variables

| Variable           | Default               | Description                              |
|--------------------|-----------------------|------------------------------------------|
| `PSMP_HOST`        | `psmp.example.com`    | PSMP proxy hostname                      |
| `VAULT_USER`       | `your.vault.user`     | CyberArk vault user                      |
| `KDBX_PATH`        | `~/Passwords.kdbx`    | KeePassXC database                       |
| `KDBX_GROUP`       | `PSM`                 | Group that holds the entries             |
| `VAULT_PASS_ENTRY` | `VaultPassword`       | Title of the vault password entry        |
| `GPG_MASTER_FILE`  | `~/.psm-master.gpg`   | GPG-encrypted KeePassXC master password  |
| `LDAP_USER`        | (empty)               | LDAP/AD users (space-separated)          |
| `SSH_OPTS`         | (see script)          | ssh options                              |
| `EXPECT_TIMEOUT`   | `30`                  | Timeout (s) for the prompts              |
| `AUTO_SUDO`        | `1`                   | `1` auto-fills `[sudo]` prompts; `0` manual sudo |

## Usage

```bash
psm admin@srv-prod01              # explicit user@host syntax
psm srv-prod01                    # user taken from ~/.ssh/config
psm -d root@switch-core01         # debug: shows all expect exchanges
psm -S admin@srv-prod01           # disable auto-sudo (manual sudo)
psm -p 2222 admin@srv-prod01      # custom SSH port
psm -v other.user admin@host      # override the vault user
psm -l                            # list the targets in KeePassXC
psm -h                            # help
```

**Bare `host` syntax (no user)**: if the user for this host is set in
`~/.ssh/config`, you can omit the `user@` part. Example:

```
# ~/.ssh/config
Host srv-prod01
    HostName 10.2.2.2
    User admin
```

→ `psm srv-prod01` is equivalent to `psm admin@10.2.2.2`.

**Auto-sudo**: `[sudo] password for ...:` prompts are filled automatically
with the target password during the interactive session. Disable it with
`-S` or `AUTO_SUDO=0` (see [Security](#security)).

## Running a command (non-interactive)

As with `ssh host "cmd"`, extra arguments are run on the target without
opening an interactive shell, and the exit code of the command is propagated.

```bash
psm srv-prod01 "systemctl status nginx"
psm admin@srv-prod01 ls -la /data
```

> The PSMP injects a banner ("session is being recorded" + legal banner)
> **before** the command output, even in non-interactive mode. This is a
> CyberArk server setting that cannot be disabled client-side: keep it in mind
> when piping the output.

## File transfer (`psm cp`)

Transfer through the PSMP with `scp`. Push and pull, recursive, multiple
files. scp flags are passed through as is.

```bash
psm cp ./deploy.sh srv-prod01:/tmp/        # push
psm cp ./deploy.sh admin@srv-prod01:/tmp/  # push, explicit user
psm cp srv-prod01:/etc/hosts .             # pull
psm cp -r ./dist srv-prod01:/var/www/      # recursive
psm cp a.conf b.conf srv-prod01:/etc/      # multiple files
```

The PSMP port is set with `psm -p PORT cp …` (translated to `-P` for scp).
The scp exit code is propagated.

## Hostname resolution

The script resolves hostnames before passing them to the PSMP, in this order:

1. **`~/.ssh/config`** — `Host srv-prod01` / `HostName 10.2.2.2` (instant)
2. **`/etc/hosts` + DNS** — system resolution with a 2s timeout
3. **No match** — the hostname is passed to the PSMP as is

For a service account, the KeePassXC lookup tries the resolved name first
(`app@10.2.2.2`), then the original name (`app@srv-prod01`). Both naming
conventions work (see [KeePassXC entry layout](#keepassxc-entry-layout)).

The short DNS timeout (2s) avoids hanging on hostnames that the client
machine cannot resolve: the PSMP has its own internal DNS for the final
resolution.

## Flow

### SSH key + GPG mode (no GUI)

```
psm admin@srv-prod01
  │
  ├─ ssh-agent has keys → vault password not needed
  ├─ gpg -qd ~/.psm-master.gpg
  │    → keepassxc-cli show ... "PSM/admin@srv-prod01" → TARGET_PASS (env)
  │
  ├─ expect:
  │    spawn ssh your.vault.user@admin@srv-prod01@psmp.example.com
  │    [banner hidden, vault auth with the SSH key]
  │    "Password:"              → sends TARGET_PASS
  │    interact (auto-sudo on [sudo] prompts)
  │
  └─ interactive shell on srv-prod01
```

### SSH key + Secret Service mode (GUI)

```
psm admin@srv-prod01
  │
  ├─ ssh-agent has keys → vault password not needed
  ├─ secret-tool lookup Title "admin@srv-prod01"   → TARGET_PASS (env)
  │
  ├─ expect:
  │    spawn ssh your.vault.user@admin@srv-prod01@psmp.example.com
  │    [banner hidden, vault auth with the SSH key]
  │    "Password:"       → sends TARGET_PASS
  │    interact
  │
  └─ interactive shell on srv-prod01
```

### Password mode (vault + target)

```
psm admin@srv-prod01
  │
  ├─ ssh-agent without keys → fetch the vault password
  ├─ fetch "VaultPassword"                         → VAULT_PASS  (env)
  ├─ fetch "admin@srv-prod01"                      → TARGET_PASS (env)
  │   (source: secret-tool → keepassxc-cli+GPG → interactive keepassxc-cli)
  │
  ├─ expect:
  │    spawn ssh your.vault.user@admin@srv-prod01@psmp.example.com
  │    [banner hidden]
  │    "Vault Password:" → sends VAULT_PASS
  │    "Password:"       → sends TARGET_PASS
  │    interact
  │
  └─ interactive shell on srv-prod01
```

## Security

- Passwords reach `expect` through environment variables
  (`$env(VAULT_PASS)`, `$env(TARGET_PASS)`), never on the command line, so
  they do not show up in `ps`, `/proc/*/cmdline` or the shell history.
- The variables are `unset` as soon as `expect` exits, including on errors
  (`|| rc=$?` pattern).
- No password is written to disk. The temporary expect file only contains
  `$env(...)` references, not values.
- In Secret Service mode, `secret-tool` talks to the daemon over D-Bus
  without ever exposing the KeePassXC database.
- In GPG mode, only the encrypted master password is on disk. Decryption goes
  through `gpg-agent` (time-limited cache).
- **Debug mode (`-d`)**: a warning is printed because `exp_internal` shows
  the passwords in clear text in the output. Do not use it in production.
- **Auto-sudo** (on by default): the target password automatically answers
  `[sudo] password for …:` prompts during the session. **Beware of hops**: if
  you `ssh` from the target to another server, this mechanism would send the
  target's password to the sudo prompt of the other server (wrong password,
  and a secret leaked to a machine it does not belong to). Disable it then:
  - `psm -S host` for the session, or `AUTO_SUDO=0` in the config as the default;
  - on the fly in an open session: `export SUDO_PROMPT='pw: '` (changes the
    sudo prompt so that it no longer matches) then `sudo -s`.

## Exit codes

| Code  | Cause                                              |
|-------|----------------------------------------------------|
| 0     | Session ended normally                             |
| 2     | Usage error (arguments, options)                   |
| 3     | Password retrieval failed                          |
| 10    | Vault password required but not available         |
| 11    | Timeout waiting for a prompt                       |
| 12    | Connection closed (eof)                            |
| 13    | Permission denied (SSH key rejected)               |
| 14    | SSH passphrase requested (key not loaded in the agent) |
| 20–24 | Failure between vault and target (incl. MFA)      |
| 30–32 | Failure after target auth                          |

In exec (`psm host "cmd"`) and `psm cp` modes, once authentication succeeds,
the exit code is the one returned by the remote command or by scp, propagated
as is (so it can overlap with the codes above).

## Known limitations

- **MFA not supported**: if the PSMP asks for an OTP between the two prompts,
  the script stops with a clear message (code 21).
- The prompt regexes (`vault password`, `password`) are generic. If your PSMP
  uses unusual labels, run with `-d` to see the raw exchanges and adapt the
  `expect` blocks in the script.
- Auto-sudo only matches the `[sudo] password for ...:` format. Custom sudo
  prompts and `su` prompts are not intercepted.
- Hostname resolution does not handle IPv6 explicitly.
- **exec — PSMP banner**: the output of `psm host "cmd"` is preceded by the
  legal banner / recording notice injected by the PSMP (cannot be disabled
  client-side).
- **`psm cp` — target detection**: an scp flag value containing `:` before a
  `/` (e.g. `-o Foo=a:b`, rare) can be mistaken for the remote target; use
  `scp` directly in that case.
- **`psm cp`** does not support remote-to-remote transfers (a single PSMP target).

## License

MIT
