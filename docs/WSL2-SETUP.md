# Complete psm-ssh setup on WSL2

Step-by-step guide to set up psm-ssh on WSL2 (Windows 10/11), with
persistent `ssh-agent` and `gpg-agent`, using the keepassxc-cli + GPG mode
(no GUI).

Tested on **Ubuntu 22.04 / 24.04** and **Fedora** under WSL2. The `apt`
commands apply to Ubuntu/Debian; use `dnf` instead on Fedora.

---

## 1. WSL2 prerequisites

### Enable systemd (WSL 0.67.6+)

systemd makes user services (ssh-agent, gpg-agent) easier to manage.
Edit `/etc/wsl.conf` in your distro:

```ini
[boot]
systemd=true

[interop]
enabled=true
appendWindowsPath=false
```

Then, from PowerShell (not WSL):

```powershell
wsl --shutdown
wsl
```

Check: `systemctl status` should answer without errors.

### Clock synchronization

The WSL2 clock can drift after sleep, which breaks Kerberos tickets and
TLS certificates. Force a resync at each startup:

```bash
# In ~/.bashrc or ~/.zshrc
alias wsl-time-sync='sudo hwclock -s'
```

A systemd unit would be cleaner, but it is skipped here: not critical for
psm-ssh.

---

## 2. Installing dependencies

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

> **No need for `libsecret-tools` or the KeePassXC GUI** on WSL2 without
> an X/Wayland server: this guide uses the keepassxc-cli + GPG mode.

Check the versions:

```bash
expect -v
ssh -V
keepassxc-cli --version
gpg --version
```

---

## 3. Persistent ssh-agent

WSL2 kills the parent process whenever a terminal is closed, so
`ssh-agent` dies with it. Three options, in order of preference:

### Option A — systemd user unit (recommended, clean)

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

Then export the variable in `~/.bashrc` (or `~/.zshrc`):

```bash
export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"
```

Reload the shell, then:

```bash
ssh-add ~/.ssh/id_rsa          # or the key you use for the PSMP
ssh-add -l                     # should list the key
```

