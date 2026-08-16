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
# Entité HA où publier le SHA déployé (lue par git-exporter skip_when_deploy_pending).
# Doit correspondre à repository.deployed_sha_entity côté exporter (même défaut).
DEPLOYED_SHA_ENTITY="${DEPLOYED_SHA_ENTITY:-input_text.ha_deployed_sha}"
# Entité HEARTBEAT — époch (secondes) réécrit à CHAQUE passe saine (fetch OK), qu'il y
# ait déploiement réel OU non. deployed_sha ne convient PAS comme signal de vivacité :
# quand rien ne change, le deployer republie le MÊME SHA et input_text.set_value avec une
# valeur identique NE rafraîchit ni last_updated ni last_reported (vérifié 2026-08-13) →
# un watchdog basé sur son âge criait « silencieux » alors que la boucle tournait (faux
# positif à chaque période >45 min sans déploiement, cas nominal). L'époch change à chaque
# passe → l'état bouge → le watchdog peut mesurer un vrai âge « dernière passe saine ».
HEARTBEAT_ENTITY="${HEARTBEAT_ENTITY:-input_text.git_deployer_heartbeat}"

TMP="${TMP:-/tmp/git-deployer}"
BK="$TMP/rollback"

# Profondeur de recherche « ce contenu live vient-il d'un commit connu ? » (cf.
# find_known_commit). 200 commits couvrent largement l'historique qu'un /config peut
# retarder — au-delà, c'est que le déployeur est arrêté depuis des semaines et le
# diagnostic « modifié en live » redevient l'hypothèse honnête.
KNOWN_DEPTH=200

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

# core_ready — l'API Core répond-elle ? `GET /` renvoie {"message":"API running."}
# dès que Core sert des requêtes. Sonde bon marché, sans effet de bord.
core_ready() { ha GET / >/dev/null 2>&1; }

# wait_core_ready TRIES DELAY — attend que Core réponde. Une passe entière est
# INUTILISABLE quand Core redémarre : on ne peut ni lire la base (deployed_sha),
# ni valider (check_config), ni recharger. Pire, chacune de ces lectures échoue en
# SILENCE et la passe part sur des valeurs de repli fausses.
#
# Vécu 2026-08-16 à 00h14 puis 00h18 (deux passes consécutives, pendant un
# redémarrage de Core) : heartbeat non publié → base illisible → repli sur le HEAD
# d'avant-fetch (la base empoisonnée qu'alpha.9 venait justement d'éliminer) →
# 3 fichiers écrits → check_config injoignable, échec en 0 s (une vraie validation
# prend ~60 s) → ROLLBACK. Deux ROLLBACK sans le moindre YAML invalide : le
# `check_config` manuel rejoué à 00h20 répond `valid`. Coût : une fausse alerte au
# watchdog (il déclenche sur ROLLBACK à 15 min) et un risque de perte silencieuse
# par la base de repli.
#
# Donc : pas de Core, pas de passe. On saute proprement plutôt que d'en faire une
# mauvaise. 20 essais × 15 s = 5 min de patience, très au-delà des ~3 min que met
# un redémarrage de Core sur Yellow, et bien en deçà de l'intervalle de 900 s.
wait_core_ready() {
  local tries="${1:-20}" delay="${2:-15}" n=1
  while ! core_ready; do
    if [ "$n" -ge "$tries" ]; then return 1; fi
    [ "$n" = 1 ] && bashio::log.warning "Core injoignable — attente (redémarrage en cours ?)"
    sleep "$delay"; n=$(( n + 1 ))
  done
  [ "$n" = 1 ] || bashio::log.info "Core de nouveau joignable après $(( (n - 1) * delay ))s"
  return 0
}

notify() { # notify TITLE MESSAGE
  local b
  b=$(printf '{"title":"%s","message":"%s","notification_id":"git_deployer"}' \
        "$(jesc "$1")" "$(jesc "$2")")
  ha POST /services/persistent_notification/create "$b" >/dev/null 2>&1 || true
}

fail() { bashio::log.error "$1"; notify "🔴 git-deployer — échec" "$1"; return 1; }

