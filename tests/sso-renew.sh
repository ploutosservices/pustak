#!/usr/bin/env bash
# sso-renew.sh — a signed-in reader stays signed in past the token's hour, and a name kuber does
# not give is MARKED, not left blank.
#
#     bash tests/sso-renew.sh
#
# The owner, 2026-10-05, signed out mid-visit and then shown blank cells with nothing in the log:
# "when you get nothing from Kuber, can you indicate it somehow, should google token be renewed on
# each page load, preferably in background." Both answers live on the SIGNED-IN surface, so this
# signs in for real at the door and reads the server-side session row.
#
#   renewal    a token near expiry is traded for a new one of the SAME reader on the next page;
#              with ssoRenew disabled the same state is NOT renewed (the control: the check can fail);
#              a renewal key the provider refuses ENDS the session and says so in the log.
#   the dash   a stand-in reader gives one name of two: the given one is drawn, the other carries
#              the dash titled "kuber did not give this to <reader>", and the log names the id;
#              a reader that answers 500 puts the dash in both, titled with the status.
#
# BENCH ONLY, and not in a container: the stand-in reader listens on this machine's loopback, which
# is a different loopback from a containerised MODx's. It signs in as the suites' machine identity
# at the door's non-production realm.
set -uo pipefail

HOST=${MODX_TEST_HOST:-}   # empty: the context's live http_host, read after lib.sh
IP=${MODX_TEST_IP:-127.0.0.1}
CTX=${MODX_TEST_CTX:-platform}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ALIAS=sso-renew-suite

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -n "$HOST" ] || HOST=$(ctx_host "$CTX") || exit 2

read -r SCHEME PORT < <(host_origin "$HOST")
DOOR=$(host_door "$HOST") || exit 2

require_repo
require_bench
require_nonprod_door
if [ -n "${MODX_PHP_RUN:-}" ]; then
  echo "REFUSING TO RUN: MODx runs in a container on this ground (MODX_PHP_RUN is set), so the" >&2
  echo "                 stand-in kuber reader on this machine's loopback is not MODx's loopback." >&2
  exit 2
fi

echo "the reader stays signed in, and a missing name is marked"

