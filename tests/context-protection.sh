#!/usr/bin/env bash
# context-protection.sh — a protected context refuses an anonymous caller AND admits a member.
#
#     bash tests/context-protection.sh                 # default context: claude
#     MODX_TEST_CTX=worldview MODX_TEST_HOST=worldview.<bench zone> bash tests/context-protection.sh
#
# WHY THIS EXISTS. The `claude` context served its pages, at 200, with their content, to
# anybody on the internet, for as long as its name resolved. Nothing was broken — it had simply
# never been declared as a context (only as a domain), so `setup/04` built it no access model at
# all. The estate's other protection tests could not have caught it: `verify-file-protection.py`
# asserts the model matches the DECLARATION, and a context absent from the declaration matches it
# perfectly. What was missing is the only question that cannot be answered from the declaration —
# what does the wire return, to whom.
#
# So this is measured over HTTP, in both directions, and neither direction is trusted alone:
#
#   anonymous  -> refused, and TOLD HOW TO SIGN IN (302 to the SSO entry, not the retired form)
#   a member   -> the page, and the same content the anonymous caller did not get
#
# The comparison at the end is the assertion that cannot go green over a public page: a marker is
# taken out of what the MEMBER was served and required to be absent from the anonymous body. An
# earlier version of this file checked the anonymous body against strings this page was expected to
# contain, and it PASSED while the page was being served in full — the bench's copy predated the
# content those strings came from. A check that cannot fail is worse than no check.
#
# BENCH ONLY. It signs in as the suites' machine identity at the door's non-production realm, and
# it restores every sso.* value it touches — including DELETING the keys that were absent before it
# ran. It refuses on a bench whose http_host is not a bench host.
set -uo pipefail

CTX=${MODX_TEST_CTX:-platform}
HOST=${MODX_TEST_HOST:-}   # empty: the context's live http_host, read after lib.sh
IP=${MODX_TEST_IP:-127.0.0.1}
# THE IDP IS THE GROUND'S FACT, NOT THIS FILE'S: the context's own sso.oidc_issuer row, read below.
# This carried a dev-box literal (http://127.0.0.1:9200) as its default, so on the staging ground it
# refused against an address nothing was ever going to answer on; then it took MOCK_OIDC_URL, which
# named a provider that is retired. No literal and no variable, because a default here
# decides what silence means and silence meant "this box".
IDP=
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -n "$HOST" ] || HOST=$(ctx_host "$CTX") || exit 2

# The scheme and port are DECLARED, not assumed — see lib.sh origin_of(). This REFUSES if the
# ground cannot tell it which, rather than speaking http at an https edge and reporting the 301
# as a failure of the page.
read -r SCHEME PORT < <(ctx_origin "$CTX")
DOOR=$(ctx_door "$CTX") || exit 2

require_repo
require_bench

echo "context protection — $CTX ($HOST), both directions"

