#!/usr/bin/env bash
# Garde-fou : la base de comparaison d'une passe = le SHA RÉELLEMENT APPLIQUÉ dans
# /config (publié dans `input_text.ha_deployed_sha`), jamais le SHA qu'on vient de
# fetcher.
#
# Pourquoi ce test existe. `deploy_once` fait `git reset --hard origin/<branche>` AVANT
# de décider quoi appliquer : le clone de travail avance donc même quand la passe
# n'applique rien (conflit, Core absent, dry-run, échec d'écriture). Une passe suivante
# qui repartirait de « HEAD d'avant-fetch » croirait que /config contient déjà la cible
# de la passe ratée, avec deux dégâts qui s'entretiennent l'un l'autre :
#
#   1. PERTE SILENCIEUSE — les fichiers de la passe ratée sortent du diff et ne sont
#      PLUS JAMAIS déployés. Aucune erreur n'est levée : le déployeur se déclare vert.
#   2. CONFLIT FANTÔME — `old:<fichier>` ne correspond plus au live, donc la garde
#      anti-écrasement crie « modifiée en live » sur un fichier que personne n'a
#      touché, indéfiniment.
#
# C'est l'incident du 2026-08-08 → 2026-08-15 : 7 jours de chaîne gelée. Le correctif
# (`resolve_base`) lit la base dans l'entité HA, publiée UNIQUEMENT sur un état /config
# cohérent, avec deux replis explicites — entité vide (amorçage) et SHA absent du clone
# (branche réécrite) — et un refus net quand Core est injoignable, cas où un repli
# fabriquerait justement la base empoisonnée qu'on cherche à éliminer.
#
# Ce fichier vient de ha-vallesvilles-family (`tests/test_deploy_base_is_deployed_sha.py`),
# où il gardait `bin/deploy/deploy-from-git.sh` — le script de référence POSIX, retiré
# le 2026-08-16 après avoir divergé de l'add-on. Il garde désormais le script qui tourne
# réellement.
#
# Le vrai script est piloté sur un dépôt jetable, avec `bashio` et l'API HA simulés :
# aucune instance Home Assistant n'est requise. Lancer : bash tests/test_base_deployed_sha.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_SH="${RUN_SH_UNDER_TEST:-$REPO_ROOT/git-deployer/root/run.sh}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"
export PATH="$BIN:$PATH"

fail=0
ok()   { printf '  ✅ %s\n' "$1"; }
ko()   { printf '  ❌ %s\n' "$1"; fail=1; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (attendu «$3», obtenu «$2»)"; fi; }
# grep -c sur un journal : le comptage sert d'assertion « ce message est apparu ».
saw()  { if grep -qF "$2" "$T/out.log"; then ok "$1"; else ko "$1 (message absent du journal)"; fi; }
unseen(){ if grep -qF "$2" "$T/out.log"; then ko "$1 (message présent alors qu'il ne devait pas)"; else ok "$1"; fi; }

# --- bashio simulé : le shebang de run.sh est `#!/usr/bin/env bashio`, donc exécuter le
# script revient à lancer `bashio run.sh`. Ce faux bashio définit les fonctions attendues
# puis source le script — même mécanique que le vrai, sans le Superviseur.
cat > "$BIN/bashio" <<'EOF'
#!/bin/bash
bashio::config() {
  case "$1" in
    repository.url)              printf '%s' "$CFG_REPO" ;;
    repository.username)         printf 'u' ;;
    repository.password)         printf 'p' ;;
    repository.branch)           printf 'main' ;;
    deploy.subdir)               printf 'config' ;;
    deploy.dry_run)              printf 'false' ;;
    deploy.allow_partial)        printf 'false' ;;
    deploy.backup_before)        printf 'false' ;;
    deploy.interval)             printf '0' ;;
    deploy.restart_on_rest)      printf 'false' ;;
    deploy.restart_min_interval) printf '3600' ;;
  esac
}
# Sur stderr, comme le vrai bashio : plusieurs fonctions de run.sh rendent leur
# résultat par stdout (resolve_base) et journalisent en même temps.
bashio::log.info()      { echo "[info] $*" >&2; }
bashio::log.warning()   { echo "[warn] $*" >&2; }
bashio::log.error()     { echo "[err ] $*" >&2; }
bashio::config.require()   { :; }
bashio::config.has_value() { return 0; }
bashio::exit.nok()      { echo "$*" >&2; exit 1; }
source "$1"
EOF
chmod +x "$BIN/bashio"

