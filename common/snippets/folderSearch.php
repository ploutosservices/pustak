/**
 * folderSearch — a folder page asks a search service about its own context's pages.
 *
 * A folder page carries a search box; the reader's words go SERVER-SIDE to the search service for
 * the folder's own context, and the answer comes back as a feed (fmt=feed) that tableRenderer
 * draws: the answer first, then each page it was taken from, one click away.
 *
 *   [[!folderSearch]]     the box; with ?ask=<words>, the box and the answer under it
 *
 * AS THE READER, NEVER AS THE SITE. The service decides who may read which context from its own
 * access map, and it is asked with the reader's own id_token — the token their sign-in gave MODx,
 * verified here first and forwarded. Asking as the site would hand one person's pages to whoever
 * opened the folder. Nobody signed in: the box says so and nothing is asked. A token that does not
 * verify ends the MODx session, so the reader signs in again: the token must never leave unverified.
 *
 * THE CONTEXT IS THE FOLDER'S OWN, never the reader's choice: the page's context key is what is
 * sent. `ask`, not `q`: MODx's friendly URLs carry the page's own path in ?q=.
 *
 * SimpleSearch is untouched: this is the other tool, the one that answers a question. Config: the
 * system setting `modxsearch.ask_url` (the service's /v1/ask, reached on the same machine). Empty:
 * no box at all.
 *
 * Must be called uncached ([[!folderSearch]]): it reads the query string and the session.
 */

$h = function ($v) { return htmlspecialchars(is_scalar($v) ? (string) $v : '', ENT_QUOTES, 'UTF-8'); };

$askUrl = trim((string) $modx->getOption('modxsearch.ask_url', null, ''));
if ($askUrl === '' || !preg_match('#^https?://#i', $askUrl)) {
    return '';                     // this ground has no estate search: no box
}
// A credential is never sent in clear: https, loopback, or a name under the estate's internal zone.
$askHost = strtolower((string) parse_url($askUrl, PHP_URL_HOST));
$zone    = strtolower(trim((string) $modx->getOption('estate.internal_zone', null, '')));
if (!preg_match('#^https://#i', $askUrl) && !in_array($askHost, ['127.0.0.1', '::1', 'localhost'], true)
    && ($zone === '' || substr($askHost, -strlen($zone)) !== $zone)) {
    $modx->log(modX::LOG_LEVEL_ERROR, "folderSearch: refusing to present a bearer credential in clear text to $askUrl");
    return '';
}

$res    = $modx->resource;
$here   = $modx->makeUrl($res->get('id'), '', '', 'full');
$words  = isset($_GET['ask']) && is_string($_GET['ask']) ? trim($_GET['ask']) : '';
$ctxKey = $modx->context ? (string) $modx->context->get('key') : '';

// The same form, and the same "asking…" note and single press, as the Feeds page's search:
// class feed-search is what Bootstrap.5.Javascript's submit handler looks for.
// Worn as the estate form: a labelled field, GO at the edge.
$form = '<form class="estate-form feed-search mb-3" method="get" action="' . $h($here) . '">'
      . '<div class="estate-filter-row"><div class="estate-filter-fields">'
      . '<label class="estate-label">Ask <input class="estate-field" type="search" name="ask" size="50" value="' . $h($words) . '" placeholder="a question about these pages"></label>'
      . '<span class="feed-search-wait" hidden>Asking — an answer takes up to a minute…</span>'
      . '</div><div class="estate-filter-actions"><button class="estate-go" type="submit">Go</button></div></div>'
      . '</form>';
$say = function ($text) use ($form, $h) {
    return $form . '<p class="text-body-secondary">' . $h($text) . '</p>';
};

if ($words === '') {
    return $form;
}
if (!$modx->user || $ctxKey === '' || !$modx->user->isAuthenticated($ctxKey)) {
    return $say('Sign in to ask about these pages.');
}

