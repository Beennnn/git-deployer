#!/usr/bin/env bash
# Garde-fou : en mode boucle, `input_boolean.git_deployer_run_now` = `on` doit déclencher
# une passe TOUT DE SUITE, sans que personne ne redémarre l'add-on.
#
# Pourquoi ce test existe. Forcer une passe par `hassio.addon_restart` est contre-indiqué
# deux fois : le redémarrage retire brièvement le marqueur `input_text.ha_deployed_sha` à la
# garde de `git-exporter`, ce qui rouvre la course lost-update que cette garde ferme
# (2026-08-16) ; et un redémarrage qui repart d'un clone frais peut sauter l'apply
# (2026-08-08). Tant que la seule alternative était d'attendre jusqu'à 15 min, l'interdit se
# faisait contourner. Le déclencheur ne vaut donc que s'il tient trois promesses, verrouillées
# ici :
#
#   1. drapeau levé → la passe part en quelques secondes, pas au bout de l'intervalle ;
#   2. l'add-on éteint le drapeau lui-même, et AVANT la passe : éteint après, un drapeau
#      survivrait à une passe en échec et chaque tour en relancerait une — une boucle serrée
#      née d'un seul clic ;
#   3. drapeau au repos ou entité absente → l'attente tient, et rien n'est déployé plus tôt.
#      Le point « entité absente » compte autant que les autres : le déclencheur est
#      facultatif, une install qui n'a pas créé le helper doit se comporter comme avant.
#
# Le vrai script est piloté en mode boucle sur un dépôt jetable, `bashio` et l'API HA
# simulés : aucune instance Home Assistant requise. L'intervalle est mis à 3600 s pour que
# toute passe observée pendant le test soit forcément due au déclencheur — l'échéance
# normale, elle, ne tombera jamais.
#
# Lancer : bash tests/test_run_now_trigger.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_SH="${RUN_SH_UNDER_TEST:-$REPO_ROOT/git-deployer/root/run.sh}"

T="$(mktemp -d)"
LOOP_PID=""
cleanup() { [ -n "$LOOP_PID" ] && kill "$LOOP_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
BIN="$T/bin"; mkdir -p "$BIN"
export PATH="$BIN:$PATH"

fail=0
ok()   { printf '  ✅ %s\n' "$1"; }
ko()   { printf '  ❌ %s\n' "$1"; fail=1; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (attendu «$3», obtenu «$2»)"; fi; }

# wait_for TIMEOUT CMD… — attend qu'une condition devienne vraie, au plus TIMEOUT secondes.
# Rend 0 dès qu'elle l'est. Sert à mesurer « la passe est partie vite » sans dormir en dur.
wait_for() {
  local t="$1"; shift; local n=0
  while [ "$n" -lt "$t" ]; do
    if "$@"; then return 0; fi
    sleep 1; n=$(( n + 1 ))
  done
  return 1
}

# --- bashio simulé (même mécanique que test_restart_on_rest.sh) ----------------------
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
    deploy.interval)             printf '%s' "${CFG_INTERVAL-3600}" ;;
    deploy.restart_on_rest)      printf 'false' ;;
    deploy.restart_min_interval) printf '3600' ;;
  esac
}
bashio::log.info()      { echo "[info] $*" >&2; }
bashio::log.warning()   { echo "[warn] $*" >&2; }
bashio::log.error()     { echo "[err ] $*" >&2; }
bashio::config.require()   { :; }
bashio::config.has_value() { return 0; }
bashio::exit.nok()      { echo "$*" >&2; exit 1; }
source "$1"
EOF
chmod +x "$BIN/bashio"

# --- curl simulé. Deux ajouts par rapport au test REST : il sert l'état du drapeau depuis
# un fichier, et l'éteint sur `input_boolean/turn_off` — c'est ainsi qu'on vérifie que
# l'add-on accuse réception lui-même. `$RUN_NOW_STATE` = `absent` fait échouer la requête
# comme le ferait `curl -f` sur un 404, ce qui simule une install sans le helper.
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
url=""; data=""; prev=""; maxtime=""
for a in "$@"; do
  case "$prev" in -d) data="$a" ;; --max-time) [ "$a" != 0 ] && maxtime="$a" ;; esac
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
echo "$url" >> "$CURL_LOG"
# Mode « Core redémarre » : la connexion est acceptée mais rien ne revient. Le vrai curl
# attend alors le délai TCP par défaut — des dizaines de secondes — SAUF si l'appelant a posé
# `--max-time`, auquel cas il rend la main à l'échéance avec le code 28. Ce stub reproduit
# les deux comportements : c'est ce qui rend le test capable d'échouer sur la version sans
# borne, où la boucle de scrutation reste figée sur un seul appel au lieu de tourner.
if [ -f "$FREEZE_FILE" ]; then
  if [ -n "$maxtime" ]; then sleep "$maxtime"; else sleep 45; fi
  exit 28
fi
case "$url" in
  */api/) printf '{"message":"API running."}'; exit 0 ;;
  */api/states/input_text.ha_deployed_sha)
    printf '{"entity_id":"input_text.ha_deployed_sha","state":"%s"}' "$(cat "$SHA_STATE" 2>/dev/null)"
    exit 0 ;;
  */api/states/input_boolean.git_deployer_run_now)
    s="$(cat "$RUN_NOW_STATE" 2>/dev/null)"
    [ "$s" = absent ] && exit 22
    printf '{"entity_id":"input_boolean.git_deployer_run_now","state":"%s"}' "$s"
    exit 0 ;;
  */api/services/input_boolean/turn_off)
    echo off > "$RUN_NOW_STATE"; printf '{}'; exit 0 ;;
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