reader=$(drill_reader)   # a machine identity, never a person
[ -z "$reader" ] && { echo "REFUSING TO RUN: drill_reader could not seat the suites' machine identity on this ground." >&2; exit 2; }
plugin=$(q "SELECT COUNT(*) FROM modx_site_plugins p JOIN modx_site_plugin_events e ON e.pluginid=p.id
            WHERE p.name='ssoRenew' AND p.disabled=0 AND e.event='OnWebPageInit';")
[ "$plugin" = 1 ] || { echo "REFUSING TO RUN: ssoRenew is not installed and bound to OnWebPageInit on this bench." >&2; exit 2; }
LOG="$MODX_ROOT/core/logs/error.log"
[ -n "${MODX_ROOT:-}" ] || { echo "REFUSING TO RUN: MODX_ROOT is not set — the error log cannot be read." >&2; exit 2; }

was_url=$(q "SELECT value FROM modx_system_settings WHERE \`key\`='kuber.reader_url';")
tmp=$(mktemp -d); chmod 700 "$tmp"
cleanup() {
  q "DELETE FROM modx_site_content WHERE context_key='$CTX' AND alias='$ALIAS';" >/dev/null 2>&1
  q "UPDATE modx_system_settings SET value='$was_url' WHERE \`key\`='kuber.reader_url';" >/dev/null 2>&1
  q "UPDATE modx_site_plugins SET disabled=0 WHERE name='ssoRenew';" >/dev/null 2>&1
  # local_php is a function, so `local_php -S … &` is a subshell and $! is ITS pid: kill the php under
  # it first, or the server outlives the run (136 of them were found in /tmp on 2026-10-12).
  [ -n "${listener:-}" ] && { pkill -P "$listener" 2>/dev/null; kill "$listener" 2>/dev/null; }
  modx_php "$REPO/clear-cache.php" "$MODX_ROOT" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# --- the server-side session, read and edited by key -------------------------------------------
# The MODx session is a row in modx_session, PHP-serialised. Only two scalars are ever edited here
# (the token's expiry and the renewal key), each matched by its own key, so no decoder is needed.
sess() {   # sess get <key> | sess set-exp <epoch> | sess set-refresh <value>
  python3 - "$sid" "$@" <<'PY'
import getpass, os, re, sys, pymysql
sid, op = sys.argv[1], sys.argv[2]
sock = os.environ.get('MODX_DB_SOCKET')
kw = (dict(unix_socket=sock, user=os.environ.get('MODX_DB_USER') or getpass.getuser(), password='')
      if sock and not os.environ.get('MODX_DB_PASS')
      else dict(host=os.environ.get('MODX_DB_HOST', 'localhost'), user=os.environ.get('MODX_DB_USER') or getpass.getuser(),
                password=os.environ.get('MODX_DB_PASS', '')))
c = pymysql.connect(database=os.environ.get('MODX_DB_NAME', 'modx'), charset='utf8mb4', **kw)
cur = c.cursor()
cur.execute("SELECT data FROM modx_session WHERE id=%s", (sid,))
row = cur.fetchone()
data = (row[0] if row else '') or ''
if op == 'get':
    m = re.search(re.escape(sys.argv[3]) + r'\|(?:i:(\d+);|s:\d+:"([^"]*)";)', data)
    print((m.group(1) or m.group(2)) if m else '')
    sys.exit(0)
if op == 'set-exp':
    new, n = re.subn(r'sso\.id_token_exp\|i:\d+;', 'sso.id_token_exp|i:%d;' % int(sys.argv[3]), data)
elif op == 'set-refresh':
    v = sys.argv[3]
    new, n = re.subn(r'sso\.refresh_token\|s:\d+:"[^"]*";', 'sso.refresh_token|s:%d:"%s";' % (len(v), v), data)
else:
    sys.exit('unknown op ' + op)
if n != 1:
    sys.exit(f'{op}: the key is not in session {sid} exactly once (found {n})')
cur.execute("UPDATE modx_session SET data=%s WHERE id=%s", (new, sid))
c.commit()
PY
}

# --- a stand-in kuber reader: gives the name of id 1 only, or answers 500 ----------------------
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
cat > "$tmp/reader.php" <<'PHP'
<?php
$mode = trim((string) @file_get_contents(getenv('READER_MODE')));
file_put_contents(getenv('READER_MODE') . '.auth', ($_SERVER['HTTP_AUTHORIZATION'] ?? '') . "\n", FILE_APPEND);
header('Content-Type: application/json');
if ($mode === '500') { http_response_code(500); echo '{"error":"down"}'; return; }
echo json_encode(['1' => 'Name One']);
PHP
echo ok > "$tmp/mode"
READER_MODE="$tmp/mode" local_php -S "127.0.0.1:$port" -t "$tmp" >"$tmp/listener.out" 2>&1 &
listener=$!
for _ in $(seq 40); do (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null && break; sleep 0.05; done
q "UPDATE modx_system_settings SET value='http://127.0.0.1:$port/reader.php' WHERE \`key\`='kuber.reader_url';"

q "INSERT INTO modx_site_content
     (type,pagetitle,longtitle,description,introtext,alias,uri,published,deleted,template,
      parent,context_key,hidemenu,menuindex,searchable,cacheable,richtext,createdby,
      createdon,publishedon,publishedby,content)
   VALUES ('document','sso renew suite','','','','$ALIAS','$ALIAS',1,0,4,
      0,'$CTX',1,0,0,0,0,1,UNIX_TIMESTAMP(),UNIX_TIMESTAMP(),1,
      '<p>one: <span class=\"bird\" kuberid=\"1\"></span></p><p>two: <span class=\"bird\" kuberid=\"2\"></span></p><p>three: <span kuberid=\"1\"></span></p>');" \
  || { echo "could not create the test page" >&2; exit 2; }
clear_cache

PAGE="$SCHEME://$DOOR/$ALIAS"
jar="$tmp/cookies"
C=(curl -sS --resolve "${DOOR%%:*}:$PORT:$IP" -b "$jar" -c "$jar" -m 15)

# --- sign in for real at the door --------------------------------------------------------------
loc=$("${C[@]}" -o /dev/null -w '%{redirect_url}' "$SCHEME://$DOOR/sso-login?sso=go")
cb=$(idp_sign_in "$loc" "$reader")   # the door's form, by password (lib.sh)
"${C[@]}" -o /dev/null "$cb"
sid=$(awk '/PHPSESSID/ {print $7}' "$jar" | tail -1)
check "$([ -n "$(sess get sso.verified_email)" ] && echo 1 || echo 0)" "signed in on the bench as $reader" "session $sid"
check "$([ -n "$(sess get sso.refresh_token)" ] && echo 1 || echo 0)" \
      "the sign-in kept a renewal key beside the token" "no sso.refresh_token in session $sid"

# --- renewal ------------------------------------------------------------------------------------
tok0=$(sess get sso.id_token)
"${C[@]}" -o /dev/null "$PAGE"
check "$([ "$(sess get sso.id_token)" = "$tok0" ] && echo 1 || echo 0)" \
      "a token with most of its hour left is NOT renewed (one call an hour, not one a page)" ""

# The control first: with the plugin off, the near-expiry state must survive a page unchanged —
# otherwise the green below could be something other than ssoRenew.
q "UPDATE modx_site_plugins SET disabled=1 WHERE name='ssoRenew';"; clear_cache
sess set-exp $(( $(date +%s) + 60 ))
"${C[@]}" -o /dev/null "$PAGE"
check "$([ "$(sess get sso.id_token)" = "$tok0" ] && echo 1 || echo 0)" \
      "control: with ssoRenew disabled, a token about to expire is left as it is" ""
q "UPDATE modx_site_plugins SET disabled=0 WHERE name='ssoRenew';"; clear_cache

sess set-exp $(( $(date +%s) + 60 ))
"${C[@]}" -o /dev/null "$PAGE"
tok1=$(sess get sso.id_token); exp1=$(sess get sso.id_token_exp)
check "$([ -n "$tok1" ] && [ "$tok1" != "$tok0" ] && echo 1 || echo 0)" \
      "a token about to expire is renewed on the next page" "token unchanged or gone"
check "$([ "${exp1:-0}" -gt $(( $(date +%s) + 1800 )) ] && echo 1 || echo 0)" \
      "and the new one has most of an hour ahead of it" "exp=$exp1"
check "$([ "$(sess get sso.verified_email)" = "$reader" ] && echo 1 || echo 0)" \
      "and the reader is still signed in, as the same person" "verified_email=$(sess get sso.verified_email)"

# --- the dash -----------------------------------------------------------------------------------
lines0=$(wc -l < "$LOG" 2>/dev/null || echo 0)
out=$("${C[@]}" "$PAGE")
check "$(hasre "$out" 'class="bird" kuberid="1" title="Name One">[[:space:]]*</span>')" "a name kuber gives is a bird's TOOLTIP, not text on screen" \
      "$(printf '%s' "$out" | grep -o 'kuberid="1" title.\{0,60\}' | head -1)"
check "$(has "$out" '<span kuberid="1">Name One</span>')" "  and any other element shows it as its text" \
      "$(printf '%s' "$out" | grep -o '<span kuberid="1">[^<]*' | head -1)"
check "$(has "$out" "kuberid=\"2\"><span class=\"kuber-unnamed\" title=\"No name: kuber did not give this to $reader.\">&mdash;</span>")" \
      "a name kuber does not give shows the dash, titled with why" \
      "$(printf '%s' "$out" | grep -o 'kuberid="2">[^/]*' | head -1)"
check "$(has "$(tail -n +"$((lines0 + 1))" "$LOG" 2>/dev/null)" "kuber gave no name for 2")" \
      "and the log names the id, at a level production keeps" "no 'kuber gave no name for 2' in $LOG"
check "$(hasnt "$out" 'kuberid="1"><span class="kuber-unnamed"')" "a drawn name carries no dash" ""
# What reached the reader: the reader's door token EXCHANGED for kuber, asked for by
# this context's own door client — never the reader's own id_token (aud = the context's client).
claims=$(tail -1 "$tmp/mode.auth" | sed 's/^Bearer //' | cut -d. -f2 | python3 -c 'import sys,base64,json; p=sys.stdin.read().strip(); c=json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))); print(c.get("aud"), c.get("azp"), c.get("typ"))' 2>/dev/null)
read -r aud azp typ <<<"$claims"
client=$(q "SELECT value FROM modx_context_setting WHERE context_key='$CTX' AND \`key\`='sso.oidc_client_id';")
check "$([ "$aud" = kuber ] && [ "$typ" = Bearer ] && [ -n "$client" ] && [ "$azp" = "$client" ] && echo 1 || echo 0)" \
      "kuber is sent the reader's token exchanged for kuber, by this context's client" "aud '$aud' azp '$azp' typ '$typ', client '$client'"

echo 500 > "$tmp/mode"
out=$("${C[@]}" "$PAGE")
check "$(has "$out" 'kuberid="1"><span class="kuber-unnamed" title="No name: kuber did not answer (HTTP 500).">&mdash;</span>')" \
      "a reader that answers 500 puts the dash in every cell, titled with the status" \
      "$(printf '%s' "$out" | grep -o 'kuberid="1">[^/]*' | head -1)"
echo ok > "$tmp/mode"

# --- a renewal key the provider refuses ends the session ----------------------------------------
lines0=$(wc -l < "$LOG" 2>/dev/null || echo 0)
sess set-refresh "not-a-key-the-provider-issued"
sess set-exp $(( $(date +%s) + 60 ))
"${C[@]}" -o /dev/null "$PAGE"
check "$([ -z "$(sess get sso.verified_email)" ] && echo 1 || echo 0)" \
      "a renewal key the provider refuses ends the session" "verified_email still $(sess get sso.verified_email)"
check "$(has "$(tail -n +"$((lines0 + 1))" "$LOG" 2>/dev/null)" "ssoRenew: $reader's token could not be renewed")" \
      "and the log says whose and why" "no ssoRenew line in $LOG"

summary
