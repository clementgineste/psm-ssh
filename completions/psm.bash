# Bash completion for psm
# Completes flags, hostnames from ~/.ssh/config, and local paths for `psm cp`
#
# Installation:
#   source ~/psm-ssh/completions/psm.bash        (in ~/.bashrc)
#   OR
#   sudo cp completions/psm.bash /etc/bash_completion.d/psm

_psm_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"

    # -p and -v take a value (port, vault user) → no completion
    if [[ "$prev" == -*[pv] ]]; then
        return
    fi

    # Flags
    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-d -S -l -p -v -h" -- "$cur") )
        return
    fi

    # Index of the first non-flag argument (skips flags and the value of
    # -p/-v, grouped ones included: -dp 2222) → detects `cp` after flags.
    local i cmd_idx=0
    for (( i = 1; i < COMP_CWORD; i++ )); do
        case "${COMP_WORDS[i]}" in
            -*[pv]) (( i++ )) ;;
            -*)     ;;
            *)      cmd_idx=$i; break ;;
        esac
    done

    # doctor and setup take no argument
    if (( cmd_idx > 0 )) && [[ "${COMP_WORDS[cmd_idx]}" == @(doctor|setup) ]]; then
        return
    fi

    # cp subcommand: complete local paths + hostnames
    if (( cmd_idx > 0 )) && [[ "${COMP_WORDS[cmd_idx]}" == "cp" ]]; then
        local hosts_cp
        hosts_cp=$(awk '/^[Hh]ost / && !/[*?]/ {for(i=2;i<=NF;i++) print $i}' \
                   ~/.ssh/config 2>/dev/null)
        if [[ "$cur" == *@* ]]; then
            local prefix="${cur%@*}@" partial="${cur#*@}"
            COMPREPLY=( $(compgen -P "$prefix" -W "$hosts_cp" -- "$partial") )
        else
            # Local paths (descends into subdirectories) + known hostnames.
            if declare -F _filedir >/dev/null 2>&1; then
                _filedir
            else
                compopt -o filenames 2>/dev/null
                mapfile -t COMPREPLY < <(compgen -f -- "$cur")
            fi
            COMPREPLY+=( $(compgen -W "$hosts_cp" -- "$cur") )
        fi
        return
    fi

    # Hostnames from ~/.ssh/config (wildcards * ? excluded)
    local hosts
    hosts=$(awk '/^[Hh]ost / && !/[*?]/ {for(i=2;i<=NF;i++) print $i}' \
            ~/.ssh/config 2>/dev/null)

    if [[ "$cur" == *@* ]]; then
        local prefix="${cur%@*}@"
        local partial="${cur#*@}"
        COMPREPLY=( $(compgen -P "$prefix" -W "$hosts" -- "$partial") )
    else
        COMPREPLY=( $(compgen -W "cp doctor setup $hosts" -- "$cur") )
    fi
}
complete -F _psm_complete psm
