#!/usr/bin/env bash
# Garde-fou : le mot de passe du dépôt peut vivre dans /config/secrets.yaml au lieu
# des options de l'add-on, via une indirection « !secret <clé> ».
#
# Pourquoi ce test existe. Les options du Superviseur sont stockées en clair et
# ressortent en clair à toute interrogation de l'API — le type `password:` du schéma
# ne masque que l'interface. Le 2026-08-16, une simple lecture des options a recopié
# le PAT GitHub dans un transcript, et il a fallu le révoquer. `resolve_secret` est la
# parade : l'option ne contient plus que le NOM d'une clé, la valeur reste dans
# secrets.yaml, que l'API n'expose pas.
#
# Quatre propriétés valent d'être verrouillées, parce que les rater se paie cher :
#
#   1. RÉTRO-COMPATIBILITÉ — une valeur sans préfixe passe telle quelle. C'est ce qui
#      permet de déployer cette version AVANT de changer l'option ; l'ordre inverse
#      casserait la boucle de déploiement, et c'est l'add-on qui déploie.
#   2. LA VALEUR NE FUIT PAS — aucune sortie de diagnostic ne doit contenir le secret,
#      pas même un message d'erreur. Sinon on a déplacé la fuite, pas supprimée.
#   3. L'ERREUR NOMME LA CLÉ MANQUANTE — sans ça, une faute de frappe dans le nom et
#      un jeton révoqué produisent le même « 401 » indéchiffrable.
#   4. LE PARSING TIENT — guillemets, commentaire de fin de ligne, clé indentée : une
#      valeur mal découpée donne un jeton silencieusement faux, donc une panne
#      d'authentification qu'on ira chercher du mauvais côté.
#
# La fonction est extraite de run.sh et exécutée seule, avec un faux bashio : aucun
# Superviseur requis. Lancer : bash tests/test_secret_indirection.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_SH="${RUN_SH_UNDER_TEST:-$REPO_ROOT/git-deployer/root/run.sh}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail=0
ok()    { printf '  ✅ %s\n' "$1"; }
ko()    { printf '  ❌ %s\n' "$1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (attendu «$3», obtenu «$2»)"; fi; }

# --- la vraie fonction, extraite de run.sh -----------------------------------
sed -n '/^resolve_secret() {/,/^}/p' "$RUN_SH" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || { printf '❌ resolve_secret introuvable dans %s\n' "$RUN_SH"; exit 1; }

# --- faux bashio : les journaux vont sur STDERR, comme le vrai (fd préservé), pour
# ne pas se coller au secret rendu sur STDOUT — c'est justement ce que le test 2
# vérifie, il ne doit pas être faussé par le harnais lui-même.
bashio::log.error() { printf 'ERROR: %s\n' "$*" >&2; }
bashio::exit.nok()  { bashio::log.error "$@"; exit 1; }

SECRETS_FILE="$T/secrets.yaml"
# shellcheck disable=SC1091
. "$T/fn.sh"

cat > "$SECRETS_FILE" <<'EOF'
# commentaire de tête
github_pat_deployer: github_pat_11ABCDEF_nue
quoted_double: "github_pat_11ABCDEF_double"
quoted_simple: 'github_pat_11ABCDEF_simple'
avec_commentaire: github_pat_11ABCDEF_cmt  # expire le 2026-11-14
diese_colle: jeton#interne
avec_deux_points: https://exemple.test/chemin
espaces_autour:      github_pat_11ABCDEF_pad
vide:
imbrique:
  interne: valeur_indentee
EOF

# 1. Rétro-compatibilité : sans préfixe, la valeur passe telle quelle.
check "valeur nue rendue inchangée" \
  "$(resolve_secret 'github_pat_litteral' 'repository.password')" 'github_pat_litteral'
check "valeur vide rendue inchangée" \
  "$(resolve_secret '' 'repository.password')" ''