# The context must be declared protected, or this suite is asserting nothing. Read from the estate
# the setup scripts read, never from a list here.
protected=$(MODX_ESTATE=${MODX_ESTATE:-} python3 -c "
import sys; sys.path.insert(0, '$REPO/setup')
from estate import PROTECTED_CONTEXTS
print('1' if '$CTX' in PROTECTED_CONTEXTS else '0')" 2>/dev/null)
if [ "$protected" != 1 ]; then
  echo "REFUSING TO RUN: '$CTX' is not declared protected in the estate MODX_ESTATE names." >&2
  echo "          This suite would then pass by asserting nothing." >&2
  exit 2
fi

# The context's own door issuer — the ground's statement of where this context signs in (#1380;
# the system trio that used to answer this is retired).
IDP=$(q "SELECT value FROM modx_context_setting WHERE context_key='$CTX' AND \`key\`='sso.oidc_issuer' LIMIT 1;" 2>/dev/null)
if [ -z "$IDP" ]; then
  echo "REFUSING TO RUN: this ground has not said where its OIDC provider is." >&2
  echo "                 Give '$CTX' an sso.oidc_issuer row (the bench's sign-in setup, on a bench). No assertion" >&2
  echo "                 has run: a statement about the ground, not about the tree." >&2
  exit 2
fi
# WHERE THIS CONTEXT'S SIGN-IN ACTUALLY GOES. A context on sso.provider=oidc follows
# its own sso.oidc_* rows — the estate sign-in door. Its issuer's discovery document is the
# reachability check (setup/12-sso.py reads the same document).
CTX_AUTH=$(q "SELECT value FROM modx_context_setting WHERE context_key='$CTX' AND \`key\`='sso.oidc_auth_endpoint';")
CTX_ISS=$(q "SELECT value FROM modx_context_setting WHERE context_key='$CTX' AND \`key\`='sso.oidc_issuer';")
reach="${CTX_ISS%/}/.well-known/openid-configuration"
if [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$reach")" != 200 ]; then
  echo "REFUSING TO RUN: the provider is not answering at $reach — the member half cannot be measured," >&2
  echo "          and the anonymous half alone is the one-way proof that let the claude context's exposure happen." >&2
  exit 2
fi

# ── sso.*: save, repoint, and put back exactly what was here ───────────────────────────────────
# Two columns, not CONCAT(key,'\t',value): mysql's batch output escapes a tab INSIDE a value as the
# two characters \t, so the concatenated form came back unsplittable and the restore matched no key.
saved=$(q "SELECT \`key\`, value FROM modx_system_settings WHERE \`key\` LIKE 'sso.%';")
added=""
tmp=$(mktemp -d); chmod 700 "$tmp"
restore() {
  while IFS=$'\t' read -r k v; do
    [ -z "$k" ] && continue
    q "UPDATE modx_system_settings SET value='$v' WHERE \`key\`='$k';" >/dev/null 2>&1
  done <<< "$saved"
  for k in $added; do
    q "DELETE FROM modx_system_settings WHERE \`key\`='$k';" 2>/dev/null
  done
  modx_php "$REPO/clear-cache.php" >/dev/null
  rm -rf "$tmp"
  echo "  sso.* restored (rows removed: ${added:-none})"
}
trap restore EXIT

ensure_setting() {   # an ABSENT key is why an UPDATE-only version of this silently left sign-in
  if [ "$(q "SELECT COUNT(*) FROM modx_system_settings WHERE \`key\`='$1';")" = 0 ]; then
    q "INSERT INTO modx_system_settings (\`key\`,value,xtype,namespace,area)
       VALUES ('$1','$2','textfield','core','authentication');" 2>/dev/null
    added="$added $1"
  else
    q "UPDATE modx_system_settings SET value='$2' WHERE \`key\`='$1';" 2>/dev/null
  fi
}

# ── 1. anonymous ────────────────────────────────────────────────────────────────────────────────
# THE URI, NOT THE ALIAS. MODx routes a request on `uri`; `alias` is only the last segment
# a person typed into the manager, and the two differ on 1,197 published resources in this estate —
# every static file (`quote-shepherd` -> `quote-shepherd.pdf`) and, in the `claude` context, the
# very row this query picks: id 1582 is alias `actuator`, uri `actuator.json`.
#
# WHAT THAT COST, and it is why this is not a tidy-up. This suite asked for `/actuator`, got 404,
# and reported it as THREE protection failures — "…and is refused or sent to sign-in", "THE MEMBER
# READS THE PAGE", and "the anonymous body is a fraction of the member's (45964 vs 45997 bytes)".
# The last one is the tell: both bodies were the SAME 404 page, 33 bytes apart. Nobody could read
# it, so protection looked broken while nothing was wrong with protection at all. It has been red
# every night on sevak-nj since, against a ticket that was closed.
#
# AND IT MUST CARRY CONTENT. Fixing the uri made the page RESOLVE, and
# the run on 2026-08-28 then failed three checks further down with `got ''` and `(0 vs 0 bytes)`:
# the member was served HTTP 200 and a body of nothing. Row 1582 is a CONTAINER — `actuator.json`
# with `actuator/info` under it — and its own `content` column is empty, so there is no member-only
# text on it for the comparison to take a marker out of. A protection suite whose subject carries
# no content cannot tell "the anonymous caller got none of it" from "there was none of it": both
# bodies are empty and every assertion about the difference is vacuous. So the subject is required
# to have a body, and TRIM because a column holding a newline is the same emptiness spelled longer.
#
# This is a stricter filter than `alias<>'support'`, not a looser one — it can only ever narrow the
# candidate set, so it cannot make this suite pass over a page it used to fail on.
#
# AND NEVER A DECLARED MACHINE DOOR. This suite's subject must be a page whose
# protection is MODx's to enforce. A machine door is deliberately outside that — its own element
# refuses the caller, so it answers an anonymous request 401 with a JSON body and no sign-in
# redirect, and every assertion below about a member reading more of it than a stranger is vacuous
# on a body that is the same refusal both times. Picking one would be the alias fault above exactly: a red
# that describes the suite's choice of subject rather than the estate's protection.
#
# Today the only door is `actuator/info`, which this query cannot reach anyway (`parent<>0`) — so
# this line changes no run. It is here because that is an accident of where the row sits, and the
# next door declared need not sit there. The list comes from the rendered `access.model`, the same
# declaration 04 writes and protectOnSave reads; a ground that has never run 04 has no setting, and
# the filter is then empty rather than guessed.
DOORS=$(q "SELECT value FROM modx_system_settings WHERE \`key\`='access.model';" \
        | python3 -c 'import json,sys
raw = sys.stdin.read().strip()
doors = (json.loads(raw).get("machine_doors") or []) if raw else []
print(",".join("'"'"'" + d.replace("'"'"'", "'"'"''"'"'") + "'"'"'" for d in doors))' 2>/dev/null)

# COALESCE because `uri` is empty when friendly URLs are off; the alias is the right answer then.
page=${MODX_TEST_PAGE:-$(q "SELECT COALESCE(NULLIF(uri,''), alias) FROM modx_site_content
    WHERE context_key='$CTX' AND published=1 AND parent=0 AND alias<>'support'
      AND TRIM(COALESCE(content,'')) <> ''
      ${DOORS:+AND COALESCE(NULLIF(uri,''), alias) NOT IN ($DOORS)}
    ORDER BY menuindex, id LIMIT 1;")}
[ -z "$page" ] && { echo "REFUSING TO RUN: '$CTX' has no published page outside support that carries any content — there is nothing here whose absence from an anonymous body would prove anything." >&2; exit 2; }
echo "  the page under test resolves from the database: /$page"

code()  { curl -s -o /dev/null -w '%{http_code}'   --resolve "${DOOR%%:*}:$PORT:$IP" "$SCHEME://$DOOR/$1"; }
redir() { curl -s -o /dev/null -w '%{redirect_url}' --resolve "${DOOR%%:*}:$PORT:$IP" "$SCHEME://$DOOR/$1"; }

root_code=$(code ''); root_to=$(redir '')
check "$([ "$root_code" = 302 ] && echo 1 || echo 0)" "the context root redirects an anonymous caller" "HTTP $root_code"
check "$(hasre "$root_to" 'sso-login$')" "…to the SSO entry, not the retired login form" "got '$root_to'"

anon_code=$(code "$page"); anon_to=$(redir "$page")
# 401 OR A REDIRECT TO SIGN-IN, and 200 is the only real failure — the same correction
# protect-on-save needed today. This demanded exactly 401 because that is what the
# old bench answered; staging sends an anonymous visitor to the context's own sign-in, which is
# what was made correct on both grounds. The assertions below already prove the part
# that matters — the anonymous caller receives 0 bytes of the member's 52046 — so demanding a
# particular refusal SHAPE here was the suite describing a bench, not protection.
check "$([ "$anon_code" != 200 ] && echo 1 || echo 0)" \
      "a content page is not SERVED to an anonymous caller" "HTTP $anon_code — it was served"
case "$anon_code" in
  401) anon_ok=1 ;;
  30[1237]) case "$anon_to" in *sso-login*|*login*) anon_ok=1 ;; *) anon_ok=0 ;; esac ;;
  *) anon_ok=0 ;;
esac
check "$anon_ok" "…and is refused or sent to sign-in" \
      "HTTP $anon_code${anon_to:+ -> $anon_to} — expected 401, or a 30x to this context's sign-in"
# ONE SIGN-IN SCREEN, THE DOOR'S: an anonymous /sso-login goes straight to THIS context's
# authorization endpoint, with NO prompt= — a silent ask (prompt=none) would bring back MODx's own card,
# which is the second screen he refused. Never a refusal, never a page of MODx's own.
si_code=$(code sso-login); si_to=$(redir sso-login)
check "$([ "$si_code" = 302 ] && [ -n "$CTX_AUTH" ] && [ "$(has "$si_to" "$CTX_AUTH")" = 1 ] && [ "$(has "$si_to" 'prompt=')" = 0 ] && echo 1 || echo 0)" \
      "the sign-in page sends an anonymous caller straight to the door, with no prompt (one screen)" "HTTP $si_code ${si_to:0:160}"
# THE SIGNED-OUT RETURN IS THE DOOR'S PAGE, NOT OURS (#1428; claude/shared/design/door-standard-login.md
# §2). The door hands a sign-out back to /sso-login?reason=signed_out, and MODx sends the browser
# straight on to the door's sign-in with chowkidar_reason=signed_out — the door's own words, "You are
# signed out", head its page. No kc_idp_hint: a hint skips the buttons and the provider, which still
# knows the person, signs them straight back in.
so_to=$(redir 'sso-login?reason=signed_out')
check "$([ "$(code 'sso-login?reason=signed_out')" = 302 ] && [ -n "$CTX_AUTH" ] && [ "$(has "$so_to" "$CTX_AUTH")" = 1 ] && [ "$(has "$so_to" 'chowkidar_reason=signed_out')" = 1 ] && echo 1 || echo 0)" \
      "the signed-out return goes straight to the door's sign-in, carrying chowkidar_reason=signed_out" "${so_to:0:200}"
check "$([ "$(has "$so_to" 'kc_idp_hint')" = 0 ] && [ "$(has "$so_to" 'prompt=')" = 0 ] && echo 1 || echo 0)" \
      "  with no kc_idp_hint and no prompt, so the person presses Sign in themselves" "${so_to:0:200}"
bogus_to=$(redir 'sso-login?reason=anything_else')
check "$([ "$(has "$bogus_to" "${CTX_AUTH:-//}")" = 1 ] && [ "$(has "$bogus_to" 'chowkidar_reason')" = 0 ] && echo 1 || echo 0)" \
      "a reason outside the door's fixed list is not forwarded" "${bogus_to:0:200}"
for q in 'state=signed-out' 'sso=out' 'sso=card' 'mgr=open'; do
  so=$(curl -s --resolve "${DOOR%%:*}:$PORT:$IP" "$SCHEME://$DOOR/sso-login?$q")
  check "$([ "$(has "$so" 'You are signed out of')" = 0 ] && [ "$(code "sso-login?$q")" = 302 ] && echo 1 || echo 0)" \
        "?$q draws no MODx signed-out card; it goes to the door" "${so:0:160}"
done
check "$([ "$(code robots)"    = 200 ] && echo 1 || echo 0)" "the support subtree stays anonymous"
anon_body=$(curl -s --resolve "${DOOR%%:*}:$PORT:$IP" "$SCHEME://$DOOR/$page")

# ── 2. a member ────────────────────────────────────────────────────────────────────────────────
# Whose account this is is a fact about the estate, not about a test file: resolved from the groups
# that actually cover this context.
reader=$(drill_reader)   # a machine identity, never a person
[ -z "$reader" ] && { echo "REFUSING TO RUN: drill_reader could not seat the suites' machine identity on this ground." >&2; exit 2; }

clear_cache

jar="$tmp/jar"
# The fifth suite that signs in, which c60efcf's "four" missed: it presents this box's certificate
# like the other four, so the door's certificate sign-in sees the same caller on every suite.
C=(curl -sS --resolve "${DOOR%%:*}:$PORT:$IP" -b "$jar" -c "$jar" -m 15)
loc=$("${C[@]}" -o /dev/null -w '%{redirect_url}' "$SCHEME://$DOOR/sso-login?sso=go")
check "$(has "$loc" "${CTX_AUTH:-$IDP}")" "sign-in leaves for the provider" "got '$loc'"
cb=$(idp_sign_in "$loc" "$reader")   # the door's form, by password (lib.sh)
check "$(has "$cb" 'code=')" "signing in yields an authorization code" "got '$cb'"
check "$([ "$("${C[@]}" -o /dev/null -w '%{http_code}' "$cb")" = 302 ] && echo 1 || echo 0)" \
      "the callback completes the exchange"

member_code=$("${C[@]}" -o /dev/null -w '%{http_code}' "$SCHEME://$DOOR/$page")
check "$([ "$member_code" = 200 ] && echo 1 || echo 0)" "THE MEMBER READS THE PAGE" "HTTP $member_code"
member_body=$("${C[@]}" "$SCHEME://$DOOR/$page")

# ── 3. the comparison — the one check that cannot pass while the page is public ────────────────
marker=$(printf '%s' "$member_body" | python3 -c '
import sys, re
html = re.sub(r"(?is)<(script|style).*?</\1>", " ", sys.stdin.read())
texts = [t.strip() for t in re.split(r"<[^>]+>", html)]
print(max(texts, key=len) if texts else "")')
check "$([ "${#marker}" -ge 20 ] && echo 1 || echo 0)" \
      "a marker was taken from the member's own copy" "got '${marker:0:60}'"
check "$(hasnt "$anon_body" "$marker")" "the anonymous caller received NONE of that content" \
      "the member's text appeared in the anonymous response"
check "$([ "${#anon_body}" -lt $(( ${#member_body} / 2 )) ] && echo 1 || echo 0)" \
      "the anonymous body is a fraction of the member's (${#anon_body} vs ${#member_body} bytes)"

# ── 4. the member signs out, at the door (#1428; door-standard-login.md §2) ────────────────────
# One hop, not followed: the sign-out ends MODx's session and hands the browser to the door's
# end_session_endpoint with the session's id_token and a way back to this context's sign-in entry.
out_to=$("${C[@]}" -o /dev/null -w '%{redirect_url}' "$SCHEME://$DOOR/sso-logout")
shown=$(printf '%s' "$out_to" | sed -E 's/(id_token_hint=)[^&]*/\1<token>/')   # a failure never prints a token
check "$([ "$(has "$out_to" 'protocol/openid-connect/logout')" = 1 ] && [ "$(has "$out_to" 'id_token_hint=')" = 1 ] && echo 1 || echo 0)" \
      "sign-out goes to the door's end_session_endpoint with id_token_hint" "${shown:0:240}"
check "$(has "$out_to" 'post_logout_redirect_uri=')" \
      "  and names where the door returns the browser" "${shown:0:240}"
check "$(has "$out_to" 'sso-login%3Freason%3Dsigned_out')" \
      "  which is this context's sign-in entry with reason=signed_out" "${shown:0:300}"
after=$("${C[@]}" -o /dev/null -w '%{http_code}' "$SCHEME://$DOOR/$page")
check "$([ "$after" != 200 ] && echo 1 || echo 0)" "after it, the page is no longer served to that browser" "HTTP $after"

summary