# notify_clear — retire la notif d'échec dès qu'une passe redevient saine. Sans ça,
# un hoquet réseau transitoire (DNS de la box qui rate ponctuellement la résolution
# de github.com → « Could not resolve host ») laissait une notif 🔴 collée alors que
# la passe suivante repassait verte 15 min plus tard : fausse alerte persistante.
notify_clear() {
  ha POST /services/persistent_notification/dismiss \
     '{"notification_id":"git_deployer"}' >/dev/null 2>&1 || true
}

# git_retry TRIES -- <args git…> — réessaie une commande git transitoirement
# faillible (réseau/DNS) avant d'abandonner. Cause concrète observée : le plugin DNS
# du Superviseur n'a pas d'upstream explicite et dépend de la box (192.168.1.1), qui
# rate parfois la résolution de github.com. Un seul essai suffisait alors à déclencher
# une notif alarmante, alors que la connectivité revenait aussitôt. Backoff court :
# 3 tentatives, 10s puis 20s entre les essais.
git_retry() {
  local tries="$1"; shift
  local n=1 delay
  while true; do
    if git "$@"; then return 0; fi
    if [ "$n" -ge "$tries" ]; then return 1; fi
    delay=$(( n * 10 ))
    bashio::log.warning "git échec transitoire (tentative ${n}/${tries}) — réessai dans ${delay}s"
    sleep "$delay"
    n=$(( n + 1 ))
  done
}

# publish_deployed_sha SHA — publie le SHA avec lequel /config est désormais cohérent
# dans une entité HA. Lu par git-exporter (skip_when_deploy_pending) pour NE PAS
# snapshoter un /config d'avant-déploiement → supprime la course exporter/deployer.
# À appeler à CHAQUE état cohérent (déployé OU déjà à jour), jamais tant qu'un conflit
# reste non résolu. Best-effort — n'échoue jamais le déploiement. Voir le repo
# consommateur ha-vallesvilles-family : docs/design/deploy-snapshot-race.md.
publish_deployed_sha() {
  if ha POST /services/input_text/set_value \
       "{\"entity_id\":\"${DEPLOYED_SHA_ENTITY}\",\"value\":\"$1\"}" >/dev/null 2>&1; then
    bashio::log.info "deployed_sha publié : ${1:0:8}"
  else
    bashio::log.warning "deployed_sha non publié (déploiement OK malgré tout)"
  fi
}

# resolve_base FALLBACK — renvoie le SHA que /config contient RÉELLEMENT, à utiliser
# comme base du diff `old..new` et de la garde anti-écrasement.
#
# La base doit être le dernier SHA effectivement APPLIQUÉ, jamais le dernier SHA
# FETCHÉ. Les deux divergent dès qu'une passe n'applique rien (conflit, dry_run,
# échec après reset) : `git reset --hard` avance le clone de travail quoi qu'il
# arrive, donc « HEAD d'avant-fetch » surestime ce que /config contient.
#
# Deux dégâts observés en production (ha-vallesvilles-family, 2026-08-08 → 08-15,
# 7 jours de gel) :
#   1. perte silencieuse — les fichiers d'une passe en CONFLIT sortaient du diff de
#      la passe suivante (leur cible était devenue la base) et n'étaient PLUS JAMAIS
#      déployés, sans qu'aucune erreur ne le signale ;
#   2. conflit fantôme auto-entretenu — `old:<fichier>` ne correspondant plus au live,
#      la garde criait « modifiée en live » sur des fichiers que personne n'avait
#      touchés, à chaque passe, indéfiniment.
#
# deployed_sha n'est publié que sur un état /config cohérent : c'est la seule base
# fiable, et elle est déjà écrite par cet addon. Repli sur FALLBACK (l'ancien
# comportement) si l'entité répond mais ne porte pas de SHA (amorçage : entité
# fraîchement créée, jamais renseignée) ou pointe un commit absent du clone.
#
# En revanche, quand c'est l'API Core elle-même qui ne répond pas, le repli est un
# PIÈGE : il fabrique une base fausse à partir d'un simple hoquet réseau, et c'est
# exactement le mécanisme de perte silencieuse décrit ci-dessus. Ce cas rend 2 —
# l'appelant abandonne la passe, sans rien écrire. Vécu 2026-08-16 (cf. wait_core_ready).
resolve_base() {
  local fallback="$1" sha raw
  if ! raw="$(ha GET "/states/${DEPLOYED_SHA_ENTITY}" 2>/dev/null)"; then
    bashio::log.warning "base : API Core injoignable pour lire ${DEPLOYED_SHA_ENTITY} → passe abandonnée (pas de repli : il produirait une base fausse)"
    return 2
  fi
  sha="$(printf '%s' "$raw" \
         | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]\{7,40\}\)".*/\1/p')"
  if [ -z "$sha" ]; then
    bashio::log.warning "base : ${DEPLOYED_SHA_ENTITY} lisible mais sans SHA (amorçage ?) → repli sur HEAD d'avant-fetch (${fallback:0:8})"
    printf '%s' "$fallback"; return 0
  fi
  if ! git -C "$WORK_DIR" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    bashio::log.warning "base : deployed_sha ${sha:0:8} absent du clone (branche réécrite ?) → repli sur HEAD d'avant-fetch (${fallback:0:8})"
    printf '%s' "$fallback"; return 0
  fi
  if [ "$sha" != "$fallback" ]; then
    bashio::log.info "base : deployed_sha ${sha:0:8} (HEAD d'avant-fetch ${fallback:0:8} — passe(s) précédente(s) sans application)"
  fi
  printf '%s' "$sha"
}

