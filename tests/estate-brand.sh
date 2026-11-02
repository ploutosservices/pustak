#!/usr/bin/env bash
# estate-brand.sh — every context answers the sign-in door's brand question from its own settings.
#
# The door's page fetches <origin>/.well-known/estate-brand.json with {mode: "cors", credentials:
# "omit"} and uses `name` and `logo` (claude-shared design/estate-brand-skunkworks.md). Plugin
# estateBrand answers it on OnPageNotFound. For each web context with an http_host on this bench:
#   - 200, a JSON content type, Access-Control-Allow-Origin: *, asked with NO cookie;
#   - name = the context's site_name, read from the database here, never typed;
#   - logo present exactly where the context's site_logo is set, and equal to it;
#   - another /.well-known/ path is still MODx's 404 (the plugin answers one path only).
#
# Seen red: with the plugin disabled every case but the last fails (run with ESTATE_BRAND_RED=1).
#
#   bash tests/estate-brand.sh
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_repo
require_bench

plugin=$(q "SELECT COUNT(*) FROM modx_site_plugins p JOIN modx_site_plugin_events e ON e.pluginid=p.id
            WHERE p.name='estateBrand' AND p.disabled=0 AND e.event='OnPageNotFound';")
[ "$plugin" = 1 ] || { echo "REFUSING TO RUN: estateBrand is not installed and bound to OnPageNotFound — apply it first." >&2; exit 2; }

red=0
if [ "${ESTATE_BRAND_RED:-0}" = 1 ]; then
  red=1
  q "UPDATE modx_site_plugins SET disabled=1 WHERE name='estateBrand';"; clear_cache
  echo "  (seeing red: estateBrand disabled)"
fi
restore() { [ "$red" = 1 ] && { q "UPDATE modx_site_plugins SET disabled=0 WHERE name='estateBrand';"; clear_cache; }; }
trap restore EXIT

tmp=$(mktemp -d); chmod 700 "$tmp"; trap 'restore; rm -rf "$tmp"' EXIT

ctxs=$(q "SELECT context_key FROM modx_context_setting WHERE \`key\`='http_host' AND value<>''
          AND context_key NOT IN ('mgr','web') ORDER BY context_key;")
[ -n "$ctxs" ] || { echo "REFUSING TO RUN: no web context on this bench has an http_host." >&2; exit 2; }

for ctx in $ctxs; do
  read -r scheme _ < <(ctx_origin "$ctx")
  door=$(ctx_door "$ctx")
  want_name=$(q "SELECT value FROM modx_context_setting WHERE context_key='$ctx' AND \`key\`='site_name';")
  want_logo=$(q "SELECT value FROM modx_context_setting WHERE context_key='$ctx' AND \`key\`='site_logo';")
  echo "$ctx ($door)"
  code=$(curl -s -m 20 -o "$tmp/body" -D "$tmp/head" -w '%{http_code}' "$scheme://$door/.well-known/estate-brand.json")
  head=$(tr -d '\r' < "$tmp/head" | tr 'A-Z' 'a-z')
  check "$([ "$code" = 200 ] && echo 1 || echo 0)" "answers 200 to a visitor with no cookie" "got $code"
  check "$(hasre "$head" $'(^|\n)content-type: application/json')" "content type is JSON"
  check "$(hasre "$head" $'(^|\n)access-control-allow-origin: \\*')" "Access-Control-Allow-Origin: *"
  got_name=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "$tmp/body" 2>/dev/null)
  got_logo=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("logo","(absent)"))' "$tmp/body" 2>/dev/null)
  check "$([ -n "$want_name" ] && [ "$got_name" = "$want_name" ] && echo 1 || echo 0)" \
        "name is the context's site_name ('$want_name')" "got '$got_name'"
  if [ -n "$want_logo" ]; then
    check "$([ "$got_logo" = "$want_logo" ] && echo 1 || echo 0)" "logo is the context's site_logo" "got '$got_logo'"
  else
    check "$([ "$got_logo" = "(absent)" ] && [ "$code" = 200 ] && echo 1 || echo 0)" "no site_logo, so no logo" "got '$got_logo' ($code)"
  fi
  other=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$scheme://$door/.well-known/not-a-brand.json")
  check "$([ "$other" = 404 ] && echo 1 || echo 0)" "another /.well-known/ path is still 404" "got $other"
done

summary
