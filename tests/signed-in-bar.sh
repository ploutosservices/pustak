#!/usr/bin/env bash
# signed-in-bar.sh — the estate title bar and the jump links, on a REAL signed-in page.
#
#     bash tests/signed-in-bar.sh
#
# WHY THIS EXISTS, stated plainly because it is a confession. Library's bar and its in-page
# navigation live on the SIGNED-IN surface, and until tonight nothing in this repo could open that
# surface. So every acceptance of the bar rested on the owner looking at it — repeatedly, over two
# sessions, for a thing a suite can read in four seconds. It cost twice in one evening:
#
#   * an agent reported "Library's bar is red on production" from a DEV BENCH, where an undeclared
#     ground correctly wears the red, and nothing mechanical existed to contradict it;
#   * every jump link on every page was dead for two sessions (5198af1 wrapped the content in an
#     `overflow-y:auto` shell, so `window.scrollTo` became a no-op) and NOTHING said so — the
#     handler ran, preventDefault() had already cancelled the browser's own jump, and the click was
#     silently spent. The owner found it by clicking TOGAF.
#
# Both are the same shape: a surface only a person could see, so a person was the instrument.
#
# WHAT IT ASSERTS, on the bench, signed in for real at the door:
#
#   the shared stylesheet is LINKED from the ground's own estate_cdn_url  (never a literal)
#   the bar carries data-env = the ground's own estate_env
#   the app name slot says Library, and the tenant slot names the context
#   estate_env_color SET    -> the bar emits style="--estate-env-color: <it>"
#   estate_env_color EMPTY  -> the bar emits NO style attribute at all, so the stylesheet's
#                              undeclared red is what an undeclared ground wears
#   a page with sections carries jump links, and the handler asks the TARGET to scroll itself
#   (scrollIntoView) rather than scrolling the window, which the app shell makes a no-op
#
# The colour is drilled IN BOTH DIRECTIONS against this ground's own setting, and the setting is
# put back exactly as it was found — including "absent", which is not the same as empty.
#
# BENCH ONLY. It signs in as the suites' machine identity at the door's non-production realm;
# require_nonprod_door refuses anywhere else.
set -uo pipefail

HOST=${MODX_TEST_HOST:-}   # empty: the context's live http_host, read after lib.sh
IP=${MODX_TEST_IP:-127.0.0.1}
CTX=${MODX_TEST_CTX:-platform}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ALIAS=signed-in-bar-suite

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -n "$HOST" ] || HOST=$(ctx_host "$CTX") || exit 2

read -r SCHEME PORT < <(host_origin "$HOST")
DOOR=$(host_door "$HOST") || exit 2

require_repo
require_bench
require_nonprod_door

echo "the estate title bar, signed in on the bench"

reader=$(drill_reader)   # a machine identity, never a person
[ -z "$reader" ] && { echo "REFUSING TO RUN: drill_reader could not seat the suites' machine identity on this ground." >&2; exit 2; }

# THE GROUND'S OWN VALUES, read rather than assumed — a suite that hardcoded 'production' or an
# indigo would pass on the one ground where it must fail.
env_name=$(q "SELECT \`value\` FROM modx_system_settings WHERE \`key\`='estate_env';")
cdn=$(q "SELECT \`value\` FROM modx_system_settings WHERE \`key\`='estate_cdn_url';")
[ -z "$env_name" ] && { echo "REFUSING TO RUN: this ground has no estate_env — setup/02 has not run here." >&2; exit 2; }

# The setting may be ABSENT, EMPTY or SET, and those are three states. Absent is restored by
# deleting, not by writing an empty string — which is what a careless restore would leave behind.
had_colour=$(q "SELECT COUNT(*) FROM modx_system_settings WHERE \`key\`='estate_env_color';")
was_colour=$(q "SELECT \`value\` FROM modx_system_settings WHERE \`key\`='estate_env_color';")

