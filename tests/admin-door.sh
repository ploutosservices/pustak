#!/usr/bin/env bash
# admin-door.sh — the MODx manager admits the door's AppAdmin, and MODx decides who is an admin.
#
#     bash tests/admin-door.sh
#
# claude/shared/design/library-manager-appadmin-skunkworks.md. Only the production door puts
# AppAdmin in its tokens, so the door is a STUB on this machine's
# loopback, as tests/backchannel-logout.sh does: a throwaway RSA key, its JWKS, a token endpoint that
# checks the PKCE verifier, the client and the redirect_uri and signs the claims this suite asks for,
# and a discovery document. For the run, the context's own sso.oidc_issuer / auth / token endpoints
# point at the stub, and are put back exactly as found; its client id and secret are not touched. The
# suite drives the manager's real pages over HTTP and plays the browser's leg at the door itself,
# returning to the site's /sso-callback as the door would.
#
#   switch off   the plugin does nothing: the manager shows its own sign-in
#   switch on    a visitor is sent to this site's client at the door (PKCE, no acr_values, no
#                prompt, the site's /sso-callback, a state starting mgr.);
#                /sso-callback sends that return on to the manager — control: a return without
#                the mgr. state is the site's own (SSO-01);
#                an Administrator's token holding AppAdmin is admitted to mgr, and is not ended
#                by its age;
#                refused with no session: the door's access_denied (with Sign out), a token with no
#                roles, roles without AppAdmin, roles not a list, another issuer, an impersonator claim, an
#                address with no MODx user, a user not in Administrator, a blocked user;
#                a password sign-in through the manager and through the connector's login_context=mgr
#                is refused — control: with the switch off the connector answers its own message;
#                a right password through the connector's login_context=web&add_contexts=mgr (where
#                no refusing event fires in the mgr context) opens a session that cannot reach the
#                manager — control: with the switch off the same sign-in is served;
#                a mgr session the plugin did not open is ended — control: with the switch off it
#                is served;
#                signing out of the manager sends the next manager page to the door's end-session
#                endpoint with the id_token.
#
# Seen red: with the plugin disabled every 'switch on' case fails (run with ADMIN_DOOR_RED=1).
# BENCH ONLY, and not in a container: the stub door listens on this machine's loopback.
set -uo pipefail

HOST=${MODX_TEST_HOST:-}   # empty: the context's live http_host, read after lib.sh
IP=${MODX_TEST_IP:-127.0.0.1}
CTX=${MODX_TEST_CTX:-platform}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -n "$HOST" ] || HOST=$(ctx_host "$CTX") || exit 2
read -r SCHEME PORT < <(host_origin "$HOST")
DOOR=$(host_door "$HOST") || exit 2

require_repo
require_bench
if [ -n "${MODX_PHP_RUN:-}" ]; then
  echo "REFUSING TO RUN: MODx runs in a container on this ground (MODX_PHP_RUN is set), so the" >&2
  echo "                 stub door on this machine's loopback is not MODx's loopback." >&2
  exit 2
