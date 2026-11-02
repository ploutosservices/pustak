/**
 * GoogleSSOStart — begin the sign-in at the estate's door (Chowkidar). The name is historical: a
 * renamed element deploys as a NEW one, so it keeps its name (design
 * chowkidar-step4-skunkworks-apps.md §2).
 *
 * Placed on each context's login / unauthorized page (replaces the [[!Login]] form for SSO).
 * Every arrival goes straight to the door: one sign-in screen and one signed-out screen, both
 * the door's. A sign-out returns here with `?reason=signed_out`, passed on to the door.
 * On return, GoogleSSOCallback (on the callback resource) completes the login.
 *
 * Authorization-code flow with PKCE (S256), server-side: the code and its verifier are exchanged
 * for tokens in the callback, directly against the door's token endpoint. The redirect_uri MUST
 * byte-match a return address declared on this context's door client.
 *
 * Config (context settings `sso.oidc_*`, set by setup/12-sso.py or infra's render; SsoConfig).
 *
 * No user input is trusted here except returnUrl, which is stored server-side (session) and only
 * ever used as a same-site path by the callback — never reflected — and reason, which travels only
 * when it is one of the door's fixed codes.
 */

// Already signed in? Don't re-run OAuth — go straight to the home router. This guards against a
// redirect loop: after the SSO repoint, login_page IS this resource, so anything that sends a
// logged-in user to login_page would otherwise re-enter the OAuth dance.
// AUTHENTICATED IN THIS CONTEXT, not merely KNOWN. The loop this guards against is a user who can
// already read the site being sent back to the sign-in page; a manager session is neither of those
// things here. The owner, 2026-08-14, testing sign-out on production: 'with manager open, when i sign out,
// i go to home'. That is this line — getUser() still returns him from the mgr session, so the
// sign-out sent him to sso-login and sso-login bounced him straight to /home, so he never saw the
// card or the notice saying his manager session was still open. The sign-out was working; the
// sign-in page was hiding it.
$current = $modx->getUser();
$ctxKey  = (string) $modx->context->get('key');
if ($current && (int) $current->get('id') > 0 && $current->isAuthenticated($ctxKey)) {
    $modx->sendRedirect($modx->makeUrl((int) $modx->getOption('site_start'), '', '', 'full'));
    return '';
}

// THIS CONTEXT'S CLIENT AT THE DOOR. One resolver, shared with GoogleSSOCallback, because the
// client id chosen here and there must be identical or the token exchange fails with a mismatch
// and no useful message.
require_once rtrim(MODX_CORE_PATH, '/') . '/components/pustak/lib/SsoConfig.php';
$sso = SsoConfig::forContext($modx);
if ($sso->fault !== '') {
    // NAME THE FAULT IN THE LOG, and give the screen something to quote. "Single sign-on is not
    // configured" was the whole message here, for four different causes.
    $modx->log(modX::LOG_LEVEL_ERROR, '[GoogleSSOStart] [SSO-00] ' . $sso->fault);
    return 'Single sign-on is not configured for this site. Please contact the administrator '
         . 'and quote <strong>SSO-00</strong>.';
}
$clientId = $sso->clientId;

// Where the user was originally heading (deep-link return-to-original after auth). Kept
// server-side so it can never be turned into an open-redirect via the query string.
$returnUrl = '';
if (!empty($_REQUEST['returnUrl'])) {
    $candidate = (string) $_REQUEST['returnUrl'];
    // Same-site only: a root-relative path, never a scheme/host and never protocol-relative.
    if ($candidate[0] === '/' && strpos($candidate, '//') !== 0) {
        $returnUrl = $candidate;
    }
}

// ONE SIGN-IN SCREEN, THE DOOR'S, AND ONE SIGNED-OUT SCREEN, THE DOOR'S TOO
// (claude/shared/design/door-standard-login.md §2). Every arrival goes straight to the door with no
// `prompt` and no `kc_idp_hint`: a reader the door knows comes back signed in having seen nothing,
// anyone else sees the door's own page. MODx draws no sign-in or signed-out screen of its own. A
// sign-out comes back here as ?reason=signed_out, and the reason travels on to the door as
// chowkidar_reason, so the door heads its page with its own words. Only a code on the door's fixed
// list travels; the door shows nothing for any other, and MODx sends no text of its own.
$reason = (string) ($_GET['reason'] ?? '');
if (!in_array($reason, ['signed_out', 'certificate_needed', 'session_expired', 'sign_in_again'], true)) {
    $reason = '';
}

$modx->startSession();

// CSRF state + OIDC nonce, both bound to this session and single-use.
//
// ONE ENTRY PER SIGN-IN STARTED, KEYED BY ITS STATE — not one slot per session. The owner,
// 2026-09-23: "the sign in to local modx using oidc stopped working again." A session held ONE
// state, so a second sign-in started in the same browser overwrote the first, and the first came
// back SSO-01 "state mismatch". On the dev box every context is `localhost` on its own port, a
// cookie ignores the port, so all four sites share one session — and a protected page starts a
// sign-in by itself, so any other open tab was enough. Production has one name per context, and
// the same collision still happens with two tabs of one site. Reproduced on the bench before the
// fix: start on 8312, start on 8314, finish 8312 -> SSO-01.
//
// Bounded both ways: an entry older than ten minutes is dropped (a sign-in is a round trip of
// seconds), and no more than ten are kept, oldest first out.
$state = bin2hex(random_bytes(16));
$nonce = bin2hex(random_bytes(16));
// PKCE (RFC 7636, S256), the door's contract (chowkidar-2030 §2.1): the verifier stays in this
// session beside its state, and only its hash leaves with the browser.
$verifier = rtrim(strtr(base64_encode(random_bytes(48)), '+/', '-_'), '=');
$pending = is_array($_SESSION['sso.pending'] ?? null) ? $_SESSION['sso.pending'] : [];
$now = time();
$pending = array_filter($pending, function ($p) use ($now) {
    return is_array($p) && ($now - (int) ($p['at'] ?? 0)) < 600;
});
$pending[$state] = [
    'nonce'     => $nonce,
    'verifier'  => $verifier,
    'returnUrl' => $returnUrl,
    'ctx'       => $modx->context->get('key'),
    'at'        => $now,
];
$_SESSION['sso.pending'] = array_slice($pending, -10, null, true);

// The public edge for THIS context — see SsoConfig::redirectUri for why the scheme is derived
// rather than written, and why the path is single-sourced from sso.callback_path.
// ONE definition of the callback URL, in SsoConfig, shared with the callback. It used to be
// these two lines in both files with a comment in each asking the next person to keep them
// byte-identical — which is a convention, and a convention is not a mechanism.
$redirectUri  = SsoConfig::redirectUri($modx);

$params = [
    'client_id'     => $clientId,
    'redirect_uri'  => $redirectUri,
    'response_type' => 'code',
    'scope'         => 'openid email profile',
    'state'         => $state,
    'nonce'         => $nonce,
    'code_challenge'        => rtrim(strtr(base64_encode(hash('sha256', $verifier, true)), '+/', '-_'), '='),
    'code_challenge_method' => 'S256',
];
if ($reason !== '') {
    $params['chowkidar_reason'] = $reason;
}

// The authorization endpoint is this context's door realm's (SsoConfig).
$modx->sendRedirect($sso->authEndpoint . '?' . http_build_query($params));
return '';