check "« !secretquelquechose » n'est PAS une indirection (préfixe = « !secret » + espace)" \
  "$(resolve_secret '!secretfoo' 'repository.password')" '!secretfoo'

# 2. Résolution nominale + variantes de parsing.
check "clé simple"                 "$(resolve_secret '!secret github_pat_deployer' 'p')" 'github_pat_11ABCDEF_nue'
check "guillemets doubles retirés" "$(resolve_secret '!secret quoted_double' 'p')"       'github_pat_11ABCDEF_double'
check "guillemets simples retirés" "$(resolve_secret '!secret quoted_simple' 'p')"       'github_pat_11ABCDEF_simple'
check "commentaire de fin de ligne retiré" \
  "$(resolve_secret '!secret avec_commentaire' 'p')" 'github_pat_11ABCDEF_cmt'
check "« # » collé au texte gardé (YAML exige une espace avant un commentaire)" \
  "$(resolve_secret '!secret diese_colle' 'p')" 'jeton#interne'
check "valeur contenant « : » gardée entière" \
  "$(resolve_secret '!secret avec_deux_points' 'p')" 'https://exemple.test/chemin'
check "espaces autour de la valeur retirés" \
  "$(resolve_secret '!secret espaces_autour' 'p')" 'github_pat_11ABCDEF_pad'
check "espaces autour du NOM de clé tolérés" \
  "$(resolve_secret '!secret   github_pat_deployer  ' 'p')" 'github_pat_11ABCDEF_nue'

# 3. Le secret ne part JAMAIS ailleurs que sur stdout (le canal de retour).
out="$(resolve_secret '!secret github_pat_deployer' 'repository.password' 2>"$T/err")"
check "résolution silencieuse : rien sur stderr" "$(wc -c <"$T/err" | tr -d ' ')" '0'
check "la valeur est bien rendue"                "$out" 'github_pat_11ABCDEF_nue'

# 4. Échecs : sortie non nulle, message qui NOMME la clé, et jamais la valeur.
expect_fail() { # expect_fail LIBELLÉ VALEUR ATTENDU_DANS_LE_MESSAGE
  local label="$1" value="$2" needle="$3" rc=0
  ( resolve_secret "$value" 'repository.password' ) >"$T/out" 2>"$T/err" || rc=$?
  if [ "$rc" -eq 0 ]; then ko "$label (aurait dû échouer)"; return; fi
  if ! grep -qF -- "$needle" "$T/err"; then
    ko "$label (le message ne cite pas «$needle» : $(tr -d '\n' <"$T/err"))"; return
  fi
  if grep -qF -- 'github_pat_11ABCDEF' "$T/err" "$T/out"; then
    ko "$label (le secret a fuité dans la sortie)"; return
  fi
  ok "$label"
}

expect_fail "clé absente → message nommant la clé" '!secret pas_dans_le_fichier' 'pas_dans_le_fichier'
expect_fail "clé présente mais vide → échec explicite" '!secret vide' 'vide'
expect_fail "« !secret » sans nom de clé → échec explicite" '!secret ' '!secret'
expect_fail "clé imbriquée ignorée (mapping plat attendu)" '!secret interne' 'interne'

SECRETS_FILE="$T/inexistant.yaml"
expect_fail "secrets.yaml absent → message nommant le fichier ET la clé" \
  '!secret github_pat_deployer' 'github_pat_deployer'
SECRETS_FILE="$T/secrets.yaml"

# 5. Le vrai run.sh appelle bien la fonction sur repository.password — sinon tout ce
#    qui précède teste une fonction morte.
if grep -q "resolve_secret \"\$(bashio::config 'repository.password')\"" "$RUN_SH"; then
  ok "run.sh résout repository.password via resolve_secret"
else
  ko "run.sh n'appelle pas resolve_secret sur repository.password"
fi

printf '\n%s\n' "$([ "$fail" -eq 0 ] && echo '✅ tous les tests passent' || echo '❌ échecs ci-dessus')"
exit "$fail"
