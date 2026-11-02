#!/usr/bin/env bash
# jump-slot.sh — the estate title bar's jump slot, on a REAL signed-in page (estate-title-bar.md §The jump slot).
#
#     bash tests/jump-slot.sh
#
# WHAT IT ASSERTS, on the bench, signed in for real at the door as the suites' drill reader:
#
#   a signed-in page carries ONE <nav class="estate-bar-jump"> with the list's other applications for this
#     context's tenant, in the list's order, and no entry for Library itself
#   it sits between the spacer and the actions (rule 6)
#   a signed-out page carries no slot
#   no slot at all — never an empty <nav> — for: a path that cannot be read, {}, and a list whose only
#     entry for this tenant is Library's own
#
# The list is a FIXTURE inside this checkout, not /tmp: on staging MODx runs in a container, and a
# path under this host's /tmp is unreadable there, so every "drawn" case failed nightly as a fact
# about the ground wearing the look of a fault in the page. Nor MODX_ROOT/core/cache: the
# staging job's user cannot write there (run 01a17d95 refused). The checkout is the one place both
# grounds already prove: the job's user writes it, and the container's www-data reads it — every
# php suite runs from it inside the container. The suite points the estate.tenant_apps_file ROW at
# the fixture and puts the row back exactly as it was found, including "absent". It never writes
# the file the ground was handed, and it REFUSES when it cannot write the fixture.
#
# BENCH ONLY. It signs in as the suites' machine identity at the door's non-production realm;
# require_nonprod_door refuses anywhere else.
set -uo pipefail

HOST=${MODX_TEST_HOST:-}   # empty: the context's live http_host, read after lib.sh
IP=${MODX_TEST_IP:-127.0.0.1}
CTX=${MODX_TEST_CTX:-platform}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ALIAS=jump-slot-suite
KEY=estate.tenant_apps_file

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -n "$HOST" ] || HOST=$(ctx_host "$CTX") || exit 2

read -r SCHEME PORT < <(host_origin "$HOST")
DOOR=$(host_door "$HOST") || exit 2

require_repo
require_bench
require_nonprod_door

echo "the jump slot, signed in on the bench (context $CTX)"

reader=$(drill_reader)   # a machine identity, never a person
[ -z "$reader" ] && { echo "REFUSING TO RUN: drill_reader could not seat the suites' machine identity on this ground." >&2; exit 2; }

had_row=$(q "SELECT COUNT(*) FROM modx_system_settings WHERE \`key\`='$KEY';")
was_row=$(q "SELECT \`value\` FROM modx_system_settings WHERE \`key\`='$KEY';")

# The fixture must be readable by the web server's user AND on the web server's filesystem, so it
# lives in this checkout (see the header), not in this host's /tmp, and never in the 700 directory
# the suite keeps its cookie jar in.
tmp=$(mktemp -d); chmod 700 "$tmp"
fix=$(mktemp -d -p "$REPO/tests" jump-slot-suite.XXXXXX 2>/dev/null) || {
  echo "REFUSING TO RUN: cannot create a fixture directory under $REPO/tests — the web server reads there, this user cannot write there." >&2; exit 2; }
chmod 755 "$fix"
cleanup() {
  q "DELETE FROM modx_site_content WHERE context_key='$CTX' AND alias='$ALIAS';" >/dev/null 2>&1
  if [ "$had_row" = 0 ]; then
    q "DELETE FROM modx_system_settings WHERE \`key\`='$KEY';" >/dev/null 2>&1
  else
    q "UPDATE modx_system_settings SET \`value\`='$was_row' WHERE \`key\`='$KEY';" >/dev/null 2>&1
  fi
  clear_cache >/dev/null 2>&1 || true
  rm -rf "$tmp" "$fix"
}
trap cleanup EXIT