# --- curl simulé : répond aux seuls appels dont le script a besoin ici, et propage
# `deployed_sha` d'une passe à l'autre comme le ferait la vraie entité HA. Deux leviers
# pilotent les scénarios :
#   SHA_STATE       — le fichier qui TIENT la valeur de l'entité (le test l'écrit à la main
#                     pour rejouer un amorçage, une branche réécrite, etc.) ;
#   SHA_UNREADABLE  — non vide ⇒ la lecture de l'entité ÉCHOUE (Core injoignable), sans que
#                     la sonde de vivacité `GET /` échoue : c'est exactement la fenêtre où
#                     un repli produirait une base fausse.
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
url=""; data=""; prev=""
for a in "$@"; do
  case "$prev" in -d) data="$a" ;; esac
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
echo "$url" >> "$CURL_LOG"
case "$url" in
  */api/) printf '{"message":"API running."}'; exit 0 ;;
  */api/states/input_text.ha_deployed_sha)
    [ -n "${SHA_UNREADABLE:-}" ] && exit 7      # curl -f : échec réseau
    printf '{"entity_id":"input_text.ha_deployed_sha","state":"%s"}' "$(cat "$SHA_STATE" 2>/dev/null)"
    exit 0 ;;
  */api/config/core/check_config) printf '{"result":"valid"}'; exit 0 ;;
  */api/services/input_text/set_value)
    case "$data" in
      *ha_deployed_sha*)
        printf '%s' "$data" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p' > "$SHA_STATE" ;;
    esac
    printf '{}'; exit 0 ;;
esac
printf '{}'
exit 0
EOF
chmod +x "$BIN/curl"

export CFG_REPO="$T/src"
export CONFIG_DIR="$T/config" WORK_DIR="$T/work" TMP="$T/tmp"
export HA_API="http://fake/api" HA_TOKEN=x
export RESTART_OWED_FILE="$T/restart-owed" RESTART_LAST_FILE="$T/restart-last"
export SHA_STATE="$T/sha-state" CURL_LOG="$T/curl.log"

# --- monde jetable ------------------------------------------------------------------
# Chaque scénario repart d'un dépôt, d'un /config et d'un clone NEUFS : ces tests
# décrivent des enchaînements de passes, un reste d'état d'un scénario précédent
# fausserait le suivant sans rien signaler.
world() {
  rm -rf "$T/src" "$T/config" "$T/work" "$T/tmp"
  mkdir -p "$T/src/config" "$T/config"
  git -C "$T/src" init -q -b main
  git -C "$T/src" config user.email t@t
  git -C "$T/src" config user.name t
  : > "$SHA_STATE"
  unset SHA_UNREADABLE || true
}
put()    { mkdir -p "$(dirname "$T/src/config/$1")"; printf '%s' "$2" > "$T/src/config/$1"; }
commit() { git -C "$T/src" add -A; git -C "$T/src" commit -q -m "$1"; git -C "$T/src" rev-parse HEAD; }
edit()   { mkdir -p "$(dirname "$T/config/$1")"; printf '%s' "$2" > "$T/config/$1"; }
live()   { cat "$T/config/$1" 2>/dev/null || true; }
pass()   { : > "$CURL_LOG"; "$RUN_SH" > "$T/out.log" 2>&1; printf '%s' "$?"; }

# amorce SHA — l'état de départ réaliste : premier run (clone seul, rien appliqué), on
# aligne /config sur le commit courant et on publie ce SHA, comme le ferait une passe
# réussie. Sans ça, l'entité serait vide et TOUS les scénarios partiraient en repli.
amorce() {
  pass > /dev/null
  cp -R "$T/src/config/." "$T/config/"
  printf '%s' "$1" > "$SHA_STATE"
}

# === 1. un CONFLIT ne condamne pas les fichiers de la passe suivante =================
echo "→ 1. après un conflit, les fichiers de la passe ratée sont toujours déployés"
world
put a.yaml 'a1'; put b.yaml 'b1'
v1="$(commit v1)"
amorce "$v1"

# v2 touche a.yaml ET b.yaml ; quelqu'un a édité a.yaml en live → CONFLIT.
put a.yaml 'a2'; put b.yaml 'b2'; commit v2 > /dev/null
edit a.yaml 'EDIT LIVE'
check "passe en conflit : sortie sans échec dur" "$(pass)" "0"
saw   "conflit signalé" "CONFLITS (1)"
check "tout-ou-rien : b.yaml pas écrit" "$(live b.yaml)" "b1"
check "base inchangée (rien de cohérent à publier)" "$(cat "$SHA_STATE")" "$v1"

