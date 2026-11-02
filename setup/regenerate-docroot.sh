#!/usr/bin/env bash
# regenerate-docroot.sh — rebuild install/modx-docroot.tar.gz from the BENCH file tree.
#
# The docroot tar is the complete, runnable, extension-complete MODx file tree. It and
# install/modx-seed.sql.gz are a MATCHED PAIR (same build, same MODx version) — production-install.md
# says so, and mixing a tar from one version with a seed from another is the failure this script
# exists to make unlikely. Regenerate both together, always.
#
# Written 2026-07-25 during the upgrade rehearsal. Until then this command lived in
# production-install.md as `tar czf … --exclude=core/cache --exclude=config.core.php …` — with the
# rest of the exclude list elided behind an ellipsis. A regeneration command nobody can reproduce
# from the documentation is not a documented command.
#
# BENCH ONLY. Refuses if the tree's context bindings do not look like the bench, mirroring
# regenerate-seed.sh, because a tar built from a prod tree would carry prod machine config.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The estate artefacts (the seed, the docroot tar, his documents) live in the estate repository
# now; this software carries none of them. ESTATE_REPO is derived from
# MODX_ESTATE — one name for one place — and refuses rather than guessing a path.
. "$REPO/setup/estate-repo.sh"
# No default: /srv/local/modx was the dev bench and it is gone since the bench became
# staging (2026-08-14). Name the docroot this run is about.
MODX_ROOT="${MODX_ROOT:?MODX_ROOT not set — name the docroot; there is no default since
           the bench became staging}"
OUT="$ESTATE_REPO/install/modx-docroot.tar.gz"

[ -d "$MODX_ROOT" ] || { echo "REFUSING: no tree at $MODX_ROOT" >&2; exit 1; }

# --- guard: bench, not prod. config.inc.php is excluded from the tar, but if this tree IS prod we
# --- must not build from it at all — its manager/, assets/ and components/ are prod's.
# The tree says which environment it is: application.php's `environment` (infra's render on a ground,
# the bench renderer's on a bench).
TREE_ENV=$(php -r '$a = @include $argv[1]; echo is_array($a) ? ($a["environment"] ?? "") : "";' \
  "$MODX_ROOT/core/config/application.php" 2>/dev/null) || TREE_ENV=""
if [ "$TREE_ENV" != "development" ]; then
  echo "REFUSING: $MODX_ROOT/core/config/application.php says environment '${TREE_ENV:-(none)}', not development." >&2
  echo "The docroot tar must be built from the bench, never from production." >&2
  exit 1
fi

# --- what is deliberately NOT in the tar, and why ---------------------------------------------
#
#   core/cache/            runtime. Ships nothing; a stale cache on a new machine is worse than none.
#   config.core.php        machine config — infra writes it (it hardcodes the absolute core path).
#                          Excluded ANYWHERE in the tree, not just at the root: the 3.2.3 CLI
#                          upgrade also writes manager/config.core.php and connectors/config.core.php
#                          (both new — the pre-upgrade tree and the previous tar had neither), and
#                          each hardcodes this machine's absolute core path.
#   core/config/config.inc.php
#                          machine config — DB credentials, absolute paths, site_id. Never in git.
#   setup/                 the installer. Excluded since 2026-07-25 for two reasons:
#                          (1) our install path never runs it — production-install.md unpacks this
#                              tar and then loads the DB with setup/load-seed.sh; the seed IS the
#                              installed state, so setup/index.php has no job to do;
#                          (2) MODx's own ConfigCheck (core/src/Revolution/Processors/System/
#                              ConfigCheck.php) raises "Installer still present" on every manager
#                              dashboard for as long as the directory exists. Shipping it meant
#                              every freshly built machine came up already carrying that warning.
#                          An UPGRADE does need setup/ — you stage it from the release distribution
#                          at that point and delete it again afterwards. See docs/upgrades.md.
#
# Everything else is included on purpose, including core/components/{pdotools,simplesearch} and
# core/packages/ — that is what "extension-complete" means. If an extra is uninstalled on the bench,
# it correctly disappears from the next tar.

#   config.context.php     machine config of the ground, not software. It was the HTTP_HOST ->
#                          context map, a list of somebody's domains riding inside a software
#                          tarball; now it is the one-line EdgeContext require,
#                          rendered by infra's modx-web role or written on a bench by
#                              python3 setup/config-context.py --profile <p> --write <docroot>
#                          and asserted with `--check <docroot>`.

#   core/config/application.php
#                          machine config, the same class as config.inc.php: infra renders it on a
#                          managed ground (common/lib/Application.php), and on the bench it is a
#                          hand-written copy naming this box's identity directory. First present at
#                          the 3.2.4 regeneration; the August tar predates it.
#   core/protected/        the protected-files store — runtime content written by the storage path
#                          and by the suite's probes, never software. Same regeneration.
#   core/components/pustak/
#                          OUR library (common/lib/*.php). It reaches a ground through infra's
#                          modx-web ansible role, tag modx_lib (docs/HOW-IT-WORKS.md), so a copy in
#                          this tar is a second source that is stale from the day it is built. The
#                          bench carries it because the local rebuild copies it in by hand.