# publish_heartbeat — écrit l'époch courant dans HEARTBEAT_ENTITY. Appelé à CHAQUE passe
# dès que le fetch a réussi (avant toute décision déployer/déjà-à-jour/conflit) : c'est le
# signal « la boucle vit et joint bien github ». La valeur change à chaque passe → l'état
# bouge → un watchdog peut mesurer l'âge réel de la dernière passe saine (voir la note sur
# HEARTBEAT_ENTITY plus haut : deployed_sha, republié identique, ne rafraîchit aucun
# timestamp). Best-effort — n'échoue jamais le déploiement.
publish_heartbeat() {
  local now; now="$(date -u +%s 2>/dev/null || echo 0)"
  ha POST /services/input_text/set_value \
     "{\"entity_id\":\"${HEARTBEAT_ENTITY}\",\"value\":\"${now}\"}" >/dev/null 2>&1 \
     || bashio::log.warning "heartbeat non publié (${HEARTBEAT_ENTITY} absent ?)"
}

# yaml_dq VALUE — émet un scalaire YAML DOUBLE-QUOTÉ correctement échappé.
# Indispensable pour `detail:` : sa valeur contient parfois un « : » littéral
# (ex. « Rechargé: automation reload_all ») qui, non quoté, est lu comme un mapping
# imbriqué → YAML invalide (« mapping values are not allowed here ») → yaml.safe_load
# échoue pour tout consommateur et yamllint casse le CI côté ha-vallesvilles-family.
# Échappe backslash PUIS guillemet (l'ordre compte). Cf docs/ops/deploy-status.md.
yaml_dq() {
  local s="${1:-}"
  s="${s//\\/\\\\}"   # \ -> \\
  s="${s//\"/\\\"}"   # " -> \"
  printf '"%s"' "$s"
}

# write_status RESULT SHA DETAIL — compte-rendu du dernier déploiement, lisible depuis
# git SANS accès HA : écrit sous <config>/.deploy/last-run.yaml, donc snapshoté par
# git-exporter au cycle suivant. Jamais redéployé (filtré dans la boucle d'application).
# Best-effort. RESULT ∈ OK | CONFLICT | ROLLBACK | RETRY (Core injoignable pendant la
# validation : rien de prouvé, fichiers remis en état, on retente — pas une anomalie de
# config, donc volontairement hors du déclencheur du watchdog). Voir ha-vallesvilles-family :
# docs/ops/deploy-status.md. Valeurs quotées (yaml_dq) pour garantir un YAML valide.
write_status() {
  local dir="${CONFIG_DIR}/.deploy"
  mkdir -p "$dir" 2>/dev/null || return 0
  {
    printf 'timestamp: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%H:%M:%S')"
    printf 'result: %s\n'    "$(yaml_dq "$1")"
    printf 'sha: %s\n'       "$(yaml_dq "${2:-}")"
    printf 'detail: %s\n'    "$(yaml_dq "${3:-}")"
  } > "$dir/last-run.yaml" 2>/dev/null || true
}

