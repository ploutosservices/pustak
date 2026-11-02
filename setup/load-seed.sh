#!/usr/bin/env bash
# load-seed.sh — the ONE door for loading install/modx-seed.sql.gz into a MODx DB.
#
#     setup/load-seed.sh
#
# Load + bind + verify are ONE operation here, deliberately. The seed carries some installation's
# names; binding this installation's used to be a separate hand-run step, and a seed load that
# skipped it left production resolving on the bench names with nothing complaining ("if you
# hardcode a domain it must be overwritten on upload"). Words in a runbook did not survive; this
# does: the load cannot succeed without the bind, and the bind is asserted afterwards. The names
# are infra's: MODX_ROOT's core/config/application.php holds them and
# setup/apply-environment.php writes them, then checks them.
#
# Scope: DB only — schema, content, and the domain binding. Files (docroot tar), machine config,
# nginx, DNS and cache belong to the caller: setup/make-current.sh on the bench,
# docs/production-install.md on prod. Idempotent: the seed's DROP TABLEs replace whatever was there.
#
# Config is env-driven with the dev-box values as defaults (see docs/installation.md):
#   MODX_DB_HOST / MODX_DB_USER / MODX_DB_PASS / MODX_DB_NAME, MODX_ROOT (cache clear).
# FORCE=1 overwrites a DB that already holds resources; without it a populated DB is refused.
set -euo pipefail

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "load-seed: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# THIS VERB WRITES, so its defaults are the dangerous kind. MODX_ROOT defaulted to
# /srv/local/modx — one ground's docroot, typed — and the database triple defaulted to
# one named account on `modx`. Run on a ground with only MODX_DB_PASS set, this would
# have loaded a SEED into a database called `modx` on that host, as that account, and reported success.
# lib.sh got this same treatment today for reads; a writer earns it more (2026-08-14).
MODX_ROOT="${MODX_ROOT:?MODX_ROOT not set — the docroot to install into has no default; name it}"
MODX_DB_HOST="${MODX_DB_HOST:-localhost}"
MODX_DB_PASS="${MODX_DB_PASS:?MODX_DB_PASS not set — no default (see setup/domains.py db_config)}"
case "$MODX_DB_HOST" in
  localhost|127.0.0.1|::1)
    MODX_DB_USER="${MODX_DB_USER:-$(id -un)}"   # a dev box: the OS user is the socket identity
    MODX_DB_NAME="${MODX_DB_NAME:-modx}"
    ;;
  *)
    # A database on another machine must be NAMED. The dev-box defaults describe this box, and
    # using them against another host would load a seed over whatever schema of that name is
    # there — the one failure in this file that cannot be undone by running it again.
    MODX_DB_USER="${MODX_DB_USER:?MODX_DB_HOST is $MODX_DB_HOST — a database on another machine —
            so MODX_DB_USER must be named; the default (the OS user) describes a dev box. Nothing loaded}"
    MODX_DB_NAME="${MODX_DB_NAME:?MODX_DB_HOST is $MODX_DB_HOST — a database on another machine —
            so MODX_DB_NAME must be named; the default (modx) describes a dev box. Nothing loaded}"
    ;;
esac
FORCE="${FORCE:-}"

SETUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SETUP/.." && pwd)"
# The estate artefacts (the seed, the docroot tar, his documents) live in the estate repository
# now; this software carries none of them. ESTATE_REPO is derived from
# MODX_ESTATE — one name for one place — and refuses rather than guessing a path.
. "$SETUP/estate-repo.sh"
SEED="${MODX_SEED:-$ESTATE_REPO/install/modx-seed.sql.gz}"
export MYSQL_PWD="$MODX_DB_PASS"   # keeps the password off the process list / out of logs
MYSQL=(mysql -h "$MODX_DB_HOST" -u "$MODX_DB_USER")
export MODX_ROOT MODX_DB_HOST MODX_DB_USER MODX_DB_PASS MODX_DB_NAME

log(){ printf '  %s\n' "$*"; }
die(){ printf 'load-seed: %s\n' "$*" >&2; exit 1; }

# --- preconditions (fail fast — a half-loaded DB is worse than no load) ---------------------------
[ -f "$SEED" ] || die "missing $SEED — pull the modx repo first"
command -v mysql   >/dev/null || die "mysql client absent"
command -v php     >/dev/null || die "php absent (the environment bind needs it)"
[ -f "$MODX_ROOT/core/config/application.php" ] \
  || die "no $MODX_ROOT/core/config/application.php — the names to bind are infra's render (a bench: setup/bench-application.py)"
"${MYSQL[@]}" -e 'SELECT 1' >/dev/null 2>&1 \
  || die "cannot reach MariaDB as $MODX_DB_USER@$MODX_DB_HOST"

if [ -z "$FORCE" ]; then
  existing="$("${MYSQL[@]}" -N -e "SELECT COUNT(*) FROM \`$MODX_DB_NAME\`.modx_site_content" 2>/dev/null || echo 0)"
  if [ "${existing:-0}" -gt 0 ]; then
    die "'$MODX_DB_NAME' already holds $existing resources — loading the seed WIPES them.
    Pull anything you need into the seat first, then re-run with FORCE=1."
  fi
fi

# --- load ------------------------------------------------------------------------------------------
log "create db '$MODX_DB_NAME' + load $(basename "$SEED")"
"${MYSQL[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$MODX_DB_NAME\` CHARACTER SET utf8mb4"
gunzip -c "$SEED" | "${MYSQL[@]}" "$MODX_DB_NAME"

count="$("${MYSQL[@]}" -N -e "SELECT COUNT(*) FROM \`$MODX_DB_NAME\`.modx_site_content")"
[ "${count:-0}" -gt 0 ] || die "seed load failed — 0 resources in $MODX_DB_NAME"
log "resources loaded: $count"

# --- bind (NOT optional — this is the whole point of the one door) ----------------------------------
log "bind this installation's environment (setup/apply-environment.php)"
php "$SETUP/apply-environment.php" || die "apply-environment.php failed — the DB carries the seed's names"

# --- assert (independently of the write, and what CI/drift can call) -------------------------------
php "$SETUP/apply-environment.php" --check >/dev/null \
  || die "post-load verification failed — the DB does not match application.php"
log "verified: the DB matches application.php"

# --- cache -------------------------------------------------------------------------------------------
if [ -d "$MODX_ROOT/core/cache" ]; then
  log "clear MODx cache ($MODX_ROOT/core/cache)"
  rm -rf "$MODX_ROOT/core/cache/"* 2>/dev/null || true
else
  log "no $MODX_ROOT/core/cache — skipping cache clear (clear it wherever the tree lives)"
fi

echo "load-seed: $MODX_DB_NAME loaded ($count resources), environment bound and verified."
