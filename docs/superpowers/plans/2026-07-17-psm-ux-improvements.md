# Améliorations UX psm (auto-sudo + complétion cp) — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rendre l'auto-sudo désactivable (`AUTO_SUDO` + `-S`) et faire descendre la complétion `psm cp` dans les dossiers locaux.

**Architecture:** Deux changements indépendants — un dans `psm` (`run_shell` + config + getopts), un dans `completions/psm.bash`. Exécution inline.

**Tech Stack:** Bash, expect/Tcl, bash-completion (`_filedir`).

## Global Constraints

- Conventional Commits (hook `commit-msg`) ; terminer chaque message par `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- `set -euo pipefail` conservé.
- Aucune donnée interne (IP/domaine/ID) — placeholders génériques.
- Comportement par défaut inchangé : `AUTO_SUDO=1` (auto-sudo actif) tant que ni config ni `-S` ne l'éteignent.
- Travail directement sur `main` (préférence repo). Ne pas pousser sans accord.

---

## Task 1 : toggle auto-sudo (`AUTO_SUDO` + `-S`)

**Files:**
- Modify: `psm` (bloc CONFIG ; `run_shell` ; `usage()` ; getopts de `main()`)
- Modify: `config.example`
- Modify: `README.md`

**Interfaces:**
- Consumes: `resolve_target`, `emit_auth_preamble`, `info`, globals `DEBUG`.
- Produces: global `AUTO_SUDO` (0/1) ; flag `-S`. `run_shell` génère un `interact` avec ou sans hook sudo selon `AUTO_SUDO`.

- [ ] **Step 1 : ajouter le défaut config `AUTO_SUDO`**

Dans le bloc CONFIG (après la ligne `EXPECT_TIMEOUT="${EXPECT_TIMEOUT:-30}"`), ajouter :

```bash
AUTO_SUDO="${AUTO_SUDO:-1}"   # 1 = auto-remplit les prompts [sudo] avec TARGET_PASS ; 0 = sudo manuel
```

- [ ] **Step 2 : `run_shell` — message de mode + `interact` conditionnel**

Dans `run_shell`, juste après le bloc `if [[ "${DEBUG:-0}" == 1 ]]; then warn "Mode debug…"; fi`, ajouter le feedback de mode :

```bash
    if [[ "${AUTO_SUDO:-1}" == 1 ]]; then
        info "Auto-sudo actif (le mot de passe target répond aux prompts [sudo])"
    else
        info "Auto-sudo désactivé — sudo manuel"
    fi
```

Puis, dans le groupe `{ … } > "$expect_script"`, remplacer le heredoc unique de la queue par : un heredoc commun (bloc de vérif + `set timeout -1`) suivi d'un `interact` conditionnel. Le résultat doit être :

```bash
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
EXPECT_EOF
        if [[ "${AUTO_SUDO:-1}" == 1 ]]; then
            cat <<EXPECT_EOF
        interact -o -re {\[sudo\] [Pp]assword[^:]*:} {
            send -- "\$env(TARGET_PASS)\r"
        }
EXPECT_EOF
        else
            printf '        interact\n'
        fi
    } > "$expect_script"
```

> Escaping (heredoc NON quoté) : `\[sudo\]` → `\[sudo\]` (crochet littéral Tcl), `\$env(TARGET_PASS)` → `$env(TARGET_PASS)` (substituable Tcl), `\${c_red}` → `${c_red}`. La branche `AUTO_SUDO=0` émet un `interact` nu (aucun secret envoyé).

- [ ] **Step 3 : getopts — flag `-S`**

Dans `main()`, changer `while getopts ":dlp:v:h" opt; do` en `while getopts ":dlp:v:hS" opt; do`, et ajouter dans le `case` (après `d) DEBUG=1 ;;`) :

```bash
        S) AUTO_SUDO=0 ;;
```

- [ ] **Step 4 : `usage()`**

Dans `usage()`, ajouter sous la ligne `-d` :

```
  -S          Désactive l'auto-sudo pour cette session (sudo manuel)
```

Et dans le bloc « Configuration courante », ajouter une ligne :

```
  AUTO_SUDO          = ${AUTO_SUDO:-1}
