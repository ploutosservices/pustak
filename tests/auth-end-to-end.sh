#!/usr/bin/env bash
# auth-end-to-end.sh — a real page, a real sign-in, and the token read off the wire.
#
#     bash tests/auth-end-to-end.sh
#
# WHAT THIS ADDS over tests/tableRenderer-auth.php. That test runs the real snippet against a
# stubbed $modx, so it proves the logic and the token. It cannot prove the three MODx calls the
# logic RESTS on — $modx->user->isAuthenticated($ctx), $modx->user->getOne('Profile'), and
# $_SESSION surviving into snippet scope — because a stub answers those the way I expect rather
# than the way MODx does. Getting any of them wrong shows up as a permanently blank table, which is
# also the correct output for "nobody is signed in": the failure is indistinguishable from success
# by looking at the page. So it is measured here instead, on the bench, end to end:
#
#   anonymous  -> the page renders and NOTHING is requested of the audience   (the owner's "display blank")
#   signed in  -> a Bearer arrives: the reader's door token EXCHANGED for kuber —
#                 signed by the door's published keys, aud kuber, azp this context's client, the
#                 reader's address — and the same token is refused for another audience
#
# BENCH ONLY. It creates one page and removes it. It signs in as the suites' machine identity.
set -uo pipefail

HOST=${MODX_TEST_HOST:-}   # empty: the context's live http_host, read after lib.sh
IP=${MODX_TEST_IP:-127.0.0.1}
CTX=${MODX_TEST_CTX:-$(python3 "$(dirname "${BASH_SOURCE[0]}")/../setup/estate-get.py" domains.contexts | head -1)}   # default: the estate's first context
[ -n "$CTX" ] || { echo "REFUSING TO RUN: no MODX_TEST_CTX and no context in the estate MODX_ESTATE names" >&2; exit 2; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ALIAS=tablerenderer-auth-e2e

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -n "$HOST" ] || HOST=$(ctx_host "$CTX") || exit 2

# The scheme and port are DECLARED, not assumed — see lib.sh origin_of(). This REFUSES if the
# ground cannot tell it which, rather than speaking http at an https edge and reporting the 301
# as a failure of the page.
read -r SCHEME PORT < <(host_origin "$HOST")
DOOR=$(host_door "$HOST") || exit 2

require_repo
require_bench
require_nonprod_door

echo "tableRenderer &auth — end to end on the bench"

reader=$(drill_reader)   # a machine identity, never a person
[ -z "$reader" ] && { echo "REFUSING TO RUN: drill_reader could not seat the suites' machine identity on this ground." >&2; exit 2; }