# find_known_commit TIP PATH LIVE — le contenu live de PATH est-il, octet pour octet, la
# version de PATH d'un commit atteignable depuis TIP ? Renvoie ce commit, ou rien.
#
# C'est le test qui sépare deux causes que la garde anti-écrasement confondait sous le
# même verdict « modifié en live » :
#   - une VRAIE édition humaine (File editor, UI) → contenu que git n'a jamais vu → refus,
#     c'est tout l'intérêt de la garde : ne pas écraser un travail non sauvegardé ;
#   - une PASSE INTERROMPUE du déployeur → contenu qui est exactement un état de git, juste
#     pas celui attendu. Personne n'a rien tapé, il n'y a rien à protéger, et refuser
#     d'appliquer fige la chaîne jusqu'à une intervention manuelle.
#
# Vécu le 2026-08-16 : `automations.yaml` et `template.yaml` se sont retrouvés chacun sur un
# commit DIFFÉRENT (l'un avec la PR #274 et pas la #275, l'autre l'inverse), le déployeur a
# crié « modifiés en live », et la chaîne est restée bloquée jusqu'à une restauration à la
# main par scp. Aucun humain n'avait touché ces fichiers — l'auteur était le déployeur.
#
# Une seule invocation de git par fichier : `rev-list` donne les commits, `cat-file
# --batch-check` résout les <commit>:<path> d'un coup, awk apparie les deux listes ligne à
# ligne (l'ordre est conservé). Sur une ligne trouvée $1 est le SHA du blob, sur une ligne
# absente c'est « <rev>:<path> » suivi de « missing » — la comparaison au hash ne peut donc
# pas se tromper de colonne.
find_known_commit() {
  local tip="$1" path="$2" live="$3" h
  h="$(git -C "$WORK_DIR" hash-object "$live" 2>/dev/null)" || return 1
  [ -n "$h" ] || return 1
  git -C "$WORK_DIR" rev-list -n "$KNOWN_DEPTH" "$tip" > "$TMP/revs" 2>/dev/null || return 1
  sed "s|\$|:${path}|" "$TMP/revs" \
    | git -C "$WORK_DIR" cat-file --batch-check 2>/dev/null \
    | awk -v h="$h" 'NR==FNR { c[FNR]=$0; next } $1==h { print c[FNR]; exit }' "$TMP/revs" -
}

# restore_applied — remet /config exactement dans l'état d'avant la boucle d'écriture, à
# partir de $TMP/applied (E = le fichier existait, sa copie est dans $BK ; N = il n'existait
# pas, on le retire). Idempotent, sûr si la boucle n'a rien écrit.
#
# Extrait des trois copies qui traînaient (échec de check_config, Core injoignable, signal) :
# une seule définition, donc un seul endroit où se tromper.
restore_applied() {
  local st rel live
  [ -s "$TMP/applied" ] || return 0
  while IFS=$'\t' read -r st rel; do
    [ -n "$rel" ] || continue
    live="${CONFIG_DIR}/${rel}"
    if [ "$st" = "E" ]; then cp "$BK/$rel" "$live"; else rm -f "$live"; fi
  done < "$TMP/applied"
}

# APPLY_IN_PROGRESS — vaut 1 uniquement pendant la fenêtre où /config est mi-ancien
# mi-nouveau : de la première écriture jusqu'à la décision garder/annuler. Un arrêt de
# l'add-on (Superviseur, redémarrage HA, mise à jour, OOM) pendant cette fenêtre laissait
# /config dans un état qui n'est celui d'AUCUN commit — l'état exact constaté le 2026-08-16,
# que la passe suivante interprétait ensuite comme une édition humaine.
APPLY_IN_PROGRESS=0
on_signal() {
  if [ "$APPLY_IN_PROGRESS" = 1 ]; then
    bashio::log.warning "arrêt demandé pendant l'écriture — remise en état de /config avant de sortir"
    restore_applied
    write_status ROLLBACK "" "passe interrompue par un arrêt de l'add-on — fichiers remis en état"
  fi
  exit 143
}
trap on_signal TERM INT

