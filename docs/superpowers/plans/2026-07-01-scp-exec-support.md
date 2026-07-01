# Support scp + exec — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ajouter à `psm` deux modes non-interactifs — `psm cp` (transfert scp) et `psm host "cmd"` (exec one-shot) — à travers le PSMP, en réutilisant la résolution d'hôte et la séquence d'auth `expect` existantes.

**Architecture:** Refactor de la fonction monolithique `connect()` en briques réutilisables : `resolve_target()` (résolution + fetch des credentials) et `emit_auth_preamble()` (préambule `expect` d'authentification, commun aux 3 modes). Le shell devient `run_shell()` (queue `interact`), on ajoute `run_exec()` et `run_scp()` (queue `expect eof` + propagation du code retour). Le parsing des arguments scp est isolé dans une fonction pure `parse_scp_args()`, seule partie testable unitairement.

**Tech Stack:** Bash (strict mode `set -euo pipefail`), `expect`/Tcl, scp/ssh, tests bash maison (assertions).

## Global Constraints

- **Aucune donnée interne dans le repo** : jamais d'IP, domaine, ou identifiant réels dans le code, les tests, les docs ou les messages de commit. Placeholders génériques uniquement (`srv-prod01`, `psmp.example.com`, `admin`, `vaultuser`).
- **Conventional Commits** obligatoires (hook `commit-msg`) : `type(scope): description`, types `feat|fix|docs|style|refactor|perf|test|chore|build|ci|revert`.
- **Trailer de commit** : terminer chaque message par `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Secrets via environnement uniquement** : les mots de passe transitent par `$env(VAULT_PASS)` / `$env(TARGET_PASS)`, jamais sur la ligne de commande ; `unset` systématique après `expect`.
- **Strict mode préservé** : `set -euo pipefail` reste en tête de `psm`.
- **Comportement du shell interactif inchangé** : les refactors (Tasks 1, 3, 4) sont à comportement constant, validés par non-régression manuelle.
- **Pas de push sans accord explicite de l'utilisateur** ; branche de travail : `feat/scp-exec-support`.

---

## Structure des fichiers

- **Modifier `psm`** : wrapper `main()`, extraction `resolve_target` / `emit_auth_preamble`, ajout `run_shell` / `run_exec` / `run_scp` / `parse_scp_args`, routage CLI.
- **Créer `tests/parse_scp_args.test.sh`** : tests unitaires de `parse_scp_args`.
- **Modifier `completions/psm.bash`** : complétion de `cp` + fichiers locaux.
- **Modifier `README.md`** : sections exec + transfert, table des codes de sortie, limitations.

L'unique exécutable reste `psm` (un seul fichier installable). Le guard de sourcing (Task 1) permet aux tests de charger les fonctions sans exécuter le script.

---

## Task 1: Rendre `psm` sourçable (wrapper `main()`)

**Files:**
- Modify: `psm` (bloc CLI top-level, actuellement lignes ~554-596)

**Interfaces:**
- Consumes: rien.
- Produces: fonction `main()` (encapsule getopts + validations + dispatch) ; guard de sourcing `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"`. Après cette tâche, `source ./psm` définit les fonctions sans rien exécuter.

- [ ] **Step 1: Encapsuler le bloc CLI dans `main()`**

Repérer le bloc top-level actuel qui commence à `DEBUG=0` (juste après la fonction `connect()`) et va jusqu'à `connect "$1" "$PORT"`. L'envelopper dans une fonction `main()`. Le contenu reste identique, seulement indenté d'un niveau :

```bash
# =============================================================================
# Point d'entrée
# =============================================================================
main() {
    DEBUG=0
    PORT=22
    LIST_ONLY=0

    while getopts ":dlp:v:h" opt; do
        case "$opt" in
            d) DEBUG=1 ;;
            l) LIST_ONLY=1 ;;
            p) PORT="$OPTARG" ;;
            v) VAULT_USER="$OPTARG" ;;
            h) usage; exit 0 ;;
            \?) err "Option inconnue : -$OPTARG"; usage; exit 2 ;;
            :)  err "Option -$OPTARG requiert un argument"; exit 2 ;;
        esac
    done
    shift $((OPTIND - 1))

    if [[ -n "${VAULT_PASS:-}" || -n "${TARGET_PASS:-}" ]]; then
        warn "Secrets résiduels détectés dans l'environnement (session précédente mal terminée) — purge"
        unset VAULT_PASS TARGET_PASS
    fi

    check_deps

    if (( LIST_ONLY == 1 )); then
        list_targets
        exit $?
    fi

    if (( $# != 1 )); then
        err "Argument manquant : <targetuser@targethost>"
        usage
        exit 2
    fi

    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        err "Port invalide : $PORT"
        exit 2
    fi

    connect "$1" "$PORT"
}
```

> Note : `DEBUG`/`PORT`/`LIST_ONLY` restent globaux (pas de `local`) car `connect()` et les fonctions expect lisent `DEBUG`. Le routage `cp`/exec sera ajouté en Tasks 5-6 ; pour l'instant on garde le comportement 1-argument exact.

- [ ] **Step 2: Ajouter le guard de sourcing en toute fin de fichier**

```bash
# N'exécute main que si le script est lancé directement (pas sourcé par les tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

- [ ] **Step 3: Vérifier que l'exécution directe est inchangée**

Run: `bash psm -h`
Expected: l'aide s'affiche (identique à avant), exit 0.

Run: `bash psm 2>&1; echo "rc=$?"`
Expected: `[ERR] Argument manquant` + usage, `rc=2`.

- [ ] **Step 4: Vérifier que le sourcing n'exécute rien**

Run: `source ./psm; echo "sourced ok; main is $(type -t main)"`
Expected: affiche `sourced ok; main is function` — aucune erreur d'argument, aucun appel à `connect`/`usage`.

- [ ] **Step 5: Commit**

```bash
git add psm
git commit -m "refactor: wrap CLI dispatch in main() for testability

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Fonction pure `parse_scp_args` + tests (TDD)

**Files:**
- Create: `tests/parse_scp_args.test.sh`
- Modify: `psm` (nouvelle fonction `parse_scp_args`, à placer après `list_targets`, avant `connect`)

**Interfaces:**
- Consumes: fonction `err()` (déjà définie dans `psm`).
- Produces: `parse_scp_args "$@"` — identifie l'unique remote spec parmi les arguments scp. Écrit dans des variables globales :
  - `PSA_REMOTE_HOST` : le `[user@]host` à résoudre (partie avant le premier `:`).
  - `PSA_REMOTE_PATH` : le chemin distant (après le premier `:`, `:` exclu).
  - `PSA_REMOTE_INDEX` : index (0-based) du remote spec dans `PSA_ARGV`.
  - `PSA_ARGV` : tableau de tous les arguments reçus (le consommateur remplacera `PSA_ARGV[$PSA_REMOTE_INDEX]` par `conn_str:path`).
  - Retour : `0` si exactement 1 remote spec ; `2` sinon (0 ou ≥2), avec message `err`.

- [ ] **Step 1: Écrire les tests (qui échouent)**

Créer `tests/parse_scp_args.test.sh` :

```bash
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
```

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `bash tests/parse_scp_args.test.sh`
Expected: FAIL — `parse_scp_args: command not found` ou variables vides (la fonction n'existe pas encore).

- [ ] **Step 3: Implémenter `parse_scp_args`**

Ajouter dans `psm`, après la fonction `list_targets` :

```bash
# =============================================================================
# Parsing des arguments de `psm cp` : identifie l'unique remote spec
# (règle scp standard : un ':' avant tout '/', forme [user@]host:path).
# Les flags (-x) et les chemins locaux sont ignorés pour la détection.
# =============================================================================
parse_scp_args() {
    PSA_REMOTE_HOST=""
    PSA_REMOTE_PATH=""
    PSA_REMOTE_INDEX=-1
    PSA_ARGV=("$@")
    local i arg count=0
    for i in "${!PSA_ARGV[@]}"; do
        arg="${PSA_ARGV[$i]}"
        [[ "$arg" == -* ]] && continue          # flag scp : jamais un remote spec
        if [[ "$arg" =~ ^[^/]*: ]]; then         # ':' avant tout '/'
            PSA_REMOTE_INDEX=$i
            PSA_REMOTE_HOST="${arg%%:*}"
            PSA_REMOTE_PATH="${arg#*:}"
            (( count++ )) || true
        fi
    done

    if (( count == 0 )); then
        err "psm cp : aucune cible distante (attendu 'host:/chemin')"
        return 2
    fi
    if (( count > 1 )); then
        err "psm cp : transfert distant→distant non supporté (une seule cible 'host:/chemin')"
        return 2
    fi
    return 0
}
```

> Note : `(( count++ )) || true` évite que `set -e` ne tue le script quand `count` vaut 0 (post-incrément arithmétique renvoie l'ancienne valeur, donc statut ≠ 0).

- [ ] **Step 4: Lancer les tests pour vérifier qu'ils passent**

Run: `bash tests/parse_scp_args.test.sh`
Expected: PASS — `== OK (tous les cas passent) ==`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add psm tests/parse_scp_args.test.sh
git commit -m "feat(scp): add parse_scp_args remote-spec parser with tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Extraire `resolve_target()` de `connect()`

**Files:**
- Modify: `psm` (fonction `connect`, lignes ~247-404 — partie résolution/fetch)

**Interfaces:**
- Consumes: `fetch_password`, `err`, `warn`, `info`, `debug`, globals de config (`VAULT_USER`, `PSMP_HOST`, `LDAP_USER`…).
- Produces: `resolve_target "<target>" "<port>"` (target = `[user@]host` ; `port` sert uniquement à l'affichage de la cible) — peuple les globals :
  - `R_TARGET_USER`, `R_TARGET_HOST` (résolu/IP), `R_ORIGINAL_HOST`, `R_PSMP_HOST` (après override éventuel), `R_VAULT_PASS`, `R_TARGET_PASS`, `R_CONN_STR` (`${VAULT_USER}@${R_TARGET_USER}@${R_TARGET_HOST}@${R_PSMP_HOST}`).
  - Sort en erreur (`exit 2`/`exit 3`) sur target invalide / `ssh -G` échoué / user absent / password introuvable — comportement identique à l'actuel.

- [ ] **Step 1: Créer `resolve_target()` par déplacement verbatim**

Créer une fonction `resolve_target()` juste avant `connect()`. Y **déplacer verbatim** tout le corps actuel de `connect()` depuis le parsing du target (`if [[ "$target" == *@* ]]`) jusqu'à la construction de `conn_str` incluse (l'actuelle ligne `local conn_str="${VAULT_USER}@..."`). Adapter :

- La signature : `resolve_target() { local target="$1" port="$2" ; ... }`. Le `port` ne sert qu'aux lignes `info` d'affichage de la cible (la résolution n'en dépend pas) ; conserver ces `info` avec `(via $R_PSMP_HOST:$port)`.
- Le PSMP override modifie une variable locale puis l'expose : remplacer `PSMP_HOST="$host_psmp"` par une écriture dans `R_PSMP_HOST`. Initialiser `R_PSMP_HOST="$PSMP_HOST"` en début de fonction, puis `[[ -n "$host_psmp" ]] && R_PSMP_HOST="$host_psmp"`.
- Publier les résultats dans les globals `R_*` en fin de fonction :

```bash
    # Construction de la string de connexion CyberArk (IP résolue pour le PSMP)
    R_TARGET_USER="$target_user"
    R_TARGET_HOST="$target_host"
    R_ORIGINAL_HOST="$original_host"
    R_VAULT_PASS="$vault_pass"
    R_TARGET_PASS="$target_pass"
    R_CONN_STR="${VAULT_USER}@${target_user}@${target_host}@${R_PSMP_HOST}"
    unset vault_pass target_pass
}
```

> Remplacer toute référence à `$PSMP_HOST` dans les `info()` d'affichage de cible par `$R_PSMP_HOST`.

- [ ] **Step 2: Faire appeler `resolve_target` par `connect()`**

`connect()` devient un mince wrapper qui appelle `resolve_target`, réexporte les secrets, puis garde son heredoc expect + cleanup existants. En tête de `connect()` :

```bash
connect() {
    local target="$1" port="$2"

    resolve_target "$target"

    local conn_str="$R_CONN_STR"
    local vault_pass="$R_VAULT_PASS"
    local target_pass="$R_TARGET_PASS"
    debug "Spawn: ssh -p $port $SSH_OPTS $conn_str"

    export VAULT_PASS="$vault_pass"
    export TARGET_PASS="$target_pass"
    export CONN_STR="$conn_str"
    unset vault_pass target_pass
    # ... suite inchangée (mode debug expect + heredoc + cleanup) ...
}
```

Le reste de `connect()` (à partir de `local log_init=0 exp_debug=0`) reste **identique**.

- [ ] **Step 3: Vérifier la syntaxe bash**

Run: `bash -n psm && echo "syntax ok"`
Expected: `syntax ok` (aucune erreur de parsing).

- [ ] **Step 4: Non-régression manuelle du shell (test réel)**

Run: `psm -d <un_host_de_test>` (contre le PSMP réel)
Expected: comportement identique à avant le refactor — résolution affichée, prompt target, shell interactif. Tester aussi un host `user@host` explicite et un host résolu via `~/.ssh/config`.

> Ce refactor n'a pas de test automatique (I/O ssh/keepassxc/PSMP non mockables). La validation est la non-régression manuelle du shell.

- [ ] **Step 5: Commit**

```bash
git add psm
git commit -m "refactor: extract resolve_target from connect

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Extraire `emit_auth_preamble()` + renommer `connect` → `run_shell`

**Files:**
- Modify: `psm` (fonction `connect`, partie heredoc expect)

**Interfaces:**
- Consumes: globals `DEBUG`, `EXPECT_TIMEOUT`, `VAULT_PASS_ENTRY`, et l'env `VAULT_PASS`/`TARGET_PASS`/`CONN_STR` exportés par l'appelant.
- Produces:
  - `emit_auth_preamble "<spawn_line>"` — écrit sur stdout le préambule `expect` (log_user/timeout/couleurs + ligne `spawn` + bloc d'auth vault→target avec toutes les branches d'erreur). S'arrête après l'envoi du target password.
  - `run_shell "<target>" "<port>"` — remplace `connect()` : `resolve_target` + export secrets + `emit_auth_preamble` (spawn ssh) + queue `interact` + cleanup.

- [ ] **Step 1: Créer `emit_auth_preamble()`**

Créer la fonction. Y **déplacer verbatim** le contenu du heredoc actuel de `connect()`, depuis `log_user $log_init` jusqu'à la fin du **premier** grand bloc `expect { ... }` (l'actuelle branche fermant sur `eof { ... exit 12 }`). Deux adaptations :

1. Calculer `log_init`/`exp_debug` localement depuis `DEBUG`.
2. Remplacer la ligne `spawn -noecho ssh -p $port $SSH_OPTS \$env(CONN_STR)` par `$spawn_line`.

```bash
# =============================================================================
# Préambule expect commun aux 3 modes : auth vault (optionnelle) → target.
# $1 = ligne `spawn` complète (syntaxe Tcl ; \$env(...) littéral).
# Émet le script sur stdout.
# =============================================================================
emit_auth_preamble() {
    local spawn_line="$1"
    local log_init=0 exp_debug=0
    if [[ "${DEBUG:-0}" == 1 ]]; then
        log_init=1
        exp_debug=1
    fi

    cat <<EXPECT_EOF
        log_user $log_init
        exp_internal $exp_debug
        set timeout $EXPECT_TIMEOUT

        set c_red "\033\[31m"
        set c_ylw "\033\[33m"
        set c_rst "\033\[0m"

        $spawn_line

        expect {
            -re {(?i)enter passphrase for} {
                send_user "\n\${c_red}\[ERR\]\${c_rst} Passphrase SSH demandée — clé non chargée dans l'agent\n"
                send_user "\${c_ylw}\[WARN\]\${c_rst} Charge ta clé d'abord : ssh-add\n"
                exit 14
            }
            -re {(?i)vault password\s*:\s*\$} {
                if {\$env(VAULT_PASS) eq ""} {
                    send_user "\n\${c_red}\[ERR\]\${c_rst} Vault password demandé mais aucun disponible\n"
                    send_user "\${c_ylw}\[WARN\]\${c_rst} Configure l'entrée '$VAULT_PASS_ENTRY' dans KeePassXC ou utilise une clé SSH\n"
                    exit 10
                }
                log_user 1
                send -- "\$env(VAULT_PASS)\r"

                expect {
                    -re {(?i)vault password\s*:\s*\$} {
                        send_user "\n\${c_red}\[ERR\]\${c_rst} Authentification vault échouée (mauvais VaultPassword)\n"
                        exit 20
                    }
                    -re {(?i)(otp|one-time password|mfa code)\s*:\s*\$} {
                        send_user "\n\${c_red}\[ERR\]\${c_rst} MFA détecté — non supporté par ce script\n"
                        exit 21
                    }
                    -re {(?i)permission denied} {
                        send_user "\n\${c_red}\[ERR\]\${c_rst} Permission refusée après vault password\n"
                        exit 22
                    }
                    -re {(?i)password\s*:\s*\$} {
                        send -- "\$env(TARGET_PASS)\r"
                    }
                    timeout {
                        send_user "\n\${c_red}\[ERR\]\${c_rst} Timeout en attendant le prompt target\n"
                        exit 23
                    }
                    eof {
                        send_user "\n\${c_red}\[ERR\]\${c_rst} Connexion fermée avant prompt target\n"
                        exit 24
                    }
                }
            }
            -re {(?i)password\s*:\s*\$} {
                log_user 1
                send -- "\$env(TARGET_PASS)\r"
            }
            -re {(?i)permission denied} {
                send_user "\n\${c_red}\[ERR\]\${c_rst} Permission refusée (clé SSH rejetée ?)\n"
                exit 13
            }
            timeout {
                send_user "\n\${c_red}\[ERR\]\${c_rst} Timeout en attendant un prompt d'authentification\n"
                exit 11
            }
            eof {
                send_user "\n\${c_red}\[ERR\]\${c_rst} Connexion fermée avant authentification\n"
                exit 12
            }
        }
EXPECT_EOF
}
```

- [ ] **Step 2: Renommer `connect` → `run_shell` et l'appuyer sur le préambule**

Renommer `connect()` en `run_shell()`. Son corps compose le préambule (spawn ssh) + la queue shell existante (bloc « étape 3 » + `interact`) :

```bash
run_shell() {
    local target="$1" port="$2"

    resolve_target "$target" "$port"
    export VAULT_PASS="$R_VAULT_PASS"
    export TARGET_PASS="$R_TARGET_PASS"
    export CONN_STR="$R_CONN_STR"
    debug "Spawn: ssh -p $port $SSH_OPTS $R_CONN_STR"

    if [[ "${DEBUG:-0}" == 1 ]]; then
        warn "Mode debug : les mots de passe seront visibles dans la sortie expect"
    fi

    local rc=0 expect_script
    expect_script=$(mktemp /tmp/psm-expect.XXXXXX)
    local spawn_line="spawn -noecho ssh -p $port $SSH_OPTS \$env(CONN_STR)"

    {
        emit_auth_preamble "$spawn_line"
        cat <<EXPECT_EOF

        set timeout 3
        expect {
            -re {(?i)permission denied} {
                send_user "\n\${c_red}\[ERR\]\${c_rst} Authentification target échouée\n"
                exit 30
            }
            -re {(?i)password\s*:\s*\$} {
                send_user "\n\${c_red}\[ERR\]\${c_rst} Re-prompt target → mauvais TARGET_PASS\n"
                exit 31
            }
            eof {
                send_user "\n\${c_red}\[ERR\]\${c_rst} Connexion fermée après auth target\n"
                exit 32
            }
            timeout {}
            -re {.+} {}
        }

        set timeout -1
        interact -o -re {\[sudo\] [Pp]assword[^:]*:} {
            send -- "\$env(TARGET_PASS)\r"
        }
EXPECT_EOF
    } > "$expect_script"

    expect -f "$expect_script" || rc=$?
    rm -f "$expect_script"
    unset VAULT_PASS TARGET_PASS CONN_STR
    return $rc
}
```

- [ ] **Step 3: Mettre à jour l'appel dans `main()`**

Dans `main()`, remplacer `connect "$1" "$PORT"` par `run_shell "$1" "$PORT"`.

- [ ] **Step 4: Vérifier la syntaxe + le script expect généré**

Run: `bash -n psm && echo "syntax ok"`
Expected: `syntax ok`.

Run (inspection du script généré, sans exécuter expect) :
```bash
source ./psm
DEBUG=0 EXPECT_TIMEOUT=30 VAULT_PASS_ENTRY=VaultPassword \
  bash -c 'source ./psm; emit_auth_preamble "spawn -noecho ssh \$env(CONN_STR)"' | head -20
```
Expected: le préambule Tcl s'affiche, avec la ligne `spawn -noecho ssh $env(CONN_STR)` correctement insérée et `$env(...)` littéral (non expansé par bash).

- [ ] **Step 5: Non-régression manuelle du shell (test réel)**

Run: `psm <host_de_test>` puis `psm -d <host_de_test>` (contre le PSMP)
Expected: shell interactif fonctionnel, auto-sudo opérationnel, comportement identique à avant. Vérifier qu'un `sudo` dans la session distante déclenche bien l'envoi automatique du target password.

- [ ] **Step 6: Commit**

```bash
git add psm
git commit -m "refactor(expect): extract emit_auth_preamble, rename connect to run_shell

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `run_exec` — exécution de commande one-shot

**Files:**
- Modify: `psm` (nouvelle fonction `run_exec` + routage dans `main`)

**Interfaces:**
- Consumes: `resolve_target`, `emit_auth_preamble`, globals `DEBUG`, `SSH_OPTS`.
- Produces: `run_exec "<target>" "<port>" "<remote_cmd>"` — exécute `remote_cmd` sur la cible via ssh non-interactif, propage le code retour de ssh. Routage : `psm [user@]host "cmd…"` (≥ 2 args positionnels).

- [ ] **Step 1: Implémenter `run_exec`**

Ajouter après `run_shell` :

```bash
# =============================================================================
# Exécution non-interactive d'une commande distante (façon `ssh host "cmd"`).
# La commande passe par $env(REMOTE_CMD) : un seul mot Tcl, transmis tel quel
# au shell distant, sans substitution/backslash Tcl.
# =============================================================================
run_exec() {
    local target="$1" port="$2" remote_cmd="$3"

    resolve_target "$target" "$port"
    export VAULT_PASS="$R_VAULT_PASS"
    export TARGET_PASS="$R_TARGET_PASS"
    export CONN_STR="$R_CONN_STR"
    export REMOTE_CMD="$remote_cmd"
    debug "Spawn: ssh -p $port $SSH_OPTS $R_CONN_STR <cmd>"
    info "Exécution : $remote_cmd"

    if [[ "${DEBUG:-0}" == 1 ]]; then
        warn "Mode debug : les mots de passe seront visibles dans la sortie expect"
    fi

    local rc=0 expect_script
    expect_script=$(mktemp /tmp/psm-expect.XXXXXX)
    local spawn_line="spawn -noecho ssh -p $port $SSH_OPTS \$env(CONN_STR) \$env(REMOTE_CMD)"

    {
        emit_auth_preamble "$spawn_line"
        cat <<'EXPECT_EOF'

        # Non-interactif : laisse la commande produire sa sortie puis propage son code.
        log_user 1
        set timeout -1
        expect eof
        catch wait result
        exit [lindex $result 3]
EXPECT_EOF
    } > "$expect_script"

    expect -f "$expect_script" || rc=$?
    rm -f "$expect_script"
    unset VAULT_PASS TARGET_PASS CONN_STR REMOTE_CMD
    return $rc
}
```

> La queue utilise un heredoc **quoté** (`<<'EXPECT_EOF'`) car elle ne contient que du Tcl littéral (`$result`, `[lindex ...]`) — aucune expansion bash souhaitée.

- [ ] **Step 2: Ajouter le routage exec dans `main()`**

Dans `main()`, remplacer le bloc « exactement 1 argument » par un routage. La commande distante est jointe façon ssh (`"$*"`) :

```bash
    if (( $# < 1 )); then
        err "Argument manquant : <targetuser@targethost> [commande]"
        usage
        exit 2
    fi

    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        err "Port invalide : $PORT"
        exit 2
    fi

    local target="$1"; shift
    if (( $# > 0 )); then
        run_exec "$target" "$PORT" "$*"       # psm host "cmd..."
    else
        run_shell "$target" "$PORT"           # psm host  (shell interactif)
    fi
```

> Le routage `cp` sera inséré en tête en Task 6.

- [ ] **Step 3: Vérifier la syntaxe**

Run: `bash -n psm && echo "syntax ok"`
Expected: `syntax ok`.

- [ ] **Step 4: Test réel contre le PSMP**

Run: `psm <host_de_test> "ls -la /tmp"`
Expected: la sortie de `ls` s'affiche (précédée du banner PSMP — attendu), puis rendu de la main.

Run: `psm <host_de_test> "exit 7"; echo "rc=$?"`
Expected: `rc=7` — le code retour de la commande distante est propagé.

Run: `psm <host_de_test> false; echo "rc=$?"`
Expected: `rc=1` (arguments non quotés joints façon ssh).

- [ ] **Step 5: Commit**

```bash
git add psm
git commit -m "feat(exec): support one-shot command execution via psm host \"cmd\"

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `run_scp` — transfert de fichiers via `psm cp`

**Files:**
- Modify: `psm` (nouvelle fonction `run_scp` + routage `cp` dans `main`)

**Interfaces:**
- Consumes: `parse_scp_args`, `resolve_target`, `emit_auth_preamble`, globals `DEBUG`, `SSH_OPTS`.
- Produces: `run_scp "$@"` (args = tout ce qui suit `cp`) — résout la cible, réécrit le remote spec, lance scp piloté par expect, propage le code retour de scp. Routage : `psm cp [flags] SRC… DST`.

- [ ] **Step 1: Implémenter `run_scp`**

Ajouter après `run_exec`. Le `port` provient du global `PORT` (option `psm -p`), traduit en `-P` scp. Les arguments réécrits sont passés à expect en éléments distincts via `-- "${PSA_ARGV[@]}"` :

```bash
# =============================================================================
# Transfert de fichiers via scp à travers le PSMP.
# Args = arguments bruts après `cp` (flags scp + chemins + un remote spec).
# =============================================================================
run_scp() {
    parse_scp_args "$@" || exit $?

    resolve_target "$PSA_REMOTE_HOST" "$PORT"
    # Réécrit l'unique remote spec avec la conn_str CyberArk (IP résolue).
    PSA_ARGV[$PSA_REMOTE_INDEX]="${R_CONN_STR}:${PSA_REMOTE_PATH}"

    export VAULT_PASS="$R_VAULT_PASS"
    export TARGET_PASS="$R_TARGET_PASS"
    debug "Spawn: scp -P $PORT $SSH_OPTS ${PSA_ARGV[*]}"
    info "Transfert scp via $R_PSMP_HOST"

    if [[ "${DEBUG:-0}" == 1 ]]; then
        warn "Mode debug : les mots de passe seront visibles dans la sortie expect"
    fi

    local rc=0 expect_script
    expect_script=$(mktemp /tmp/psm-expect.XXXXXX)
    # {*}$argv : expansion Tcl des arguments scp (passés via -- ci-dessous).
    local spawn_line="spawn -noecho scp -P $PORT $SSH_OPTS {*}\$argv"

    {
        emit_auth_preamble "$spawn_line"
        cat <<'EXPECT_EOF'

        # Non-interactif : affiche la progression scp puis propage son code retour.
        log_user 1
        set timeout -1
        expect eof
        catch wait result
        exit [lindex $result 3]
EXPECT_EOF
    } > "$expect_script"

    expect -f "$expect_script" -- "${PSA_ARGV[@]}" || rc=$?
    rm -f "$expect_script"
    unset VAULT_PASS TARGET_PASS
    return $rc
}
```

> Les secrets ne passent **jamais** par `$argv` (uniquement `$env(...)`). Le `conn_str` dans `$argv` (visible dans `ps`) ne contient aucun mot de passe. `resolve_target` gère seule l'affichage de la cible résolue.

- [ ] **Step 2: Ajouter le routage `cp` en tête du dispatch de `main()`**

Dans `main()`, juste après la validation du port et avant le `local target="$1"`, intercaler :

```bash
    if [[ "$1" == "cp" ]]; then
        shift
        if (( $# < 2 )); then
            err "Usage : psm cp [flags] SRC... DST"
            exit 2
        fi
        run_scp "$@"
        exit $?
    fi
```

- [ ] **Step 3: Vérifier la syntaxe**

Run: `bash -n psm && echo "syntax ok"`
Expected: `syntax ok`.

- [ ] **Step 4: Tests réels contre le PSMP**

Run (pull): `psm cp <host_de_test>:/etc/hosts /tmp/hosts.pulled && cat /tmp/hosts.pulled`
Expected: fichier récupéré, contenu affiché, rc=0.

Run (push): `echo test > /tmp/psm-push.txt && psm cp /tmp/psm-push.txt <host_de_test>:/tmp/ && echo "rc=$?"`
Expected: `rc=0`, fichier présent côté distant.

Run (récursif): `mkdir -p /tmp/psm-dir && touch /tmp/psm-dir/a /tmp/psm-dir/b && psm cp -r /tmp/psm-dir <host_de_test>:/tmp/`
Expected: dossier transféré, rc=0.

Run (erreur parsing): `psm cp ./a ./b; echo "rc=$?"`
Expected: `[ERR] psm cp : aucune cible distante`, `rc=2`.

- [ ] **Step 5: Commit**

```bash
git add psm
git commit -m "feat(scp): support file transfer via psm cp

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Documentation, aide et complétion

**Files:**
- Modify: `psm` (fonction `usage`)
- Modify: `README.md`
- Modify: `completions/psm.bash`

**Interfaces:**
- Consumes: rien.
- Produces: aide, README et complétion à jour. Pas de test automatique — vérification visuelle.

- [ ] **Step 1: Mettre à jour `usage()`**

Dans la fonction `usage()`, ajouter sous les exemples existants :

```bash
  psm srv-prod01 "systemctl status nginx"   # exécute une commande (non-interactif)
  psm cp ./deploy.sh srv-prod01:/tmp/        # pousse un fichier (scp)
  psm cp srv-prod01:/etc/hosts .             # récupère un fichier
  psm cp -r ./dist srv-prod01:/var/www/      # transfert récursif
```

Et une ligne dans le bloc d'usage en tête :

```
Usage: psm [options] <targetuser@targethost|targethost> [commande]
       psm [options] cp [flags-scp] SRC... DST
```

- [ ] **Step 2: Documenter dans `README.md`**

Après la section « Usage », ajouter deux sections :

````markdown
## Exécuter une commande (non-interactif)

Comme `ssh host "cmd"`, un 2ᵉ argument est exécuté sur la cible sans ouvrir de
shell interactif ; le code retour de la commande est propagé.

```bash
psm srv-prod01 "systemctl status nginx"
psm admin@srv-prod01 ls -la /data
```

> Le proxy PSMP injecte un banner (« session is being recorded » + banner légal)
> **avant** la sortie de la commande, même en non-interactif. C'est un réglage
> serveur CyberArk, non désactivable côté client — en tenir compte lors d'un pipe.

## Transfert de fichiers (`psm cp`)

Transfert via `scp` à travers le PSMP. Push et pull, récursif, multi-fichiers.
Les flags scp sont transmis tels quels.

```bash
psm cp ./deploy.sh srv-prod01:/tmp/        # push
psm cp ./deploy.sh admin@srv-prod01:/tmp/  # push, user explicite
psm cp srv-prod01:/etc/hosts .             # pull
psm cp -r ./dist srv-prod01:/var/www/      # récursif
psm cp a.conf b.conf srv-prod01:/etc/      # multi-fichiers
```

Le port du PSMP se règle via `psm -p PORT cp …` (traduit en `-P` pour scp).
Le code retour de scp est propagé.
````

Mettre à jour la table **Codes de sortie** en ajoutant une ligne :

```
| (scp/cmd) | Code retour réel de scp/ssh propagé (0 = ok)  |
```

Ajouter dans **Limitations connues** :

```
- **exec — banner PSMP** : la sortie de `psm host "cmd"` est précédée du banner
  légal / notification d'enregistrement injecté par le PSMP (non désactivable
  côté client).
- **`psm cp` — détection cible** : un flag scp à valeur contenant `:` avant un
  `/` (ex. `-o Foo=a:b`, rare) peut être confondu avec une cible distante ;
  utiliser `scp` directement dans ce cas.
- **`psm cp`** ne gère pas le transfert distant→distant (une seule cible PSMP).
```

- [ ] **Step 3: Mettre à jour la complétion bash**

Dans `completions/psm.bash`, compléter le mot-clé `cp` et, après `cp`, proposer hostnames + fichiers locaux. Remplacer la fin de `_psm_complete` :

```bash
    # Sous-commande cp : compléter fichiers locaux + hostnames
    if [[ "${COMP_WORDS[1]}" == "cp" && "$COMP_CWORD" -ge 2 ]]; then
        local hosts_cp
        hosts_cp=$(awk '/^[Hh]ost / && !/[*?]/ {for(i=2;i<=NF;i++) print $i}' \
                   ~/.ssh/config 2>/dev/null)
        if [[ "$cur" == *@* ]]; then
            local prefix="${cur%@*}@" partial="${cur#*@}"
            COMPREPLY=( $(compgen -P "$prefix" -W "$hosts_cp" -- "$partial") )
        else
            COMPREPLY=( $(compgen -f -W "$hosts_cp" -- "$cur") )
        fi
        return
    fi

    # Hostnames depuis ~/.ssh/config (exclut les wildcards * ?)
    local hosts
    hosts=$(awk '/^[Hh]ost / && !/[*?]/ {for(i=2;i<=NF;i++) print $i}' \
            ~/.ssh/config 2>/dev/null)

    if [[ "$cur" == *@* ]]; then
        local prefix="${cur%@*}@"
        local partial="${cur#*@}"
        COMPREPLY=( $(compgen -P "$prefix" -W "$hosts" -- "$partial") )
    else
        COMPREPLY=( $(compgen -W "cp $hosts" -- "$cur") )
    fi
}
```

> `compgen -W "cp $hosts"` ajoute `cp` à la liste de premier niveau.

- [ ] **Step 4: Vérifier l'aide et la syntaxe**

Run: `bash psm -h`
Expected: l'aide montre les nouvelles lignes `cp` et commande.

Run: `bash -n completions/psm.bash && echo "completion ok"`
Expected: `completion ok`.

- [ ] **Step 5: Relancer les tests unitaires (non-régression)**

Run: `bash tests/parse_scp_args.test.sh`
Expected: `== OK (tous les cas passent) ==`.

- [ ] **Step 6: Commit**

```bash
git add psm README.md completions/psm.bash
git commit -m "docs(scp): document cp and exec modes, extend bash completion

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (auteur du plan)

**Couverture de la spec :**
- Routage CLI (cp/exec/shell) → Tasks 5-6 (dispatch dans `main`). ✓
- `resolve_target` → Task 3. ✓
- `emit_auth_preamble` + queues → Task 4 (shell), 5 (exec), 6 (scp). ✓
- Parsing scp (`^[^/]*:`, 0/≥2 → erreur, réécriture) → Task 2 + Task 6. ✓
- exec via `$env(REMOTE_CMD)`, code retour propagé → Task 5. ✓
- scp argv distincts, `-P` port, passthrough flags → Task 6. ✓
- Sécurité (secrets via env, unset) → préservée Tasks 4-6. ✓
- Codes de sortie (auth réutilisés + code scp/ssh propagé) → Tasks 4-6, doc Task 7. ✓
- Tests `parse_scp_args` → Task 2. ✓
- Doc + complétion + limitations (banner, flag-`:`, distant→distant) → Task 7. ✓

**Cohérence des noms :** `resolve_target`, `emit_auth_preamble`, `run_shell`, `run_exec`, `run_scp`, `parse_scp_args`, globals `R_*` et `PSA_*` — utilisés de façon cohérente entre les tâches productrices et consommatrices.

**Placeholders :** aucun « TBD/TODO » ; code complet fourni pour toute fonction nouvelle ; extractions verbatim référencées par plage de lignes.
