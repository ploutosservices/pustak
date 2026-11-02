#!/usr/bin/env bash
# backchannel-logout.sh — the door's back-channel sign-out ends the MODx sessions it names, and
# nothing else ends anything.
#
#     bash tests/backchannel-logout.sh
#
# claude/shared/design/back-channel-logout-skunkworks.md §3. The door is NOT called: this mints a
# throwaway RSA key pair, serves its public half as the door's keys (a stub on this machine's
# loopback, put in the context's sso.oidc_jwks_uri for the run), and signs its own logout tokens
# with the context's real issuer and client id. The sessions are minted as modx_session rows of the
# bench's first active user, read and edited by key as tests/sso-renew.sh does.
#
#   (a) a token signed by a DIFFERENT key -> 400, the session survives; unknown kids refetch the
#       keys at most once per 60 s
#   (b) each of rules 1 and 3-6 broken alone, a wrong method / content type / field count / size
#       -> 400 or 405, the session survives and the registry holds nothing for it
#   (c) a valid token naming the session -> 200, the registry holds its sid, the row is gone, and
#       the next request is signed out; a session WRITTEN BACK after that is ended by ssoRenew on
#       its next page (control: with ssoRenew disabled it is not)
#   (d) a valid token naming nobody -> 200, and an unnamed session survives
#
# BENCH ONLY, and not in a container: the stub keys listen on this machine's loopback.
set -uo pipefail

HOST=${MODX_TEST_HOST:-}   # empty: the context's live http_host, read after lib.sh
IP=${MODX_TEST_IP:-127.0.0.1}
CTX=${MODX_TEST_CTX:-platform}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ALIAS=backchannel-logout-suite
TOPIC=/pustak/ended-sid/

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -n "$HOST" ] || HOST=$(ctx_host "$CTX") || exit 2

read -r SCHEME PORT < <(host_origin "$HOST")
DOOR=$(host_door "$HOST") || exit 2

require_repo
require_bench
if [ -n "${MODX_PHP_RUN:-}" ]; then
  echo "REFUSING TO RUN: MODx runs in a container on this ground (MODX_PHP_RUN is set), so the" >&2
  echo "                 stub keys on this machine's loopback are not MODx's loopback." >&2
  exit 2
fi

