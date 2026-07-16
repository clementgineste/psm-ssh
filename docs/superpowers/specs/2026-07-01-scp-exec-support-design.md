# Design — Transfert de fichiers (`psm cp`) et exécution de commande (`psm host "cmd"`)

**Date :** 2026-07-01
**Statut :** validé (design) — prêt pour plan d'implémentation

## Contexte et problème

`psm` ne sait aujourd'hui qu'ouvrir un **shell interactif** à travers le proxy
CyberArk PSMP via `expect` (fonction `connect()`, qui se termine
par `interact`). Deux usages courants manquent :

1. **Transfert de fichiers** — pousser/tirer des fichiers via `scp` à travers le
   PSMP (`psm cp`).
2. **Exécution de commande one-shot** — lancer une commande distante sans shell
   interactif, façon `ssh host "cmd"` (`psm host "cmd"`).

Les deux ont été **validés manuellement** contre le PSMP de prod :

- `scp vaultuser@targetuser@targethost@psmphost:/chemin dest` fonctionne.
- `ssh vaultuser@targetuser@targethost@psmphost "ls"` fonctionne (le PSMP
  n'oblige pas la session interactive).

Dans les deux cas, le PSMP présente **exactement le même prompt** que le shell :

```
(vaultuser@targetuser@targethost@psmphost) Target password is required. Target password:
```

Le regex `expect` déjà en place (`password\s*:\s*$`) le matche. La séquence
d'authentification (vault password optionnel si clé SSH, puis target password)
est donc **identique** aux trois modes.

## Objectifs

- `psm cp [flags] SRC… DST` : transfert de fichiers via scp, push et pull,
  récursif (`-r`), multi-fichiers, passthrough des flags scp.
- `psm [user@]host "cmd…"` : exécution non-interactive d'une commande distante,
  code retour propagé.
- Réutiliser au maximum la logique existante (résolution d'hôte, fetch des
  credentials, séquence d'auth `expect`) sans duplication.
- Préserver le comportement actuel du shell interactif à l'identique.

## Non-objectifs

- Support `sftp` (YAGNI — `scp` couvre le besoin « pousser des fichiers »).
- Transfert distant→distant (`scp host1:/a host2:/b`) : une seule cible PSMP.
- Filtrage du banner légal du PSMP en mode exec (voir « Amélioration future »).
- IPv6 explicite (limitation existante inchangée).

## Découvertes de validation

- **Prompt identique** aux trois modes → regex d'auth réutilisable tel quel.
- **exec autorisé** par le PSMP : `ssh …@…@…@… "ls"` renvoie la sortie puis
  rend la main (pas de shell forcé).
- **Banner PSMP inévitable côté client** : « session is being recorded » + le
  banner légal s'affichent **même avec `ssh -q`** ; ils sont injectés par le
  PSMP après l'auth, sur le canal de session. En mode exec, la sortie de la
  commande est donc précédée de ce banner. C'est un réglage serveur CyberArk
  (géré par les admins CyberArk), non désactivable côté client.

## Interface CLI et routage

Le `getopts` global (`-d/-l/-p/-v/-h`) reste inchangé et absorbe les options
`psm` avant les arguments positionnels. Le routage se fait ensuite sur les
positionnels restants :

| Forme                                   | Mode                        | Fonction     |
|-----------------------------------------|-----------------------------|--------------|
| `psm cp [flags] SRC… DST`               | transfert de fichiers       | `run_scp`    |
| `psm [user@]host "cmd…"` (≥ 2 args)     | exec non-interactif         | `run_exec`   |
| `psm [user@]host` (1 arg)               | shell interactif (actuel)   | `run_shell`  |
| autre                                   | erreur d'usage (code 2)     | —            |

Exemples :

```bash
# transfert
psm cp ./deploy.sh admin@srv-prod01:/tmp/     # push
psm cp ./deploy.sh srv-prod01:/tmp/           # push, user via ~/.ssh/config
psm cp srv-prod01:/etc/hosts .                # pull
psm cp -r ./dist srv-prod01:/var/www/         # récursif
psm cp a.conf b.conf srv-prod01:/etc/         # multi-fichiers

# exec one-shot
psm srv-prod01 "ls -la /data"
psm admin@srv-prod01 systemctl status nginx

# options psm combinables
psm -d -p 22 cp -r ./dist srv-prod01:/tmp/
```

`psm cp` accepte le port du PSMP via l'option `psm -p PORT`, traduite en `-P`
pour scp (scp utilise `-P` majuscule là où ssh/psm utilisent `-p`).

## Architecture

Refactor selon l'approche « extraire le commun » : la logique aujourd'hui
enfouie dans `connect()` est scindée en briques réutilisables.

### `resolve_target([user@]host)`

Extraite de `connect()`. Effectue, à l'identique de l'existant :

- parse `user@host` ou `host` seul ;
- `ssh -G` : résolution `HostName`, extraction `User` si absent, override
  `PSM_PSMP_HOST` (via `SetEnv`) ;
- résolution DNS (`getent`, timeout 2 s) ;
- détection du mode d'auth vault (clé SSH via `ssh-add -l` vs password) ;
- ordre de lookup KeePassXC selon `LDAP_USER` ;
- fetch du target password (et du vault password si mode password).

Expose le résultat via des variables (préfixe `R_`) : `R_TARGET_USER`,
`R_TARGET_HOST` (résolu), `R_PSMP_HOST`, `R_CONN_STR`
(`vaultuser@targetuser@targethost@psmphost`), `R_TARGET_PASS`, `R_VAULT_PASS`.
Émet les messages `info()` d'affichage de cible comme aujourd'hui.

Les trois consommateurs (`run_shell`, `run_scp`, `run_exec`) appellent
`resolve_target`, exportent les secrets via l'environnement, puis lancent leur
`expect`.

### `emit_auth_preamble(spawn_line)`

Fonction bash générant le heredoc `expect` **commun** : `log_user`,
`exp_internal`, `timeout`, définition des couleurs Tcl, ligne `spawn` (fournie
en paramètre), et le bloc `expect` d'authentification (branche vault password →
target password, avec toutes les branches d'erreur existantes : passphrase SSH,
MFA, permission denied, timeout, eof). Ce bloc s'arrête juste après l'envoi du
target password.

Chaque mode concatène ensuite sa **queue** :

- **shell** (`run_shell`) : bloc de vérif rapide d'erreur d'auth (timeout 3 s)
  puis `interact` avec auto-sudo — **inchangé** par rapport à l'actuel.
- **non-interactif** (`run_scp`, `run_exec`) :
  ```tcl
  set timeout -1
  expect eof
  catch wait result
  exit [lindex $result 3]
  ```
  → attend la fin du transfert/commande et **propage le code retour réel** de
  scp/ssh.

En mode non-interactif, `log_user` passe à `1` juste après l'envoi du target
password afin d'afficher la progression scp / la sortie de la commande.

### Lignes `spawn` par mode

- **shell** : `spawn -noecho ssh -p $port $SSH_OPTS $env(CONN_STR)`
- **exec** : `spawn -noecho ssh -p $port $SSH_OPTS $env(CONN_STR) $env(REMOTE_CMD)`
- **scp** : `spawn -noecho scp -P $port $SSH_OPTS {*}$argv`

## `run_exec` — exécution de commande

- La commande distante est jointe façon ssh (`psm host ls /data` ≡
  `psm host "ls /data"`) et passée via `$env(REMOTE_CMD)` — un seul mot Tcl,
  donc ssh la transmet telle quelle au shell distant. Le passage par
  l'environnement évite toute substitution/backslash Tcl (même raison que
  `CONN_STR` aujourd'hui).
- Queue non-interactive commune → code retour de ssh propagé.
- Le banner PSMP précède la sortie de la commande (limitation documentée).

## `run_scp` — parsing et transfert

### Identification du remote spec

Parmi les arguments **non-flag**, le remote spec est celui qui matche
`^[^/]*:` (règle scp standard : un `:` apparaît avant tout `/`, forme
`[user@]host:path`).

- **Exactement 1** remote spec requis.
  - **0** → erreur « aucune cible distante (host:path) » (code 2).
  - **≥ 2** → erreur « transfert distant→distant non supporté » (code 2).
- Le remote spec est scindé en `[user@]host` (avant le premier `:`) et `:path`
  (le `:` et la suite).
- `[user@]host` → `resolve_target` → l'argument est **réécrit** en
  `${R_CONN_STR}:${path}`.
- **Tous les autres arguments** (flags scp, chemins locaux) sont conservés
  inchangés, dans l'ordre. On ne parse pas finement les flags : comme on ne
  fait que remplacer le remote spec en place, les flags à valeur séparée
  (`-l 1000`, `-o …`) et le multi-fichiers fonctionnent naturellement.

### Fonction pure `parse_scp_args`

La détection/réécriture est isolée dans une fonction pure et testable :
entrée = liste d'arguments ; sortie = `host` à résoudre, `path` distant, et la
liste d'arguments réécrite (avec un placeholder à substituer par `conn_str`
une fois la résolution faite). Séparer cette fonction du pilotage `expect`
permet de la tester sans PSMP.