# --- dépôt jetable -------------------------------------------------------------------
SRC="$T/src"; mkdir -p "$SRC/config"
git -C "$SRC" init -q -b main
git -C "$SRC" config user.email t@t; git -C "$SRC" config user.name t
commit() { git -C "$SRC" add -A; git -C "$SRC" commit -q -m "$1"; }

printf 'a: 1\n' > "$SRC/config/automations.yaml"
commit "base"

export CFG_REPO="$SRC"
export CONFIG_DIR="$T/config" WORK_DIR="$T/work" TMP="$T/tmp"
export HA_API="http://fake/api" HA_TOKEN=x
export RESTART_OWED_FILE="$T/restart-owed" RESTART_LAST_FILE="$T/restart-last"
export SHA_STATE="$T/sha-state" RUN_NOW_STATE="$T/run-now-state"
export FREEZE_FILE="$T/freeze"   # présent ⇔ l'API Core ne répond plus (redémarrage simulé)
export CURL_LOG="$T/curl.log"; : > "$CURL_LOG"
# 1 s au lieu de 15 : c'est le pas de scrutation, pas la logique. Le garder à 15 ne
# testerait rien de plus et rendrait la suite 15× plus lente.
export RUN_NOW_POLL=1
export CFG_INTERVAL=3600
mkdir -p "$CONFIG_DIR"
cp -R "$SRC/config/." "$CONFIG_DIR/"
echo off > "$RUN_NOW_STATE"

deployed() { cat "$CONFIG_DIR/automations.yaml" 2>/dev/null; }
is_deployed() { [ "$(deployed)" = "$1" ]; }
turn_offs() { grep -c '/api/services/input_boolean/turn_off' "$CURL_LOG" || true; }

# --- la boucle tourne en tâche de fond pour toute la durée du test --------------------
"$RUN_SH" > "$T/out.log" 2>&1 &
LOOP_PID=$!

echo "→ amorçage : premier tour = clone, puis attente"
wait_for 30 test -d "$WORK_DIR/.git" || ko "clone initial jamais fait"
ok "clone initial fait, la boucle attend"

# --- 1. drapeau levé → passe immédiate ------------------------------------------------
printf 'a: 2\n' > "$SRC/config/automations.yaml"; commit "auto v2"
echo on > "$RUN_NOW_STATE"
echo "→ drapeau levé (l'échéance normale, elle, est à 3600 s)"
if wait_for 20 is_deployed "a: 2"; then ok "passe anticipée : fichier déployé en < 20 s"
else ko "aucune passe : le déclencheur n'a pas été vu"; fi
check "drapeau éteint par l'add-on" "$(cat "$RUN_NOW_STATE")" "off"
check "extinction demandée une seule fois" "$(turn_offs)" "1"

# --- 2. drapeau au repos → l'attente tient --------------------------------------------
printf 'a: 3\n' > "$SRC/config/automations.yaml"; commit "auto v3"
echo "→ drapeau au repos, 6 s d'observation"
sleep 6
check "rien déployé sans demande" "$(deployed)" "a: 2"

# --- 3. entité absente → aucun déclenchement, aucun bruit -----------------------------
# Le helper est facultatif : une install qui ne l'a pas créé doit se comporter comme avant,
# et surtout ne pas remplir le journal d'un avertissement par tour de scrutation.
echo absent > "$RUN_NOW_STATE"
echo "→ entité absente, 6 s d'observation"
before="$(wc -l < "$T/out.log")"
sleep 6
after="$(wc -l < "$T/out.log")"
check "toujours rien déployé" "$(deployed)" "a: 2"
# Le critère est la CROISSANCE du journal pendant l'absence, pas un total : ce qu'on veut
# exclure, c'est un avertissement à chaque tour de scrutation (6 tours ici, ~60 par intervalle
# réel). Les mentions légitimes — ligne de démarrage, sonde unique, une ligne par passe
# anticipée — sont hors de cette fenêtre et ne doivent pas faire échouer le test.
grown=$(( after - before ))
if [ "$grown" -le 1 ]; then ok "journal silencieux pendant l'absence (+${grown} ligne(s) en 6 tours)"
else ko "journal bruyant : +${grown} lignes en 6 tours de scrutation"; fi

# --- 4. le déclencheur remarche une fois l'entité revenue -----------------------------
echo on > "$RUN_NOW_STATE"
echo "→ entité revenue et drapeau levé"
if wait_for 20 is_deployed "a: 3"; then ok "passe anticipée à nouveau"
else ko "le déclencheur ne repart pas après une absence"; fi

# --- 5. Core muet pendant la scrutation → la boucle continue de tourner -----------------
# Le cas vécu le 2026-08-16 : l'add-on venait de redémarrer HA, la scrutation est tombée sur
# un Core qui accepte la connexion sans répondre, et elle s'est FIGÉE — 85 s de latence au
# lieu de ≤ 15 s. Sans borne, un seul appel suspend toute la boucle ; avec, chaque tentative
# rend la main et le tour suivant a lieu à l'heure.
printf 'a: 4\n' > "$SRC/config/automations.yaml"; commit "auto v4"
: > "$FREEZE_FILE"
echo on > "$RUN_NOW_STATE"
echo "→ Core muet, drapeau levé pendant la panne, retour au bout de 12 s"
T0=$(date +%s)
sleep 12
rm -f "$FREEZE_FILE"
if wait_for 25 is_deployed "a: 4"; then
  ok "passe partie $(( $(date +%s) - T0 ))s après la levée (Core muet 12 s inclus)"
else
  ko "boucle figée par un appel sans borne : rien déployé $(( $(date +%s) - T0 ))s après"
fi

kill "$LOOP_PID" 2>/dev/null; LOOP_PID=""

[ "$fail" = 0 ] && echo "TOUS LES TESTS PASSENT" || echo "ÉCHEC"
exit "$fail"
