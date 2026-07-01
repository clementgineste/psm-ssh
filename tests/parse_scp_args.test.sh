#!/usr/bin/env bash
# Tests unitaires de parse_scp_args (fonction pure de psm).
# Usage : bash tests/parse_scp_args.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../psm"   # le guard main() empêche l'exécution du script
set +e                  # neutralise le set -e hérité de psm pour les cas d'erreur

fails=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'ok   - %s\n' "$desc"
    else
        printf 'FAIL - %s\n       attendu: %q\n       obtenu : %q\n' "$desc" "$expected" "$actual"
        fails=1
    fi
}
assert_rc() {
    local desc="$1" expected="$2"; shift 2
    local rc
    if "$@" >/dev/null 2>&1; then rc=0; else rc=$?; fi
    assert_eq "$desc" "$expected" "$rc"
}

# Cas 1 — pull simple : host:/path en source
parse_scp_args srv:/etc/hosts . >/dev/null 2>&1
assert_eq "pull: host"  "srv"        "$PSA_REMOTE_HOST"
assert_eq "pull: path"  "/etc/hosts" "$PSA_REMOTE_PATH"
assert_eq "pull: index" "0"          "$PSA_REMOTE_INDEX"

# Cas 2 — push simple : host:/path en destination
parse_scp_args ./f.txt srv:/tmp/ >/dev/null 2>&1
assert_eq "push: host"  "srv"   "$PSA_REMOTE_HOST"
assert_eq "push: path"  "/tmp/" "$PSA_REMOTE_PATH"
assert_eq "push: index" "1"     "$PSA_REMOTE_INDEX"

# Cas 3 — user@host explicite
parse_scp_args ./f admin@srv:/tmp/ >/dev/null 2>&1
assert_eq "user@host: host" "admin@srv" "$PSA_REMOTE_HOST"

# Cas 4 — flag récursif avant les chemins
parse_scp_args -r ./dist srv:/var/www/ >/dev/null 2>&1
assert_eq "-r: host"  "srv"        "$PSA_REMOTE_HOST"
assert_eq "-r: index" "2"          "$PSA_REMOTE_INDEX"

# Cas 5 — multi-fichiers vers un dossier distant
parse_scp_args a b srv:/etc/ >/dev/null 2>&1
assert_eq "multi: index" "2"   "$PSA_REMOTE_INDEX"
assert_eq "multi: host"  "srv" "$PSA_REMOTE_HOST"

# Cas 6 — flag à valeur séparée (-l 1000) : la valeur ne doit pas être prise pour un remote
parse_scp_args -l 1000 ./f srv:/tmp/ >/dev/null 2>&1
assert_eq "flag-valeur: index" "3"   "$PSA_REMOTE_INDEX"
assert_eq "flag-valeur: host"  "srv" "$PSA_REMOTE_HOST"

# Cas 7 — chemin local absolu non confondu (: absent)
parse_scp_args /tmp/a srv:/b >/dev/null 2>&1
assert_eq "abs-local: index" "1"   "$PSA_REMOTE_INDEX"
assert_eq "abs-local: host"  "srv" "$PSA_REMOTE_HOST"

# Cas 8 — chemin local relatif avec ':' après un '/' non confondu
parse_scp_args ./a:b srv:/tmp/ >/dev/null 2>&1
assert_eq "local-colon: index" "1"   "$PSA_REMOTE_INDEX"
assert_eq "local-colon: host"  "srv" "$PSA_REMOTE_HOST"

# Cas 9 — ':' dans le chemin distant : split au premier ':'
parse_scp_args "srv:/tmp/a:b" . >/dev/null 2>&1
assert_eq "colon-in-path: host" "srv"       "$PSA_REMOTE_HOST"
assert_eq "colon-in-path: path" "/tmp/a:b"  "$PSA_REMOTE_PATH"

# Cas 10 — aucune cible distante → rc=2
assert_rc "0 remote: rc" "2" parse_scp_args ./a ./b

# Cas 11 — deux cibles distantes → rc=2
assert_rc "2 remotes: rc" "2" parse_scp_args srv1:/a srv2:/b

if (( fails )); then
    echo "== ÉCHEC =="
    exit 1
fi
echo "== OK (tous les cas passent) =="