# Le conflit est levé à la main : a.yaml revient à la version attendue.
edit a.yaml 'a1'
# v3 ne touche que c.yaml. Avec le bug, la base de la passe 3 serait v2 (le clone a déjà
# été reset) : a.yaml et b.yaml sortiraient du diff pour toujours.
put c.yaml 'c1'; v3="$(commit v3)"
check "passe suivante : succès" "$(pass)" "0"
check "a.yaml rattrapé"  "$(live a.yaml)" "a2"
check "b.yaml rattrapé"  "$(live b.yaml)" "b2"
check "c.yaml déployé"   "$(live c.yaml)" "c1"
check "base publiée = v3" "$(cat "$SHA_STATE")" "$v3"

# === 2. pas de CONFLIT FANTÔME sur un fichier que personne n'a touché ================
echo "→ 2. un fichier intact n'est jamais accusé d'avoir été modifié en live"
world
put a.yaml 'a1'; put t.yaml 't1'
v1="$(commit v1)"
amorce "$v1"

put a.yaml 'a2'; put t.yaml 't2'; commit v2 > /dev/null
edit a.yaml 'EDIT LIVE'
pass > /dev/null                       # conflit sur a.yaml ; t.yaml reste intact en live
edit a.yaml 'a1'                       # conflit levé
put t.yaml 't3'; commit v3 > /dev/null

check "passe suivante : succès" "$(pass)" "0"
unseen "aucun conflit fantôme" "modifiée en live"
check  "t.yaml déployé" "$(live t.yaml)" "t3"

# === 3. entité lisible mais VIDE → repli sur HEAD d'avant-fetch ======================
# L'amorçage d'une instance neuve : l'entité existe, personne n'y a encore rien publié.
# L'ancien comportement doit rester le filet — une entité vide ne fait jamais échouer.
echo "→ 3. entité vide (amorçage) : repli, pas d'échec"
world
put a.yaml 'a1'; v1="$(commit v1)"
amorce "$v1"
put a.yaml 'a2'; commit v2 > /dev/null
: > "$SHA_STATE"                       # entité vide

check "passe : succès" "$(pass)" "0"
saw   "repli annoncé" "repli sur HEAD d'avant-fetch"
check "a.yaml déployé" "$(live a.yaml)" "a2"

# === 4. SHA valide mais ABSENT du clone → repli =====================================
# Branche réécrite côté amont (force-push, rebase) : le SHA publié ne désigne plus rien.
echo "→ 4. deployed_sha inconnu du clone (branche réécrite) : repli, pas d'échec"
world
put a.yaml 'a1'; v1="$(commit v1)"
amorce "$v1"
put a.yaml 'a2'; commit v2 > /dev/null
printf 'deaddeaddeaddeaddeaddeaddeaddeaddeaddead' > "$SHA_STATE"   # 40 hex, inexistant

check "passe : succès" "$(pass)" "0"
saw   "repli annoncé" "absent du clone"
check "a.yaml déployé" "$(live a.yaml)" "a2"

# === 5. base ILLISIBLE (Core injoignable) → passe abandonnée, AUCUNE écriture =======
# La divergence la plus coûteuse des scénarios 3 et 4 : ici l'entité n'est pas vide, elle
# est INACCESSIBLE. Replier sur le HEAD d'avant-fetch fabriquerait exactement la base
# empoisonnée que ces tests traquent — d'où l'abandon net. Vécu le 2026-08-16 (deux
# ROLLBACK fantômes à 00h14 et 00h18, sur une config que check_config validait à 00h20).
echo "→ 5. lecture de la base impossible : on saute la passe plutôt que d'en faire une mauvaise"
world
put a.yaml 'a1'; v1="$(commit v1)"
amorce "$v1"
put a.yaml 'a2'; commit v2 > /dev/null
export SHA_UNREADABLE=1

check "passe : sortie sans échec dur (on retentera)" "$(pass)" "0"
saw   "abandon annoncé" "passe abandonnée"
unseen "pas de repli silencieux" "repli sur HEAD d'avant-fetch"
check "aucune écriture" "$(live a.yaml)" "a1"
unset SHA_UNREADABLE

[ "$fail" = 0 ] && echo "TOUS LES TESTS PASSENT" || echo "ÉCHEC"
exit "$fail"