cs() { q "SELECT value FROM modx_context_setting WHERE context_key='$CTX' AND \`key\`='$1';"; }
[ "$(cs sso.provider)" = oidc ] || { echo "REFUSING TO RUN: '$CTX' does not sign in through the door (sso.provider is not oidc)." >&2; exit 2; }
ISS=$(cs sso.oidc_issuer); AUD=$(cs sso.oidc_client_id)
[ -n "$ISS" ] && [ -n "$AUD" ] || { echo "REFUSING TO RUN: '$CTX' has no sso.oidc_issuer or sso.oidc_client_id." >&2; exit 2; }
page=$(q "SELECT COUNT(*) FROM modx_site_content WHERE context_key='$CTX' AND uri='sso-backchannel-logout'
          AND deleted=0 AND published=1 AND content LIKE '%[[!ssoBackchannelLogout]]%';")
[ "$page" = 1 ] || { echo "REFUSING TO RUN: '$CTX' has no /sso-backchannel-logout page — run setup/12-sso.py." >&2; exit 2; }
plugin=$(q "SELECT COUNT(*) FROM modx_site_plugins p JOIN modx_site_plugin_events e ON e.pluginid=p.id
            WHERE p.name='ssoRenew' AND p.disabled=0 AND e.event='OnWebPageInit';")
[ "$plugin" = 1 ] || { echo "REFUSING TO RUN: ssoRenew is not installed and bound to OnWebPageInit on this bench." >&2; exit 2; }
read -r uid reader < <(q "SELECT u.id, p.email FROM modx_user_attributes p JOIN modx_users u ON u.id=p.internalKey
                          WHERE u.active=1 AND p.email LIKE '%@%' ORDER BY u.id LIMIT 1;")
[ -n "${reader:-}" ] || { echo "REFUSING TO RUN: no active user with an email on this bench." >&2; exit 2; }

echo "the door's back-channel sign-out, in context $CTX"

# The ending is a DELETE of modx_session rows; a session cache would keep serving a deleted one.
dbs=$(q "SELECT value FROM modx_system_settings WHERE \`key\`='cache_db_session';")
check "$([ -z "$dbs" ] || [ "$dbs" = 0 ] && echo 1 || echo 0)" "cache_db_session is off, so a deleted session row is gone" "cache_db_session=$dbs"

was_jwks=$(cs sso.oidc_jwks_uri)
# THE SETTING IS OPTIONAL (SsoConfig: absent, the issuer's discovery document names the keys), so a
# context may hold no row for it. An UPDATE of a missing row changes nothing and the snippet fetched the
# door's real keys: the suite then failed 8 checks with 'no RSA key for kid' and zero hits. So the run
# writes the row whether or not it exists, and the cleanup removes a row the run created.
had_jwks=$(q "SELECT COUNT(*) FROM modx_context_setting WHERE context_key='$CTX' AND \`key\`='sso.oidc_jwks_uri';")
tmp=$(mktemp -d); chmod 700 "$tmp"
sessions=(); sids=()
cleanup() {
  if [ "${had_jwks:-0}" = 0 ]; then
    q "DELETE FROM modx_context_setting WHERE context_key='$CTX' AND \`key\`='sso.oidc_jwks_uri';" >/dev/null 2>&1
  else
    q "UPDATE modx_context_setting SET value='$was_jwks' WHERE context_key='$CTX' AND \`key\`='sso.oidc_jwks_uri';" >/dev/null 2>&1
  fi
  q "DELETE FROM modx_site_content WHERE context_key='$CTX' AND alias='$ALIAS';" >/dev/null 2>&1
  q "UPDATE modx_site_plugins SET disabled=0 WHERE name='ssoRenew';" >/dev/null 2>&1
  for s in "${sessions[@]}"; do q "DELETE FROM modx_session WHERE id='$s';" >/dev/null 2>&1; done
  for s in "${sids[@]}"; do
    q "DELETE m FROM modx_register_messages m JOIN modx_register_topics t ON t.id=m.topic
       WHERE t.name='$TOPIC' AND m.id='$s';" >/dev/null 2>&1
  done
  [ -n "${listener:-}" ] && { pkill -P "$listener" 2>/dev/null; kill "$listener" 2>/dev/null; }
  modx_php "$REPO/clear-cache.php" "$MODX_ROOT" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# --- the stub door: two keys, one published --------------------------------------------------------
KID=bcl-suite-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
local_php -r '
  foreach (["a", "b"] as $n) {
    $k = openssl_pkey_new(["private_key_bits" => 2048, "private_key_type" => OPENSSL_KEYTYPE_RSA]);
    openssl_pkey_export($k, $pem); file_put_contents($argv[1] . "/$n.pem", $pem);
    if ($n === "a") {
      $d = openssl_pkey_get_details($k)["rsa"];
      $u = fn($s) => rtrim(strtr(base64_encode($s), "+/", "-_"), "=");
      file_put_contents($argv[1] . "/jwks.json", json_encode(["keys" => [
        ["kty" => "RSA", "use" => "sig", "alg" => "RS256", "kid" => $argv[2], "n" => $u($d["n"]), "e" => $u($d["e"])]]]));
    }
  }' "$tmp" "$KID" || { echo "could not mint the throwaway keys" >&2; exit 2; }
cat > "$tmp/keys.php" <<'PHP'
<?php
file_put_contents(getenv('HITS'), "hit\n", FILE_APPEND);
header('Content-Type: application/json');
readfile(getenv('JWKS'));
PHP
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
: > "$tmp/hits"
HITS="$tmp/hits" JWKS="$tmp/jwks.json" local_php -S "127.0.0.1:$port" -t "$tmp" >"$tmp/listener.out" 2>&1 &
listener=$!
for _ in $(seq 40); do (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null && break; sleep 0.05; done
q "INSERT INTO modx_context_setting (context_key, \`key\`, value, xtype, namespace, area)
   VALUES ('$CTX', 'sso.oidc_jwks_uri', 'http://127.0.0.1:$port/keys.php', 'textfield', 'core', 'authentication')
   ON DUPLICATE KEY UPDATE value=VALUES(value);"
hits() { grep -c hit "$tmp/hits"; }

# mint <key a|b> '<header overrides>' '<claim overrides>' — a JSON null removes a field.
cat > "$tmp/mint.php" <<'PHP'
<?php
[, $key, $hOver, $cOver, $iss, $aud, $kid, $sid] = $argv;
$h = (object) ['alg' => 'RS256', 'kid' => $kid, 'typ' => 'logout+jwt'];
$c = (object) ['iss' => $iss, 'aud' => $aud, 'iat' => time(), 'jti' => bin2hex(random_bytes(8)),
               'events' => (object) ['http://schemas.openid.net/event/backchannel-logout' => new stdClass()],
               'sid' => $sid, 'sub' => 'suite'];
foreach ([[$h, $hOver], [$c, $cOver]] as [$o, $over]) {
    foreach ((array) json_decode($over ?: '{}') as $k => $v) {
        if ($v === null) { unset($o->$k); } else { $o->$k = $v; }
    }
}
$u = fn($s) => rtrim(strtr(base64_encode($s), '+/', '-_'), '=');
$in = $u(json_encode($h)) . '.' . $u(json_encode($c, JSON_UNESCAPED_SLASHES));
openssl_sign($in, $sig, file_get_contents(dirname(__FILE__) . "/$key.pem"), OPENSSL_ALGO_SHA256);
echo $in, '.', $u($sig);
PHP
mint() { local_php "$tmp/mint.php" "$1" "${2:-}" "${3:-}" "$ISS" "$AUD" "${KIDX:-$KID}" "${SIDX:-$SID}"; }

C=(curl -sS --resolve "${DOOR%%:*}:$PORT:$IP" -m 15)
BCL="$SCHEME://$DOOR/sso-backchannel-logout"
post() { "${C[@]}" -o "$tmp/body" -D "$tmp/head" -w '%{http_code}' -X POST \
           -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "logout_token=$1" "$BCL"; }

# --- sessions, as rows ------------------------------------------------------------------------------
newid() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
newsid() { local x; x=$(newid); echo "${x:0:8}-${x:8:4}-${x:12:4}-${x:16:4}-${x:20:12}"; }
sdata() {   # sdata <sid> — what GoogleSSOCallback leaves in a door session, minus the tokens
  printf 'modx.user.contextTokens|a:1:{s:%d:"%s";i:%d;}sso.verified_email|s:%d:"%s";sso.sid|s:%d:"%s";' \
    "${#CTX}" "$CTX" "$uid" "${#reader}" "$reader" "${#1}" "$1"
}
put_session() {   # put_session <id> <sid> — insert, or write back, the row
  q "REPLACE INTO modx_session (id, access, data) VALUES ('$1', UNIX_TIMESTAMP(), UNHEX('$(sdata "$2" | od -An -v -tx1 | tr -d ' \n')'));"
}
row() { q "SELECT data FROM modx_session WHERE id='$1';"; }
signed_in() { local d; d=$(row "$1"); [[ $d == *"sso.verified_email|"* && $d == *"s:${#CTX}:\"$CTX\";i:$uid;"* ]] && echo 1 || echo 0; }
recorded() { q "SELECT COUNT(*) FROM modx_register_messages m JOIN modx_register_topics t ON t.id=m.topic
                WHERE t.name='$TOPIC' AND m.id='$1' AND m.expires > UNIX_TIMESTAMP() + 604000;"; }

q "INSERT INTO modx_site_content
     (type,pagetitle,longtitle,description,introtext,alias,uri,published,deleted,template,
      parent,context_key,hidemenu,menuindex,searchable,cacheable,richtext,createdby,
      createdon,publishedon,publishedby,content)
   VALUES ('document','back-channel suite','','','','$ALIAS','$ALIAS',1,0,0,
      0,'$CTX',1,0,0,0,0,1,UNIX_TIMESTAMP(),UNIX_TIMESTAMP(),1,'<p>back-channel suite</p>');" \
  || { echo "could not create the test page" >&2; exit 2; }
clear_cache
# THE COOKIE'S NAME IS THE GROUND'S (session_name; `PHPSESSID<ctx>` on this bench), so it is read
# off an anonymous answer rather than typed — a typed name that missed made every visit anonymous.
read -r CK anon < <("${C[@]}" -o /dev/null -D - "$SCHEME://$DOOR/$ALIAS" \
                     | sed -n 's/^[Ss]et-[Cc]ookie: \([^=]*\)=\([^;]*\).*/\1 \2/p' | head -1)
[ -n "${CK:-}" ] || { echo "REFUSING TO RUN: an anonymous visit to /$ALIAS set no session cookie." >&2; exit 2; }
sessions+=("$anon")
visit() { "${C[@]}" -o /dev/null -b "$CK=$1" "$SCHEME://$DOOR/$ALIAS"; }

S=$(newid); SID=$(newsid); sessions+=("$S"); sids+=("$SID")
put_session "$S" "$SID"
visit "$S"
# MODx's own view, not the row as written: it adds the reader's user.config only for a session it
# has signed in to this context.
check "$(has "$(row "$S")" "modx.$CTX.user.config|")" "a minted door session is one MODx serves as signed in" "$(row "$S" | cut -c1-160)"
check "$(signed_in "$S")" "  and a page visit keeps it so (the control for every 'survives' below)" "$(row "$S" | cut -c1-160)"

# --- (a) a different key ------------------------------------------------------------------------
check "$([ "$(post "$(mint b)")" = 400 ] && echo 1 || echo 0)" "(a) a token signed by a DIFFERENT key under the published kid is refused 400" "$(cat "$tmp/body")"
check "$([ "$(hits)" = 1 ] && echo 1 || echo 0)" "    the door's keys were fetched, once" "hits=$(hits)"
h0=$(hits)
post "$(KIDX=unknown-1 mint b)" >/dev/null
post "$(KIDX=unknown-2 mint b)" >/dev/null
check "$([ $(( $(hits) - h0 )) -le 1 ] && echo 1 || echo 0)" "    two unknown kids in a row refetch the keys at most once" "$(( $(hits) - h0 )) fetches"

# --- (b) each rule broken alone -------------------------------------------------------------------
refused() {   # refused <label> <status> — the last post's answer
  check "$([ "$2" = "${3:-400}" ] && echo 1 || echo 0)" "(b) $1 -> ${3:-400}" "got $2: $(head -c 160 "$tmp/body")"
}
big=$(printf 'x%.0s' $(seq 8200))
refused "rule 1: not three parts"            "$(post "$(mint a).x")"
refused "rule 1: over 8 KB"                  "$(post "$(mint a '' "{\"pad\":\"$big\"}")")"
refused "rule 1: alg is not RS256"           "$(post "$(mint a '{"alg":"HS256"}')")"
refused "rule 1: no kid"                     "$(post "$(mint a '{"kid":null}')")"
refused "rule 1: typ at+jwt"                 "$(post "$(mint a '{"typ":"at+jwt"}')")"
refused "rule 3: iss is not the door"        "$(post "$(mint a '' '{"iss":"https://elsewhere.invalid/realms/dev"}')")"
refused "rule 3: aud is another client"      "$(post "$(mint a '' '{"aud":["someone-else"]}')")"
refused "rule 4: no iat"                     "$(post "$(mint a '' '{"iat":null}')")"
refused "rule 4: iat 10 minutes old"         "$(post "$(mint a '' "{\"iat\":$(( $(date +%s) - 600 ))}")")"
refused "rule 4: iat 10 minutes ahead"       "$(post "$(mint a '' "{\"iat\":$(( $(date +%s) + 600 ))}")")"
refused "rule 4: exp past"                   "$(post "$(mint a '' "{\"exp\":$(( $(date +%s) - 10 ))}")")"
refused "rule 5: no events"                  "$(post "$(mint a '' '{"events":null}')")"
refused "rule 5: events is a list"           "$(post "$(mint a '' '{"events":["http://schemas.openid.net/event/backchannel-logout"]}')")"
refused "rule 5: events lacks the logout event" "$(post "$(mint a '' '{"events":{"http://example.invalid/other":{}}}')")"
refused "rule 6: no sid (sub only)"          "$(post "$(mint a '' '{"sid":null}')")"
refused "rule 6: a sid outside [A-Za-z0-9-]" "$(post "$(mint a '' '{"sid":"a b;c"}')")"
refused "rule 6: a nonce"                    "$(post "$(mint a '' '{"nonce":"n"}')")"
good=$(mint a)
refused "GET" "$("${C[@]}" -o "$tmp/body" -w '%{http_code}' "$BCL")" 405
refused "a JSON body" "$("${C[@]}" -o "$tmp/body" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
          --data "{\"logout_token\":\"$good\"}" "$BCL")"
refused "two logout_token fields" "$("${C[@]}" -o "$tmp/body" -w '%{http_code}' -X POST \
          --data-urlencode "logout_token=$good" --data-urlencode "logout_token=$good" "$BCL")"
refused "a body over 16 KB" "$("${C[@]}" -o "$tmp/body" -w '%{http_code}' -X POST \
          --data-urlencode "logout_token=$good" --data-urlencode "pad=$(printf 'y%.0s' $(seq 16400))" "$BCL")"
visit "$S"
check "$(signed_in "$S")" "    after every refusal the named session is still signed in" "$(row "$S" | cut -c1-160)"
check "$([ "$(recorded "$SID")" = 0 ] && echo 1 || echo 0)" "    and the registry holds nothing for its sid" ""

# --- (d) a valid token naming nobody ---------------------------------------------------------------
NOBODY=$(newsid); sids+=("$NOBODY")
check "$([ "$(post "$(SIDX=$NOBODY mint a)")" = 200 ] && echo 1 || echo 0)" \
      "(d) a valid token naming no session is answered 200" "$(cat "$tmp/body")"
check "$(signed_in "$S")" "    and the session it does not name is untouched" ""

# --- (c) a valid token naming the session ---------------------------------------------------------
S2=$(newid); SID2=$(newsid); sessions+=("$S2"); sids+=("$SID2")
put_session "$S2" "$SID2"
lines0=$(wc -l < "$MODX_ROOT/core/logs/error.log" 2>/dev/null || echo 0)
code=$(post "$(mint a)")
check "$([ "$code" = 200 ] && echo 1 || echo 0)" "(c) a valid token naming the session is answered 200" "got $code: $(cat "$tmp/body")"
check "$(hasre "$(cat "$tmp/head")" '[Cc]ache-[Cc]ontrol: no-store')" "    with Cache-Control: no-store" "$(grep -i cache-control "$tmp/head")"
check "$([ "$(recorded "$SID")" = 1 ] && echo 1 || echo 0)" "    the registry holds its sid, for 7 days" ""
check "$([ -z "$(row "$S")" ] && echo 1 || echo 0)" "    its modx_session row is gone" "$(row "$S" | cut -c1-160)"
check "$(signed_in "$S2")" "    a session of another door sid is untouched" ""
visit "$S"
check "$([ "$(signed_in "$S")" = 0 ] && echo 1 || echo 0)" "    and the next request with its cookie is signed out" "$(row "$S" | cut -c1-160)"

# The written-back session: a request in flight writes the row again after the delete. The control
# first — with ssoRenew off it must survive, or the green below is something other than ssoRenew.
q "UPDATE modx_site_plugins SET disabled=1 WHERE name='ssoRenew';"; clear_cache
put_session "$S" "$SID"; visit "$S"
check "$(signed_in "$S")" "    control: with ssoRenew disabled, a written-back session stays signed in" ""
q "UPDATE modx_site_plugins SET disabled=0 WHERE name='ssoRenew';"; clear_cache
put_session "$S" "$SID"; visit "$S"
check "$([ "$(signed_in "$S")" = 0 ] && echo 1 || echo 0)" "    a written-back session is ended by ssoRenew on its next page" "$(row "$S" | cut -c1-160)"
check "$(has "$(tail -n +"$((lines0 + 1))" "$MODX_ROOT/core/logs/error.log" 2>/dev/null)" "ssoRenew: door session $SID")" \
      "    and the log names the door session" "no 'ssoRenew: door session $SID' in the error log"
visit "$S2"
check "$(signed_in "$S2")" "    and the other door session is still signed in after it" ""

summary
