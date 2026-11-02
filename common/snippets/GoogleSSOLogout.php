/**
 * GoogleSSOLogout — end the MODx web session (SSO-only replacement for the Login extra's logout).
 * Placed on each context's logout_page resource as [[!GoogleSSOLogout]].
 *
 * Since the Login package is removed and Google is the only login path, logout is just: drop THIS
 * context's web session and return the user to the login entry. We deliberately do NOT hit Google's
 * logout endpoint — that would sign the user out of their entire Google account, not just this site.
 *
 * Mirrors what modLoginController::logout does internally (removeSessionContext + OnWebLogout), so
 * behaviour is unchanged from the user's point of view: click logout -> session gone -> login screen.
 */

$context = $modx->context->get('key');

// THE MANAGER SIGNS OUT FIRST (the owner, 2026-10-24: "either sign me out or show me the button to
// sign out. you leave me hanging"). Its session is a different cookie, which only a manager request
// can end, so when the browser carries one the sign-out goes through /manager/?pustak-signout=<this
// page's path> (adminDoor) and comes back here with mgr=done. Before anything below runs, so the door
// session is still there to end on the second pass.
if (($_GET['mgr'] ?? '') !== 'done') {
    $mgrName = 'PHPSESSID';
    $ss = $modx->getObject(\MODX\Revolution\modSystemSetting::class, 'session_name');
    if ($ss && trim((string) $ss->get('value')) !== '') { $mgrName = trim((string) $ss->get('value')); }
    if (!empty($_COOKIE[$mgrName]) && $mgrName !== session_name()) {
        $modx->sendRedirect(rtrim(MODX_SITE_URL, '/') . MODX_MANAGER_URL . '?pustak-signout=' . rawurlencode((string) $modx->resource->get('uri')));
        return '';
    }
}

// THE DOOR'S SESSION ENDS TOO (the owner, 2026-10-20: "a logout should log out of app and
// keycloak"). Read before the session keys below are dropped: the id_token this session signed in
// with, or the one a refused address left (GoogleSSOCallback), is the door's id_token_hint.
// claude/shared/design/modx-door-session.md.
$doorHint = (string) ($_SESSION['sso.id_token'] ?? ($_SESSION['sso.door_hint'] ?? ''));

$modx->invokeEvent('OnBeforeWebLogout', ['user' => $modx->user]);
$modx->user->removeSessionContext($context);
$modx->invokeEvent('OnWebLogout', ['user' => $modx->user]);

// AND THE IDENTITY THIS SITE ITSELF ISSUED. Dropping the context token was the whole of logout,
// which left every key the SSO callback wrote sitting in the session: sso.verified_email is what
// tableRenderer's &auth asserts to kuber and sso.id_token is what the bookkeeping-names plugin
// presents. A reader who clicked 'sign out' kept an identity this estate would still vouch for on
// the next page that asked. The owner, 2026-08-14: 'i cannot logout when manager is logged in' — the
// manager half is below; this half was true for everyone.
unset(
    $_SESSION['sso.verified_email'],
    $_SESSION['sso.id_token'],
    $_SESSION['sso.id_token_exp'],
    $_SESSION['sso.access_token'],
    $_SESSION['sso.refresh_token'],
    $_SESSION['sso.returnUrl'],
    $_SESSION['sso.pending'],
    $_SESSION['sso.door_hint']
);

// THE MANAGER IN THIS SAME SESSION ends here. Where a site context has no session_name of its own
// (production, measured 2026-10-24: both answer Set-Cookie PHPSESSID), the site and the manager share
// one session, so `mgr` is in it and is ended through the manager's own logout events. Where they are
// separate, it was ended on the way here (adminDoor, ?pustak-signout).
if ($modx->user && $modx->user->isAuthenticated('mgr')) {
    $modx->invokeEvent('OnBeforeManagerLogout', ['user' => $modx->user, 'loginContext' => 'mgr']);
    $modx->user->removeSessionContext('mgr');
    $modx->invokeEvent('OnManagerLogout', ['user' => $modx->user, 'loginContext' => 'mgr']);
}
if ($modx->user && $modx->user->isAuthenticated('mgr')) {
    // No screen of MODx's own says it any more, so the log does.
    $modx->log(modX::LOG_LEVEL_WARN, '[GoogleSSOLogout] the manager session survived the sign-out');
}

// Return to the login entry (GoogleSSOStart); fall back to the site start if login_page is unset.
$target = (int) $modx->getOption('login_page') ?: (int) $modx->getOption('site_start');
$url = $modx->makeUrl($target, '', '', 'full');

// THE SIGN-OUT ENDS AT CHOWKIDAR, AND COMES BACK TO THE DOOR'S SIGN-IN (#1428;
// claude/shared/design/door-standard-login.md §2). The door ends its session in every application
// (back-channel), returns the browser to this context's sign-in entry with ?reason=signed_out, and
// GoogleSSOStart sends it straight on to the door's sign-in page, which says "You are signed out".
// The id_token is the hint when the session holds one; client_id alone ends the door session when it
// does not. Nothing of MODx's own is drawn on the way.
require_once rtrim(MODX_CORE_PATH, '/') . '/components/pustak/lib/SsoConfig.php';
$sso = SsoConfig::forContext($modx);
$endSession = $sso->fault === '' ? $sso->endSessionEndpoint() : '';
if ($endSession !== '') {
    $args = ['client_id' => $sso->clientId, 'post_logout_redirect_uri' => $url . (strpos($url, '?') === false ? '?' : '&') . 'reason=signed_out'];
    if ($doorHint !== '') {
        $args = ['id_token_hint' => $doorHint] + $args;
    }
    $modx->sendRedirect($endSession . (strpos($endSession, '?') === false ? '?' : '&') . http_build_query($args));
    return '';
}

// No door configured for this context: nothing to sign out of but this site.
$modx->sendRedirect($modx->makeUrl((int) $modx->getOption('site_start'), '', '', 'full'));
return '';
