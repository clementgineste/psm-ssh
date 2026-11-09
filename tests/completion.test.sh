#!/usr/bin/env bash
# Tests for the bash completion (completions/psm.bash).
# Runs twice: plain bash (compgen fallback) and with bash-completion loaded
# (_filedir), when it is installed.
# Usage: bash tests/completion.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fixture: fake HOME with an ssh config, and a local tree to complete paths in
mkdir -p "$WORK/home/.ssh" "$WORK/tree/work/sub" "$WORK/tree/my dir"
printf 'Host srv-prod01 srv-prod02\nHost LC*\n' > "$WORK/home/.ssh/config"
: > "$WORK/tree/work/sub/test.sh"

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'ok   - %s\n' "$desc"
    else
        printf 'FAIL - %s\n       expected: %q\n       actual  : %q\n' "$desc" "$expected" "$actual"
        fails=1
    fi
}

# Completes the given words (the last one is the word being completed) and
# prints the candidates, sorted and joined with '|'.
complete_words() {
    local -a sorted
    COMP_WORDS=("$@")
    COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
    COMPREPLY=()
    _psm_complete 2>/dev/null
    mapfile -t sorted < <(printf '%s\n' "${COMPREPLY[@]}" | LC_ALL=C sort)
    local IFS='|'
    printf '%s' "${sorted[*]}"
}

# Prints the number of failures as exit code (runs in a subshell).
run_suite() {
    local mode="$1"
    fails=0
    HOME="$WORK/home"
    cd "$WORK/tree" || exit 1

    assert_eq "$mode: flags"            "-S|-d|-h|-l|-p|-v"                 "$(complete_words psm -)"
    assert_eq "$mode: -p value"         ""                                  "$(complete_words psm -p '')"
    assert_eq "$mode: hosts"            "srv-prod01|srv-prod02"             "$(complete_words psm srv)"
    assert_eq "$mode: user@host"        "admin@srv-prod01|admin@srv-prod02" "$(complete_words psm admin@srv-prod0)"
    assert_eq "$mode: cp subcommand"    "cp"                                "$(complete_words psm c)"
    assert_eq "$mode: doctor subcommand" "doctor"                           "$(complete_words psm doc)"
    assert_eq "$mode: setup subcommand" "setup|srv-prod01|srv-prod02"       "$(complete_words psm s)"
    assert_eq "$mode: doctor offers --deep" "--deep"                        "$(complete_words psm doctor '')"
    assert_eq "$mode: doctor -- → --deep" "--deep"                          "$(complete_words psm doctor --)"
    assert_eq "$mode: nothing after --deep" ""                              "$(complete_words psm doctor --deep '')"
    assert_eq "$mode: nothing after setup" ""                               "$(complete_words psm setup '')"
    assert_eq "$mode: hosts after -p"   "srv-prod01|srv-prod02"             "$(complete_words psm -p 2222 srv)"

    assert_eq "$mode: cp local dir"     "./work/sub"                        "$(complete_words psm cp ./work/)"
    assert_eq "$mode: cp nested file"   "./work/sub/test.sh"                "$(complete_words psm cp ./work/sub/)"
    assert_eq "$mode: cp path w/ space" "./my dir"                          "$(complete_words psm cp ./my)"
    assert_eq "$mode: cp hosts"         "srv-prod01|srv-prod02"             "$(complete_words psm cp f srv)"
    assert_eq "$mode: cp user@host"     "admin@srv-prod01|admin@srv-prod02" "$(complete_words psm cp f admin@srv-prod0)"

    assert_eq "$mode: cp after -d"      "./work/sub"                        "$(complete_words psm -d cp ./work/)"
    assert_eq "$mode: cp after -p N"    "./work/sub"                        "$(complete_words psm -p 2222 cp ./work/)"
    assert_eq "$mode: cp after -dp N"   "./work/sub"                        "$(complete_words psm -dp 2222 cp ./work/)"
    assert_eq "$mode: cp after -v U"    "./work/sub"                        "$(complete_words psm -v vuser cp ./work/)"
    assert_eq "$mode: cp after -p N, host" "srv-prod01|srv-prod02"          "$(complete_words psm -p 2222 cp f srv)"

    exit "$fails"
}

total_fails=0

# Suite 1: plain bash, no bash-completion → compgen fallback
(
    # shellcheck source=/dev/null
    source "$HERE/../completions/psm.bash"
    unset -f _filedir 2>/dev/null
    run_suite fallback
) || total_fails=1

# Suite 2: with bash-completion (_filedir), if installed
bc=""
for candidate in /usr/share/bash-completion/bash_completion \
                 /usr/local/share/bash-completion/bash_completion \
                 /etc/bash_completion; do
    [[ -f "$candidate" ]] && { bc="$candidate"; break; }
done
if [[ -n "$bc" ]]; then
    (
        set +u   # bash-completion is not written for set -u
        # shellcheck source=/dev/null
        source "$bc"
        # shellcheck source=/dev/null
        source "$HERE/../completions/psm.bash"
        run_suite bash-completion
    ) || total_fails=1
else
    printf 'skip - bash-completion not installed, _filedir suite skipped\n'
fi

if (( total_fails )); then
    echo "== FAILED =="
    exit 1
fi
echo "== OK (all cases pass) =="