// ---- the reader's own token: verified here, then forwarded --------------------------------------
$idToken = (string) ($_SESSION['sso.id_token'] ?? '');
require_once rtrim(MODX_CORE_PATH, '/') . '/components/pustak/lib/SsoConfig.php';
$sso = SsoConfig::forContext($modx);
$audience   = $sso->clientId;
$jwksUri    = $sso->jwksUri;
$issuers    = $sso->issuers;
$jwksSource = $jwksUri === '' ? null : function () use ($jwksUri) {
    $c = curl_init($jwksUri);
    curl_setopt_array($c, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 8,
                           CURLOPT_HTTPHEADER => ['Accept: application/json']]);
    $b  = curl_exec($c);
    $ok = curl_getinfo($c, CURLINFO_RESPONSE_CODE) === 200;
    curl_close($c);
    $j = ($ok && is_string($b)) ? json_decode($b, true) : null;
    return is_array($j) ? $j : null;
};
$why = null;
$verifiedEmail = null;
if ($idToken !== '' && $audience !== '' && $jwksSource !== null) {
    require_once rtrim(MODX_CORE_PATH, '/') . '/components/pustak/lib/GoogleToken.php';
    $verifiedEmail = \Kuber\Core\GoogleToken::verify($idToken, [$audience], $why, $jwksSource, $issuers);
} else {
    $why = $idToken === '' ? 'no id_token in session'
         : ($audience === '' ? 'no audience for this context (no client at the door)' : 'the door has no keys address');
}
if ($verifiedEmail === null) {
    $modx->log(modX::LOG_LEVEL_ERROR, "folderSearch: the reader's token did not validate ($why) — ending the "
        . 'MODx session; they sign in again and get a fresh one.');
    $modx->user->removeSessionContext($ctxKey);
    unset($_SESSION['sso.id_token'], $_SESSION['sso.id_token_exp'], $_SESSION['sso.verified_email'],
          $_SESSION['sso.refresh_token'], $_SESSION['sso.access_token']);
    return $say('Your sign-in has expired. Sign in again to ask about these pages.');
}

// ---- the token khojo is sent: the reader's EXCHANGED at the door for khojo ----------------------
// Not the reader's own id_token (addressed to this MODx context): khojo checks aud = itself and azp =
// a MODx context client. No exchange, no call — never the reader's own token instead.
$forKhojo = $sso->exchangeFor((string) ($_SESSION['sso.access_token'] ?? ''), 'khojo');
if ($forKhojo === '') {
    $modx->log(modX::LOG_LEVEL_ERROR, 'folderSearch: the door gave no token for khojo (no access token in '
        . 'the session, or the exchange was refused) — the search did not run.');
    return $say('The search could not run just now. Sign out and in again if it keeps happening.');
}

// ---- one request: the words, this folder's context, the answer as a feed ---------------------
// An answer takes tens of seconds (the model reads the passages it was handed), so it waits 150.
$ch = curl_init($askUrl);
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_POST           => true,
    CURLOPT_POSTFIELDS     => json_encode(['question' => $words, 'context' => $ctxKey, 'fmt' => 'feed',
                                           'base' => (string) $modx->getOption('site_url')]),
    CURLOPT_CONNECTTIMEOUT => 3,
    CURLOPT_TIMEOUT        => 150,
    CURLOPT_FOLLOWLOCATION => false,   // a 302 elsewhere would carry the credential off-host
    // The reader's token and nothing else: MODx's own application badge is not this service's.
    CURLOPT_HTTPHEADER     => ['Content-Type: application/json', 'Accept: application/json',
                               "Authorization: Bearer $forKhojo"],
]);
$body = curl_exec($ch);
$code = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
$err  = curl_error($ch);
curl_close($ch);

if ($body === false || $code !== 200) {
    // The service names its reason in `detail` ("that context is not open to this account"); the
    // reader is shown it, because it is what tells them what to do.
    $detail = '';
    $j = is_string($body) ? json_decode($body, true) : null;
    if (is_array($j) && isset($j['detail']) && is_string($j['detail'])) {
        $detail = $j['detail'];
    }
    $modx->log(modX::LOG_LEVEL_ERROR, "folderSearch: $askUrl answered "
        . ($body === false ? "nothing ($err)" : "HTTP $code" . ($detail !== '' ? " — $detail" : ''))
        . " for $verifiedEmail in context $ctxKey");
    return $say('The search could not answer' . ($detail !== '' ? ': ' . $detail : ($body === false ? ' — it did not respond.' : " (HTTP $code).")));
}

return $form . $modx->runSnippet('tableRenderer', ['json' => (string) $body,
    'class' => 'estate-top estate-striped estate-sort estate-filter']);
