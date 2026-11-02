#!/usr/bin/env bash
# MODx bench make-current — the skunkworks leg of machine-currency.
#
# Brings a *provisioned* dev box's MODx bench up to the git-master state from the repo artifacts,
# in one command: unpack docroot tar -> write machine config -> create+load seed -> bind bench
# domains -> clear cache -> verify. This is the "reinstall -> makeCurrent" MODx step (the FL faltu-2
# plan): infra provisions the box, this brings MODx current, then a single DNS flip of the bench names
# activates it.
#
# Boundary. Infra owns everything AROUND the tree (the nginx vhost for the bench names, php-fpm pool www-data,
# the `modx` DB grant, the /srv permission model, DNS). Everything INSIDE $MODX_ROOT — app files,
# machine config, data — is here. BENCH ONLY. Prod is install/production-install.md, infra-applied;
# this script must never point at a prod DB.
#
# Config is env-driven (one home per fact); defaults are the bench values, so a plain run works on a
# freshly provisioned dev box. MODX_ROOT can point anywhere. MODX_DB_NAME effectively cannot: the
# dev-box grant covers `modx` and `kuber` only, so a scratch database cannot be created here.
# To rehearse destructively, do it on a box that is NOT the bench and restore with this
# script — that is what the from-nothing install rehearsal did, and it is the better tool anyway.
set -euo pipefail

# No default: this verb WRITES the docroot it is given, and a guessed one is overwritten
# unasked. Name the docroot this run is about.
MODX_ROOT="${MODX_ROOT:?MODX_ROOT not set — name the docroot this run writes; there is no default}"
# The bench is the on-box copy nginx serves by name, the same setup as every other environment.
MODX_PROFILE="${MODX_PROFILE:-bench}"
case "$MODX_PROFILE" in bench) ;; *)
  echo "make-current: MODX_PROFILE must be 'bench' (got '$MODX_PROFILE'). Production is
  install/production-install.md and is infra-applied; this script must never point at it." >&2
  exit 2 ;;
esac
MODX_DB_HOST="${MODX_DB_HOST:-localhost}"
MODX_DB_USER="${MODX_DB_USER:-$(id -un)}"   # a dev box: the OS user is the socket identity
MODX_DB_PASS="${MODX_DB_PASS:?MODX_DB_PASS not set — no default (see setup/domains.py db_config)}"
MODX_DB_NAME="${MODX_DB_NAME:-modx}"
FORCE="${FORCE:-}"                 # set FORCE=1 to overwrite an existing populated bench

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The estate artefacts (the seed, the docroot tar, his documents) live in the estate repository
# now; this software carries none of them. ESTATE_REPO is derived from
# MODX_ESTATE — one name for one place — and refuses rather than guessing a path.
. "$REPO/setup/estate-repo.sh"
TAR="$ESTATE_REPO/install/modx-docroot.tar.gz"
# The bench's names are infra's (config scripts/modx-environment.py), never typed here.
FIRST_CTX=$(python3 "$REPO/setup/estate-get.py" domains.contexts | head -1) || { echo "REFUSING: the estate declares no contexts" >&2; exit 1; }
SEED="$ESTATE_REPO/install/modx-seed.sql.gz"
export MYSQL_PWD="$MODX_DB_PASS"   # keeps the password off the process list / out of logs
MYSQL=(mysql -h "$MODX_DB_HOST" -u "$MODX_DB_USER")

log(){ printf '  %s\n' "$*"; }
die(){ printf 'make-current: %s\n' "$*" >&2; exit 1; }

# --- 0) preconditions (fail fast: a half-provisioned box should stop here, not half-work) ----------
[ -f "$TAR" ]  || die "missing $TAR — pull the modx repo first"
[ -f "$SEED" ] || die "missing $SEED — pull the modx repo first"
command -v mysql   >/dev/null || die "mysql client absent — box not provisioned (infra: MariaDB)"
command -v python3 >/dev/null || die "python3 absent — box not provisioned (infra)"
"${MYSQL[@]}" -e 'SELECT 1' >/dev/null 2>&1 \
  || die "cannot reach MariaDB as $MODX_DB_USER@$MODX_DB_HOST — box not provisioned (infra: modx grant)"

