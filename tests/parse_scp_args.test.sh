#!/usr/bin/env bash
# Unit tests for parse_scp_args (pure function of psm).
# Usage : bash tests/parse_scp_args.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../psm"   # the main() guard prevents the script from running
set +e                  # disable the set -e inherited from psm for the error cases

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
assert_rc() {
    local desc="$1" expected="$2"; shift 2
    local rc
    if "$@" >/dev/null 2>&1; then rc=0; else rc=$?; fi
    assert_eq "$desc" "$expected" "$rc"
}

# Case 1 — simple pull: host:/path as source
parse_scp_args srv:/etc/hosts . >/dev/null 2>&1
assert_eq "pull: host"  "srv"        "$PSA_REMOTE_HOST"
assert_eq "pull: path"  "/etc/hosts" "$PSA_REMOTE_PATH"
assert_eq "pull: index" "0"          "$PSA_REMOTE_INDEX"

# Case 2 — simple push: host:/path as destination
parse_scp_args ./f.txt srv:/tmp/ >/dev/null 2>&1
assert_eq "push: host"  "srv"   "$PSA_REMOTE_HOST"
assert_eq "push: path"  "/tmp/" "$PSA_REMOTE_PATH"
assert_eq "push: index" "1"     "$PSA_REMOTE_INDEX"

# Case 3 — explicit user@host
parse_scp_args ./f admin@srv:/tmp/ >/dev/null 2>&1
assert_eq "user@host: host" "admin@srv" "$PSA_REMOTE_HOST"

# Case 4 — recursive flag before the paths
parse_scp_args -r ./dist srv:/var/www/ >/dev/null 2>&1
assert_eq "-r: host"  "srv"        "$PSA_REMOTE_HOST"
assert_eq "-r: index" "2"          "$PSA_REMOTE_INDEX"

# Case 5 — multiple files to a remote directory
parse_scp_args a b srv:/etc/ >/dev/null 2>&1
assert_eq "multi: index" "2"   "$PSA_REMOTE_INDEX"
assert_eq "multi: host"  "srv" "$PSA_REMOTE_HOST"

# Case 6 — flag with a separate value (-l 1000): the value must not be taken for a remote
parse_scp_args -l 1000 ./f srv:/tmp/ >/dev/null 2>&1
assert_eq "flag-value: index" "3"   "$PSA_REMOTE_INDEX"
assert_eq "flag-value: host"  "srv" "$PSA_REMOTE_HOST"

# Case 7 — absolute local path not mistaken for a remote (no ':')
parse_scp_args /tmp/a srv:/b >/dev/null 2>&1
assert_eq "abs-local: index" "1"   "$PSA_REMOTE_INDEX"
assert_eq "abs-local: host"  "srv" "$PSA_REMOTE_HOST"

# Case 8 — relative local path with ':' after a '/' not mistaken for a remote
parse_scp_args ./a:b srv:/tmp/ >/dev/null 2>&1
assert_eq "local-colon: index" "1"   "$PSA_REMOTE_INDEX"
assert_eq "local-colon: host"  "srv" "$PSA_REMOTE_HOST"

# Case 9 — ':' in the remote path: split on the first ':'
parse_scp_args "srv:/tmp/a:b" . >/dev/null 2>&1
assert_eq "colon-in-path: host" "srv"       "$PSA_REMOTE_HOST"
assert_eq "colon-in-path: path" "/tmp/a:b"  "$PSA_REMOTE_PATH"

# Case 10 — no remote target → rc=2
assert_rc "0 remote: rc" "2" parse_scp_args ./a ./b

# Case 11 — two remote targets → rc=2
assert_rc "2 remotes: rc" "2" parse_scp_args srv1:/a srv2:/b

if (( fails )); then
    echo "== FAILED =="
    exit 1
fi
echo "== OK (all cases pass) =="