fi
plugin=$(q "SELECT COUNT(DISTINCT e.event) FROM modx_site_plugins p JOIN modx_site_plugin_events e ON e.pluginid=p.id
            WHERE p.name='adminDoor' AND p.disabled=0;")
[ "$plugin" = 5 ] || { echo "REFUSING TO RUN: adminDoor is not installed and bound to its five events — apply it first." >&2; exit 2; }
# sso.admin_door is kept as found and put back: a bench restored from production holds production's
# row (measured 2026-10-31: value 1), and refusing then left this suite unrun on every restored bench.
held=$(q "SELECT COUNT(*) FROM modx_system_settings WHERE \`key\`='sso.admin_door';")
admin_row() { q "SELECT $1 FROM modx_system_settings WHERE \`key\`='sso.admin_door';"; }
if [ "$held" = 1 ]; then hv=$(admin_row value); hx=$(admin_row xtype); hn=$(admin_row namespace); ha=$(admin_row area); fi
CLIENT=$(q "SELECT value FROM modx_context_setting WHERE context_key='$CTX' AND \`key\`='sso.oidc_client_id';")
SITE=$(q "SELECT value FROM modx_context_setting WHERE context_key='$CTX' AND \`key\`='site_url';")
[ -n "$CLIENT" ] && [ -n "$SITE" ] || { echo "REFUSING TO RUN: context $CTX has no sso.oidc_client_id or site_url." >&2; exit 2; }
# The endpoints this run points at the stub, each kept as found ('-' for absent) and put back.
OIDC=(sso.oidc_issuer sso.oidc_auth_endpoint sso.oidc_token_endpoint sso.oidc_jwks_uri)
declare -A was
for k in "${OIDC[@]}"; do
  [ "$(q "SELECT COUNT(*) FROM modx_context_setting WHERE context_key='$CTX' AND \`key\`='$k';")" = 1 ] \
    && was[$k]=$(q "SELECT value FROM modx_context_setting WHERE context_key='$CTX' AND \`key\`='$k';") || was[$k]=-
done

echo "the manager's sign-in at the door as AppAdmin, on $DOOR"

tmp=$(mktemp -d); chmod 700 "$tmp"
users=(); sessions=()
setting() { q "REPLACE INTO modx_system_settings (\`key\`, value, xtype, namespace, area) VALUES ('$1', '$2', 'textfield', 'core', 'pustak');"; }
cleanup() {
  q "DELETE FROM modx_system_settings WHERE \`key\`='sso.admin_door';" >/dev/null 2>&1
  if [ "$held" = 1 ]; then
    q "INSERT INTO modx_system_settings (\`key\`, value, xtype, namespace, area) VALUES ('sso.admin_door', '$hv', '$hx', '$hn', '${ha:-}');" >/dev/null 2>&1
  fi
  for k in "${OIDC[@]}"; do
    if [ "${was[$k]}" = - ]; then q "DELETE FROM modx_context_setting WHERE context_key='$CTX' AND \`key\`='$k';" >/dev/null 2>&1
    # REPLACE, not UPDATE: the run DELETEs sso.oidc_jwks_uri, and an UPDATE of a deleted row restores nothing.
    else q "REPLACE INTO modx_context_setting (context_key, \`key\`, value, xtype, namespace, area) VALUES ('$CTX', '$k', '${was[$k]}', 'textfield', 'core', 'pustak');" >/dev/null 2>&1; fi
  done
  q "UPDATE modx_site_plugins SET disabled=0 WHERE name='adminDoor';" >/dev/null 2>&1
  for u in "${users[@]}"; do
    q "DELETE FROM modx_member_groups WHERE member=$u; DELETE FROM modx_user_attributes WHERE internalKey=$u;
       DELETE FROM modx_users WHERE id=$u;" >/dev/null 2>&1
  done
  for s in "${sessions[@]}"; do q "DELETE FROM modx_session WHERE id='$s';" >/dev/null 2>&1; done
  [ -n "${A:-}" ] && q "DELETE FROM modx_session WHERE data LIKE '%pustak.admin_door|i:$A;%';" >/dev/null 2>&1
  [ -n "${listener:-}" ] && { pkill -P "$listener" 2>/dev/null; kill "$listener" 2>/dev/null; }
  modx_php "$REPO/clear-cache.php" "$MODX_ROOT" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# --- three throwaway people ---------------------------------------------------------------------------
tag=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
dom=example.test   # a reserved name: these people exist only for the run
admin_group=$(q "SELECT id FROM modx_membergroup_names WHERE name='Administrator';")
[ -n "$admin_group" ] || { echo "REFUSING TO RUN: no Administrator group on this bench." >&2; exit 2; }
admin_role=$(q "SELECT role FROM modx_member_groups WHERE user_group=$admin_group ORDER BY role LIMIT 1;")
newid() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
person() {   # person <name> <in Administrator 0|1> — prints the id
  local email="admin-door-$1-$tag@$dom" id
  q "INSERT INTO modx_users (username, password, active, createdon) VALUES ('$email', '$(newid)', 1, UNIX_TIMESTAMP());"
  id=$(q "SELECT id FROM modx_users WHERE username='$email';")
  q "INSERT INTO modx_user_attributes (internalKey, email, fullname, blocked, address, comment) VALUES ($id, '$email', '$1', 0, '', '');"
  [ "$2" = 1 ] && q "INSERT INTO modx_member_groups (user_group, member, role, rank) VALUES ($admin_group, $id, ${admin_role:-2}, 0);"
  echo "$id"
}
A=$(person admin 1); users+=("$A"); AE="admin-door-admin-$tag@$dom"
M=$(person member 0); users+=("$M"); ME="admin-door-member-$tag@$dom"
# A's password, set through MODx's own API so it is hashed as MODx hashes it.
PW=pw-$(newid)
local_php -r '
  define("MODX_API_MODE", true); require $argv[1] . "/config.core.php";
  require MODX_CORE_PATH . "vendor/autoload.php";
  $modx = \MODX\Revolution\modX::getInstance(); $modx->initialize("mgr");
  $u = $modx->getObject(\MODX\Revolution\modUser::class, (int) $argv[2]);
  $u->set("password", $argv[3]); exit($u->save() ? 0 : 1);
' "$MODX_ROOT" "$A" "$PW" || { echo "could not set the throwaway admin's password" >&2; exit 2; }

# --- the stub door ------------------------------------------------------------------------------------
KID=adm-suite-$tag
local_php -r '
  $k = openssl_pkey_new(["private_key_bits" => 2048, "private_key_type" => OPENSSL_KEYTYPE_RSA]);
  openssl_pkey_export($k, $pem); file_put_contents($argv[1] . "/key.pem", $pem);
  $d = openssl_pkey_get_details($k)["rsa"];
  $u = fn($s) => rtrim(strtr(base64_encode($s), "+/", "-_"), "=");
  file_put_contents($argv[1] . "/jwks.json", json_encode(["keys" => [
    ["kty" => "RSA", "use" => "sig", "alg" => "RS256", "kid" => $argv[2], "n" => $u($d["n"]), "e" => $u($d["e"])]]]));
' "$tmp" "$KID" || { echo "could not mint the throwaway key" >&2; exit 2; }
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
STUB="http://127.0.0.1:$port"
ISS="$STUB/realms/suite"
cat > "$tmp/door.php" <<'PHP'
<?php
// The stub door. /case.json (written by the suite per sign-in) holds the PKCE challenge it expects
// and the claims to sign; the token endpoint refuses a wrong verifier, redirect_uri or client.
$dir = getenv('DIR'); $iss = getenv('ISS'); $path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
header('Content-Type: application/json');
if ($path === '/realms/suite/.well-known/openid-configuration') {
    echo json_encode(['issuer' => $iss, 'jwks_uri' => "$iss/certs", 'end_session_endpoint' => "$iss/logout",
                      'authorization_endpoint' => "$iss/auth", 'token_endpoint' => "$iss/token"]);
    return;
}
if ($path === '/realms/suite/certs') { readfile("$dir/jwks.json"); return; }
if ($path === '/realms/suite/token') {
    $case = json_decode(file_get_contents("$dir/case.json"), true);
    $v = (string) ($_POST['code_verifier'] ?? '');
    $ch = rtrim(strtr(base64_encode(hash('sha256', $v, true)), '+/', '-_'), '=');
    $why = ($_POST['grant_type'] ?? '') !== 'authorization_code' ? 'grant'
         : (($_POST['client_id'] ?? '') !== getenv('CLIENT') || ($_POST['client_secret'] ?? '') === '' ? 'client'
         : (($_POST['redirect_uri'] ?? '') !== getenv('REDIRECT') ? 'redirect_uri'
         : ($ch !== $case['challenge'] ? 'pkce' : (($_POST['code'] ?? '') !== 'suite-code' ? 'code' : ''))));
    file_put_contents("$dir/token.log", ($why ?: 'ok') . "\n", FILE_APPEND);
    if ($why !== '') { http_response_code(400); echo json_encode(['error' => 'invalid_grant', 'why' => $why]); return; }
    $u = fn($s) => rtrim(strtr(base64_encode($s), '+/', '-_'), '=');
    $in = $u(json_encode(['alg' => 'RS256', 'kid' => getenv('KID'), 'typ' => 'JWT'])) . '.'
        . $u(json_encode($case['claims'], JSON_UNESCAPED_SLASHES));
    openssl_sign($in, $sig, file_get_contents("$dir/key.pem"), OPENSSL_ALGO_SHA256);
    echo json_encode(['id_token' => "$in." . $u($sig), 'access_token' => 'suite', 'token_type' => 'Bearer']);
    return;
}
http_response_code(404); echo '{}';
PHP
REDIRECT="${SITE%/}/sso-callback"
DIR="$tmp" ISS="$ISS" KID="$KID" CLIENT="$CLIENT" REDIRECT="$REDIRECT" \
  local_php -S "127.0.0.1:$port" "$tmp/door.php" >"$tmp/listener.out" 2>&1 &
listener=$!
for _ in $(seq 40); do (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null && break; sleep 0.05; done

ctxset() { q "REPLACE INTO modx_context_setting (context_key, \`key\`, value, xtype, namespace, area) VALUES ('$CTX', '$1', '$2', 'textfield', 'core', 'pustak');"; }
ctxset sso.oidc_issuer "$ISS"
ctxset sso.oidc_auth_endpoint "$ISS/auth"
ctxset sso.oidc_token_endpoint "$ISS/token"
q "DELETE FROM modx_context_setting WHERE context_key='$CTX' AND \`key\`='sso.oidc_jwks_uri';"
switch() { setting sso.admin_door "$1"; clear_cache; }

C=(curl -sS --resolve "${DOOR%%:*}:$PORT:$IP" -m 15)
MGR="$SCHEME://$DOOR/manager/"
SITECB="$SCHEME://$DOOR/sso-callback"
CONN="$SCHEME://$DOOR/connectors/index.php"
loc() { sed -n 's/^[Ll]ocation: *\([^[:space:]]*\).*/\1/p' "$1" | tail -1; }
qp() { python3 -c 'import sys,urllib.parse as u; print(u.parse_qs(u.urlparse(sys.argv[1]).query).get(sys.argv[2],[""])[0])' "$1" "$2"; }
row() { q "SELECT data FROM modx_session WHERE id='$1';"; }
cookie() { awk -v n="$2" '$6==n{v=$7} END{print v}' "$1"; }

# signin <jar> '<claim overrides JSON>' — the browser's whole leg: manager -> door -> the site's
# /sso-callback -> the manager's callback. The door's answer is ${ANSWER:-code=suite-code}.
# Leaves $tmp/relay.head (the site callback's answer), $tmp/cb.head and $tmp/cb.body (the manager's),
# and sets START (the door URL) and RELAY (where /sso-callback sent the browser).
signin() {
  local jar=$1 over=${2:-'{}'} state nonce challenge
  "${C[@]}" -c "$jar" -b "$jar" -o /dev/null -D "$tmp/start.head" "$MGR"
  START=$(loc "$tmp/start.head")
  state=$(qp "$START" state); nonce=$(qp "$START" nonce); challenge=$(qp "$START" code_challenge)
  local_php -r '
    [, $f, $challenge, $iss, $aud, $email, $nonce, $over] = $argv;
    $c = ["iss" => $iss, "aud" => $aud, "azp" => $aud, "sub" => "suite-sub", "email" => $email, "roles" => ["offline_access", "AppAdmin"],
          "certificate_subject" => "CN=suite@example.org",
          "email_verified" => true, "nonce" => $nonce, "iat" => time(), "exp" => time() + 300, "sid" => "suite-sid"];
    foreach (json_decode($over, true) ?: [] as $k => $v) { if ($v === null) { unset($c[$k]); } else { $c[$k] = $v; } }
    file_put_contents($f, json_encode(["challenge" => $challenge, "claims" => $c], JSON_UNESCAPED_SLASHES));
  ' "$tmp/case.json" "$challenge" "$ISS" "$CLIENT" "${EMAIL:-$AE}" "$nonce" "$over"
  "${C[@]}" -c "$jar" -b "$jar" -o /dev/null -D "$tmp/relay.head" "$SITECB?${ANSWER:-code=suite-code}&state=$state"
  RELAY=$(loc "$tmp/relay.head")
  [[ $RELAY == /* ]] && RELAY="$SCHEME://$DOOR$RELAY"
  CB=$("${C[@]}" -c "$jar" -b "$jar" -o "$tmp/cb.body" -D "$tmp/cb.head" -w '%{http_code}' "${RELAY:-$SITECB}")
}
# after <jar> — what the next manager page does: 'in' (served), 'door' (sent to the door), or the code.
after() {
  local code; code=$("${C[@]}" -c "$1" -b "$1" -o "$tmp/after.body" -D "$tmp/after.head" -w '%{http_code}' "$MGR")
  if [ "$code" = 302 ] && [[ $(loc "$tmp/after.head") == "$ISS/auth"* ]]; then echo door
  elif [ "$code" = 200 ] && ! grep -q 'modx-login\|id="modx-login' "$tmp/after.body"; then echo in
  else echo "$code"; fi
}

# --- switch off ---------------------------------------------------------------------------------------
switch 0
jar=$tmp/off.jar
code=$("${C[@]}" -c "$jar" -o "$tmp/off.body" -D "$tmp/off.head" -w '%{http_code}' "$MGR")
check "$([ "$code" = 200 ] && [ -z "$(loc "$tmp/off.head")" ] && echo 1 || echo 0)" \
      "switch off: the manager shows its own sign-in, nobody is sent to the door" "got $code $(loc "$tmp/off.head")"
login_msg() {   # login_msg <extra args...> — the connector login's message for user A, wrong password
  "${C[@]}" -X POST "$CONN" --data-urlencode "action=Security/Login" --data-urlencode "username=$AE" \
    --data-urlencode "password=not-the-password" "$@" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("message",""))' 2>/dev/null
}
off_msg=$(login_msg --data-urlencode login_context=mgr)
check "$(hasnt "$off_msg" 'estate door')" "  control: the connector's login answers its own message" "$off_msg"
pw_login() {   # pw_login <jar> — the connector's web login adding mgr, with A's right password
  "${C[@]}" -c "$1" -b "$1" -o "$tmp/pw.body" -X POST "$CONN" --data-urlencode "action=Security/Login" \
    --data-urlencode "username=$AE" --data-urlencode "password=$PW" \
    --data-urlencode login_context=web --data-urlencode add_contexts=mgr
}
pw_login "$tmp/pwoff.jar"
check "$(has "$(cat "$tmp/pw.body")" '"success":true')" "  control: the connector's web login adding mgr succeeds with the right password" "$(head -c 200 "$tmp/pw.body")"
check "$([ "$(after "$tmp/pwoff.jar")" = in ] && echo 1 || echo 0)" "  control: and with the switch off that session is served the manager" "$(head -c 160 "$tmp/after.body")"
# THE MANAGER'S COOKIE NAME IS THE GROUND'S (session_name), read off the anonymous answer.
CK=$(sed -n 's/^[Ss]et-[Cc]ookie: \([^=]*\)=.*/\1/p' "$tmp/off.head" | head -1)
[ -n "$CK" ] || { echo "REFUSING TO RUN: an anonymous manager visit set no session cookie." >&2; exit 2; }
S=$(newid); sessions+=("$S")
q "REPLACE INTO modx_session (id, access, data) VALUES ('$S', UNIX_TIMESTAMP(),
     'modx.user.contextTokens|a:1:{s:3:\"mgr\";i:$A;}');"
"${C[@]}" -o /dev/null -b "$CK=$S" "$MGR"
check "$(has "$(row "$S")" 'modx.mgr.user.config|')" "  control: a mgr session the plugin did not open is served" "$(row "$S" | cut -c1-160)"

# --- switch on ----------------------------------------------------------------------------------------
switch 1
[ "${ADMIN_DOOR_RED:-0}" = 1 ] && { q "UPDATE modx_site_plugins SET disabled=1 WHERE name='adminDoor';"; clear_cache; echo "  (seeing red: adminDoor disabled)"; }

"${C[@]}" -o /dev/null -b "$CK=$S" "$MGR"
check "$(hasnt "$(row "$S")" "s:3:\"mgr\";i:$A;")" "switch on: that mgr session is ended on its next request" "$(row "$S" | cut -c1-160)"

jar=$tmp/a.jar; signin "$jar"
check "$([[ $START == "$ISS/auth?"* ]] && echo 1 || echo 0)" "a visitor is sent to this site's door" "Location: $START"
check "$([ "$(qp "$START" client_id)" = "$CLIENT" ] && [ "$(qp "$START" redirect_uri)" = "$REDIRECT" ] \
          && [ -z "$(qp "$START" acr_values)" ] && [ -z "$(qp "$START" prompt)" ] \
          && [ "$(qp "$START" code_challenge_method)" = S256 ] && [[ $(qp "$START" state) == mgr.* ]] && echo 1 || echo 0)" \
      "  as client $CLIENT, callback $REDIRECT, no acr_values, no prompt, PKCE S256, state mgr." "$START"
check "$([[ $RELAY == "$MGR?modx-admin-callback&"* ]] && [ "$(qp "$RELAY" code)" = suite-code ] && echo 1 || echo 0)" \
      "  the site's /sso-callback sends the return on to the manager" "Location: $RELAY"
check "$([ "$CB" = 302 ] && [ "$(loc "$tmp/cb.head")" = "$MGR" ] && echo 1 || echo 0)" \
      "an Administrator's token holding AppAdmin is admitted" "got $CB $(loc "$tmp/cb.head") $(head -c 200 "$tmp/cb.body")"
check "$([ "$(tail -1 "$tmp/token.log" 2>/dev/null)" = ok ] && echo 1 || echo 0)" "  the door saw the right client, callback and PKCE verifier" "$(tail -1 "$tmp/token.log" 2>/dev/null)"
check "$([ "$(after "$jar")" = in ] && echo 1 || echo 0)" "  and the next manager page is served" "$(head -c 200 "$tmp/after.body")"
AS=$(cookie "$jar" "$CK"); sessions+=("$AS")
check "$(has "$(row "$AS")" "pustak.admin_door|i:$A;")" "  its session carries the mark" "$(row "$AS" | cut -c1-200)"

refused() {   # refused <label> <ADM code> <claim overrides> [email]
  local jar=$tmp/r$RANDOM.jar
  EMAIL=${4:-$AE} signin "$jar" "$3"
  check "$([ "$CB" = 403 ] && grep -q "$2" "$tmp/cb.body" && echo 1 || echo 0)" "refused $2: $1" "got $CB $(head -c 300 "$tmp/cb.body")"
  check "$([ "$(after "$jar")" = door ] && echo 1 || echo 0)" "  and no session: the next manager page goes to the door" "$(head -c 160 "$tmp/after.body")"
}
refused "a token with no roles"                    ADM-14 '{"roles":null}'
refused "roles without AppAdmin"                   ADM-14 '{"roles":["offline_access","appadmin"]}'
refused "roles not a list (the string AppAdmin)"   ADM-14 '{"roles":"AppAdmin"}'
refused "gold without AppAdmin"                    ADM-14 '{"roles":["offline_access"],"acr":"gold"}'
refused "another issuer (iss realms/dev)"          ADM-18 "{\"iss\":\"$STUB/realms/dev\"}"
ANSWER='error=access_denied&error_description=chowkidar_certificate_required' refused "the door's access_denied" ADM-04 '{}'
check "$(has "$(cat "$tmp/cb.body")" '>Sign out</a>')" "  and that page offers Sign out, not another sign-in" "$(head -c 400 "$tmp/cb.body")"
refused "acting as someone (impersonator claim)"    ADM-21 '{"impersonator":"someone"}'
refused "an address with no MODx user"             ADM-30 '{}' "admin-door-nobody-$tag@$dom"
refused "a user not in Administrator"              ADM-34 '{}' "$ME"
q "UPDATE modx_user_attributes SET blocked=1, blockeduntil=0 WHERE internalKey=$A;"
refused "a blocked user"                           ADM-33 '{}'
q "UPDATE modx_user_attributes SET blocked=0 WHERE internalKey=$A;"

# A return to /sso-callback whose state is not the manager's is the site's own, not sent on.
"${C[@]}" -o "$tmp/site.body" -D "$tmp/site.head" "$SITECB?code=suite-code&state=not-the-managers"
check "$([ -z "$(loc "$tmp/site.head")" ] && grep -q 'SSO-01' "$tmp/site.body" && echo 1 || echo 0)" \
      "control: a return without the mgr. state is the site's own (SSO-01), not sent to the manager" "$(loc "$tmp/site.head") $(grep -o 'SSO-[0-9]*' "$tmp/site.body" | head -1)"

# The door's rule decides freshness now: a token issued 13 hours ago that holds AppAdmin is admitted,
# and the session holds no deadline of its own.
gjar=$tmp/g.jar; signin "$gjar" "{\"iat\":$(( $(date +%s) - 46800 ))}"
GS=$(cookie "$gjar" "$CK"); sessions+=("$GS")
check "$([ "$CB" = 302 ] && [ "$(after "$gjar")" = in ] && echo 1 || echo 0)" "a token issued 13 hours ago holding AppAdmin is admitted and served" "got $CB $(head -c 160 "$tmp/after.body")"
check "$(hasnt "$(row "$GS")" 'pustak.admin_gold_until')" "  and its session holds no gold deadline" "$(row "$GS" | cut -c1-200)"

code=$("${C[@]}" -o /dev/null -D "$tmp/pw.head" -w '%{http_code}' -X POST "$MGR" \
        --data-urlencode "username=$AE" --data-urlencode "password=x" --data-urlencode "login=1")
check "$([ "$code" = 302 ] && [[ $(loc "$tmp/pw.head") == "$ISS/auth"* ]] && echo 1 || echo 0)" \
      "a password posted to the manager never reaches its form: sent to the door" "got $code $(loc "$tmp/pw.head")"
m=$(login_msg --data-urlencode login_context=mgr)
check "$(has "$m" 'estate door')" "the connector's login_context=mgr is refused" "$m"
pw_login "$tmp/pwon.jar"
PS=$(cookie "$tmp/pwon.jar" "$CK"); sessions+=("$PS")
check "$([ "$(after "$tmp/pwon.jar")" = door ] && echo 1 || echo 0)" \
      "the connector's web login adding mgr, right password: its next manager page goes to the door" "$(head -c 160 "$tmp/after.body")"
check "$(hasnt "$(row "$PS")" "s:3:\"mgr\";i:$A;")" "  and its session no longer holds mgr" "$(row "$PS" | cut -c1-160)"
m=$(login_msg --data-urlencode login_context=web)
check "$(hasnt "$m" 'estate door')" "  control: a web-only login is not the plugin's to refuse" "$m"

# --- sign-out ends the door session -----------------------------------------------------------------
tok=$(row "$AS" | sed -n 's/.*modx\.mgr\.user\.token|s:[0-9]*:"\([^"]*\)".*/\1/p')
"${C[@]}" -c "$jar" -b "$jar" -o "$tmp/out.body" -X POST -H "modAuth: $tok" "$CONN" \
  --data-urlencode action=Security/Logout --data-urlencode login_context=mgr
check "$(has "$(cat "$tmp/out.body")" '"success":true')" "the manager's sign-out succeeds" "$(head -c 200 "$tmp/out.body")"
"${C[@]}" -c "$jar" -b "$jar" -o /dev/null -D "$tmp/bye.head" "$MGR"
bye=$(loc "$tmp/bye.head")
check "$([[ $bye == "$ISS/logout?"* ]] && [ -n "$(qp "$bye" id_token_hint)" ] && echo 1 || echo 0)" \
      "  and the next manager page ends the door session, with the id_token as hint" "Location: $bye"
check "$([ "$(after "$jar")" = door ] && echo 1 || echo 0)" "  after which the manager goes to the door again" ""

summary