point_at() {   # point the setting row at a path, then make the page read it
  if [ "$(q "SELECT COUNT(*) FROM modx_system_settings WHERE \`key\`='$KEY';")" = 0 ]; then
    q "INSERT INTO modx_system_settings (\`key\`,\`value\`,xtype,namespace,area)
       VALUES ('$KEY','$1','textfield','core','site');" >/dev/null
  else
    q "UPDATE modx_system_settings SET \`value\`='$1' WHERE \`key\`='$KEY';" >/dev/null
  fi
  clear_cache
}
fixture() { printf '%s' "$2" > "$fix/$1"; chmod 644 "$fix/$1"; printf '%s' "$fix/$1"; }

entry() { printf '{"app":"%s","name":"%s","url":"%s","icon":"https://cdn.example.test/%s.svg"}' "$1" "$2" "$3" "$1"; }
LIST=$(fixture list.json "{\"$CTX\":[$(entry munshi Munshi https://munshi.example.test/),$(entry modx Saraswati https://library.example.test/),$(entry kuber Kuber https://kuber.example.test/)],\"elsewhere\":[$(entry munshi Elsewhere https://elsewhere.example.test/)]}")
EMPTY=$(fixture empty.json '{}')
ONLY_SELF=$(fixture self.json "{\"$CTX\":[$(entry modx Saraswati https://library.example.test/)]}")

q "INSERT INTO modx_site_content
     (type,pagetitle,longtitle,description,introtext,alias,uri,published,deleted,template,
      parent,context_key,hidemenu,menuindex,searchable,cacheable,richtext,createdby,
      createdon,publishedon,publishedby,content)
   VALUES ('document','jump slot suite','','','','$ALIAS','$ALIAS',1,0,4,
      0,'$CTX',1,0,0,0,0,1,UNIX_TIMESTAMP(),UNIX_TIMESTAMP(),1,'<p>body</p>');" \
  || { echo "could not create the test page" >&2; exit 2; }

PAGE="$SCHEME://$DOOR/$ALIAS"
jar="$tmp/cookies"
C=(curl -sS --resolve "${DOOR%%:*}:$PORT:$IP" -b "$jar" -c "$jar" -m 10)
ANON=(curl -sS -L --resolve "${DOOR%%:*}:$PORT:$IP" -m 10)

slot() { printf '%s' "$1" | grep -o '<nav class="estate-bar-jump"[^>]*>.*</nav>' | head -1 | sed 's#</nav>.*#</nav>#'; }
navs() { printf '%s' "$1" | grep -o '<nav class="estate-bar-jump"' | wc -l | tr -d ' '; }

# --- signed out first: the page as nobody sees it ---------------------------------------------
point_at "$LIST"
anon=$("${ANON[@]}" "$PAGE")
check "$(has "$anon" 'class="estate-bar"')" "signed out: the bar itself renders (the control for the next line)" \
      "$(printf '%s' "$anon" | head -c 160)"
check "$([ "$(navs "$anon")" = 0 ] && echo 1 || echo 0)" "signed out: no jump slot" "found $(navs "$anon")"

# --- sign in for real through the bench's provider ---------------------------------------------
loc=$("${C[@]}" -o /dev/null -w '%{redirect_url}' "$SCHEME://$DOOR/sso-login?sso=go")
cb=$(idp_sign_in "$loc" "$reader")
"${C[@]}" -o /dev/null "$cb"
sid=$(awk '/PHPSESSID/ {print $7}' "$jar" | tail -1)
signed=$(q "SELECT data FROM modx_session WHERE id='$sid';" | grep -c 'user.token')
check "$([ "$signed" = 1 ] && echo 1 || echo 0)" "signed in on the bench as the drill reader" "session $sid"
[ "$signed" = 1 ] || { summary; exit 1; }

# --- drawn ------------------------------------------------------------------------------------
out=$("${C[@]}" "$PAGE")
s=$(slot "$out")
check "$([ "$(navs "$out")" = 1 ] && echo 1 || echo 0)" "signed in: one jump slot" "found $(navs "$out")"
check "$(has "$s" '<a href="https://munshi.example.test/" data-estate-tip="Open Munshi"><img src="https://cdn.example.test/munshi.svg" alt="Munshi"></a>')" \
      "each entry drawn as handed: href, tip, img src, alt" "$s"
m=$(printf '%s' "$s" | grep -bo 'munshi.example.test' | head -1 | cut -d: -f1)
k=$(printf '%s' "$s" | grep -bo 'kuber.example.test' | head -1 | cut -d: -f1)
check "$([ -n "$m" ] && [ -n "$k" ] && [ "$m" -lt "$k" ] && echo 1 || echo 0)" "in the list's order (Munshi before Kuber)" "$s"
check "$(hasnt "$s" 'library.example.test')" "Library's own entry is not drawn" "$s"
check "$(hasnt "$s" 'elsewhere.example.test')" "another tenant's entry is not drawn" "$s"
bar=$(printf '%s' "$out" | tr -d '\n' | grep -o 'estate-bar-spacer.*estate-bar-actions' | head -1)
check "$(has "$bar" 'estate-bar-jump')" "it sits between the spacer and the actions" "$(printf '%s' "$bar" | head -c 200)"

# --- not drawn at all ---------------------------------------------------------------------------
point_at "$fix/no-such-file.json"
o=$("${C[@]}" "$PAGE"); check "$([ "$(navs "$o")" = 0 ] && has "$o" 'class="estate-bar"' >/dev/null && echo 1 || echo 0)" "a path that cannot be read: no slot" "found $(navs "$o")"
point_at "$EMPTY"
o=$("${C[@]}" "$PAGE"); check "$([ "$(navs "$o")" = 0 ] && echo 1 || echo 0)" "{}: no slot" "found $(navs "$o")"
point_at "$ONLY_SELF"
o=$("${C[@]}" "$PAGE"); check "$([ "$(navs "$o")" = 0 ] && echo 1 || echo 0)" "only Library's own entry: no slot" "found $(navs "$o")"

summary
