/**
 * unauthorizedNotice — what a person sees when MODx REFUSES a page.
 *
 * THE DEFECT THIS EXISTS FOR. `unauthorized_page` and `login_page` are the same resource on every
 * gated context: setup/12 points both at the context's `sso-login` entry. Signed OUT that is
 * correct — you were refused, so go and sign in. Signed IN and not a member of the context it is a
 * loop with no exit and no explanation:
 *
 *     refused -> sso-login -> "already signed in" -> site_start -> refused -> sso-login -> …
 *
 * GoogleSSOStart returns a signed-in visitor to `site_start`, which on a protected context is
 * `userHome`, which routes them at a page they are still not allowed to see. The person is bounced
 * between two pages that each believe the other one will handle it, and neither ever says the one
 * fact that would end it: *this account is not a member of this area*. The owner met it himself on
 * staging on 2026-08-12; his membership was changed so he will not meet it again, which is exactly
 * why the behaviour is fixed here rather than left to be rediscovered by somebody without that fix.
 *
 * THE RULE IT OBEYS comes from one repo over, and it is the whole point: a failure a person is
 * shown must name itself — the real reason, or a reference that appears verbatim in a log. A
 * redirect names nothing at all, which is worse than a bare sentence: there is not even a string to
 * photograph and send to admissions.
 *
 * BEHAVIOUR, one branch per state of the visitor:
 *
 *   signed out          forward to the sign-in entry, carrying the page they were asking for as
 *                       returnUrl. This is what happens today and it is right; the only change is
 *                       that the deep link survives the round trip.
 *   signed in, refused  ACC-01. Name the account, name nothing else about the estate, offer the one
 *                       action that can work (sign out, sign in as somebody else) and never a
 *                       sign-in link — a sign-in link IS the loop.
 *   login_page missing  ACC-02. Rather than an empty href (an anchor with no target is
 *                       indistinguishable from a working one until it is clicked).
 *   login_page is THIS  ACC-03. Refuse to forward to ourselves. A misconfiguration that would
 *                       otherwise reproduce the very loop this snippet was written to end.
 *
 * WHAT IT DELIBERATELY DOES NOT DO: it never says which group or context would have been required,
 * and it never lists what else exists. The visitor is told about their own session and nothing
 * about the estate's shape — the same line GoogleSSOCallback's $deny draws, for the same reason.
 *
 * Placed as `[[!unauthorizedNotice]]` on each context's `sso-unauthorized` resource by setup/12,
 * which then points `unauthorized_page` at it. UNCACHED, always: the answer depends on who is
 * asking, and a cached copy would show one visitor's name to the next one.
 */

$requested = (string) ($_SERVER['REQUEST_URI'] ?? '/');
// Same-site path only, and never protocol-relative — this value is handed back out as a query
// parameter, so it is treated as untrusted even though it came from the server's own forward.
if ($requested === '' || $requested[0] !== '/' || strpos($requested, '//') === 0) {
    $requested = '/';
}

$loginId  = (int) $modx->getOption('login_page');
$logoutId = (int) $modx->getOption('logout_page');
$thisId   = ($modx->resource instanceof modResource) ? (int) $modx->resource->get('id') : 0;