tmp=$(mktemp -d); chmod 700 "$tmp"
cleanup() {
  q "DELETE FROM modx_site_content WHERE context_key='$CTX' AND alias='$ALIAS';" >/dev/null 2>&1
  if [ "$had_colour" = 0 ]; then
    q "DELETE FROM modx_system_settings WHERE \`key\`='estate_env_color';" >/dev/null 2>&1
  else
    q "UPDATE modx_system_settings SET \`value\`='$was_colour' WHERE \`key\`='estate_env_color';" >/dev/null 2>&1
  fi
  modx_php "$REPO/clear-cache.php" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

set_colour() {   # "" means empty-but-present
  if [ "$(q "SELECT COUNT(*) FROM modx_system_settings WHERE \`key\`='estate_env_color';")" = 0 ]; then
    q "INSERT INTO modx_system_settings (\`key\`,\`value\`,xtype,namespace,area)
       VALUES ('estate_env_color','$1','textfield','core','site');" >/dev/null
  else
    q "UPDATE modx_system_settings SET \`value\`='$1' WHERE \`key\`='estate_env_color';" >/dev/null
  fi
  # lib.sh's clear_cache, not `modx_php "$REPO/clear-cache.php" || true`: on staging modx_php runs
  # INSIDE the container, which cannot see this checkout's path, so that line failed silently and the
  # page kept the old setting — "a ground WITH a colour" red on modx_staging_tests (2026-10-05) while
  # the bench, where the path exists, was green. clear_cache feeds the script on stdin, refuses when
  # it does not say "Cache cleared", and waits out opcache's revalidation window.
  clear_cache
}

# A page with two section headers, so the jump nav has something to build from. sectionHead is the
# form Library's own pages use for a heading that is not collapsible.
q "INSERT INTO modx_site_content
     (type,pagetitle,longtitle,description,introtext,alias,uri,published,deleted,template,
      parent,context_key,hidemenu,menuindex,searchable,cacheable,richtext,createdby,
      createdon,publishedon,publishedby,content)
   VALUES ('document','signed-in bar suite','','','','$ALIAS','$ALIAS',1,0,4,
      0,'$CTX',1,0,0,0,0,1,UNIX_TIMESTAMP(),UNIX_TIMESTAMP(),1,
      '[[\$sectionHead? &id=\`alpha\` &nav=\`Alpha\` &anchor=\`anchor-target\` &title=\`Alpha\`]]
       <p>body</p>
       [[\$sectionHead? &id=\`beta\` &nav=\`Beta\` &anchor=\`anchor-target\` &title=\`Beta\`]]');" \
  || { echo "could not create the test page" >&2; exit 2; }
modx_php "$REPO/clear-cache.php" >/dev/null 2>&1 || true

PAGE="$SCHEME://$DOOR/$ALIAS"
jar="$tmp/cookies"
C=(curl -sS --resolve "${DOOR%%:*}:$PORT:$IP" -b "$jar" -c "$jar" -m 10)

# --- sign in for real at the door --------------------------------------------------------------
loc=$("${C[@]}" -o /dev/null -w '%{redirect_url}' "$SCHEME://$DOOR/sso-login?sso=go")
cb=$(idp_sign_in "$loc" "$reader")   # the door's form, by password (lib.sh)
"${C[@]}" -o /dev/null "$cb"
sid=$(awk '/PHPSESSID/ {print $7}' "$jar" | tail -1)
signed=$(q "SELECT data FROM modx_session WHERE id='$sid';" | grep -c 'user.token')
check "$([ "$signed" = 1 ] && echo 1 || echo 0)" "signed in on the bench as an existing user" "session $sid"
[ "$signed" = 1 ] || { summary; exit 1; }

# --- the bar, with a colour on the ground ------------------------------------------------------
set_colour '#123456'
out=$("${C[@]}" "$PAGE")

check "$(has "$out" "$cdn/estate/titlebar/titlebar.css")" \
      "the shared stylesheet is linked from the ground's own estate_cdn_url" \
      "looked for $cdn/estate/titlebar/titlebar.css"
check "$(has "$out" "class=\"estate-bar\" data-env=\"$env_name\"")" \
      "the bar carries this ground's own environment name" "expected data-env=\"$env_name\""
check "$(has "$out" 'style="--estate-env-color: #123456"')" \
      "a ground WITH a colour puts it on the bar as --estate-env-color" \
      "$(printf '%s' "$out" | grep -o '<header[^>]*>' | head -1)"
APP_NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["identity"]["display_name"])' "$REPO/service.json")
check "$(has "$out" "estate-bar-app\">$APP_NAME")" \
      "the app name slot says the manifest's display name ($APP_NAME)" \
      "$(printf '%s' "$out" | grep -o 'estate-bar-app[^<]*<[^<]*' | head -1)"
# "Where am I signed in" links the door's account page for this context's realm.
iss=$(q "SELECT value FROM modx_context_setting WHERE \`key\`='sso.oidc_issuer' AND context_key=(SELECT context_key FROM modx_context_setting WHERE \`key\`='http_host' AND value='${DOOR%%:*}' LIMIT 1) LIMIT 1;")
check "$([ -n "$iss" ] && has "$out" "href=\"${iss%/}/account\"" || echo 0)" \
      "the bar links 'Where am I signed in' to the door's account page" "issuer '$iss'"
# Rule 8 of estate-title-bar.md: every icon in the bar is the estate icon for its meaning,
# from this ground's CDN, and its hover is data-estate-tip — no Bootstrap glyph, no title on a control.
# The greeting's title is the address tooltip on a name, not an icon, so only <a> and <button> count.
bar=$(printf '%s' "$out" | sed -n '/<header class="estate-bar"/,/<\/header>/p')
check "$(hasnt "$bar" 'class="bi ')" \
      "rule 8: the bar draws no Bootstrap glyph" \
      "$(printf '%s' "$bar" | grep -o 'class="bi [^"]*"' | sort -u | tr '\n' ' ')"
for m in menu print search sessions sign-out; do
  check "$(has "$bar" "$cdn/estate/icons/$m.svg?v=")" \
        "rule 8: the bar draws the estate '$m' icon from the ground's CDN" "looked for $cdn/estate/icons/$m.svg?v="
done
# A picture the CDN does not serve draws a BLANK button behind every green check above: on 2026-10-29
# sessions.svg was a 404 at the CDN and "where am I signed in" was invisible. Every icon the bar asks for
# must answer 200 where the bar asks for it.
for u in $(printf '%s' "$bar" | grep -o "$cdn/estate/icons/[a-z-]*\.svg?v=[0-9a-f]*" | sort -u); do
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$u")
  check "$([ "$code" = 200 ] && echo 1 || echo 0)" "rule 8: the CDN serves ${u##*/icons/}" "got $code for $u"
done
titled=$(printf '%s' "$bar" | grep -o '<\(a\|button\)[^>]*>' | grep ' title=')
check "$([ -z "$titled" ] && echo 1 || echo 0)" \
      "rule 8: no control in the bar carries its hover as title" "$(printf '%s' "$titled" | head -2)"
check "$(has "$bar" 'data-estate-tip="Where am I signed in"')" \
      "rule 8: where am I signed in carries its hover as data-estate-tip" ""
check "$(has "$("${C[@]/$jar/$tmp/anon}" "$PAGE")" "$cdn/estate/icons/sign-in.svg?v=")" \
      "rule 8: signed out, the bar draws the estate 'sign-in' icon" "a fresh cookie jar, no session"
check "$(hasre "$out" "estate-bar-(tenant|context)[^>]*>[^<]*[A-Za-z]")" \
      "the tenant slot names something rather than rendering empty" \
      "$(printf '%s' "$out" | grep -o 'estate-bar-\(tenant\|context\)[^<]*<[^<]*' | head -1)"

# --- and with NO colour: the bar must say nothing rather than something reassuring --------------
# This is the half that matters. The failure this whole ticket exists to remove is an undeclared
# ground wearing production's colour, and the only way the stylesheet's red can reach it is if the
# bar emits NO property at all. An empty property would win over the fallback and paint nothing.
set_colour ''
out0=$("${C[@]}" "$PAGE")
# The BAR'S OWN TAGS, not the page: the page's stylesheet names the property too
# (Bootstrap.5.CSS, `var(--estate-env-color, …)`, 235df72 on 2026-10-02), and a whole-page search
# went red on every ground from then on while the bar was right (modx_staging_tests, 2026-10-03).
# The control beside it: the same reader run on the page WITH a colour must find the property, or
# this check could not go red.
bar_tags() { printf '%s' "$1" | grep -o '<header class="estate-bar"[^>]*>\|<nav class="navbar[^"]*estate-sections"[^>]*>'; }
check "$(hasnt "$(bar_tags "$out0")" '--estate-env-color')" \
      "a ground with NO colour emits no property at all, so the undeclared red applies" \
      "$(bar_tags "$out0" | head -1)"
check "$(has "$(bar_tags "$out")" '--estate-env-color')" \
      "control: the same reader finds the property on the bar when the ground HAS a colour" \
      "$(bar_tags "$out" | head -1)"

# --- the jump links, and the scroll that the app shell breaks -----------------------------------
check "$(has "$out" 'href="#alpha" class="jump-link"')" \
      "a page with section headers builds its own jump links" \
      "$(printf '%s' "$out" | grep -o 'href="#[a-z]*" class="jump-link"' | head -2 | tr '\n' ' ')"
# THE REGRESSION GUARD. page.full puts the content in `flex:1 1 auto; overflow-y:auto`, so the
# document itself does not scroll and a window scroll is a silent no-op. Naming the mechanism here
# is deliberate: the next person to "simplify" this handler back to window.scrollTo gets a red.
# THE CALL, NOT THE WORD — and this line is here because the drill caught it. Asserting on
# `scrollIntoView` alone passed with the PRE-FIX chunk installed, because the CSS chunk's own
# comment explains the fix in prose and the page carries that prose. A check its own documentation
# can satisfy is a check that cannot go red.
check "$(has "$out" 'scrollTarget.scrollIntoView(')" \
      "the jump handler asks the target to scroll itself, not the window" \
      "the app shell scrolls, the document does not — window.scrollTo is a no-op here"
check "$(hasnt "$out" 'window.scrollTo({ top: y')" \
      "and the window-scrolling form is gone" "5198af1 made it a no-op"

summary
