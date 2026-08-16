#!/usr/bin/env bash
# Garde-fou : un déploiement qui touche l'intégration `rest` doit REDÉMARRER Home
# Assistant, pas seulement le recharger.
#
# Pourquoi ce test existe. `rest` ne se recharge pas (home-assistant/core#93527) : le
# rechargement recrée ses entités sans avoir retiré les précédentes, donc l'ANCIENNE
# configuration reste en service. Un déploiement de `rest.yaml` suivi du seul
# `reload_all` est un no-op SILENCIEUX — fichiers écrits, `deployed_sha` à jour, aucun
# effet. C'est le pire mode de panne pour un déployeur, et rien dans les journaux ne le
# distingue d'un succès. Trois choses sont donc verrouillées ici :
#
#   1. un déploiement REST déclenche bien `homeassistant/restart` ;
#   2. un déploiement ordinaire ne redémarre RIEN (le redémarrage coûte ~1 min de
#      coupure : le déclencher trop large serait une régression, pas une prudence) ;
#   3. un redémarrage empêché par l'étranglement (`restart_min_interval`) est MÉMORISÉ
#      et honoré à une passe ultérieure — y compris une passe qui n'a rien à déployer.
#      Sans ce point, l'étranglement recréerait exactement le no-op qu'il doit éviter,
#      puisque plus rien ensuite ne redemanderait le redémarrage.
#
# Le vrai script est piloté sur un dépôt jetable, avec `bashio` et l'API HA simulés :
# aucune instance Home Assistant n'est requise. Lancer : bash tests/test_restart_on_rest.sh
set -euo pipefail

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
    deploy.restart_on_rest)      printf '%s' "${CFG_RESTART_ON_REST-true}" ;;
    deploy.restart_min_interval) printf '%s' "${CFG_RESTART_MIN-3600}" ;;
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

# --- curl simulé : répond aux seuls appels dont le script a besoin, journalise chaque
# URL appelée (c'est le journal qu'on assertionne) et propage `deployed_sha` d'une passe
# à l'autre, comme le ferait la vraie entité HA.
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

# --- dépôt jetable ---------------------------------------------------------------
SRC="$T/src"; mkdir -p "$SRC/config"
git -C "$SRC" init -q -b main
git -C "$SRC" config user.email t@t; git -C "$SRC" config user.name t
commit() { git -C "$SRC" add -A; git -C "$SRC" commit -q -m "$1"; }

printf 'a: 1\n'                      > "$SRC/config/automations.yaml"
printf 'sensor:\n  - resource: http://x\n' > "$SRC/config/rest.yaml"
commit "base"

export CFG_REPO="$SRC"
export CONFIG_DIR="$T/config" WORK_DIR="$T/work" TMP="$T/tmp"
export HA_API="http://fake/api" HA_TOKEN=x
export RESTART_OWED_FILE="$T/restart-owed" RESTART_LAST_FILE="$T/restart-last"
export SHA_STATE="$T/sha-state"
mkdir -p "$CONFIG_DIR"
# /config part de l'état du commit de base : c'est la situation réelle d'une instance déjà
# déployée, et la condition pour que la garde anti-écrasement voie « live == version git
# précédente » plutôt qu'un fichier inconnu.
cp "$SRC/config/." "$CONFIG_DIR/" -r 2>/dev/null || cp -R "$SRC/config/." "$CONFIG_DIR/"

pass() { # pass LABEL — une passe complète, journal curl remis à zéro
  CURL_LOG="$T/curl.log"; export CURL_LOG; : > "$CURL_LOG"
  "$RUN_SH" > "$T/out.log" 2>&1 || true
}
restarts() { grep -c '/api/services/homeassistant/restart' "$T/curl.log" || true; }

# --- 1. amorçage : clone + première application ------------------------------------
pass "clone"                                   # premier run = clone, rien d'appliqué
printf 'a: 2\n' > "$SRC/config/automations.yaml"; commit "auto"
pass "deploy non-REST"
echo "→ déploiement ordinaire (automations.yaml)"
check "fichier appliqué" "$(cat "$CONFIG_DIR/automations.yaml")" "a: 2"
check "aucun redémarrage" "$(restarts)" "0"

# --- 2. déploiement REST → redémarrage ---------------------------------------------
printf 'sensor:\n  - resource: http://y\n' > "$SRC/config/rest.yaml"; commit "rest"
pass "deploy REST"
echo "→ déploiement de rest.yaml"
check "redémarrage déclenché" "$(restarts)" "1"
check "besoin consommé" "$([ -e "$RESTART_OWED_FILE" ] && echo oui || echo non)" "non"

# --- 3. dialecte `- platform: rest` dans un autre fichier ---------------------------
printf 'sensor:\n  - platform: rest\n    resource: http://z\n' > "$SRC/config/sensor.yaml"
commit "platform rest"
printf '0\n' > "$RESTART_LAST_FILE"            # créneau rouvert
pass "deploy platform:rest"
echo "→ déploiement d'un « - platform: rest » (sensor.yaml)"
check "redémarrage déclenché" "$(restarts)" "1"

# --- 4. étranglement : différé, puis honoré à une passe SANS déploiement ------------
printf 'sensor:\n  - resource: http://w\n' > "$SRC/config/rest.yaml"; commit "rest again"
date -u +%s > "$RESTART_LAST_FILE"             # on vient de redémarrer
pass "deploy REST étranglé"
echo "→ second déploiement REST dans l'heure"
check "redémarrage différé" "$(restarts)" "0"
check "fichier tout de même déployé" "$(sed -n 2p "$CONFIG_DIR/rest.yaml")" "  - resource: http://w"
check "besoin mémorisé" "$([ -s "$RESTART_OWED_FILE" ] && echo oui || echo non)" "oui"

echo "0" > "$RESTART_LAST_FILE"                # le créneau s'ouvre
pass "passe sans rien à déployer"
echo "→ passe suivante, rien à déployer"
check "redémarrage rattrapé" "$(restarts)" "1"
check "besoin consommé" "$([ -e "$RESTART_OWED_FILE" ] && echo oui || echo non)" "non"

# --- 5. désactivation explicite ----------------------------------------------------
printf 'sensor:\n  - resource: http://v\n' > "$SRC/config/rest.yaml"; commit "rest off"
printf '0\n' > "$RESTART_LAST_FILE"
export CFG_RESTART_ON_REST=false
pass "restart_on_rest=false"
unset CFG_RESTART_ON_REST
echo "→ restart_on_rest: false"
check "aucun redémarrage" "$(restarts)" "0"

[ "$fail" = 0 ] && echo "TOUS LES TESTS PASSENT" || echo "ÉCHEC"
exit "$fail"