// THE SAME CARD AS THE SIGN-IN SCREEN, 2026-09-12. The owner: "the login screens are pretty dull. can
// we make consistent like trump or kuber." This is the other half of that pair — a reader meets it
// by being refused, so it is a sign-in screen in every way that matters, and it rendered as a bare
// unstyled div while the page it forwards to was a card. `access-refused` is KEPT on the outer
// element: it is a hook anything else may already select on, and removing it to tidy the markup
// would be a change nobody asked for. Nothing about the four branches, the 403, the log line or
// the reference code moves.
// A WHOLE PAGE, THE SAME CARD AS THE ERROR PAGE (the owner, 2026-10-05: "can you make it similar to
// other page you just updated"). The sso-unauthorized resources have template 0, so this output IS
// the response; it carries its own head (Bootstrap.5.Head, as the sign-in page does) and names the
// Library and the site above the message. Text in the text's own colour — no grey (his rule).
$refuse = function (string $ref, string $logMsg, string $headline, string $body) use ($modx) {
    $modx->log(modX::LOG_LEVEL_WARN, '[unauthorizedNotice] [' . $ref . '] ' . $logMsg);
    @http_response_code(403);
    $site = htmlspecialchars((string) $modx->getOption('site_name'), ENT_QUOTES, 'UTF-8');
    // The application's name, from its manifest (service.json identity.display_name -> setup/02).
    $app = htmlspecialchars((string) $modx->getOption('estate_app_name'), ENT_QUOTES, 'UTF-8');
    return '<!doctype html><html lang="en">' . $modx->getChunk('Bootstrap.5.Head')
         . '<body class="bg-light">'
         . '<div class="access-refused min-vh-100 d-flex align-items-center justify-content-center px-3">'
         . '<div class="card border shadow-sm rounded-3" style="max-width:24rem;width:100%;">'
         . '<div class="card-body text-center p-4 p-sm-5">'
         . '<img src="' . htmlspecialchars(rtrim((string) $modx->getOption('estate_cdn_url'), '/'), ENT_QUOTES, 'UTF-8')
         . '/brand/20261007-veena/veena.svg" alt="" height="64" class="mb-3"'
         . ' style="max-width:10rem;object-fit:contain;">'
         . '<h1 class="h5 fw-semibold mb-1">' . $app . '</h1>'
         . '<p class="mb-4">' . $site . '</p>'
         . '<h2 class="h6 fw-semibold mb-3">' . $headline . '</h2>'
         . '<div>' . $body . '</div>'
         . '<p class="small mb-0 mt-4">If you believe this is wrong, contact the '
         . 'administrator and quote <strong>' . htmlspecialchars($ref, ENT_QUOTES, 'UTF-8')
         . '</strong>.</p>'
         . '</div></div></div></body></html>';
};

$user = $modx->getUser();
$signedIn = ($user && (int) $user->get('id') > 0);

if (!$signedIn) {
    // Nobody is signed in, so sending them to sign in is the correct and complete answer.
    if ($loginId <= 0) {
        return $refuse('ACC-02', 'refused ' . $requested . ' for an anonymous visitor and this '
            . 'context has no login_page, so there is nowhere to send them',
            'This page requires you to sign in',
            '<p>Sign-in is not configured for this site, so there is no way to continue from here.</p>');
    }
    if ($loginId === $thisId) {
        return $refuse('ACC-03', 'login_page and unauthorized_page are the same resource (' . $thisId
            . ') — refusing to forward to ourselves',
            'This page requires you to sign in',
            '<p>The sign-in page for this site is misconfigured, so there is no way to continue from here.</p>');
    }
    $modx->sendRedirect($modx->makeUrl($loginId, '', ['returnUrl' => $requested], 'full'));
    return '';
}

// Signed in and still refused: the one case the old behaviour could not express.
$profile = $user->getOne('Profile');
$who = '';
if ($profile) { $who = trim((string) $profile->get('email')); }
if ($who === '') { $who = (string) $user->get('username'); }
$whoHtml = htmlspecialchars($who, ENT_QUOTES, 'UTF-8');

$action = '';
if ($logoutId > 0 && $logoutId !== $thisId) {
    $url = $modx->makeUrl($logoutId, '', '', 'full');
    if (is_string($url) && $url !== '') {
        $action = '<p class="mt-4 mb-0"><a class="btn btn-outline-dark w-100 py-2" href="'
                . htmlspecialchars($url, ENT_QUOTES, 'UTF-8')
                . '">Sign out and use a different account</a></p>';
    }
}

return $refuse(
    'ACC-01',
    'refused ' . $requested . ' for signed-in user ' . $who . ' in context '
        . (string) $modx->context->get('key') . ' — authenticated but not permitted',
    'This account cannot open that page',
    '<p>You are signed in as <strong>' . $whoHtml . '</strong>. That account is not a member of this '
        . 'area, so signing in again will not help.</p>' . $action
);
