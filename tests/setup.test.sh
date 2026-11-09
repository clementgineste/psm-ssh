#!/usr/bin/env bash
# Tests for the building blocks of `psm doctor` and `psm setup`.
# External tools are replaced by shell functions (stubs) defined in each case,
# except for the ~/.bashrc block test, which runs a real ssh-agent.
# Usage: bash tests/setup.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
AGENT_PIDS=()
cleanup() {
    local p
    for p in "${AGENT_PIDS[@]}"; do kill "$p" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

# Sandbox HOME before sourcing psm, so that no real config is loaded
export HOME="$WORK/home"
mkdir -p "$HOME"
unset PSM_CONFIG SSH_AUTH_SOCK GPG_TTY

# shellcheck source=/dev/null
source "$HERE/../psm"   # the main() guard prevents the script from running
set +e                  # disable the set -e inherited from psm
C_RED='' C_GRN='' C_YLW='' C_CYN='' C_RST=''   # plain output, even from a terminal

fails=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'ok   - %s\n' "$desc"
    else
        printf 'FAIL - %s\n       expected: %q\n       actual  : %q\n' "$desc" "$expected" "$actual"
        fails=1
    fi
}
assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf 'ok   - %s\n' "$desc"
    else
        printf 'FAIL - %s\n       missing : %q\n       in      : %q\n' "$desc" "$needle" "$haystack"
        fails=1
    fi
}

