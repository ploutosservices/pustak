<?php
/**
 * sso-provider-per-context — each context signs people in at the estate's door, as ITS OWN client.
 *
 * One provider, the door, on every name (Chowkidar 2030 step 4, #1380; claude-shared
 * design/chowkidar-step4-skunkworks-apps.md). WHAT THIS PROVES:
 *   - a context resolves to its own door client, endpoints and issuer — on a PUBLIC name too, which
 *     the retired rule ("public names use Google") refused;
 *   - Google is reached by nothing: no Google endpoint, issuer or client, whatever settings a
 *     ground still carries (production holds sso.google_* rows until they are retired);
 *   - the choice is PER CONTEXT: one MODx, four contexts, four clients;
 *   - a context with no door client is a NAMED fault, never a fallback;
 *   - the callback URL has ONE definition, so the two halves of a sign-in cannot disagree.
 *
 * A known-answer control runs FIRST, so a harness that can only pass is as visible as one that can
 * only fail.
 *
 *   php tests/sso-provider-per-context.php
 */
declare(strict_types=1);

require_once __DIR__ . '/../common/lib/SsoConfig.php';

$pass = 0; $fail = 0;
function check(bool $ok, string $label, string $detail = ''): void {
    global $pass, $fail;
    if ($ok) { $pass++; echo "  ok    $label\n"; }
    else { $fail++; echo "  FAIL  $label\n"; if ($detail !== '') echo "        $detail\n"; }
}

/**
 * The smallest thing SsoConfig actually needs: getOption(). Deliberately a stub rather than a real
 * modX — the unit under test is a settings resolver, and standing up MODx to ask it which string it
 * returns would test the database instead.
 */
class FakeModx {
    private array $opts;
    public function __construct(array $opts) { $this->opts = $opts; }
    public function getOption($key) { return $this->opts[$key] ?? null; }
}

$DOOR = [
    'sso.oidc_issuer'            => 'https://door.example.test/realms/dev',
    'sso.oidc_auth_endpoint'     => 'https://door.example.test/realms/dev/auth',
    'sso.oidc_token_endpoint'    => 'https://door.example.test/realms/dev/token',
    'sso.oidc_userinfo_endpoint' => 'https://door.example.test/realms/dev/userinfo',
    'sso.oidc_jwks_uri'          => 'https://door.example.test/realms/dev/certs',
    'sso.callback_path'          => 'sso-callback',
    'estate.internal_zone'       => '.internal.test',
];
$PUBLIC = $DOOR + [
    'http_host'              => 'www.example.org',
    'site_url'               => 'https://www.example.org/',
    'sso.oidc_client_id'     => 'modx-public',
    'sso.oidc_client_secret' => 'public-secret',
    // What production still carries until those rows are retired. Nothing may read them.
    'sso.google_client_id'   => 'g-client',
    'sso.google_client_secret' => 'g-secret',
    'sso.auth_endpoint'      => 'https://elsewhere.example/authorize',
    'sso.issuer'             => 'https://elsewhere.example',
];
$INTERNAL = $DOOR + [
    'http_host'                  => 'ctx.app.internal.test',
    'site_url'                   => 'http://ctx.app.internal.test/',
    'sso.oidc_client_id'         => 'modx-ctx',
    'sso.oidc_client_secret'     => 'ctx-secret',
];

// ── 0. the control ─────────────────────────────────────────────────────────────────────────────
// If the resolver ignored its context and answered one fixed client, every assertion below about a
// context's OWN client would pass while proving nothing. Prove first that two contexts differ.
$c0a = SsoConfig::forContext(new FakeModx($PUBLIC));
$c0b = SsoConfig::forContext(new FakeModx($INTERNAL));
check($c0a->clientId === 'modx-public' && $c0b->clientId === 'modx-ctx',
      'control: the resolver answers each context with its own client',
      "public={$c0a->clientId} internal={$c0b->clientId}");

// ── 1. a public name signs in at the door, as its own client ──────────────────────────────────
$c = SsoConfig::forContext(new FakeModx($PUBLIC));
check($c->provider === 'oidc'
   && $c->clientId === 'modx-public' && $c->clientSecret === 'public-secret'
   && $c->authEndpoint === 'https://door.example.test/realms/dev/auth'
   && $c->tokenEndpoint === 'https://door.example.test/realms/dev/token'
   && $c->issuers === ['https://door.example.test/realms/dev']
   && $c->fault === '',
      'a PUBLIC context resolves to the door with its own client — no zone rule refuses it',
      json_encode([$c->provider, $c->clientId, $c->authEndpoint, $c->issuers, $c->fault]));

