#!/usr/bin/env bash
# Garde-fou : une passe ne recharge que ce qu'elle a touché, et ne refait pas un backup
# complet à chaque fois.
#
# Pourquoi ce test existe. `homeassistant.reload_all` recharge TOUTES les intégrations
# rechargeables d'un coup. Mesuré le 2026-08-16 sur ha-vallesvilles-family : 77 secondes
# de blocage de la boucle d'événements de Core, pendant lesquelles le client MQTT perd sa
# connexion et TOUTES les entités Zigbee2MQTT passent `unavailable`. 20 décrochages ce
# jour-là, dont 19 sans la moindre cause réseau — deux jours de diagnostic ont accusé le
# réseau du garage. Et le `hassio.backup_full` d'avant écriture ajoutait ~3 min 45 s
# d'écriture disque par passe, 41 fois dans la journée.
#
# Quatre choses sont donc verrouillées ici :
#
#   1. un déploiement d'`automations.yaml` n'appelle QUE `automation/reload` — ni
#      `reload_all`, ni `reload_core_config` ;
#   2. un fichier hors configuration chargée (`dashboards/*`) ne recharge RIEN ;
#   3. un fichier structurant (`configuration.yaml`) ou inconnu (`sensor.yaml`) retombe
#      sur le rechargement large. C'est le point qui protège du pire mode de panne : un
#      rechargement MANQUÉ produit un déploiement sans effet, silencieux. Mieux vaut geler
#      que mentir ;
#   4. `backup_min_interval` saute le backup complet dans la fenêtre, et le refait
#      au-delà.
#
# Le vrai script est piloté sur un dépôt jetable, avec `bashio` et l'API HA simulés :
# aucune instance Home Assistant n'est requise. Lancer : bash tests/test_targeted_reload.sh
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

# --- bashio simulé : même mécanique que dans les autres tests (le shebang de run.sh est
# `#!/usr/bin/env bashio`, donc lancer le script revient à `bashio run.sh`).
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
    deploy.backup_before)        printf '%s' "${CFG_BACKUP_BEFORE-false}" ;;
    deploy.backup_min_interval)  printf '%s' "${CFG_BACKUP_MIN-86400}" ;;
    deploy.interval)             printf '0' ;;
    deploy.restart_on_rest)      printf '%s' "${CFG_RESTART_ON_REST-false}" ;;
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

# --- curl simulé : journalise chaque URL appelée (c'est le journal qu'on assertionne) et
# propage `deployed_sha` d'une passe à l'autre, comme le ferait la vraie entité HA.
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
SRC="$T/src"; mkdir -p "$SRC/config/dashboards"
git -C "$SRC" init -q -b main
git -C "$SRC" config user.email t@t; git -C "$SRC" config user.name t
commit() { git -C "$SRC" add -A; git -C "$SRC" commit -q -m "$1"; }

printf 'a: 1\n'          > "$SRC/config/automations.yaml"
printf 's: 1\n'          > "$SRC/config/scripts.yaml"
printf 't: 1\n'          > "$SRC/config/template.yaml"
printf 'i: 1\n'          > "$SRC/config/input_number.yaml"
printf 'title: 1\n'      > "$SRC/config/dashboards/maison.yaml"
printf 'sensor: []\n'    > "$SRC/config/sensor.yaml"
printf 'homeassistant:\n' > "$SRC/config/configuration.yaml"
commit "base"

export CFG_REPO="$SRC"
export CONFIG_DIR="$T/config" WORK_DIR="$T/work" TMP="$T/tmp"
export HA_API="http://fake/api" HA_TOKEN=x
export RESTART_OWED_FILE="$T/restart-owed" RESTART_LAST_FILE="$T/restart-last"
export BACKUP_LAST_FILE="$T/backup-last"
export SHA_STATE="$T/sha-state"
mkdir -p "$CONFIG_DIR"
cp -R "$SRC/config/." "$CONFIG_DIR/"

