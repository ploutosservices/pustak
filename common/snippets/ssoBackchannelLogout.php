/**
 * ssoBackchannelLogout — the door's back-channel sign-out (OpenID Connect Back-Channel Logout 1.0
 * §2.4–2.8). Lives on /sso-backchannel-logout in each SSO-gated context, called `[[!ssoBackchannelLogout]]`.
 * claude/shared/design/back-channel-logout-skunkworks.md.
 *
 * WHY. When a person signs out at the door, the door POSTs a `logout_token` naming the door session
 * (`sid`) to every client that session signed in to. Until now MODx kept its own session for up to
 * the 7-day cookie after the door's had ended. This ends every MODx session carrying that `sid`.
 *
 * THE ADDRESS IS OPEN: the door is the caller and presents no certificate and no session. What
 * admits a request is the token alone — signed under a `kid` in the DOOR's published keys, for this
 * context's client, fresh. Anything else is 400 and nothing ends; a context that does not sign in
 * through the door answers 400 too, because no session here can carry a door `sid`.
 *
 * TWO ACTS, because a request in flight writes its session back (modSessionHandler::write()
 * recreates a deleted row): the ended `sid` is written to MODx's own registry, where ssoRenew finds
 * it on that session's next page, and the rows carrying it are deleted now.
 *
 * NO jti STORE: `iat` must be within 5 minutes either way, which bounds replay, and ending an ended
 * session again is harmless.
 */

/** @var modX $modx */

$send = static function (int $status, string $text) {
    while (ob_get_level() > 0) { ob_end_clean(); }
    header('Content-Type: text/plain; charset=utf-8');
    header('Cache-Control: no-store');                 // §2.8, on every answer
    if ($status === 405) { header('Allow: POST'); }
    http_response_code($status);
    echo $text, "\n";
    exit;                                              // the answer is the whole response, never a page
};
$refuse = static function (string $why) use ($modx, $send) {
    $modx->log(modX::LOG_LEVEL_ERROR, "[ssoBackchannelLogout] refused: $why");   // a fault, as the callback's $fail
    $send(400, "refused: $why");
};

// --- the request ---------------------------------------------------------------------------------
if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    $send(405, 'only POST');
}
$ctype = strtolower(trim(explode(';', (string) ($_SERVER['CONTENT_TYPE'] ?? ''))[0]));
if ($ctype !== 'application/x-www-form-urlencoded') {
    $refuse('Content-Type is not application/x-www-form-urlencoded');
}
$raw = (string) file_get_contents('php://input', false, null, 0, 16385);
if (strlen($raw) > 16384) {
    $refuse('body over 16 KB');
}
// Counted on the raw body, not $_POST: PHP keeps the last of two same-named fields silently.
$tokens = [];
foreach ($raw === '' ? [] : explode('&', $raw) as $pair) {
    $kv = explode('=', $pair, 2);
    if (urldecode($kv[0]) === 'logout_token') { $tokens[] = urldecode($kv[1] ?? ''); }
}
if (count($tokens) !== 1) {
    $refuse('the body carries ' . count($tokens) . ' logout_token fields, not exactly one');
}
$jwt = $tokens[0];

require_once rtrim(MODX_CORE_PATH, '/') . '/components/pustak/lib/SsoConfig.php';
$sso = SsoConfig::forContext($modx);
if ($sso->provider !== 'oidc' || $sso->fault !== '') {
    $refuse('this context does not sign in through the door'
            . ($sso->fault !== '' ? " ({$sso->fault})" : ''));
}
$issuer = (string) ($sso->issuers[0] ?? '');
if ($sso->jwksUri === '' || $issuer === '' || $sso->clientId === '') {
    $refuse('no door keys address, issuer or client id for this context, so no token can be checked');
}

// --- rule 1: shape -------------------------------------------------------------------------------
$b64 = static function (string $d) {
    return base64_decode(strtr($d, '-_', '+/') . str_repeat('=', (4 - strlen($d) % 4) % 4), true);
};
$parts = explode('.', $jwt);
if (strlen($jwt) > 8192 || count($parts) !== 3) {
    $refuse('not a three-part JWT of at most 8 KB');
}
$header = json_decode((string) $b64($parts[0]), true);
if (!is_array($header) || ($header['alg'] ?? null) !== 'RS256'
    || !is_string($header['kid'] ?? null) || $header['kid'] === '') {
    $refuse('header is not RS256 with a kid');
}
if (array_key_exists('typ', $header) && !in_array($header['typ'], ['JWT', 'logout+jwt'], true)) {
    $refuse('typ ' . var_export($header['typ'], true) . ' is not a logout token');
}
$kid = $header['kid'];