# --- 1) GUARD — never silently lose in-flight work (machine-currency's blessed guarantee) ----------------------
if [ -z "$FORCE" ]; then
  if ! git -C "$REPO" diff --quiet || ! git -C "$REPO" diff --cached --quiet; then
    die "the modx repo has uncommitted changes. make-current reloads the DB from the committed seed
    and would bury un-landed work. Commit/push first (or, if you know it's safe, FORCE=1)."
  fi
  existing="$("${MYSQL[@]}" -N -e "SELECT COUNT(*) FROM \`$MODX_DB_NAME\`.modx_site_content" 2>/dev/null || echo 0)"
  if [ "${existing:-0}" -gt 0 ]; then
    die "'$MODX_DB_NAME' already holds $existing resources — reloading the seed WIPES them. If this
    bench has edits, pull+commit them into the seat first; then re-run with FORCE=1 to overwrite."
  fi
fi

# --- 2) app files (stock MODX; index.php is NOT modified). config.context.php is NOT in the tar —
# it was taken out of it and is written at step 3b.
log "unpack docroot -> $MODX_ROOT"
mkdir -p "$MODX_ROOT"
tar xzf "$TAR" -C "$MODX_ROOT"

# --- 3) machine config, INSIDE the tree (the tar deliberately excludes these) -----------------------
# The identity fields (site_id/uuid/sessionname/lastInstallTime) pair with the seed's origin install
# and are reproduced verbatim so config and seed match. Only the DB creds are env-driven.
log "write config.core.php + core/config/config.inc.php"
cat > "$MODX_ROOT/config.core.php" <<PHP
<?php
define('MODX_CORE_PATH', '$MODX_ROOT/core/');
define('MODX_CONFIG_KEY', 'config');
PHP
mkdir -p "$MODX_ROOT/core/config"
cat > "$MODX_ROOT/core/config/config.inc.php" <<PHP
<?php
/** MODX Configuration file — generated by setup/make-current.sh (bench) */
\$database_type = 'mysql';
\$database_server = '$MODX_DB_HOST';
\$database_connection_charset = 'utf8mb4';
\$table_prefix = 'modx_';
\$dbase = '$MODX_DB_NAME';
\$database_user = '$MODX_DB_USER';
\$database_password = getenv('MODX_DB_PASS') ?: '$MODX_DB_PASS';
\$database_dsn = 'mysql:host=$MODX_DB_HOST;dbname=$MODX_DB_NAME;charset=utf8mb4';
\$config_options = array('override_table' => 'MyISAM');
\$driver_options = array();

\$lastInstallTime = 1783973543;
\$site_id = 'modx6a5546a7486f68.95348200';
\$site_sessionname = 'SN6a5546a746326';
\$https_port = '443';
\$uuid = 'de25872c-ce73-4652-905a-04fbd4d4162b';

if (!defined('MODX_ASSETS_PATH')) {
    \$modx_assets_path= '$MODX_ROOT/assets/';
    \$modx_assets_url= '/assets/';
    define('MODX_ASSETS_PATH', \$modx_assets_path);
    define('MODX_ASSETS_URL', \$modx_assets_url);
}
if (!defined('MODX_BASE_PATH')) {
    \$modx_base_path= '$MODX_ROOT/';
    \$modx_base_url= '/';
    define('MODX_BASE_PATH', \$modx_base_path);
    define('MODX_BASE_URL', \$modx_base_url);
}
if (!defined('MODX_CONNECTORS_PATH')) {
    \$modx_connectors_path= '$MODX_ROOT/connectors/';
    \$modx_connectors_url= '/connectors/';
    define('MODX_CONNECTORS_PATH', \$modx_connectors_path);
    define('MODX_CONNECTORS_URL', \$modx_connectors_url);
}
if (!defined('MODX_CORE_PATH')) {
    \$modx_core_path= '$MODX_ROOT/core/';
    define('MODX_CORE_PATH', \$modx_core_path);
}
if (!defined('MODX_MANAGER_PATH')) {
    \$modx_manager_path= '$MODX_ROOT/manager/';
    \$modx_manager_url= '/manager/';
    define('MODX_MANAGER_PATH', \$modx_manager_path);
    define('MODX_MANAGER_URL', \$modx_manager_url);
}
if (!defined('MODX_PROCESSORS_PATH')) {
    \$modx_processors_path= '$MODX_ROOT/core/src/Revolution/Processors/';
    define('MODX_PROCESSORS_PATH', \$modx_processors_path);
}

if(defined('PHP_SAPI') && (PHP_SAPI == "cli" || PHP_SAPI == "embed")) {
    \$isSecureRequest = false;
} else {
    \$isSecureRequest = ((isset(\$_SERVER['HTTPS']) && !empty(\$_SERVER['HTTPS']) && strtolower(\$_SERVER['HTTPS']) !== 'off') || parse_url('http://' . \$_SERVER['HTTP_HOST'], PHP_URL_PORT) == \$https_port);
}
if (!defined('MODX_URL_SCHEME')) {
    \$url_scheme =  \$isSecureRequest ? 'https://' : 'http://';
    define('MODX_URL_SCHEME', \$url_scheme);
}
if (!defined('MODX_HTTP_HOST')) {
    if(defined('PHP_SAPI') && (PHP_SAPI == "cli" || PHP_SAPI == "embed")) {
        define('MODX_HTTP_HOST', 'localhost');
    } else {
        \$http_host = array_key_exists('HTTP_HOST', \$_SERVER) ? parse_url(\$url_scheme . \$_SERVER['HTTP_HOST'], PHP_URL_HOST) : 'localhost';
        \$http_port = parse_url(\$url_scheme . \$_SERVER['HTTP_HOST'], PHP_URL_PORT);
        \$http_host .= in_array(\$http_port, [null, 80, 443]) ? '' : ':' . \$http_port;
        define('MODX_HTTP_HOST', \$http_host);
    }
}
if (!defined('MODX_SITE_URL')) {
    define('MODX_SITE_URL', \$url_scheme . MODX_HTTP_HOST . MODX_BASE_URL);
}
if (!defined('MODX_LOG_LEVEL_FATAL')) {
    define('MODX_LOG_LEVEL_FATAL', 0);
    define('MODX_LOG_LEVEL_ERROR', 1);
    define('MODX_LOG_LEVEL_WARN', 2);
    define('MODX_LOG_LEVEL_INFO', 3);
    define('MODX_LOG_LEVEL_DEBUG', 4);
}
PHP

# --- 3b) config.context.php + the library it requires — THE CONTEXT COMES FROM THE EDGE ----
# config.context.php is one line requiring core/components/pustak/lib/EdgeContext.php, which takes
# the context from HTTP_X_TENANT (nginx sets it from the name's tenant) and answers the estate's 404 page for anything else. The host
# is never read, so there is no map to generate.
#
# THE LIBRARY IS PLACED HERE TOO. On a managed ground infra's modx-web role ships common/lib (tag
# modx_lib); a bench has no role, and the tar excludes core/components/pustak. Without the copy the
# one-line require is a fatal error on every request.
#
# WITHOUT config.context.php stock index.php falls back to MODx's `web` context, which holds none of
# these pages — a bench with 1,545 resources that answered 404 everywhere (devbox-nj, 2026-08-18).
log "place common/lib -> core/components/pustak/lib"
mkdir -p "$MODX_ROOT/core/components/pustak/lib"
cp -p "$REPO"/common/lib/* "$MODX_ROOT/core/components/pustak/lib/"
log "write config.context.php (the EdgeContext require)"
python3 "$REPO/setup/config-context.py" --write "$MODX_ROOT" \
  || die "config-context.py failed — without it every request falls back to the \`web\` context and
  serves 404 for every page in the estate. Refusing to finish a bench that cannot answer."

# The bench's application.php, from infra's derivation for this machine: load-seed binds from it.
log "render the bench's application.php (setup/bench-application.py)"
MODX_ROOT="$MODX_ROOT" python3 "$REPO/setup/bench-application.py" \
  || die "bench-application.py failed — the bench's names cannot be bound"

# --- 4) data: load the seed through the ONE door — load + environment bind + verify + cache.
# Never load the seed here directly: a load without its domain bind is the failure that left production on bench hosts, and
# load-seed.sh is where that pairing is enforced (for prod too, from production-install.md).
log "load seed via setup/load-seed.sh"
FORCE=1 MODX_ROOT="$MODX_ROOT" MODX_DB_HOST="$MODX_DB_HOST" MODX_DB_USER="$MODX_DB_USER" \
  MODX_DB_PASS="$MODX_DB_PASS" MODX_DB_NAME="$MODX_DB_NAME" \
  bash "$REPO/setup/load-seed.sh"

# --- 5) verify --------------------------------------------------------------------------------------
# (the DB side — resource count and domain binding — is already asserted inside load-seed.sh)
count="$("${MYSQL[@]}" -N -e "SELECT COUNT(*) FROM \`$MODX_DB_NAME\`.modx_site_content")"
# Every page is protected, so the RIGHT answer for an anonymous request is NOT 200:
# the home page 302s to sso-login (the userHome snippet) and sso-login itself serves 200 because
# the `support` subtree is deliberately left anonymous. Two probes, because one number cannot tell
# "serving" from "broken": sso-login 200 proves nginx + php-fpm + the Host->context map, and the
# home 302 proves the seed's access control loaded with it. A 200 on home would mean the estate is
# serving to anyone — the unprotected-pages fault — not that the box is healthy.
PROBE_HOST=$(php -r '$a = include $argv[1]; echo $a["settings"]["contexts"][$argv[2]]["http_host"] ?? "";' \
  "$MODX_ROOT/core/config/application.php" "$FIRST_CTX")
[ -n "$PROBE_HOST" ] || die "application.php names no http_host for $FIRST_CTX"
home="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $PROBE_HOST" http://localhost/ 2>/dev/null || echo 000)"
supp="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $PROBE_HOST" http://localhost/sso-login 2>/dev/null || echo 000)"
log "http $PROBE_HOST/sso-login -> $supp  (expect 200 — nginx/php-fpm/Host map)"
log "http $PROBE_HOST/          -> $home  (expect 302 to sso-login; 200 = pages NOT protected)"
# `if`, not `[ ... ] && log`: under `set -e` a false test as a bare command aborts the script.
if [ "$supp" != "200" ]; then log "  WARN: sso-login did not serve — check nginx/php-fpm/DNS on this box"; fi
if [ "$home"  = "200" ]; then log "  WARN: home served anonymously — run setup/verify-file-protection.py"; fi

# --- 6) git hooks: canonicalize body files at commit so hand-commits match export.py/pull.py -------
# core.hooksPath is per-clone local config (not tracked), so a fresh box would otherwise never run
# the tracked pre-commit hook. Point git at seat/hooks here so the enforcement travels with the box,
# not with anyone's memory. Absolute path — regenerated per box, so a machine-specific path is fine.
# The pre-commit hook canonicalises DOCUMENTS, which live in the estate repo now — so the
# hook is installed on THAT clone, not on this one. Pointing this repo at a hooks directory
# it no longer contains would silently disable the enforcement (git ignores a missing path).
log "install git hooks (core.hooksPath -> the estate repo's seat/hooks)"
git -C "$ESTATE_REPO" config core.hooksPath "$ESTATE_REPO/seat/hooks"

echo "make-current: MODx bench is current ($count resources), answering at $PROBE_HOST and its sibling names."
