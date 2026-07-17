# Design — améliorations UX psm : toggle auto-sudo + complétion cp locale

**Date :** 2026-07-17
**Statut :** validé (design)

Deux améliorations indépendantes, regroupées dans un même lot :

- **A.** contrôle de l'auto-sudo (`AUTO_SUDO` + flag `-S`)
- **B.** complétion `psm cp` des chemins locaux profonds

---

## Volet A — contrôle de l'auto-sudo

### Problème
En shell interactif, `run_shell` arme un hook `interact` qui répond
automatiquement à tout prompt `[sudo] password for …:` avec le `TARGET_PASS` de
la cible. Lors d'un **rebond** (ssh depuis la cible vers un autre serveur), ce
hook injecte le mot de passe du **premier** serveur dans le prompt sudo du
serveur rebondi — mauvais mot de passe, et **fuite** d'un secret vers une
machine à qui il n'appartient pas.

### Design
- **Config** : variable `AUTO_SUDO`, défaut `1` (comportement actuel conservé).
  `AUTO_SUDO="${AUTO_SUDO:-1}"` dans le bloc CONFIG ; sourçable via
  `~/.config/psm/config`.
- **Flag** : `-S` désactive l'auto-sudo pour la session (`AUTO_SUDO=0`), override
  la config. getopts `:dlp:v:h` → `:dlp:v:hS` ; case `S) AUTO_SUDO=0 ;;`. Accepté
  globalement, sans effet sur `cp`/exec (pas d'`interact`), sans erreur. Pas de
  flag de forçage ON (YAGNI) : pour un défaut OFF permanent, `AUTO_SUDO=0` en
  config.
- **`run_shell`** : hook sudo conditionnel —
  `AUTO_SUDO=1` → `interact -o -re {\[sudo\] [Pp]assword[^:]*:} { send -- "$env(TARGET_PASS)\r" }` (actuel) ;
  `AUTO_SUDO=0` → `interact` nu.
  Escaping : dans le fichier expect généré, le bloc auto-sudo doit contenir
  `$env(TARGET_PASS)` (substituable par Tcl) et `\[sudo\]` (crochet littéral).
- **Feedback** : au lancement du shell, un `info` indique le mode
  (`auto-sudo actif` / `auto-sudo désactivé — sudo manuel`).

### Workaround immédiat (déjà utilisable, sans modif)
Couper l'auto-sudo à la volée dans une session ouverte, en changeant le prompt
sudo pour qu'il n'égale plus le hook :
```bash
export SUDO_PROMPT='pw: '   # tous les sudo suivants de la session
sudo -s                     # affiche "pw: ", psm n'intercepte pas
# ponctuel : sudo -p 'pw: ' -s
```

---

## Volet B — complétion `psm cp` des chemins locaux

### Problème
La complétion `cp` actuelle fait `compgen -f -W "$hosts" -- "$cur"` **sans**
`compopt -o filenames`, donc elle ne descend pas dans les sous-dossiers et
affiche mal les chemins (ex. `psm cp ./work/truc/test.sh` ne se complète pas).

### Design (`completions/psm.bash`, branche `cp`)
- `cur` contient `@` → complète les hostnames (`user@host`), inchangé.
- sinon → complète les **chemins locaux** via `_filedir` (fonction standard de
  bash-completion : descend dans les sous-dossiers, gère dossiers/espaces/
  affichage). Fallback si `_filedir` absent : `compopt -o filenames` +
  `compgen -f -- "$cur"`. Les **hostnames** connus restent proposés en
  complément (destination `host:`).

Résultat : `psm cp ./work/tr<TAB>` descend dans `./work/truc/…` ; `psm cp fichier srv<TAB>` propose toujours les hosts.

---

## Périmètre / tests
- Volet A n'affecte que `run_shell` ; volet B que `completions/psm.bash`.
- Vérifications : `bash -n psm` et `bash -n completions/psm.bash` ; génération du
  script expect dans les deux modes (hook présent quand `AUTO_SUDO=1`, `interact`
  nu quand `0`) ; `bash tests/parse_scp_args.test.sh` (non-régression) ;
  validation manuelle (rebond + complétion `cp ./…`) contre le poste réel.
- Docs : `usage()` (`-S`), `README.md` (section auto-sudo + note complétion),
  `config.example` (`AUTO_SUDO`).

## Exécution
Inline (petite taille) — pas de fleet de subagents.