// ── 2. Google is reached by nothing ────────────────────────────────────────────────────────────
$all = json_encode([$c->authEndpoint, $c->tokenEndpoint, $c->issuers, $c->clientId, $c->jwksUri]);
check(strpos($all, 'google') === false && strpos($all, 'g-client') === false && strpos($all, 'elsewhere') === false,
      'no Google endpoint, issuer or client, and no retired trio, whatever rows the ground still holds', $all);

// ── 3. per CONTEXT, not per install ────────────────────────────────────────────────────────────
$a = SsoConfig::forContext(new FakeModx($INTERNAL));
check($a->clientId === 'modx-ctx' && $a->clientSecret === 'ctx-secret' && $a->fault === ''
   && $a->userinfoEndpoint === 'https://door.example.test/realms/dev/userinfo'
   && $a->jwksUri === 'https://door.example.test/realms/dev/certs',
      'two contexts of one install resolve independently, each with its own client and secret');

// ── 4. no door client is a named fault, never a fallback ───────────────────────────────────────
$none = ['http_host' => 'www.example.org', 'site_url' => 'https://www.example.org/',
         'sso.google_client_id' => 'g-client', 'sso.google_client_secret' => 'g-secret'];
$c = SsoConfig::forContext(new FakeModx($none));
check($c->fault !== '' && strpos($c->fault, 'sso.oidc_client_id') !== false && $c->authEndpoint === '',
      'a context with no door client (only the old Google rows) is a named fault, not Google', $c->fault);

// ── 5. a missing setting names itself ──────────────────────────────────────────────────────────
$partial = $INTERNAL;
unset($partial['sso.oidc_client_secret'], $partial['sso.oidc_token_endpoint']);
$c = SsoConfig::forContext(new FakeModx($partial));
check($c->fault !== ''
   && strpos($c->fault, 'sso.oidc_client_secret') !== false
   && strpos($c->fault, 'sso.oidc_token_endpoint') !== false,
      'an incomplete context names EVERY missing setting', $c->fault);
check(strpos($c->fault, 'sso.oidc_issuer') === false,
      'and does not name the ones that are present', $c->fault);

// ── 5b. the JWKS URL is DISCOVERED when it is not configured ────────────────────────────
// A conforming OIDC client discovers a provider from its issuer. Making this a sixth setting turned
// "verify the token" into a change request on another agent, which is a gate on finished work.
// Configured wins (deterministic, no network); absent falls to the issuer's discovery document.
$c = SsoConfig::forContext(new FakeModx($INTERNAL));
check($c->jwksUri === 'https://door.example.test/realms/dev/certs',
      'a configured sso.oidc_jwks_uri is used as-is, with no network call', $c->jwksUri);

$nojwks = $INTERNAL; unset($nojwks['sso.oidc_jwks_uri']);
$c = SsoConfig::forContext(new FakeModx($nojwks));
// The issuer here does not resolve, so discovery fails and jwksUri stays empty — and CRUCIALLY the
// context does NOT fault, because an unreachable provider is not a configuration error. The refusal
// happens at the callback (SSO-19), where it is a true statement about the provider.
check($c->jwksUri === '' && $c->fault === '',
      'an unconfigured JWKS URL is not a config fault — discovery is tried, refusal is the callback\'s',
      "jwks='{$c->jwksUri}' fault='{$c->fault}'");

// And with a LIVE provider it really does discover. Skipped rather than failed where the estate's
// provider is unreachable, because a test that needs the network must say which it did.
// MODX_DOOR_ISSUER names the door's issuer on this ground: run-all.sh exports it from the first
// context's sso.oidc_issuer row; a ground that cannot answer leaves it unset and this is skipped,
// said aloud. (It read MOCK_OIDC_URL until the mock was retired.)
$door = rtrim((string) getenv('MODX_DOOR_ISSUER'), '/');
$live = $INTERNAL;
unset($live['sso.oidc_jwks_uri']);
$live['sso.oidc_issuer'] = $door;
$probe = $door === '' ? false : @file_get_contents($door . '/.well-known/openid-configuration');
$published = $probe === false ? '' : (string) (json_decode($probe, true)['jwks_uri'] ?? '');
if ($probe === false || $published === '') {
    echo "  skip  discovery against the live provider (" . ($door ?: 'MODX_DOOR_ISSUER unset') . " unreachable or publishes no jwks_uri)\n";
} else {
    $c = SsoConfig::forContext(new FakeModx($live));
    check($c->jwksUri === $published,
          'with no setting, the JWKS URL is DISCOVERED from the live issuer', $c->jwksUri);
}