### Lancement

`spawn -noecho scp -P $port $SSH_OPTS {*}$argv`, où `argv` (les arguments
réécrits) est transmis à `expect` en **éléments distincts** (`expect -f script
-- arg…`). Cela évite tout ré-quoting shell, préserve espaces/backslash dans
les chemins et empêche l'injection. Les secrets ne transitent **jamais** par
`argv` (uniquement via `$env(…)`).

## Sécurité

- Mots de passe transmis exclusivement via `$env(VAULT_PASS)` /
  `$env(TARGET_PASS)`, jamais sur la ligne de commande — inchangé.
- `REMOTE_CMD` et les arguments scp passent par l'environnement / `argv` : la
  commande distante et les chemins peuvent apparaître dans `ps`, mais ne
  contiennent pas de secret (c'est ce que l'utilisateur taperait à la main).
- Le `conn_str` figurant dans l'`argv` scp (visible dans `ps`) ne contient
  aucun mot de passe.
- `unset` systématique des secrets après `expect`, y compris en cas d'échec
  (pattern `|| rc=$?`) — inchangé.

## Codes de sortie

- Codes d'auth existants réutilisés : `11` timeout, `12` eof, `13` permission
  refusée, `10`/`20–24` vault.
- **Nouveau** : en mode scp/exec, le **code retour réel de scp/ssh est
  propagé** (0 = succès ; sinon erreur de transfert/commande).