# Fake executables for `command -v` (missing_packages only looks at PATH)
STUBS="$WORK/stubs"
mkdir -p "$STUBS/apt" "$STUBS/dnf" "$STUBS/full"
for c in apt-get expect ssh; do printf '#!/bin/sh\n' > "$STUBS/apt/$c"; done
for c in dnf expect ssh ssh-add ssh-agent keepassxc-cli pinentry; do printf '#!/bin/sh\n' > "$STUBS/dnf/$c"; done
for c in apt-get expect ssh ssh-add ssh-agent gpg keepassxc-cli pinentry-curses; do printf '#!/bin/sh\n' > "$STUBS/full/$c"; done
chmod +x "$STUBS"/*/*

# --- missing_packages --------------------------------------------------------
assert_eq "packages: apt, several missing" "openssh-client gnupg keepassxc pinentry-curses" \
    "$(PATH="$STUBS/apt" missing_packages)"
assert_eq "packages: dnf names"            "gnupg2" \
    "$(PATH="$STUBS/dnf" missing_packages)"
assert_eq "packages: nothing missing"      "" \
    "$(PATH="$STUBS/full" missing_packages)"

# --- write_config: values survive a round trip through `source` ---------------
cfg="$WORK/cfg/config"
PSMP_HOST='psmp.corp.example' VAULT_USER='j"o$h`n\x' KDBX_PATH="$HOME/db/my base.kdbx" \
KDBX_GROUP='PSM' LDAP_USER='a.b c.d' GPG_MASTER_FILE="$HOME/.psm-master.gpg" \
    write_config "$cfg"
got=$(PSMP_HOST= VAULT_USER= KDBX_PATH= KDBX_GROUP= LDAP_USER= GPG_MASTER_FILE= \
      bash -c 'source "$1"; printf "%s|%s|%s|%s|%s|%s" "$PSMP_HOST" "$VAULT_USER" "$KDBX_PATH" "$KDBX_GROUP" "$LDAP_USER" "$GPG_MASTER_FILE"' _ "$cfg")
assert_eq "config: round trip" \
    "psmp.corp.example|j\"o\$h\`n\\x|$HOME/db/my base.kdbx|PSM|a.b c.d|$HOME/.psm-master.gpg" "$got"
assert_contains "config: paths under HOME are written with \$HOME" 'KDBX_PATH="$HOME/db/my base.kdbx"' "$(cat "$cfg")"
assert_eq "config: mode 600" "600" "$(stat -c %a "$cfg")"

# --- bashrc_render -------------------------------------------------------------
rc="$WORK/bashrc"
printf 'alias ll="ls -l"\n' > "$rc"
first=$(bashrc_render "$rc")
assert_contains "bashrc: keeps the existing lines" 'alias ll="ls -l"' "$first"
assert_contains "bashrc: adds the begin marker" "$PSM_BASHRC_BEGIN" "$first"
assert_contains "bashrc: adds the end marker"   "$PSM_BASHRC_END" "$first"
printf '%s\n' "$first" > "$rc"
assert_eq "bashrc: second render changes nothing" "$first" "$(bashrc_render "$rc")"

printf 'before\n%s\nold content\n%s\nafter\n' "$PSM_BASHRC_BEGIN" "$PSM_BASHRC_END" > "$rc"
replaced=$(bashrc_render "$rc")
assert_eq "bashrc: old block replaced in place" \
    "before|$(bashrc_block | paste -sd'|')|after" "$(paste -sd'|' <<< "$replaced")"

printf 'before\n%s\nno end marker\n' "$PSM_BASHRC_BEGIN" > "$rc"
bashrc_render "$rc" >/dev/null 2>&1
assert_eq "bashrc: begin without end → refused" "1" "$?"

assert_eq "bashrc: no file → block only" "$(bashrc_block)" "$(bashrc_render "$WORK/none")"

# --- the ~/.bashrc block finds or starts an ssh-agent ---------------------------
if command -v ssh-agent >/dev/null 2>&1; then
    run="$WORK/run"; mkdir -p "$run"; chmod 700 "$run"
    eval "$(ssh-agent -s -a "$run/openssh_agent")" >/dev/null
    AGENT_PIDS+=("$SSH_AGENT_PID")
    unset SSH_AUTH_SOCK SSH_AGENT_PID
    got=$(XDG_RUNTIME_DIR="$run" SSH_AUTH_SOCK="$run/missing" \
          bash -c 'source <(cat); printf %s "$SSH_AUTH_SOCK"' < <(bashrc_block))
    assert_eq "block: switches to the live distro socket" "$run/openssh_agent" "$got"

    empty="$WORK/run-empty"; mkdir -p "$empty"
    got=$(XDG_RUNTIME_DIR="$empty" SSH_AUTH_SOCK="" \
          bash -c 'source <(cat); printf "%s %s" "$SSH_AUTH_SOCK" "${SSH_AGENT_PID:-}"' < <(bashrc_block))
    sock="${got% *}" pid="${got#* }"
    [[ -n "$pid" ]] && AGENT_PIDS+=("$pid")
    assert_eq "block: starts an agent when none answers" "$HOME/.ssh/psm-agent.sock" "$sock"
    rc_add=0; SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1 || rc_add=$?
    assert_eq "block: the started agent answers (no key → rc 1)" "1" "$rc_add"
else
    printf 'skip - ssh-agent not installed, block runtime tests skipped\n'
fi

# --- gpg parsing (stubbed gpg) ------------------------------------------------
gpg() {
    case "$*" in
        *--list-packets*)
            printf '# off=0 ctb=84 tag=1 hlen=2 plen=94\n'
            printf ':pubkey enc packet: version 3, algo 18, keyid 7845A76AAF98B403\n'
            printf '\tdata: [263 bits]\n:encrypted data packet:\n' ;;
        *--list-secret-keys*)
            printf 'sec:u:255:22:C13E677CF27F5451:1793983123:::u:::scESC:::+::ed25519:::0:\n'
            printf 'fpr:::::::::5F1F94752409FAF70AC439C6C13E677CF27F5451:\n'
            printf 'uid:u::::1793983123::F2E7::Test User <test@example.com>::::::::::0:\n'
            printf 'ssb:u:255:18:7845A76AAF98B403:1793983123::::::e:::+::cv25519::\n'
            printf 'fpr:::::::::9F7F419AE1BF4557283E64237845A76AAF98B403:\n'
            printf 'sec:r:255:22:AAAAAAAAAAAAAAAA:1793983123:::u:::scESC:::+::ed25519:::0:\n'
            printf 'fpr:::::::::BBBBBBBBBBBBBBBBBBBBBBBBAAAAAAAAAAAAAAAA:\n'
            printf 'uid:r::::1793983123::F2E7::Revoked <old@example.com>::::::::::0:\n'
            printf 'sec:u:255:22:CCCCCCCCCCCCCCCC:1793983123:::u:::scSC:::+::ed25519:::0:\n'
            printf 'fpr:::::::::DDDDDDDDDDDDDDDDDDDDDDDDCCCCCCCCCCCCCCCC:\n'
            printf 'uid:u::::1793983123::F2E7::Sign Only <sign@example.com>::::::::::0:\n' ;;
    esac
}
assert_eq "gpg: recipient key id"       "7845A76AAF98B403" "$(gpg_recipient_keyids "$WORK/any.gpg")"
assert_contains "gpg: secret key ids include subkeys" "7845A76AAF98B403" "$(gpg_secret_keyids)"
assert_eq "gpg: usable encryption keys (revoked and sign-only skipped)" \
    "$(printf '5F1F94752409FAF70AC439C6C13E677CF27F5451\tTest User <test@example.com>')" \
    "$(gpg_encrypt_keys)"
unset -f gpg

# Symmetric file, with more packets written after the matching one (SIGPIPE case)
gpg() { printf ':symkey enc packet: version 4, cipher 9, aead 0, s2k 3, hash 2\n'; sleep 0.2
        printf ':encrypted data packet:\n'; }
gpg_is_symmetric "$WORK/any.gpg"
assert_eq "gpg: symmetric file detected, late output included" "0" "$?"
unset -f gpg

# --- doctor: ssh-agent ---------------------------------------------------------
systemctl() { [[ "$*" == *"ssh-agent.socket"*"Listen"* ]] && printf '/run/user/1000/openssh_agent (Stream)\n'; return 0; }
assert_eq "distro agent socket from systemd" "/run/user/1000/openssh_agent" "$(distro_agent_socket)"

ssh-add() { return 2; }
out=$(SSH_AUTH_SOCK="$WORK/no-such-socket" doctor_ssh_agent; echo "fails=$DOC_FAILS")
assert_contains "doctor ssh: missing socket is a FAIL"  "[FAIL]" "$out"
assert_contains "doctor ssh: fix points to the distro socket" \
    'export SSH_AUTH_SOCK="/run/user/1000/openssh_agent"' "$out"
assert_contains "doctor ssh: failure counted" "fails=1" "$out"

mkdir -p "$HOME/.config/systemd/user"
: > "$HOME/.config/systemd/user/ssh-agent.service"
out=$(SSH_AUTH_SOCK="$WORK/no-such-socket" doctor_ssh_agent)
assert_contains "doctor ssh: custom unit hiding the distro one" "hides" "$out"
rm -f "$HOME/.config/systemd/user/ssh-agent.service"

systemctl() { return 0; }   # no distro agent
out=$(SSH_AUTH_SOCK="" doctor_ssh_agent)
assert_contains "doctor ssh: no psm block → fix is psm setup" "fix: psm setup" "$out"
bashrc_block > "$HOME/.bashrc"
out=$(SSH_AUTH_SOCK="" doctor_ssh_agent)
assert_contains "doctor ssh: psm block present → fix is to reload the shell" "source ~/.bashrc" "$out"
rm -f "$HOME/.bashrc"
unset -f systemctl ssh-add

# --- doctor: config placeholders -----------------------------------------------
out=$(PSM_CONFIG_LOADED="" PSMP_HOST=psmp.example.com VAULT_USER=your.vault.user doctor_config; echo "fails=$DOC_FAILS")
assert_contains "doctor config: no file is a FAIL"           "[FAIL] No config file" "$out"
assert_contains "doctor config: no file, one failure only"   "fails=1" "$out"
out=$(PSM_CONFIG_LOADED="$cfg" PSMP_HOST=psmp.example.com VAULT_USER=your.vault.user doctor_config; echo "fails=$DOC_FAILS")
assert_contains "doctor config: placeholder host"  "[FAIL] PSMP_HOST is still the placeholder" "$out"
assert_contains "doctor config: placeholder user"  "[FAIL] VAULT_USER is still the placeholder" "$out"
assert_contains "doctor config: 2 failures"        "fails=2" "$out"

# --- doctor: main [FAIL] cases --------------------------------------------------
out=$(PATH="$STUBS/apt" doctor_packages; echo "fails=$DOC_FAILS")
assert_contains "doctor packages: missing is a FAIL"  "[FAIL] Missing packages: openssh-client" "$out"
assert_contains "doctor packages: apt fix"            "fix: sudo apt-get install -y openssh-client" "$out"
assert_contains "doctor packages: failure counted"    "fails=1" "$out"

out=$(KDBX_PATH="$WORK/no-such.kdbx" doctor_kdbx; echo "fails=$DOC_FAILS")
assert_contains "doctor kdbx: missing database is a FAIL" "[FAIL] Database not found" "$out"
assert_contains "doctor kdbx: failure counted"            "fails=1" "$out"

# Real gpg-connect-agent exits 0 with or without an agent: only the D line differs.
# It writes "OK" after the D line: a `| grep -q` would stop reading, the late
# write gets SIGPIPE, and pipefail turns the match into a failure.
gpg-connect-agent() { printf 'D 4242\n'; sleep 0.2; printf 'OK\n'; }
out=$(GPG_MASTER_FILE="$WORK/no-such.gpg" doctor_gpg; echo "fails=$DOC_FAILS")
assert_contains "doctor gpg: missing master file is a FAIL" "[FAIL] Master password file not found" "$out"
assert_contains "doctor gpg: agent running"                 "[ OK ] gpg-agent is running" "$out"
gpg-connect-agent() { echo "gpg-connect-agent: no gpg-agent running in this session" >&2; return 0; }
out=$(GPG_MASTER_FILE="$WORK/no-such.gpg" doctor_gpg)
assert_contains "doctor gpg: agent not running is only info" "[INFO] gpg-agent is not running" "$out"
unset -f gpg-connect-agent

foreign="$WORK/foreign.gpg"; : > "$foreign"; chmod 644 "$foreign"
gpg() {
    case "$*" in
        *--list-packets*)     printf ':pubkey enc packet: version 3, algo 18, keyid 1111222233334444\n' ;;
        *--list-secret-keys*) printf 'ssb:u:255:18:7845A76AAF98B403:1793983123::::::e:::+::cv25519::\n' ;;
    esac
}
out=$(GPG_MASTER_FILE="$foreign" doctor_gpg; echo "fails=$DOC_FAILS")
assert_contains "doctor gpg: mode 644 is a WARN"         "[WARN] $foreign has mode 644" "$out"
assert_contains "doctor gpg: key not in the keyring"     "[FAIL] Encrypted for 1111222233334444" "$out"
unset -f gpg

# --- doctor: install, clone state shown even when psm is not in PATH ------------
out=$(PATH=/usr/bin:/bin; psm_self() { echo "$WORK/clone-x/psm"; }; clone_state() { echo behind; }; doctor_install)
assert_contains "doctor install: not in PATH"           "[FAIL] psm is not in PATH" "$out"
assert_contains "doctor install: clone checked anyway"  "[WARN] Clone $WORK/clone-x is behind origin" "$out"

# --- doctor: ssh keys present but not loaded -------------------------------------
if command -v ssh-keygen >/dev/null 2>&1; then
    mkdir -p "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N '' -C loaded -f "$HOME/.ssh/id_ed25519" </dev/null
    ssh-keygen -q -t ed25519 -N '' -C other  -f "$HOME/.ssh/id_other"   </dev/null
    loaded_fp=$(ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub" | awk '{print $2}')
    ssh-add() { [[ "$1" == -l ]] && printf '256 %s loaded (ED25519)\n' "$loaded_fp"; }
    assert_eq "unloaded keys: only the key missing from the agent" \
        "$HOME/.ssh/id_other" "$(unloaded_ssh_keys)"
    sock="$WORK/run/openssh_agent"   # live agent started by the block test above
    if [[ -S "$sock" ]]; then
        out=$(SSH_AUTH_SOCK="$sock" doctor_ssh_agent)
        assert_contains "doctor ssh: lists keys not loaded" "~/.ssh/id_other" "$out"
        ssh-add() { return 1; }
        out=$(SSH_AUTH_SOCK="$sock" doctor_ssh_agent)
        assert_contains "doctor ssh: no key loaded → fix names the keys" "fix: ssh-add ~/.ssh/id_ed25519 ~/.ssh/id_other" "$out"
    else
        printf 'skip - no live agent socket, doctor ssh key cases skipped\n'
    fi
    unset -f ssh-add
    rm -f "$HOME"/.ssh/id_*
fi

# --- doctor: clone freshness (read-only, ls-remote) -------------------------------
if command -v git >/dev/null 2>&1; then
    g() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }
    g init -q "$WORK/src" && g -C "$WORK/src" commit -q --allow-empty -m one
    g clone -q --bare "$WORK/src" "$WORK/origin.git"
    g clone -q "$WORK/origin.git" "$WORK/clone"
    g clone -q "$WORK/origin.git" "$WORK/other"
    assert_eq "clone: up to date"               "current" "$(clone_state "$WORK/clone")"
    g -C "$WORK/other" commit -q --allow-empty -m two && g -C "$WORK/other" push -q 2>/dev/null
    assert_eq "clone: behind origin"            "behind"  "$(clone_state "$WORK/clone")"
    g -C "$WORK/clone" pull -q 2>/dev/null && g -C "$WORK/clone" commit -q --allow-empty -m local
    assert_eq "clone: local commits only"       "current" "$(clone_state "$WORK/clone")"
    mkdir -p "$WORK/plain"
    assert_eq "clone: not a git clone"          "none"    "$(clone_state "$WORK/plain")"
    g -C "$WORK/clone" remote set-url origin "$WORK/gone.git"
    assert_eq "clone: origin unreachable"       "unknown" "$(clone_state "$WORK/clone")"
    unset -f g
fi

# --- doctor --deep (stubbed gpg and keepassxc-cli) ----------------------------------
GPG_MASTER_FILE="$WORK/master.gpg"; : > "$GPG_MASTER_FILE"
KDBX_PATH="$WORK/db.kdbx";          : > "$KDBX_PATH"
KDBX_GROUP=PSM VAULT_PASS_ENTRY=VaultPassword
gpg() { [[ "$*" == *-qd* && -n "$master" ]] && printf '%s' "$master"; }
keepassxc-cli() {
    local pw
    IFS= read -r pw || true
    [[ "$pw" == right ]] || return 1
    case "$*" in
        "ls -q $KDBX_PATH")     printf 'PSM/\n' ;;
        "ls -q $KDBX_PATH PSM")    # missing group → rc 1; empty group → "[empty]" (translated)
            (( kp_group )) || return 1
            printf '%s\n' "${kp_entries:-[vide]}" ;;
        *) return 1 ;;
    esac
}
ssh-add() { return 1; }   # no key loaded
kp_group=1
master=right kp_entries=$'VaultPassword\nroot@srv-prod01'
out=$(doctor_deep; echo "fails=$DOC_FAILS")
assert_contains "deep: database opened"        "[ OK ] Database opened" "$out"
assert_contains "deep: group and entry count"  "[ OK ] Group PSM: 2 entries" "$out"
assert_contains "deep: vault password entry"   "[ OK ] Vault password entry: PSM/VaultPassword" "$out"
assert_contains "deep: no failure"             "fails=0" "$out"
master=""
out=$(doctor_deep; echo "fails=$DOC_FAILS")
assert_contains "deep: gpg cannot decrypt"     "[FAIL] Cannot decrypt" "$out"
master=wrong
out=$(doctor_deep; echo "fails=$DOC_FAILS")
assert_contains "deep: wrong master password"  "[FAIL] The password in $GPG_MASTER_FILE does not open" "$out"
master=right kp_group=0
out=$(doctor_deep; echo "fails=$DOC_FAILS")
assert_contains "deep: group missing"          "[FAIL] Group PSM not found" "$out"
kp_group=1 kp_entries=""
out=$(doctor_deep; echo "fails=$DOC_FAILS")
assert_contains "deep: empty group exists, 0 entries" "[ OK ] Group PSM: 0 entries" "$out"
master=right kp_entries="root@srv-prod01"
out=$(doctor_deep; echo "fails=$DOC_FAILS")
assert_contains "deep: no vault entry and no key" "[FAIL] No SSH key loaded and no PSM/VaultPassword entry" "$out"
ssh-add() { return 0; }   # a key is loaded
out=$(doctor_deep; echo "fails=$DOC_FAILS")
assert_contains "deep: no vault entry, key loaded → info" "fails=0" "$out"
unset -f gpg keepassxc-cli ssh-add

# --- doctor: arguments ---------------------------------------------------------------
run_doctor --bogus >/dev/null 2>&1
assert_eq "doctor: unknown argument → rc 2" "2" "$?"

if (( fails )); then
    echo "== FAILED =="
    exit 1
fi
echo "== OK (all cases pass) =="