// ── 6. one definition of the callback URL ──────────────────────────────────────────────────────
// GoogleSSOStart and GoogleSSOCallback used to build this separately, kept identical by a comment
// asking the next person nicely. Every conforming provider compares the two.
check(SsoConfig::redirectUri(new FakeModx($PUBLIC)) === 'https://www.example.org/sso-callback',
      'callback URL on a public context is https and the configured path',
      SsoConfig::redirectUri(new FakeModx($PUBLIC)));
check(SsoConfig::redirectUri(new FakeModx($INTERNAL)) === 'http://ctx.app.internal.test/sso-callback',
      'callback URL on an internal context follows the context scheme, not a literal https',
      SsoConfig::redirectUri(new FakeModx($INTERNAL)));
// THE TWO ABOVE ARE UNEDITED, DELIBERATELY. Both fixtures have site_url and http_host naming the
// same authority — which is every context on production and on staging — so they are the proof
// that building the callback from site_url changed nothing on any ground that exists today.
//
// The third fixture is a context whose address DIVERGES from its http_host (no ground binds one
// that way since the bench port doors were retired, #1276; SsoConfig still builds the callback from
// site_url, and this pins that it does).
$LOCAL = array_merge($INTERNAL, ['http_host' => 'worldview.modx.internal.test',
                                 'site_url'  => 'http://localhost:8314/']);
check(SsoConfig::redirectUri(new FakeModx($LOCAL)) === 'http://localhost:8314/sso-callback',
      'a context RESOLVED on one name and REACHED on another builds its callback from the one a '
    . 'browser can reach',
      SsoConfig::redirectUri(new FakeModx($LOCAL)));
// ...and the port survives. A construction that took only the scheme from site_url would produce
// http://worldview.modx.internal.test/sso-callback and look almost right in a log.
check(strpos(SsoConfig::redirectUri(new FakeModx($LOCAL)), ':8314/') !== false,
      'the callback keeps the PORT — a provider compares redirect_uri byte for byte',
      SsoConfig::redirectUri(new FakeModx($LOCAL)));
// A context with no site_url at all must not produce a malformed URL; it falls back to the old
// construction and lets the provider refuse, rather than emitting '://.../sso-callback'.
$NOSITE = array_merge($INTERNAL, ['site_url' => '']);
check(SsoConfig::redirectUri(new FakeModx($NOSITE)) === 'https://ctx.app.internal.test/sso-callback',
      'an empty site_url falls back to http_host and a well-formed URL, not to nonsense',
      SsoConfig::redirectUri(new FakeModx($NOSITE)));

// ── the deep-link destination is read BEFORE login replaces the session ──────────────────
// The owner: a signed-out visit to an internal context's /capability signed him in and landed him on /home.
// The callback read $_SESSION['sso.returnUrl'] at its redirect step, which runs AFTER
// runProcessor('security/login') — and MODx's login replaces the session, so the read found
// nothing and fell through to the userHome router. An ORDER defect, invisible in every unit that
// tests the pieces, so it is asserted as an order.
// CODE ONLY. Two earlier versions of this check matched the word inside a COMMENT — first the
// snippet's docstring, then the very comment that explains this defect — and both failed on
// correct code. Comment lines are stripped before anything is located. Third time today that a
// check of mine has been fooled by its own documentation (2026-08-14).
$cb = implode("\n", array_filter(
    file(__DIR__ . '/../common/snippets/GoogleSSOCallback.php', FILE_IGNORE_NEW_LINES),
    fn($l) => !preg_match('#^\s*(//|\*|/\*)#', $l)));
// Since 2026-09-23 the destination travels in the PENDING entry its state names (several sign-ins
// can be in flight in one browser), so what must come first is the read of that entry.
$posRead  = strpos($cb, "\$_SESSION['sso.pending']");
// The CALL, not the word: the first version searched for "security/login" and matched the
// docstring at the top of the snippet, so it failed on correct code and would have passed on
// broken code once that line moved. Found by it going red on the fix (2026-08-14).
$posLogin = strpos($cb, 'addSessionContext(');
check($posRead !== false && $posLogin !== false && $posRead < $posLogin,
      'the returnUrl is captured BEFORE the session context changes',
      "read at $posRead, addSessionContext at $posLogin — capture first, so no later session handling can reach it");
check(substr_count($cb, "\$started['returnUrl']") === 1 && substr_count($cb, "sso.returnUrl") === 0,
      '  and it is read in exactly one place, from the pending entry',
      'a second read after login would reintroduce the defect quietly');

echo "\n$pass passed, $fail failed\n";
exit($fail === 0 ? 0 : 1);
