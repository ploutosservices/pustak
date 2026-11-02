#!/bin/bash
# deploy-local.sh — deploy the local bench FROM A GIT REF, the way production is deployed.
#
# The owner, 2026-09-18, after the bench carried documents that no push had made public: "what is
# the source of git for this operation. a local copy or master git … should it pull first."
#
# Two acts, two names. PREVIEW reads the working tree (`import.py`, `seat/push.py`) and is for an
# edit not yet committed. DEPLOY reads a named ref after a fetch, so what lands on the bench is
# what Gitea holds — the same discipline as infra's apply-modx-elements.sh, which archives the
# ref into a scratch directory and applies from there. Nothing uncommitted rides along.
#
#   setup/deploy-local.sh [--ref origin/master] [--estate-ref origin/master] [--elements-only|--documents-only]
#
# Order matters and is fixed here: documents first (seat/push.py also writes the seat's element
# copies, which are production's), then elements from common/, then the cache.
#
# Ground: MODX_ROOT (no default — name the bench, as make-current.sh and modx-snapshot.sh do),
# MODX_DB_SOCKET (default /run/mysqld/mysqld.sock), the software repo beside this file, and the
# estate repo beside it as ../modx-estate unless MODX_ESTATE_REPO names another checkout.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
ESTATE=${MODX_ESTATE_REPO:-$(cd "$REPO/../modx-estate" && pwd)}
REF=origin/master; EREF=origin/master; DO_DOCS=1; DO_ELEMENTS=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF=$2; shift 2 ;;
    --estate-ref) EREF=$2; shift 2 ;;
    --elements-only) DO_DOCS=0; shift ;;
    --documents-only) DO_ELEMENTS=0; shift ;;
    *) echo "usage: $0 [--ref REF] [--estate-ref REF] [--elements-only|--documents-only]" >&2; exit 2 ;;
  esac
done

export MODX_ROOT="${MODX_ROOT:?MODX_ROOT not set — name the bench docroot to deploy onto; there is no default}"
export MODX_DB_SOCKET=${MODX_DB_SOCKET:-/run/mysqld/mysqld.sock}
export MODX_ESTATE=${MODX_ESTATE:-$ESTATE/estate.json}
[[ -d $MODX_ROOT/core ]] || { echo "deploy-local: no bench at $MODX_ROOT" >&2; exit 2; }

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT

# PULL FIRST — a ref is only as current as the last fetch.
git -C "$REPO" fetch -q origin
git -C "$ESTATE" fetch -q origin
sw=$(git -C "$REPO" rev-parse --short "$REF"); es=$(git -C "$ESTATE" rev-parse --short "$EREF")
echo "deploy-local: software $REF = $sw, estate $EREF = $es -> $MODX_ROOT"

# The ref, archived — the working trees are never read and never touched.
mkdir -p "$SCRATCH/modx" "$SCRATCH/estate"
git -C "$REPO" archive "$REF" | tar -x -C "$SCRATCH/modx"
git -C "$ESTATE" archive "$EREF" seat estate.json | tar -x -C "$SCRATCH/estate"
# seat/push.py reads the seat's element copies too; the archive holds none (they are gitignored),
# so only the tracked documents travel — which is exactly the point.

if [[ $DO_DOCS = 1 ]]; then
  echo "deploy-local: documents from estate $es"
  MODX_REPO_DIR="$SCRATCH/modx" MODX_ESTATE="$SCRATCH/estate/estate.json" python3 "$SCRATCH/estate/seat/push.py"
fi
if [[ $DO_ELEMENTS = 1 ]]; then
  echo "deploy-local: elements from software $sw"
  python3 "$SCRATCH/modx/import.py"
  # THE SETTINGS TRAVEL WITH THE ELEMENTS, because a restore deletes them and an element needs them.
  # `ops.sh local restore_modx_dev` loads PRODUCTION's dump, which carries production's system
  # settings and therefore none of the rows setup/02 declares — estate_cdn_url and estate_env among
  # them. The bench then renders a bar whose configuration is missing, and the only thing standing
  # between that and a broken page is a fallback. Running 02 here means the documented step after a
  # restore puts the ground back whole, rather than a person remembering a second command.
  # MODX_ESTATE_ENV is the bench's own: this script only ever writes to MODX_ROOT on this box.
  MODX_ESTATE_ENV=${MODX_ESTATE_ENV:-development} python3 "$SCRATCH/modx/setup/02-system-settings.py"
  # THE CLASS LIBRARY TRAVELS WITH THE ELEMENTS, as ops.sh _modx_lib_sync does for staging and
  # production: an element that require_once's a class the bench does not have is a PHP fatal
  # on its first request. Missed here until 2026-10-23, when an element needed a new library class
  # and the bench answered 500. No --delete, as the deploy's copy deletes nothing.
  lib="$MODX_ROOT/core/components/pustak/lib"
  mkdir -p "$lib"
  rsync -rt --chmod=D2775,F0664 "$SCRATCH/modx/common/lib/" "$lib/"
  echo "deploy-local: class library $lib = common/lib @ $sw"
fi
php "$SCRATCH/modx/clear-cache.php"
echo "deploy-local: DONE — bench at software $sw, estate $es"
