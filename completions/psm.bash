# Autocomplétion bash pour psm
# Complète les flags et les hostnames depuis ~/.ssh/config
#
# Installation :
#   source ~/psm-ssh/completions/psm.bash        (dans ~/.bashrc)
#   OU
#   sudo cp completions/psm.bash /etc/bash_completion.d/psm

_psm_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Flag -p attend un argument (port) → pas de complétion
    if [[ "$prev" == "-p" || "$prev" == "-v" ]]; then
        return
    fi

    # Flags
    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-d -l -p -v -h" -- "$cur") )
        return
    fi

    # Hostnames depuis ~/.ssh/config (exclut les wildcards * ?)
    local hosts
    hosts=$(awk '/^[Hh]ost / && !/[*?]/ {for(i=2;i<=NF;i++) print $i}' \
            ~/.ssh/config 2>/dev/null)

    # Si l'user a tapé user@<tab>, complète juste la partie host
    if [[ "$cur" == *@* ]]; then
        local prefix="${cur%@*}@"
        local partial="${cur#*@}"
        COMPREPLY=( $(compgen -P "$prefix" -W "$hosts" -- "$partial") )
    else
        COMPREPLY=( $(compgen -W "$hosts" -- "$cur") )
    fi
}
complete -F _psm_complete psm