pass() {
  CURL_LOG="$T/curl.log"; export CURL_LOG; : > "$CURL_LOG"
  "$RUN_SH" > "$T/out.log" 2>&1 || true
}
# Liste triée des services de rechargement appelés, pour une assertion lisible.
reloads() {
  sed -n 's#.*/api/services/##p' "$T/curl.log" \
    | grep -E 'reload' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
backups() { grep -c '/api/services/hassio/backup_full' "$T/curl.log" || true; }

pass   # premier run = clone, rien d'appliqué

# --- 1. automations.yaml seul → automation/reload, et RIEN d'autre -----------------
printf 'a: 2\n' > "$SRC/config/automations.yaml"; commit "auto"
pass
echo "→ automations.yaml seul"
check "fichier appliqué"      "$(cat "$CONFIG_DIR/automations.yaml")" "a: 2"
check "rechargement ciblé"    "$(reloads)" "automation/reload"

# --- 2. plusieurs domaines → un service par domaine, dédoublonné -------------------
printf 'a: 3\n' > "$SRC/config/automations.yaml"
printf 's: 2\n' > "$SRC/config/scripts.yaml"
printf 't: 2\n' > "$SRC/config/template.yaml"
printf 'i: 2\n' > "$SRC/config/input_number.yaml"
commit "multi"
pass
echo "→ automations + scripts + template + input_number"
check "un service par domaine" "$(reloads)" \
      "automation/reload input_number/reload script/reload template/reload"

# --- 3. dashboards/ → aucun rechargement ------------------------------------------
printf 'title: 2\n' > "$SRC/config/dashboards/maison.yaml"; commit "dash"
pass
echo "→ dashboards/maison.yaml seul (Lovelace YAML relit à la demande)"
check "fichier appliqué"       "$(cat "$CONFIG_DIR/dashboards/maison.yaml")" "title: 2"
check "aucun rechargement"     "$(reloads)" ""

# --- 4. fichier inconnu → repli LARGE ---------------------------------------------
# sensor.yaml est volontairement hors table : sa plateforme est indéterminable, donc on
# préfère geler que rater le rechargement et produire un déploiement silencieusement sans
# effet.
printf 'sensor: [1]\n' > "$SRC/config/sensor.yaml"; commit "sensor"
pass
echo "→ sensor.yaml (hors table)"
check "repli reload_all"       "$(reloads)" "homeassistant/reload_all homeassistant/reload_core_config"

# --- 5. configuration.yaml → structurant, repli LARGE ------------------------------
printf 'homeassistant:\n  name: x\n' > "$SRC/config/configuration.yaml"; commit "conf"
pass
echo "→ configuration.yaml (structurant)"
check "repli reload_all"       "$(reloads)" "homeassistant/reload_all homeassistant/reload_core_config"

# --- 6. un seul fichier inconnu suffit à élargir toute la passe ---------------------
printf 'a: 4\n'        > "$SRC/config/automations.yaml"
printf 'sensor: [2]\n' > "$SRC/config/sensor.yaml"
commit "mixte"
pass
echo "→ automations.yaml + sensor.yaml"
check "élargi par le fichier inconnu" "$(reloads)" \
      "homeassistant/reload_all homeassistant/reload_core_config"

# --- 7. étranglement du backup complet ---------------------------------------------
export CFG_BACKUP_BEFORE=true
rm -f "$BACKUP_LAST_FILE"
printf 'a: 5\n' > "$SRC/config/automations.yaml"; commit "bk1"
pass
echo "→ backup_before, premier déploiement (créneau ouvert)"
check "backup effectué"        "$(backups)" "1"

printf 'a: 6\n' > "$SRC/config/automations.yaml"; commit "bk2"
pass
echo "→ déploiement suivant dans la fenêtre de 24 h"
check "backup sauté"           "$(backups)" "0"
check "fichier tout de même déployé" "$(cat "$CONFIG_DIR/automations.yaml")" "a: 6"

printf '0\n' > "$BACKUP_LAST_FILE"   # le créneau se rouvre
printf 'a: 7\n' > "$SRC/config/automations.yaml"; commit "bk3"
pass
echo "→ créneau rouvert"
check "backup refait"          "$(backups)" "1"

export CFG_BACKUP_MIN=0
printf 'a: 8\n' > "$SRC/config/automations.yaml"; commit "bk4"
pass
echo "→ backup_min_interval: 0 (ancien comportement)"
check "backup à chaque passe"  "$(backups)" "1"

[ "$fail" = 0 ] && echo "TOUS LES TESTS PASSENT" || echo "ÉCHEC"
exit "$fail"
