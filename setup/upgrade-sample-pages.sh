#!/usr/bin/env bash
# upgrade-sample-pages.sh <outdir> — the "three real pages" of docs/upgrades.md Phase 1 step 2.
#
# Every content page now requires sign-in, so an anonymous curl gets a 302 and a before/after diff
# of it proves nothing. This signs in at the door exactly as tests/auth-end-to-end.sh does, as the
# suites' machine identity (lib.sh drill_reader, an allContextMember), and saves:
#   family/greece        a plain content page
#   corporate/shubha     a tableRenderer page
#   family/construction  a chunk-heavy page (cards and sections)
# plus each context's public sso-login page. Run it before and after, then diff the directories:
# only MODx's render-time footer (total time / query time / query count) should differ.
#
# BENCH ONLY: it seats the drill reader and signs in at the door's non-production realm.
set -uo pipefail
OUT=${1:?usage: upgrade-sample-pages.sh <outdir>}; mkdir -p "$OUT"
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$REPO/tests/lib.sh"
require_bench
require_nonprod_door
IP=${MODX_TEST_IP:-127.0.0.1}
reader=$(drill_reader)
[ -n "$reader" ] || { echo "REFUSING: drill_reader could not seat the suites' machine identity on this bench" >&2; exit 2; }

fetch() {  # <alias>
  # The context is the page's own, read from the database: a context key typed here went stale
  # the day the estate renamed its contexts, and ctx_host then refused on a key nothing holds.
  local ctx
  ctx=$(q "SELECT DISTINCT context_key FROM modx_site_content WHERE alias='$1' AND deleted=0;")
  [ -n "$ctx" ] && [ "$(printf '%s\n' "$ctx" | wc -l)" -eq 1 ] || {
    echo "REFUSING: page alias '$1' must be in exactly one context on this bench; found: ${ctx:-none}" >&2; exit 2; }
  set -- "$ctx" "$1"
  local host door jar="$OUT/jar-$1" SCHEME PORT
  host=$(ctx_host "$1") || exit 2   # the context's live name, from the database
  read -r SCHEME PORT < <(host_origin "$host")
  door=$(ctx_door "$1") || exit 2   # where to knock: the context's name (lib.sh ctx_door)
  C=(curl -sS --resolve "${door%%:*}:$PORT:$IP" -b "$jar" -c "$jar" -m 20)
  if [ ! -s "$jar" ]; then
    local loc cb
    loc=$("${C[@]}" -o /dev/null -w '%{redirect_url}' "$SCHEME://$door/sso-login?sso=go")
    cb=$(idp_sign_in "$loc" "$reader") || exit 1   # the door's form, by password (lib.sh)
    "${C[@]}" -o /dev/null "$cb"
    curl -sS --resolve "${door%%:*}:$PORT:$IP" -m 20 -o "$OUT/$1-sso-login.html" \
         -w "$1/sso-login %{http_code} %{size_download}\n" "$SCHEME://$door/sso-login"
  fi
  "${C[@]}" -o "$OUT/$1-$2.html" -w "$1/$2 %{http_code} %{size_download}\n" "$SCHEME://$door/$2"
}
fetch greece
fetch shubha
fetch construction
rm -f "$OUT"/jar-*