```

Et `AUTO_SUDO` à la liste des variables d'environnement supportées.

- [ ] **Step 5 : `config.example`**

Ajouter (section SSH/expect) :

```bash
# Auto-sudo : 1 = répond automatiquement aux prompts [sudo] avec le target
# password (pratique sur la cible directe). 0 = sudo manuel (recommandé si tu
# rebondis vers d'autres serveurs — évite d'envoyer le mauvais mot de passe).
# AUTO_SUDO="1"
```

- [ ] **Step 6 : `README.md`**

Remplacer la puce auto-sudo existante de la section « Sécurité » (« **Auto-sudo** : le target password est envoyé automatiquement… ») par :

```markdown
- **Auto-sudo** (défaut activé) : le target password répond automatiquement aux
  prompts `[sudo] password for …:` pendant la session. **Attention au rebond** :
  si tu fais `ssh` vers un autre serveur depuis la cible, ce mécanisme enverrait
  le mot de passe de la cible au prompt sudo du serveur rebondi (mauvais mot de
  passe, et fuite d'un secret). Désactive-le alors :
  - `psm -S host` pour la session, ou `AUTO_SUDO=0` en config par défaut ;
  - à la volée dans une session déjà ouverte : `export SUDO_PROMPT='pw: '`
    (change le prompt sudo pour qu'il échappe au mécanisme) puis `sudo -s`.
```

Ajouter `AUTO_SUDO` à la table des variables de configuration, et `-S` à la liste des options d'usage.

- [ ] **Step 7 : vérifs**

Run: `bash -n psm && echo "syntax ok"`
Expected: `syntax ok`.

Run (le flag est bien parsé) : `bash psm -S -h >/dev/null 2>&1; echo "rc=$?"`
Expected: `rc=0` (l'aide sort, `-S` accepté sans erreur d'option).

> Le comportement runtime (hook présent/absent selon `AUTO_SUDO`) est validé manuellement contre le PSMP : `psm host` (auto-sudo) puis `psm -S host` (sudo manuel), et un rebond avec `-S`.

- [ ] **Step 8 : commit**

```bash
git add psm config.example README.md
git commit -m "feat(sudo): make auto-sudo toggleable via AUTO_SUDO and -S

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2 : complétion `psm cp` des chemins locaux

**Files:**
- Modify: `completions/psm.bash` (branche `cp`)

**Interfaces:**
- Consumes: rien.
- Produces: complétion des chemins locaux profonds pour `psm cp`.

- [ ] **Step 1 : remplacer la branche `else` de la complétion `cp`**

Dans `completions/psm.bash`, la branche `cp` fait actuellement, dans son `else` (cas non `user@host`) : `COMPREPLY=( $(compgen -f -W "$hosts_cp" -- "$cur") )`. Remplacer cet `else` par :

```bash
        else
            # Chemins locaux (descente dans les sous-dossiers) + hostnames connus.
            if declare -F _filedir >/dev/null 2>&1; then
                _filedir
            else
                compopt -o filenames 2>/dev/null
                COMPREPLY=( $(compgen -f -- "$cur") )
            fi
            COMPREPLY+=( $(compgen -W "$hosts_cp" -- "$cur") )
        fi
```

> `_filedir` (bash-completion) gère la descente dans les dossiers, les espaces et l'affichage des basenames. Fallback `compgen -f` + `compopt -o filenames` si absente. `_filedir` lit `$cur` par portée dynamique bash (déjà `local` dans `_psm_complete`). Les hostnames restent proposés pour la destination `host:`.

- [ ] **Step 2 : vérifs**

Run: `bash -n completions/psm.bash && echo "syntax ok"`
Expected: `syntax ok`.

Run (chargement + structure, fallback si `_filedir` absente) :
```bash
bash -c '
  source completions/psm.bash
  mkdir -p /tmp/psm-comp/work/truc && : > /tmp/psm-comp/work/truc/test.sh
  cd /tmp/psm-comp
  COMP_WORDS=(psm cp ./work/); COMP_CWORD=2
  _psm_complete
  printf "%s\n" "${COMPREPLY[@]}"
'
```
Expected: la complétion propose une entrée descendant dans `./work/` (ex. `./work/truc` ou `./work/truc/`), preuve que la descente locale fonctionne (via `_filedir` ou le fallback).

> Le confort interactif complet (TAB successifs) se valide manuellement dans un shell avec la complétion sourcée.

- [ ] **Step 3 : commit**

```bash
git add completions/psm.bash
git commit -m "feat(completion): complete local paths for psm cp

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (auteur du plan)

- **Couverture spec :** Volet A → Task 1 (config, `-S`, `run_shell` conditionnel, feedback, doc). Volet B → Task 2 (`_filedir` + fallback + hosts). ✓
- **Placeholders :** aucun ; code complet fourni pour chaque step. ✓
- **Cohérence :** `AUTO_SUDO` (global, défaut 1) lu identiquement dans CONFIG / `main` / `run_shell` ; escaping du heredoc conditionnel explicité. ✓