// --- rule 2: the door's signature ----------------------------------------------------------------
// The door's keys, cached on disk per keys address. An unknown kid refetches AT MOST ONCE PER 60
// SECONDS whatever arrives: this address is open, and a stream of made-up kids must not become a
// stream of calls to the door.
$cache = sys_get_temp_dir() . '/pustak-bcl-jwks-' . substr(hash('sha256', $sso->jwksUri), 0, 16) . '.json';
$jwks  = is_readable($cache) ? json_decode((string) file_get_contents($cache), true) : null;
$jwks  = is_array($jwks) ? $jwks : ['keys' => [], 'fetched' => 0];
$known = static function (array $set) use ($kid): bool {
    foreach ($set['keys'] ?? [] as $k) { if (($k['kid'] ?? null) === $kid) { return true; } }
    return false;
};
$age = time() - (int) ($jwks['fetched'] ?? 0);
if ((!$known($jwks) || $age > 86400) && $age >= 60) {
    $c = curl_init($sso->jwksUri);
    curl_setopt_array($c, [CURLOPT_RETURNTRANSFER => true, CURLOPT_CONNECTTIMEOUT => 2, CURLOPT_TIMEOUT => 3,
                           CURLOPT_HTTPHEADER => ['Accept: application/json']]);
    $b  = curl_exec($c);
    $ok = curl_getinfo($c, CURLINFO_RESPONSE_CODE) === 200;
    curl_close($c);
    $got = ($ok && is_string($b)) ? json_decode($b, true) : null;
    // The attempt is stamped even when it fails, or a door that is down would be asked on every call.
    $jwks = (is_array($got) && is_array($got['keys'] ?? null)) ? ['keys' => $got['keys']] : $jwks;
    $jwks['fetched'] = time();
    $tmp = $cache . '.' . getmypid();
    if (@file_put_contents($tmp, json_encode($jwks)) !== false) { @rename($tmp, $cache); }
}
// THE ESTATE'S ONE JWK-TO-KEY CONVERSION, not a second one. GoogleToken::verify() cannot take this
// token — it demands an email, which a logout token never carries — and the vendored file is not
// ours to edit, so its private pemForKid() is reached by reflection.
require_once rtrim(MODX_CORE_PATH, '/') . '/components/pustak/lib/GoogleToken.php';
$pem = (new ReflectionMethod(\Kuber\Core\GoogleToken::class, 'pemForKid'))->invoke(null, $jwks, $kid);
if ($pem === null) {
    $refuse("no RSA key for kid '$kid' in the door's published keys");
}
$sig = $b64($parts[2]);
if ($sig === false || $sig === ''
    || openssl_verify($parts[0] . '.' . $parts[1], $sig, $pem, OPENSSL_ALGO_SHA256) !== 1) {
    $refuse('signature does not verify under the door\'s key');
}

// --- rules 3–6: the claims, believed only now ------------------------------------------------------
$claims = json_decode((string) $b64($parts[1]));        // objects kept as objects: `events` must be one
if (!($claims instanceof stdClass)) {
    $refuse('unreadable payload');
}
if (($claims->iss ?? null) !== $issuer) {
    $refuse('iss is not the door');
}
$aud = $claims->aud ?? null;
if (!(is_string($aud) ? $aud === $sso->clientId : (is_array($aud) && in_array($sso->clientId, $aud, true)))) {
    $refuse("aud does not name {$sso->clientId}");
}
$now = time();
if (!is_int($claims->iat ?? null) || abs($now - $claims->iat) > 300) {
    $refuse('iat absent or more than 5 minutes from now');
}
if (property_exists($claims, 'exp') && (!is_int($claims->exp) || $claims->exp < $now)) {
    $refuse('expired');
}
if (!(($claims->events ?? null) instanceof stdClass)
    || !property_exists($claims->events, 'http://schemas.openid.net/event/backchannel-logout')) {
    $refuse('events does not hold the back-channel logout event');
}
// sid REQUIRED. A token naming only `sub` would end every session of that person, including ones
// they open after it; the door is set to send sid.
$sid = $claims->sid ?? null;
if (!is_string($sid) || !preg_match('/^[A-Za-z0-9-]{1,64}$/', $sid)) {
    $refuse('no usable sid');
}
if (property_exists($claims, 'nonce')) {
    $refuse('a logout token carries no nonce');
}

// --- accepted: end every session carrying that sid -------------------------------------------------
// (1) the registry first, so a session a request in flight writes back is ended by ssoRenew on its
// next page; 7 days is the cookie's life, after which no session can carry this sid.
$recorded = false;
$registry = $modx->getService('registry', 'registry.modRegistry');
$register = $registry ? $registry->getRegister('pustak', 'registry.modDbRegister') : null;
if ($register && $register->connect()) {
    $register->subscribe('/pustak/ended-sid/');
    $recorded = $register->send('/pustak/ended-sid/', [$sid => $now], ['ttl' => 604800]);
    $register->unsubscribe('/pustak/ended-sid/');
}
// (2) the rows. A full scan, bound, and only on a sign-out.
$table = $modx->getTableName(\MODX\Revolution\modSession::class);
$st = $modx->prepare("DELETE FROM $table WHERE INSTR(data, :needle) > 0");
$deleted = ($st && $st->execute([':needle' => 'sso.sid|s:' . strlen($sid) . ':"' . $sid . '";']))
         ? $st->rowCount() : -1;

if (!$recorded || $deleted < 0) {
    $modx->log(modX::LOG_LEVEL_ERROR, "[ssoBackchannelLogout] door session $sid: "
        . ($recorded ? '' : 'NOT recorded in the registry; ') . ($deleted < 0 ? 'rows NOT deleted' : "$deleted row(s) deleted"));
    $send(500, 'the sign-out could not be recorded');
}
$modx->log(modX::LOG_LEVEL_INFO, "[ssoBackchannelLogout] door session $sid ended: $deleted session row(s) deleted");
$send(200, 'ended');