- Erreur de parsing `psm cp` (0 ou ≥ 2 remote specs) → `2` (usage).

La table des codes de sortie du README est mise à jour en conséquence.

## Documentation et complétion

- `usage()` : ajouter `psm cp …` et `psm [user@]host "cmd"`.
- `README.md` : sections « Exécuter une commande » et « Transfert de fichiers »
  (exemples push/pull/récursif/multi-fichiers), table des codes de sortie MAJ,
  limitations MAJ.
- `completions/psm.bash` : compléter le mot-clé `cp` ; après `cp`, compléter
  hostnames (`~/.ssh/config`, comme aujourd'hui) et fichiers locaux.

## Tests

- **`tests/parse_scp_args.test.sh`** : tests de la fonction pure
  `parse_scp_args` (assertions bash). Cas : push simple, pull, `-r`,
  multi-fichiers, flag à valeur (`-l 1000`), 0 remote (erreur), 2 remotes
  (erreur), extraction correcte de `host`/`path`.
- Le pilotage `expect` (auth, scp, exec) est validé **manuellement** contre le
  PSMP réel — non mockable (le PSMP ne peut être simulé).

## Limitations (à documenter dans le README)

- **Détection remote spec** : un flag à valeur contenant `:` avant un `/` (ex.
  `-o Foo=a:b`, rare) peut être confondu avec un remote spec ; dans ce cas,
  utiliser `scp` directement.
- **exec** : dépend de l'autorisation du one-shot côté PSMP (validé sur le
  PSMP de prod ; peut différer sur d'autres PSMP).
- **Banner PSMP en mode exec** : la sortie de la commande est précédée du
  banner légal / de notification d'enregistrement injecté par le PSMP
  (non désactivable côté client).
- **Distant→distant** non supporté (une seule cible PSMP).
- **IPv6** non géré explicitement (inchangé).

## Amélioration future — filtrage du banner (hors v1)

Pour rendre la sortie de `psm host "cmd"` exploitable en pipe, wrapper la
commande distante avec des marqueurs :

```
echo __PSM_START__; <cmd>; echo __PSM_END__:$?
```

et ne restituer via `expect` que ce qui se trouve entre les marqueurs. Bénéfice
secondaire : récupérer le **vrai code retour de la commande** (et non celui de
ssh). Écarté de la v1 car la réécriture de la commande distante peut casser
certains cas (here-docs, commandes exotiques, quoting complexe).