EXCLUDES=(
  --exclude=./core/cache
  --exclude=config.core.php
  --exclude=./core/config/config.inc.php
  --exclude=./core/config/application.php
  --exclude=./core/protected
  --exclude=./core/components/pustak
  --exclude=./setup
  --exclude=./config.context.php
)

echo "building $OUT from $MODX_ROOT"
tar czf "$OUT" -C "$MODX_ROOT" "${EXCLUDES[@]}" .

# List the members ONCE, then match with a HERE-STRING — never a pipe.
#
# `something | grep -q PATTERN` is a trap under `set -o pipefail`: grep exits at its first match,
# the writer takes SIGPIPE, the pipeline reports 141, and the caller reads that as "check failed".
# Whether it happens at all depends on buffering, so it looks intermittent. A here-string is a
# redirect, not a pipeline, so an early grep exit costs nothing. (Same failure shape as the time
# a deploy verb aborted rc=141 part-way and still reported success.)
MEMBERS="$(tar tzf "$OUT")"
has()     { grep -qxF "$1" <<< "$MEMBERS"; }
matches() { grep -q  "$1" <<< "$MEMBERS"; }

# --- verify the excludes actually held. A tar that silently shipped credentials is the one
# --- failure mode worth paying for twice.
fail=0
if matches 'config\.core\.php$'; then
  echo "ABORT: a config.core.php is present in the tar — machine config must never be committed." >&2
  grep 'config\.core\.php$' <<< "$MEMBERS" >&2
  fail=1
fi
if has './core/config/config.inc.php'; then
  echo "ABORT: core/config/config.inc.php is present in the tar — it carries DB credentials." >&2
  fail=1
fi
if matches '^\./core/cache/.'; then
  echo "ABORT: core/cache contents are present in the tar." >&2
  fail=1
fi
if matches '^\./setup/'; then
  echo "ABORT: setup/ is present in the tar (see the note above)." >&2
  fail=1
fi
if has './core/config/application.php' || matches '^\./core/protected/.' || matches '^\./core/components/pustak/'; then
  echo "ABORT: core/config/application.php, core/protected/ or core/components/pustak/ is in the tar —" >&2
  echo "machine config, runtime content, or our own library that infra ships separately." >&2
  fail=1
fi
if has './config.context.php'; then
  echo "ABORT: config.context.php is present in the tar — it is the ground's file, written at" >&2
  echo "install time (setup/config-context.py; infra's modx-web role on a managed ground)." >&2
  fail=1
fi
# The estate must not ride in the software tarball in any other form either. This is the same list
# tests/estate-clean.sh check 2 enforces on the source tree, applied to the BUILT ARTIFACT — the tar
# is where an estate address survived a check that only ever read the checkout (a July
# build of assets/components/bania/js/kuber.js carried seven of them into every install, for eleven
# days, while the source had been fixed and the suite was green).
ESTATE_IDS=$(python3 "$(dirname "$0")/estate-get.py" identifiers | paste -sd'|' -)
[ -n "$ESTATE_IDS" ] || { echo "ABORT: the estate declares no identifiers (estate.json identifiers) to scan the tar for." >&2; rm -f "$OUT"; exit 1; }
LEAKED=$(tar xzOf "$OUT" --wildcards './assets/*' 2>/dev/null | grep -icE "$ESTATE_IDS" || true)
if [ "${LEAKED:-0}" -gt 0 ]; then
  echo "ABORT: $LEAKED estate identifier(s) inside the tar's assets/ — a docroot built from a bench" >&2
  echo "whose files are behind source. Sync the file from its owner and rebuild." >&2
  fail=1
fi
if [ "$fail" -ne 0 ]; then rm -f "$OUT"; exit 1; fi

# --- sanity: the tree must still be runnable, i.e. carry the pieces a fresh machine needs ---
for p in './index.php' './manager/index.php' './connectors/index.php' \
         './core/docs/version.inc.php' './core/vendor/autoload.php'; do
  has "$p" || { echo "ABORT: $p missing from the tar." >&2; rm -f "$OUT"; exit 1; }
done

VER="$(php -r 'echo (require "'"$MODX_ROOT"'/core/docs/version.inc.php")["full_version"];' 2>/dev/null || echo unknown)"
echo "docroot regenerated at MODX $VER: $OUT"
sha256sum "$OUT"
echo "Remember to update the sha256 in docs/production-install.md, and regenerate the seed"
echo "(setup/regenerate-seed.sh) from the SAME bench so the pair stays matched."
