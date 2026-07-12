#!/usr/bin/env bashio
# git-deployer — applique une branche git sur /config (le pendant « déploie »
# de git-exporter). Port bashio du script bin/deploy/deploy-from-git.sh (testé).
#
# Sûr par conception (identique au script de référence) :
#   - ne déploie que <subdir>/**  (par défaut config/) ;
#   - garde anti-écrasement : n'applique un fichier que si la version live == la
#     version git précédente (sinon CONFLIT → tout-ou-rien → rien écrit + notif) ;
#   - backup HA complet avant écriture ;
#   - check_config après écriture → rollback si invalide ;
#   - reload ciblé (automation/script/scene) ; restart suggéré si structurant ;
#   - 1er run = clone puis stop (pas d'application sans base de comparaison).
#
# Auth : parle à l'API core HA via le jeton Supervisor de l'addon
# (homeassistant_api: true) → AUCUN token HA à créer à la main.
set -euo pipefail

REPO_URL="$(bashio::config 'repository.url')"
GIT_USER="$(bashio::config 'repository.username')"
GIT_PASS="$(bashio::config 'repository.password')"
BRANCH="$(bashio::config 'repository.branch')"
SUBDIR="$(bashio::config 'deploy.subdir')"
DRY_RUN="$(bashio::config 'deploy.dry_run')"
ALLOW_PARTIAL="$(bashio::config 'deploy.allow_partial')"
BACKUP_BEFORE="$(bashio::config 'deploy.backup_before')"
INTERVAL="$(bashio::config 'deploy.interval')"

# Défauts prod ; surchargeables par env (utile pour les tests hors Supervisor).
CONFIG_DIR="${CONFIG_DIR:-/config}"
WORK_DIR="${WORK_DIR:-/data/repo}"
HA_API="${HA_API:-http://supervisor/core/api}"
HA_TOKEN="${HA_TOKEN:-${SUPERVISOR_TOKEN:-}}"

TMP="/tmp/git-deployer"

jesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'; }

ha() { # ha METHOD PATH [json]
  local m="$1" p="$2" d="${3:-}"
  if [ -n "$d" ]; then
    curl -fsS -X "$m" "${HA_API}${p}" -H "Authorization: Bearer ${HA_TOKEN}" \
         -H 'Content-Type: application/json' -d "$d"
  else
    curl -fsS -X "$m" "${HA_API}${p}" -H "Authorization: Bearer ${HA_TOKEN}"
  fi
}

notify() { # notify TITLE MESSAGE
  local b
  b=$(printf '{"title":"%s","message":"%s","notification_id":"git_deployer"}' \
        "$(jesc "$1")" "$(jesc "$2")")
  ha POST /services/persistent_notification/create "$b" >/dev/null 2>&1 || true
}

fail() { bashio::log.error "$1"; notify "🔴 git-deployer — échec" "$1"; return 1; }