deploy_once() {
  rm -rf "$TMP"; mkdir -p "$TMP"

  # Rien ne se fait sans Core : lecture de la base, validation et reload passent tous
  # par son API. Une passe menée sans lui écrit des fichiers qu'elle ne sait ni choisir
  # ni valider (cf. wait_core_ready). On saute la passe — la suivante arrive dans 900 s.
  if ! wait_core_ready; then
    bashio::log.warning "Core toujours injoignable après 5 min — passe sautée (aucune écriture). Nouvelle tentative à la passe suivante."
    return 0
  fi

  local auth_url first_run=0 old new
  auth_url="$(printf '%s' "$REPO_URL" | sed "s#https://#https://${GIT_USER}:${GIT_PASS}@#")"

  if [ -d "$WORK_DIR/.git" ]; then
    bashio::log.info "fetch ${BRANCH}…"
    git -C "$WORK_DIR" remote set-url origin "$auth_url"
    old="$(git -C "$WORK_DIR" rev-parse HEAD)"
    git_retry 3 -C "$WORK_DIR" fetch --quiet origin "$BRANCH" || { fail "git fetch a échoué (3 tentatives — réseau/DNS ?)"; return 1; }
    git -C "$WORK_DIR" reset --hard --quiet "origin/${BRANCH}" || { fail "git reset a échoué"; return 1; }
  else
    bashio::log.info "clone initial…"
    git_retry 3 clone --quiet --branch "$BRANCH" "$auth_url" "$WORK_DIR" || { fail "git clone a échoué (3 tentatives — réseau/DNS ?)"; return 1; }
    old=""; first_run=1
  fi
  git -C "$WORK_DIR" remote set-url origin "$REPO_URL"   # ne pas laisser le token dans .git/config
  new="$(git -C "$WORK_DIR" rev-parse HEAD)"
  notify_clear      # connectivité git OK → efface toute notif d'échec d'une passe antérieure
  publish_heartbeat # passe saine (fetch OK) → rafraîchit le signal de vivacité lu par le watchdog

  # Base = ce que /config contient vraiment (deployed_sha), pas ce qu'on vient de
  # fetcher : le reset --hard ci-dessus a déjà avancé le clone, y compris quand la
  # passe précédente n'a rien appliqué. Voir resolve_base.
  if [ "$first_run" != 1 ]; then
    if ! old="$(resolve_base "$old")"; then
      bashio::log.warning "passe abandonnée — base indéterminable (Core injoignable). Aucune écriture, on retente à la passe suivante."
      return 0
    fi
  fi

  if [ "$first_run" = 1 ]; then
    bashio::log.warning "PREMIER RUN — clone prêt, aucune application (pas de base de comparaison). Les prochains runs seront incrémentaux."
    notify "ℹ️ git-deployer — premier run" "Clone initialisé. Les prochaines passes appliqueront main de façon incrémentale et sûre."
    return 0
  fi
  if [ "$old" = "$new" ]; then
    bashio::log.info "déjà à jour (${new:0:8}) — rien à déployer."
    publish_deployed_sha "$new"          # /config déjà cohérent avec new
    return 0
  fi

  # --no-renames : un renommage devient delete+add (2 champs chacun), sinon la
  # ligne "R100<TAB>ancien<TAB>nouveau" casserait le parseur (status/path).
  git -C "$WORK_DIR" diff --no-renames --name-status "$old" "$new" -- "${SUBDIR}/" > "$TMP/changes" || { fail "git diff a échoué"; return 1; }
  if [ ! -s "$TMP/changes" ]; then
    bashio::log.info "aucun changement sous ${SUBDIR}/ — rien à déployer."
    publish_deployed_sha "$new"          # ${SUBDIR}/ inchangé → /config cohérent avec new
    return 0
  fi
  bashio::log.info "changements détectés :"; cat "$TMP/changes"

  : > "$TMP/apply"; : > "$TMP/conflicts"; : > "$TMP/reprises"
  local status path rel live known
  while IFS=$'\t' read -r status path; do
    [ -n "$path" ] || continue
    rel="${path#"${SUBDIR}"/}"
    # .deploy/* = compte-rendu deploy (snapshoté, jamais redéployé). .ha_run.lock +
    # .HA_VERSION = fichiers runtime écrits par HA (verrou de démarrage pid/start_ts,
    # version HA) — jamais de la config à déployer, et .ha_run.lock change à CHAQUE
    # redémarrage. logs/* = journaux applicatifs runtime (ex. logs/notifications.jsonl),
    # désindexés de git côté ha-vallesvilles-family le 2026-08-07 : réécrits en continu
    # par HA. Les sauter évite (a) d'écraser un fichier runtime live et (b) un CONFLIT
    # « suppression » tout-ou-rien quand ils sont retirés de git (leur version live
    # diffère toujours de la version git figée → sinon re-blocage du déploiement).
    case "$rel" in .deploy/*|.ha_run.lock|.HA_VERSION|logs/*) continue ;; esac
    live="${CONFIG_DIR}/${rel}"
    case "$status" in
      D*)
        [ -e "$live" ] || continue
        git -C "$WORK_DIR" show "${old}:${path}" > "$TMP/old" 2>/dev/null || : > "$TMP/old"
        if cmp -s "$TMP/old" "$live"; then printf 'D\t%s\n' "$rel" >> "$TMP/apply"
        elif known="$(find_known_commit "$new" "$path" "$live")" && [ -n "$known" ]; then
          printf 'D\t%s\n' "$rel" >> "$TMP/apply"
          printf '%s (contenu de %s — passe interrompue)\n' "$rel" "${known:0:8}" >> "$TMP/reprises"
        else printf '%s (suppression)\n' "$rel" >> "$TMP/conflicts"; fi
        ;;
      *)
        git -C "$WORK_DIR" show "${new}:${path}" > "$TMP/new" 2>/dev/null || { fail "lecture ${new}:${path}"; return 1; }
        if [ -e "$live" ] && cmp -s "$TMP/new" "$live"; then continue; fi
        git -C "$WORK_DIR" show "${old}:${path}" > "$TMP/old" 2>/dev/null || : > "$TMP/old"
        if { [ ! -e "$live" ] && [ ! -s "$TMP/old" ]; } || { [ -e "$live" ] && cmp -s "$TMP/old" "$live"; }; then
          printf 'W\t%s\n' "$rel" >> "$TMP/apply"
        elif [ -e "$live" ] && known="$(find_known_commit "$new" "$path" "$live")" && [ -n "$known" ]; then
          # Le live ne correspond ni à `old` ni à `new`, mais c'est mot pour mot un état de
          # git : passe interrompue, pas édition humaine. Rien à protéger — on applique et
          # on le DIT, au lieu d'accuser un humain et de figer la chaîne (cf.
          # find_known_commit). L'écrasement est sans perte : le contenu remplacé est
          # récupérable par son commit, nommé ci-dessous.
          printf 'W\t%s\n' "$rel" >> "$TMP/apply"
          printf '%s (contenu de %s — passe interrompue)\n' "$rel" "${known:0:8}" >> "$TMP/reprises"
        else
          printf '%s (modifiée en live)\n' "$rel" >> "$TMP/conflicts"
        fi
        ;;
    esac
  done < "$TMP/changes"

  local nb_apply nb_confl nb_repr
  nb_apply="$(wc -l < "$TMP/apply" | tr -d ' ')"
  nb_confl="$(wc -l < "$TMP/conflicts" | tr -d ' ')"
  nb_repr="$(wc -l < "$TMP/reprises" | tr -d ' ')"

  if [ "$nb_repr" -gt 0 ]; then
    bashio::log.warning "REPRISE (${nb_repr}) — contenu live issu d'un autre commit, pas d'une édition humaine : une passe précédente s'est interrompue. On réapplique."
    cat "$TMP/reprises"
  fi

  if [ "$nb_confl" -gt 0 ]; then
    bashio::log.warning "CONFLITS (${nb_confl}) — modifiés en live sans passer par git :"; cat "$TMP/conflicts"
    if [ "$ALLOW_PARTIAL" != "true" ]; then
      notify "⚠️ git-deployer suspendu (conflit)" "${nb_confl} fichier(s) modifié(s) en live non sauvegardés. Rien appliqué."
      write_status CONFLICT "$new" "${nb_confl} fichier(s) modifié(s) en live — rien appliqué"
      return 0
    fi
    bashio::log.warning "allow_partial : on applique les ${nb_apply} sûrs, on ignore les conflits."
  fi
  if [ "$nb_apply" = 0 ]; then
    bashio::log.info "rien de sûr à appliquer."
    # Sans conflit, tout était déjà appliqué → /config cohérent avec new.
    if [ "$nb_confl" = 0 ]; then publish_deployed_sha "$new"; fi
    return 0
  fi

  bashio::log.info "à appliquer (${nb_apply}) :"; sed 's/^/  /' "$TMP/apply"
  if [ "$DRY_RUN" = "true" ]; then bashio::log.info "dry_run — rien écrit."; return 0; fi

  if [ "$BACKUP_BEFORE" = "true" ]; then
    bashio::log.info "backup HA avant écriture…"
    ha POST /services/hassio/backup_full "{\"name\":\"avant-git-deployer\"}" >/dev/null 2>&1 \
      || bashio::log.warning "backup non confirmé (on continue)"
  fi

  mkdir -p "$BK"; : > "$TMP/applied"
  # À partir d'ici et jusqu'à la décision garder/annuler, /config est mi-ancien mi-nouveau :
  # toute sortie doit passer par restore_applied (échec d'écriture, signal, check_config).
  APPLY_IN_PROGRESS=1
  local op stage
  while IFS=$'\t' read -r op rel; do
    [ -n "$rel" ] || continue
    live="${CONFIG_DIR}/${rel}"
    if [ -e "$live" ]; then mkdir -p "$BK/$(dirname "$rel")"; cp "$live" "$BK/$rel"; printf 'E\t%s\n' "$rel" >> "$TMP/applied"
    else printf 'N\t%s\n' "$rel" >> "$TMP/applied"; fi
    if [ "$op" = "D" ]; then rm -f "$live"; bashio::log.info "supprimé  $rel"
    else
      mkdir -p "${CONFIG_DIR}/$(dirname "$rel")"
      # Écrire à côté puis renommer : un `> "$live"` direct tronque la cible AVANT que git
      # ait produit un octet, donc un échec (ou un arrêt) laisse HA avec un fichier vide,
      # état qui n'est celui d'aucun commit. Le fichier d'appoint est sur le MÊME système de
      # fichiers que la cible — condition pour que `mv` soit un renommage atomique et non
      # une copie ; c'est pourquoi il n'est pas dans $TMP (/tmp est un autre volume).
      stage="${live}.git-deployer.tmp"
      if ! git -C "$WORK_DIR" show "${new}:${SUBDIR}/${rel}" > "$stage" 2>/dev/null || ! mv -f "$stage" "$live"; then
        rm -f "$stage"
        bashio::log.error "écriture ${rel} en échec — annulation de la passe entière"
        restore_applied
        APPLY_IN_PROGRESS=0
        write_status ROLLBACK "$new" "écriture de ${rel} impossible — passe annulée, fichiers remis en état"
        fail "écriture ${rel} impossible — passe annulée, ${CONFIG_DIR} remis dans son état d'avant."
        return 1
      fi
      bashio::log.info "écrit     $rel"
    fi
  done < "$TMP/apply"

  # Deux échecs très différents se cachaient derrière un seul ROLLBACK :
  #   (a) Core répond « invalid » → le YAML déployé est réellement cassé. Alerte méritée.
  #   (b) Core ne répond pas du tout → on ne sait RIEN de la validité. L'ancien code
  #       repliait sur {"result":"error"} et criait « config invalide », ce qui est un
  #       mensonge : les deux ROLLBACK du 2026-08-16 (00h14, 00h18) portaient sur une
  #       config que check_config a déclarée `valid` deux minutes plus tard.
  # Le cas (b) se retente : 3 essais espacés, puis remise en état + statut RETRY, qui
  # ne réveille pas le watchdog (il ne déclenche que sur CONFLICT/ROLLBACK). La passe
  # suivante réappliquera, Core revenu.
  bashio::log.info "validation check_config…"
  local check result n=1
  while :; do
    if check="$(ha POST /config/core/check_config '{}' 2>/dev/null)"; then break; fi
    if [ "$n" -ge 3 ]; then check=""; break; fi
    bashio::log.warning "check_config injoignable (tentative ${n}/3) — Core redémarre ? réessai dans 20s"
    sleep 20; n=$(( n + 1 ))
  done

  if [ -z "$check" ]; then
    bashio::log.warning "check_config injoignable après 3 tentatives → remise en état (rien de prouvé sur la validité)"
    restore_applied
    APPLY_IN_PROGRESS=0
    write_status RETRY "$new" "Core injoignable — validation impossible, fichiers remis en état, retente à la passe suivante"
    return 0
  fi

  result="$(printf '%s' "$check" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')"
  if [ "$result" != "valid" ]; then
    bashio::log.error "check_config=${result:-inconnu} → ROLLBACK"
    restore_applied
    APPLY_IN_PROGRESS=0
    write_status ROLLBACK "$new" "config invalide après déploiement — rollback effectué"
    fail "config invalide après déploiement — rollback effectué."
    return 1
  fi
  # /config est cohérent avec `new` et validé : plus rien à annuler.
  APPLY_IN_PROGRESS=0

  # Ce qu'on va recharger, décidé AVANT de le faire — le compte-rendu doit être écrit
  # d'abord (voir juste en dessous).
  local structural=0 reload_plan=""
  if grep -qE $'\t(configuration\\.yaml|packages/)' "$TMP/apply"; then
    structural=1; reload_plan="reload_core reload_all"
  else
    if grep -q $'\tautomations\\.yaml' "$TMP/apply"; then reload_plan="${reload_plan} automation"; fi
    if grep -q $'\tscripts\\.yaml'     "$TMP/apply"; then reload_plan="${reload_plan} script"; fi
    if grep -q $'\tscenes\\.yaml'      "$TMP/apply"; then reload_plan="${reload_plan} scene"; fi
    reload_plan="${reload_plan} reload_all"
  fi

  local msg="Déployé ${nb_apply} fichier(s) depuis ${BRANCH} (${new:0:8}). Rechargé:${reload_plan}."
  if [ "$nb_repr" -gt 0 ]; then msg="${msg} Dont ${nb_repr} repris après passe interrompue."; fi
  bashio::log.info "OK — $msg"

  # ⚠️ Ordre volontaire : marqueur + compte-rendu AVANT les reloads.
  #
  # `reload_all` recharge l'intégration command_line, donc le capteur qui lit
  # .deploy/last-run.yaml (sensor.deploiement_ha_dernier_resultat côté
  # ha-vallesvilles-family). Écrire le compte-rendu APRÈS le reload lui faisait relire
  # l'ANCIEN résultat, puis attendre son `scan_interval` (5 min) pour voir le bon. Mesuré le
  # 2026-08-16 : passe OK à 14:08:10, capteur encore CONFLICT jusqu'à 14:12:57 — largement
  # assez pour croire qu'une réparation qui venait de réussir avait échoué, et repartir en
  # diagnostic. En écrivant d'abord, le reload publie lui-même le bon état, en quelques
  # secondes au lieu de cinq minutes.
  publish_deployed_sha "$new"
  write_status OK "$new" "$msg"

  if [ "$structural" = 1 ]; then
    bashio::log.info "structurant → reload_core + reload_all"
    ha POST /services/homeassistant/reload_core_config '{}' >/dev/null 2>&1 || true
  else
    case "$reload_plan" in *automation*) ha POST /services/automation/reload '{}' >/dev/null 2>&1 || true ;; esac
    case "$reload_plan" in *script*)     ha POST /services/script/reload '{}'     >/dev/null 2>&1 || true ;; esac
    case "$reload_plan" in *scene*)      ha POST /services/scene/reload '{}'      >/dev/null 2>&1 || true ;; esac
  fi
  ha POST /services/homeassistant/reload_all '{}' >/dev/null 2>&1 || true

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