tmp=$(mktemp -d); chmod 700 "$tmp"
cleanup() {
  q "DELETE FROM modx_site_content WHERE context_key='$CTX' AND alias='$ALIAS';" >/dev/null 2>&1
  # local_php is a function, so `local_php -S … &` is a subshell and $! is ITS pid: kill the php under
  # it first, or the server outlives the run (136 of them were found in /tmp on 2026-10-12).
  [ -n "${listener:-}" ] && { pkill -P "$listener" 2>/dev/null; kill "$listener" 2>/dev/null; }
  modx_php "$REPO/clear-cache.php" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
# --- the audience: a listener that records what it was sent ------------------------------------
port=$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1]); s.close()
PY
)
cat > "$tmp/router.php" <<'PHP'
<?php
$auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
file_put_contents(getenv('E2E_LOG'), $auth . "\n", FILE_APPEND);
header('Content-Type: application/json');
echo json_encode(['rows' => [['figure' => 'reached the audience']]]);
PHP
touch "$tmp/requests.log"
# WHERE THE AUDIENCE LISTENS AND WHERE MODX REACHES IT ARE TWO ADDRESSES ON A CONTAINERISED
# GROUND — AND THE SECOND ONE MUST BE A NAME.
#
# Two measurements, one after the other, on the ground's first zero-refusal runs (2026-08-14):
#   * bound 127.0.0.1 and told the page the same: "could not fetch http://127.0.0.1:46653 — Could
#     not connect". MODx is in a container; that loopback is its own.
#   * bound the container's default gateway (172.17.0.1, read from /proc/net/route inside it) and
#     tableRenderer REFUSED: "&auth will not present a bearer credential in clear text ... must be
#     https (plain http is accepted only on loopback or an internal-zone host)". That is my own production
#     guard, behaving exactly as designed, and it is right — a bearer over plain http to a bare IP
#     is the thing it exists to stop.
#
# So the audience is addressed the way the estate addresses everything: by its internal-zone name. The
# runner's own FQDN is used when it is an internal-zone one AND the container can resolve it; the fixture
# binds the interface that name resolves to, not a wildcard. A dev box (no MODX_PHP_RUN) keeps
# loopback, which the guard also allows. Anything else REFUSES rather than quietly weakening the
# rule the guard enforces in production.
BIND=127.0.0.1
REACH=127.0.0.1
if [ -n "${MODX_PHP_RUN:-}" ]; then
  # AN INTERNAL-ZONE NAME THAT RESOLVES TO THIS MACHINE — found, not guessed, and not asked for.
  #
  # The audience needs a name because tableRenderer will not send a bearer over plain http to a
  # bare IP. hanuman answers `hostname -f` without its zone and its resolv.conf search list yields
  # nothing, so I nearly asked infra to declare one. It is already declared: the site's own host
  # names resolve to the machine the suites run on — the bench context's name and the runner's own
  # internal name are both this runner's address. A fixture on a high port of that same interface is
  # reached by the same name the estate already uses, and no ground has to state anything new.
  #
  # The rule, so it holds on any ground: take an internal-zone name that resolves to an address THIS
  # machine holds, and that the container can resolve too. Never compose a zone from a hostname.
  mine=$(ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  fqdn=""; zone=$(internal_zone)
  for cand in "$HOST" "$(hostname -f 2>/dev/null)"; do
    under_zone "$cand" "$zone" || continue
    cip=$(getent hosts "$cand" 2>/dev/null | awk '{print $1; exit}')
    [ -n "$cip" ] || continue
    printf '%s\n' $mine | grep -qx "$cip" || continue      # it must be an address I hold
    fqdn="$cand"; break
  done
  if [ -n "$fqdn" ]; then
    # …and the container must be able to resolve it, or the page would name something MODx cannot
    # reach. ARGV, not an env var: manifest-drift caught that shape twice today.
    seen=$(modx_php -r 'echo gethostbyname($argv[1]) === $argv[1] ? "" : "yes";' -- "$fqdn" 2>/dev/null || true)
    [ -n "$seen" ] || fqdn=""
  fi
  if [ -n "$fqdn" ]; then
    REACH=$fqdn
    BIND=$(getent hosts "$fqdn" | awk '{print $1; exit}')
    [ -n "$BIND" ] || BIND=0.0.0.0
  else
    echo "REFUSING TO RUN: MODx runs elsewhere on this ground (MODX_PHP_RUN is set) and this" >&2
    echo "                 machine has no internal-zone name for it to call back on. tableRenderer will" >&2
    echo "                 not send a bearer over plain http to anything but loopback or an internal" >&2
    echo "                 host — correctly — so the audience cannot be reached without one, and" >&2
    echo "                 weakening that guard to run a test is not on the table." >&2
    exit 2
  fi
fi
E2E_LOG="$tmp/requests.log" local_php -S "$BIND:$port" -t "$tmp" "$tmp/router.php" >"$tmp/listener.out" 2>&1 &
listener=$!
for _ in $(seq 40); do (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null && break; sleep 0.05; done

# --- wire the bench: one page that reads through &auth ----------------------------------------
q "INSERT INTO modx_site_content
     (type,pagetitle,longtitle,menutitle,description,alias,uri,uri_override,template,content_type,
      parent,context_key,published,hidemenu,menuindex,searchable,cacheable,richtext,createdby,
      createdon,publishedon,publishedby,content)
   VALUES ('document','auth e2e','','','','$ALIAS','$ALIAS',1,0,1,
      0,'$CTX',1,1,0,0,0,0,1,UNIX_TIMESTAMP(),UNIX_TIMESTAMP(),1,
      '[[!tableRenderer? &url=\`http://$REACH:$port/figures\` &rows=\`rows\` &auth=\`kuber\`]]');" \
  || { echo "could not create the test page" >&2; exit 2; }
clear_cache

PAGE="$SCHEME://$DOOR/$ALIAS"

# --- 1. anonymous: the page must ask the audience nothing --------------------------------------
anon=$(curl -sS --resolve "${DOOR%%:*}:$PORT:$IP" -m 10 "$PAGE")
check "$([ "$(wc -l < "$tmp/requests.log")" = 0 ] && echo 1 || echo 0)" \
      "an anonymous reader causes no request to the audience" \
      "log: $(cat "$tmp/requests.log")"
check "$(hasnt "$anon" '<table')" \
      "an anonymous reader sees no table — blank, as the owner asked" "$(echo "$anon" | head -c 300)"

# --- 2. sign in for real, then load the same page ----------------------------------------------
jar="$tmp/cookies"
C=(curl -sS --resolve "${DOOR%%:*}:$PORT:$IP" -b "$jar" -c "$jar" -m 10)
loc=$("${C[@]}" -o /dev/null -w '%{redirect_url}' "$SCHEME://$DOOR/sso-login?sso=go")
cb=$(idp_sign_in "$loc" "$reader")   # the door's form, by password (lib.sh)
"${C[@]}" -o /dev/null "$cb"
sid=$(awk '/PHPSESSID/ {print $7}' "$jar" | tail -1)
signed=$(q "SELECT data FROM modx_session WHERE id='$sid';" | grep -c 'user.token')
check "$([ "$signed" = 1 ] && echo 1 || echo 0)" "signed in on the bench as an existing user" "session $sid"

out=$("${C[@]}" "$PAGE")
sent=$(tail -1 "$tmp/requests.log")
check "$([ "$(wc -l < "$tmp/requests.log")" = 1 ] && echo 1 || echo 0)" \
      "a signed-in reader causes exactly one request" "log: $(cat "$tmp/requests.log")"
check "$(hasre "$sent" '^Bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$')" \
      "a Bearer assertion arrives at the audience" "header: '$sent'"
check "$(has "$out" 'reached the audience')" \
      "the value fetched as the reader is what the page shows" "$(echo "$out" | head -c 300)"

# --- 3. the token: the door's, exchanged for kuber, checked against the door's published keys ----
# MODx mints nothing (the iss-modx assertion and kuber.jwt_private_key are retired). The verifier is
# the one every MODx caller uses (common/lib/GoogleToken.php, kuber's generated copy), fed this
# context's own door issuer and keys — as kuber's reader is.
jwt=${sent#Bearer }
verify() {   # $1 the audience expected; prints the verified address, or REFUSED: <why>
  JWT="$jwt" AUD="$1" ISS=$(ctx_setting sso.oidc_issuer) JWKS=$(ctx_setting sso.oidc_jwks_uri) \
  local_php -r '
    require getenv("LIB") . "/GoogleToken.php";
    $jwks = getenv("JWKS");
    $src = function () use ($jwks) { $j = json_decode((string) @file_get_contents($jwks), true); return is_array($j) ? $j : null; };
    $why = null;
    $e = Kuber\Core\GoogleToken::verify(getenv("JWT"), [getenv("AUD")], $why, $src, [getenv("ISS")]);
    echo $e === null ? "REFUSED: $why" : $e;
  '
}
ctx_setting() { q "SELECT value FROM modx_context_setting WHERE context_key='$CTX' AND \`key\`='$1';"; }
export LIB="$REPO/common/lib"
claims=$(printf '%s' "$jwt" | cut -d. -f2 | python3 -c 'import sys,base64,json; p=sys.stdin.read().strip(); c=json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))); print(c.get("aud"), c.get("azp"), c.get("typ"), c.get("iss"))' 2>/dev/null)
read -r aud azp typ iss <<<"$claims"
client=$(ctx_setting sso.oidc_client_id)
check "$([ "$iss" != modx ] && echo 1 || echo 0)" "the Bearer is not a MODx-minted assertion" "iss: '$iss'"
check "$([ "$aud" = kuber ] && [ "$typ" = Bearer ] && echo 1 || echo 0)" \
      "it is a token exchanged for kuber: aud kuber, typ Bearer" "aud '$aud' typ '$typ'"
check "$([ -n "$client" ] && [ "$azp" = "$client" ] && echo 1 || echo 0)" \
      "...asked for by this context's own door client" "azp '$azp', the context's client '$client'"
verified=$(verify kuber)
check "$([ "$verified" = "$reader" ] && echo 1 || echo 0)" \
      "the door's published keys verify it, for audience kuber, as the address that signed in" "returned: '$verified'"
# The control: the same token for another audience must refuse, or the line above proves only that a
# string came back.
refused=$(verify someone-else)
check "$([ "${refused%%:*}" = REFUSED ] && echo 1 || echo 0)" \
      "...and the same token is refused for another audience" "returned: '$refused'"

q "DELETE FROM modx_session WHERE id='$sid';" >/dev/null 2>&1
summary