deploy_once() {
  rm -rf "$TMP"; mkdir -p "$TMP"

  local auth_url first_run=0 old new
  auth_url="$(printf '%s' "$REPO_URL" | sed "s#https://#https://${GIT_USER}:${GIT_PASS}@#")"

  if [ -d "$WORK_DIR/.git" ]; then
    bashio::log.info "fetch ${BRANCH}…"
    git -C "$WORK_DIR" remote set-url origin "$auth_url"
    old="$(git -C "$WORK_DIR" rev-parse HEAD)"
    git -C "$WORK_DIR" fetch --quiet origin "$BRANCH" || { fail "git fetch a échoué"; return 1; }
    git -C "$WORK_DIR" reset --hard --quiet "origin/${BRANCH}" || { fail "git reset a échoué"; return 1; }
  else
    bashio::log.info "clone initial…"
    git clone --quiet --branch "$BRANCH" "$auth_url" "$WORK_DIR" || { fail "git clone a échoué"; return 1; }
    old=""; first_run=1
  fi
  git -C "$WORK_DIR" remote set-url origin "$REPO_URL"   # ne pas laisser le token dans .git/config
  new="$(git -C "$WORK_DIR" rev-parse HEAD)"

  if [ "$first_run" = 1 ]; then
    bashio::log.warning "PREMIER RUN — clone prêt, aucune application (pas de base de comparaison). Les prochains runs seront incrémentaux."
    notify "ℹ️ git-deployer — premier run" "Clone initialisé. Les prochaines passes appliqueront main de façon incrémentale et sûre."
    return 0
  fi
  if [ "$old" = "$new" ]; then
    bashio::log.info "déjà à jour (${new:0:8}) — rien à déployer."
    return 0
  fi

  # --no-renames : un renommage devient delete+add (2 champs chacun), sinon la
  # ligne "R100<TAB>ancien<TAB>nouveau" casserait le parseur (status/path).
  git -C "$WORK_DIR" diff --no-renames --name-status "$old" "$new" -- "${SUBDIR}/" > "$TMP/changes" || { fail "git diff a échoué"; return 1; }
  if [ ! -s "$TMP/changes" ]; then
    bashio::log.info "aucun changement sous ${SUBDIR}/ — rien à déployer."
    return 0
  fi
  bashio::log.info "changements détectés :"; cat "$TMP/changes"

  : > "$TMP/apply"; : > "$TMP/conflicts"
  local status path rel live
  while IFS=$'\t' read -r status path; do
    [ -n "$path" ] || continue
    rel="${path#"${SUBDIR}"/}"
    live="${CONFIG_DIR}/${rel}"
    case "$status" in
      D*)
        [ -e "$live" ] || continue
        git -C "$WORK_DIR" show "${old}:${path}" > "$TMP/old" 2>/dev/null || : > "$TMP/old"
        if cmp -s "$TMP/old" "$live"; then printf 'D\t%s\n' "$rel" >> "$TMP/apply"
        else printf '%s (suppression)\n' "$rel" >> "$TMP/conflicts"; fi
        ;;
      *)
        git -C "$WORK_DIR" show "${new}:${path}" > "$TMP/new" 2>/dev/null || { fail "lecture ${new}:${path}"; return 1; }
        if [ -e "$live" ] && cmp -s "$TMP/new" "$live"; then continue; fi
        git -C "$WORK_DIR" show "${old}:${path}" > "$TMP/old" 2>/dev/null || : > "$TMP/old"
        if { [ ! -e "$live" ] && [ ! -s "$TMP/old" ]; } || { [ -e "$live" ] && cmp -s "$TMP/old" "$live"; }; then
          printf 'W\t%s\n' "$rel" >> "$TMP/apply"
        else
          printf '%s (modifiée en live)\n' "$rel" >> "$TMP/conflicts"
        fi
        ;;
    esac
  done < "$TMP/changes"

  local nb_apply nb_confl
  nb_apply="$(wc -l < "$TMP/apply" | tr -d ' ')"
  nb_confl="$(wc -l < "$TMP/conflicts" | tr -d ' ')"

  if [ "$nb_confl" -gt 0 ]; then
    bashio::log.warning "CONFLITS (${nb_confl}) — modifiés en live sans passer par git :"; cat "$TMP/conflicts"
    if [ "$ALLOW_PARTIAL" != "true" ]; then
      notify "⚠️ git-deployer suspendu (conflit)" "${nb_confl} fichier(s) modifié(s) en live non sauvegardés. Rien appliqué."
      return 0
    fi
    bashio::log.warning "allow_partial : on applique les ${nb_apply} sûrs, on ignore les conflits."
  fi
  if [ "$nb_apply" = 0 ]; then bashio::log.info "rien de sûr à appliquer."; return 0; fi

  bashio::log.info "à appliquer (${nb_apply}) :"; sed 's/^/  /' "$TMP/apply"
  if [ "$DRY_RUN" = "true" ]; then bashio::log.info "dry_run — rien écrit."; return 0; fi

  if [ "$BACKUP_BEFORE" = "true" ]; then
    bashio::log.info "backup HA avant écriture…"
    ha POST /services/hassio/backup_full "{\"name\":\"avant-git-deployer\"}" >/dev/null 2>&1 \
      || bashio::log.warning "backup non confirmé (on continue)"
  fi

  local BK="$TMP/rollback"; mkdir -p "$BK"; : > "$TMP/applied"
  local op
  while IFS=$'\t' read -r op rel; do
    [ -n "$rel" ] || continue
    live="${CONFIG_DIR}/${rel}"
    if [ -e "$live" ]; then mkdir -p "$BK/$(dirname "$rel")"; cp "$live" "$BK/$rel"; printf 'E\t%s\n' "$rel" >> "$TMP/applied"
    else printf 'N\t%s\n' "$rel" >> "$TMP/applied"; fi
    if [ "$op" = "D" ]; then rm -f "$live"; bashio::log.info "supprimé  $rel"
    else mkdir -p "${CONFIG_DIR}/$(dirname "$rel")"; git -C "$WORK_DIR" show "${new}:${SUBDIR}/${rel}" > "$live" || { fail "écriture $rel"; return 1; }; bashio::log.info "écrit     $rel"; fi
  done < "$TMP/apply"

  bashio::log.info "validation check_config…"
  local check result
  check="$(ha POST /config/core/check_config '{}' 2>/dev/null || printf '{"result":"error"}')"
  result="$(printf '%s' "$check" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')"
  if [ "$result" != "valid" ]; then
    bashio::log.error "check_config=${result:-inconnu} → ROLLBACK"
    local st
    while IFS=$'\t' read -r st rel; do
      [ -n "$rel" ] || continue; live="${CONFIG_DIR}/${rel}"
      if [ "$st" = "E" ]; then cp "$BK/$rel" "$live"; else rm -f "$live"; fi
    done < "$TMP/applied"
    fail "config invalide après déploiement — rollback effectué."
    return 1
  fi

  local reloaded=""
  if grep -qE $'\t(configuration\\.yaml|packages/)' "$TMP/apply"; then
    bashio::log.info "structurant → reload_core + reload_all"
    ha POST /services/homeassistant/reload_core_config '{}' >/dev/null 2>&1 || true
    ha POST /services/homeassistant/reload_all '{}' >/dev/null 2>&1 && reloaded="reload_all"
  else
    grep -q $'\tautomations\\.yaml' "$TMP/apply" && ha POST /services/automation/reload '{}' >/dev/null 2>&1 && reloaded="$reloaded automation" || true
    grep -q $'\tscripts\\.yaml' "$TMP/apply"     && ha POST /services/script/reload '{}' >/dev/null 2>&1 && reloaded="$reloaded script" || true
    grep -q $'\tscenes\\.yaml' "$TMP/apply"      && ha POST /services/scene/reload '{}' >/dev/null 2>&1 && reloaded="$reloaded scene" || true
    ha POST /services/homeassistant/reload_all '{}' >/dev/null 2>&1 && reloaded="$reloaded reload_all" || true
  fi

  local msg="Déployé ${nb_apply} fichier(s) depuis ${BRANCH} (${new:0:8}). Rechargé:${reloaded:- (aucun)}."
  bashio::log.info "OK — $msg"
  notify "🟢 git-deployer — déployé" "$msg"
  return 0
}

# --- préflight ---
bashio::config.require 'repository.url'
if ! bashio::config.has_value 'repository.password'; then
  bashio::exit.nok "repository.password manquant (PAT GitHub lecture du dépôt privé)"
fi

bashio::log.info "git-deployer — dépôt=${REPO_URL} branche=${BRANCH} sous-dossier=${SUBDIR}"

if [ "${INTERVAL:-0}" -gt 0 ]; then
  bashio::log.info "mode boucle : une passe toutes les ${INTERVAL}s"
  while true; do
    deploy_once || bashio::log.warning "passe en échec — on continue"
    sleep "${INTERVAL}"
  done
else
  deploy_once
fi