The key stays loaded until WSL2 reboots. To reload it automatically at
boot, see [`keychain`](https://www.funtoo.org/Keychain) or an
ExecStartPost in the systemd unit.

### Option B — start from `~/.bashrc` (simple, no systemd)

```bash
# In ~/.bashrc
if ! pgrep -u "$USER" ssh-agent >/dev/null; then
    eval "$(ssh-agent -s)" >/dev/null
fi
if [[ -z "${SSH_AUTH_SOCK:-}" ]] || ! ssh-add -l >/dev/null 2>&1; then
    export SSH_AUTH_SOCK=$(find /tmp/ssh-* -user "$USER" -name agent.\* 2>/dev/null | head -1)
    ssh-add ~/.ssh/id_rsa 2>/dev/null
fi
```

Fragile when several terminals open at the same time, but good enough for
simple use.

### Option C — bridge to the Windows ssh-agent

Through [`npiperelay`](https://github.com/jstarks/npiperelay) + `socat`.
More complex, but it shares the keys between Windows (native OpenSSH) and
WSL. Worth looking into if you already use `ssh-agent` on the Windows side.

### Check

```bash
ssh-add -l
# Should print: 4096 SHA256:... (RSA)
```

---

## 4. gpg-agent configuration

gpg-agent caches the passphrase of your GPG key after the first entry, so
that `gpg -qd ~/.psm-master.gpg` is silent on subsequent calls.

### Use a terminal pinentry

WSL2 has no GUI, so the default pinentry (GTK/Qt) does not work.
Use `pinentry-curses` (ncurses):

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

> Fedora: the binary is `/usr/bin/pinentry` or `/usr/bin/pinentry-tty`.
> Run `which pinentry-curses || which pinentry` to check.

### Set GPG_TTY

gpg-agent needs to know the current TTY to display the pinentry.
Add to `~/.bashrc`:

```bash
export GPG_TTY=$(tty)
```

### Force an agent reload

```bash
gpg-connect-agent reloadagent /bye
```

### Test

```bash
# Create a test file encrypted with your key
echo "test" | gpg --encrypt --recipient you@example.com -o /tmp/test.gpg

# Decrypt (prompts for the passphrase the first time)
gpg -qd /tmp/test.gpg

# Decrypt again right away (should be silent, cache hit)
gpg -qd /tmp/test.gpg

rm /tmp/test.gpg
```

If the prompt does not show up or `gpg-agent` complains about the TTY,
check `echo $GPG_TTY` and export it again.

---

## 5. Creating the GPG key

If you do not have a personal GPG key yet:

```bash
gpg --full-generate-key
```

Recommended choices:
- Type: `(1) RSA and RSA`
- Size: `4096`
- Expiration: `0` (never) or `2y`, depending on your policy
- Name: your name
- Email: your email (used as `--recipient`)
- Passphrase: **strong** (it is the only thing protecting your KeePassXC database through GPG encryption)

Check:

```bash
gpg --list-secret-keys
```

Note the email associated with the key: it will be used as `--recipient`.

### Back up the key (important)

```bash
mkdir -p ~/gpg-backup && chmod 700 ~/gpg-backup
gpg --export-secret-keys --armor you@example.com > ~/gpg-backup/private.key
gpg --export --armor you@example.com > ~/gpg-backup/public.key
gpg --export-ownertrust > ~/gpg-backup/ownertrust.txt
```

Store it somewhere safe (not on your work machine, not in a git repo).

---

## 6. KeePassXC setup (CLI mode, no GUI)

### Create a KeePassXC database

From WSL2, `keepassxc-cli` can create a database:

```bash
keepassxc-cli db-create ~/Passwords.kdbx --set-password
# Type the master password twice
```

Or create it from the KeePassXC GUI on Windows, then copy the `.kdbx` to
`~/` on the WSL2 side (avoids lock issues).

### Create the PSM group

```bash
keepassxc-cli mkdir ~/Passwords.kdbx PSM
# Type the master password
```

### Add entries

```bash
# Target entry (service account on a server)
keepassxc-cli add -p ~/Passwords.kdbx "PSM/admin@srv-prod01"
# Type the master password, then the account password

# LDAP entry (personal account, same password everywhere)
keepassxc-cli add -p ~/Passwords.kdbx "PSM/john.doe"

# Vault entry (password mode; optional in SSH key mode)
keepassxc-cli add -p ~/Passwords.kdbx "PSM/VaultPassword"
```

### Check

```bash
keepassxc-cli ls ~/Passwords.kdbx PSM
# Should list: admin@srv-prod01, john.doe, VaultPassword, ...
```

---

## 7. Encrypt the KeePassXC master password with GPG

This is the file that `psm` decrypts automatically through `gpg-agent`.

```bash
# Type the master password at the prompt: it stays out of the shell history,
# and printf '%s' adds no trailing newline
printf 'KeePassXC master password: '; read -rs pw; echo
printf '%s' "$pw" | gpg --encrypt --recipient you@example.com -o ~/.psm-master.gpg
unset pw

chmod 600 ~/.psm-master.gpg
```

Test the full pipeline:

```bash
gpg -qd ~/.psm-master.gpg | \
    keepassxc-cli show -qsa Password ~/Passwords.kdbx PSM/admin@srv-prod01
# Should print the target password, without any prompt
```

First call: pinentry-curses prompts for the GPG passphrase. Subsequent
calls: silent (gpg-agent cache).

---

## 8. Installing psm-ssh

```bash
cd ~
git clone https://github.com/clementgineste/psm-ssh.git
cd psm-ssh
chmod +x psm

# Option 1: install into /usr/local/bin (system-wide)
sudo install -m 755 psm /usr/local/bin/psm

# Option 2: add to the PATH (per user)
echo 'export PATH="$HOME/psm-ssh:$PATH"' >> ~/.bashrc
```

### Enable the git hooks (if you contribute)

```bash
cd ~/psm-ssh
git config core.hooksPath .githooks
cp .githooks/patterns.example .githooks/patterns.local
$EDITOR .githooks/patterns.local
```

---

## 9. Configuration

Create the user config file:

```bash
mkdir -p ~/.config/psm
cp ~/psm-ssh/config.example ~/.config/psm/config
$EDITOR ~/.config/psm/config
```

Variables to fill in with your real values:

```bash
PSMP_HOST="psmp.example.com"
VAULT_USER="your.vault.user"
KDBX_PATH="$HOME/Passwords.kdbx"
KDBX_GROUP="PSM"
VAULT_PASS_ENTRY="VaultPassword"
GPG_MASTER_FILE="$HOME/.psm-master.gpg"
LDAP_USER="john.doe"             # your personal LDAP user, if applicable
```

### SSH key for the CyberArk vault

The PSMP accepts SSH key authentication for the vault user (if enabled on
the CyberArk side). Add the public key to your CyberArk account through
the Password Vault Web Access (PVWA), then:

```bash
ssh-add ~/.ssh/id_rsa       # if not already loaded through Option A
```

Without a loaded key, `psm` falls back to password mode (it fetches the
vault password from KeePassXC).

---

## 10. Test

```bash
# Debug mode — full trace for troubleshooting
psm -d admin@srv-prod01
```

Expected output:

```
[DBG]  Resolving ssh -G srv-prod01
[DBG]  DNS resolution: getent hosts srv-prod01 (2s timeout)
[DBG]  DNS not resolved, hostname passed as is
[INFO] Target: admin @ srv-prod01 (via psmp.example.com:22)
[DBG]  Checking ssh-agent
[INFO] SSH key mode (agent running, keys loaded)
[INFO] Looking up the target password in KeePassXC...
[DBG]  Lookup 'admin@srv-prod01'
[DBG]  Decrypting the master password via GPG (/home/user/.psm-master.gpg)
[DBG]  Password retrieved via keepassxc-cli + GPG for 'admin@srv-prod01'
[INFO] Password found (entry: PSM/admin@srv-prod01)
[DBG]  Spawn: ssh -p 22 ... your.vault.user@admin@srv-prod01@psmp.example.com
[WARN] Debug mode: passwords will be visible in the expect output
[INFO] Auto-sudo on (the target password answers [sudo] prompts)
...
# → interactive shell on srv-prod01
```

---

## 11. Troubleshooting

### `ssh-add -l` → "Could not open a connection to your authentication agent"

`SSH_AUTH_SOCK` is not exported. Restart the shell or run `source ~/.bashrc`.

### `gpg: decryption failed: No secret key`

The `--recipient` used for encryption does not match a secret key you
own. Run `gpg --list-secret-keys` to check, then encrypt again.

### `Keyboard interactive authentication failed`

Possible causes:
- Wrong target password in KeePassXC
- Account locked on the target
- The PSMP asks for MFA (not supported, see limitations)

Run with `-d` and look at the expect exchanges to find the step where it
gets stuck.

### `gpg: cannot open tty: No such device or address`

`GPG_TTY` is not exported. Add `export GPG_TTY=$(tty)` to `~/.bashrc`
and run `gpg-connect-agent reloadagent /bye`.

### `keepassxc-cli: command not found`

On some Fedora installs, the binary lives in a non-standard path. Run
`dnf list --installed | grep keepassxc`, then `which keepassxc-cli` to
locate it.

### DNS lookups take 30+ seconds

WSL2 sometimes inherits broken DNS resolvers from Windows. Check
`/etc/resolv.conf`. Temporary fix:

```bash
sudo tee /etc/resolv.conf > /dev/null <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
```

And in `/etc/wsl.conf`:

```ini
[network]
generateResolvConf=false
```

### psm exits immediately without an error

Usually caused by `set -euo pipefail` silently killing the script on a
failing command. Run with `-d` and look at the last debug line printed to
locate the failing step.

### `gpg: can't connect to the agent: IPC connect call failed`

gpg-agent is not running. Run `gpg-connect-agent reloadagent /bye`, or
`systemctl --user restart gpg-agent` on a systemd-based setup.

---

## 12. Bonus: aliases and shell integration

### Target completion

Use the completion shipped with the repo (flags, hostnames from
`~/.ssh/config`, local paths for `psm cp`):

```bash
# In ~/.bashrc
source ~/psm-ssh/completions/psm.bash
```

It never touches KeePassXC or GPG, so pressing TAB does not decrypt anything.
See the "Bash completion" section of the README.

### Shortcut for frequent targets

```bash
alias psmprod='psm admin@srv-prod01'
```

### Open several sessions in parallel

Each `psm` runs as an independent process. There is no contention on
KeePassXC as long as you do not modify the database. Several simultaneous
targets work fine.
