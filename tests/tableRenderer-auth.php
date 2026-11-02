<?php
/**
 * tableRenderer &auth — the test, run against the REAL snippet and the REAL verifier.
 *
 *     php tests/tableRenderer-auth.php
 *
 * WHAT IS UNDER TEST. A MODx page must be able to read a value from kuber at render time
 * under the identity of the person reading it, and render BLANK when there is no identity
 * (the owner, 2026-07-29: *"if not logged in, display blank"*). `&auth` is how tableRenderer presents
 * that identity: the reader's door access token EXCHANGED at the door for the &auth audience,
 * sent as `Authorization: Bearer`. MODx mints nothing.
 *
 * WHY THE PIECES ARE REAL RATHER THAN MODELLED:
 *
 *   1. THE EXCHANGE. The snippet's own SsoConfig::exchangeFor posts to a door on loopback, which
 *      records the form it was sent (grant, subject token, audience, scope, client) and answers
 *      with a token named for the audience — or refuses, for the negative case.
 *   2. THE HEADER. Asserted from the receiving end — a real HTTP server on loopback that records
 *      the Authorization header it was actually sent. Inspecting a variable inside the snippet
 *      would prove the string was built, not that it left the process.
 *   3. THE SNIPPET. The same file production runs, eval'd the way MODx eval's it (a MODx snippet is
 *      stored without an opening <?php tag), with $modx stubbed to what it touches.
 *
 * EVERY NEGATIVE CASE HAS A POSITIVE CONTROL, and vice versa, because a check that can only say
 * "no" is worthless: the wrong-key case is paired with the right-key case, the refused-transport
 * case with an accepted one, "no request was made" with "a request was made".
 */

$HOME = getenv('HOME');
$REPO = dirname(__DIR__);

$SNIPPET = getenv('TABLERENDERER') ?: $REPO . '/common/snippets/tableRenderer.php';

if (!is_file($SNIPPET)) {
    fwrite(STDERR, "tableRenderer.php not found at $SNIPPET\n");
    exit(2);
}

// ---- the receiving end -----------------------------------------------------------------------
// A real server, so "the header was sent" is measured where it arrives. It also writes one line
// per request, which is how the "no request was made at all" cases are proved: a snippet that
// refuses must not fetch as nobody, and silence is only meaningful if the log can record noise.
$TMP = sys_get_temp_dir() . '/trauth-' . getmypid();
@mkdir($TMP, 0700, true);
$LOG = "$TMP/requests.log";
touch($LOG);

file_put_contents("$TMP/router.php", <<<'PHP'
<?php
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
if ($path === '/token') {
    // The door: records the exchange it was asked for, answers a token named for the audience.
    file_put_contents(getenv('TRAUTH_LOG'), "/token\t" . json_encode($_POST) . "\n", FILE_APPEND);
    header('Content-Type: application/json');
    if (($_POST['subject_token'] ?? '') === 'refused-by-the-door') {
        http_response_code(400);
        echo '{"error":"invalid_request"}';
        return;
    }
    echo json_encode(['access_token' => 'exchanged-for-' . ($_POST['audience'] ?? ''), 'token_type' => 'Bearer']);
    return;
}
file_put_contents(getenv('TRAUTH_LOG'), $path . "\t" . $auth . "\n", FILE_APPEND);
if ($path === '/deny') {
    http_response_code(403);
    echo '{"error":"no such identity"}';
    return;
}
header('Content-Type: application/json');
echo json_encode(['rows' => [['seen' => $auth]]]);
PHP);

/** First free loopback port at or above $from — a fixed port would make the suite fail on a busy box. */
function freePort(int $from = 8399): int {
    for ($p = $from; $p < $from + 50; $p++) {
        $s = @stream_socket_server("tcp://127.0.0.1:$p", $e, $m);
        if ($s) { fclose($s); return $p; }
    }
    fwrite(STDERR, "no free port in $from..\n");
    exit(2);
}
$PORT = freePort();
$server = proc_open(
    ['php', '-S', "127.0.0.1:$PORT", '-t', $TMP, "$TMP/router.php"],
    [1 => ['file', "$TMP/server.out", 'a'], 2 => ['file', "$TMP/server.out", 'a']],
    $pipes, $TMP, ['TRAUTH_LOG' => $LOG] + $_ENV
);
register_shutdown_function(function () use ($server, $TMP) {
    if (is_resource($server)) {
        proc_terminate($server);
        proc_close($server);
    }
    @unlink("$TMP/core/components/pustak/lib");
    foreach (["$TMP/core/components/pustak", "$TMP/core/components", "$TMP/core"] as $d) { @rmdir($d); }
    array_map('unlink', glob("$TMP/*") ?: []);
    @rmdir($TMP);
});
for ($i = 0; $i < 100; $i++) {                       // wait for it to actually accept
    $c = @stream_socket_client("tcp://127.0.0.1:$PORT", $e, $m, 0.2);
    if ($c) { fclose($c); break; }
    usleep(50000);
}
$BASE = "http://127.0.0.1:$PORT";

// The snippet loads SsoConfig from MODx's own place (core/components/pustak/lib/), so that place is
// this repository's common/lib for the run.
@mkdir("$TMP/core/components/pustak", 0700, true);
symlink("$REPO/common/lib", "$TMP/core/components/pustak/lib");
define('MODX_CORE_PATH', "$TMP/core/");

// ---- $modx, stubbed to exactly what the snippet touches --------------------------------------
class StubParser {
    public $uncacheable = true;
    public function isProcessingUncacheable() { return $this->uncacheable; }
}
class StubResource {
    public $content = '';
    public function get($k) { return $k === 'content' ? $this->content : null; }
}
class StubProfile {
    public $email = '';
    public function get($k) { return $k === 'email' ? $this->email : null; }
}
class StubUser {
    public $authenticated = true;
    public $profile;
    public function __construct(string $email) { $this->profile = new StubProfile(); $this->profile->email = $email; }
    public function isAuthenticated($ctx = '') { return $this->authenticated; }
    public function getOne($alias) { return $alias === 'Profile' ? $this->profile : null; }
}
class StubContext {
    public $key = 'family';
    public function get($k) { return $k === 'key' ? $this->key : null; }
}
class StubModx {
    public $resource;
    public $user;
    public $context;
    public $parser;
    public $settings = [];                            // system settings, as MODx getOption falls back to
    public function __construct() {
        $this->resource = new StubResource();
        $this->context  = new StubContext();
        $this->parser   = new StubParser();
    }
    /** props first, then system settings, then the default — MODx's own precedence. */
    public function getOption($key, $props = null, $default = null) {
        if (is_array($props) && array_key_exists($key, $props) && $props[$key] !== null) {
            return $props[$key];
        }
        return array_key_exists($key, $this->settings) ? $this->settings[$key] : $default;
    }
    public function getParser() { return $this->parser; }
    public function log($level, $msg) { }
}

$code = file_get_contents($SNIPPET);
if (str_starts_with(ltrim($code), '<?php')) {
    $code = substr(ltrim($code), 5);
}
/** Run the snippet in its own scope so nothing leaks between cases. */
$run = function ($modx, $scriptProperties) use ($code) { return eval($code); };

/** A fresh $modx with a signed-in, door-verified reader, its access token, and this context's door client. */
$fresh = function (string $email = 'someone@example.org') use ($BASE) {
    $m = new StubModx();
    $m->user = new StubUser($email);
    $m->settings += [
        'sso.oidc_issuer' => "$BASE/realms/dev", 'sso.oidc_auth_endpoint' => "$BASE/auth",
        'sso.oidc_token_endpoint' => "$BASE/token", 'sso.oidc_jwks_uri' => "$BASE/certs",
        'sso.oidc_client_id' => 'modx-family', 'sso.oidc_client_secret' => 'client-secret-for-the-test',
    ];
    $_SESSION = ['sso.verified_email' => $email, 'sso.access_token' => 'the-readers-access-token',
                 'sso.id_token' => 'the-readers-own-id-token'];
    return $m;
};

// ---- assertions -------------------------------------------------------------------------------
$pass = 0; $fail = 0;
$check = function (string $name, bool $ok, string $detail = '') use (&$pass, &$fail) {
    if ($ok) { $pass++; printf("  ok    %s\n", $name); return; }
    $fail++;
    printf("  FAIL  %s\n", $name);
    if ($detail !== '') {
        foreach (explode("\n", rtrim($detail)) as $line) { printf("          %s\n", $line); }
    }
};
$requests = function (string $path) use ($LOG) {
    $out = [];
    foreach (file($LOG, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        [$p, $a] = array_pad(explode("\t", $line, 2), 2, '');
        if ($p === $path) { $out[] = $a; }
    }
    return $out;
};

echo "tableRenderer &auth\n";

// --- 1. the whole point: a signed-in reader's identity reaches the endpoint --------------------
$m   = $fresh();
$out = $run($m, ['url' => "$BASE/t1", 'rows' => 'rows', 'auth' => 'kuber']);
$seen = $requests('/t1');
$check('a request is made', count($seen) === 1, 'requests to /t1: ' . count($seen));
$sent = $seen[0] ?? '';
$check('the Bearer that arrives is the token the door exchanged for kuber',
    $sent === 'Bearer exchanged-for-kuber', "header was: '$sent'");
$check("...never the reader's own id_token or access token",
    !str_contains($sent, 'the-readers-own-id-token') && !str_contains($sent, 'the-readers-access-token'), $sent);
$check('the table renders', str_contains($out, '<table'), substr($out, 0, 300));

$asked = json_decode($requests('/token')[0] ?? '{}', true) ?: [];
$check('the door was asked for a token exchange', ($asked['grant_type'] ?? '') === 'urn:ietf:params:oauth:grant-type:token-exchange',
    var_export($asked, true));
$check("...of the reader's access token", ($asked['subject_token'] ?? '') === 'the-readers-access-token'
    && ($asked['subject_token_type'] ?? '') === 'urn:ietf:params:oauth:token-type:access_token');
$check('...for audience kuber, scope audience-kuber (the &auth name)',
    ($asked['audience'] ?? '') === 'kuber' && in_array('audience-kuber', explode(' ', $asked['scope'] ?? ''), true));
// Without openid in the exchange's scope the door drops openid from this client's session, and every
// later refresh comes back with no id_token, so ssoRenew ends the reader's session.
$check("...keeping the sign-in's scope, so the session still renews",
    !array_diff(['openid', 'email', 'profile'], explode(' ', $asked['scope'] ?? '')), 'scope: ' . ($asked['scope'] ?? ''));
$check("...by this context's own door client", ($asked['client_id'] ?? '') === 'modx-family');

$m = $fresh();
$out = $run($m, ['url' => "$BASE/t1b", 'rows' => 'rows', 'auth' => 'roster']);
$check('another &auth name exchanges for that audience', $requests('/t1b') === ['Bearer exchanged-for-roster'],
    var_export($requests('/t1b'), true));

// --- 2. no identity => blank, and NOTHING is asked of kuber -----------------------------------
$m = $fresh();
$_SESSION = [];                                       // signed in to MODx, but not via SSO
$out = $run($m, ['url' => "$BASE/t2", 'rows' => 'rows', 'auth' => 'kuber']);
$check('an unverified reader produces no request at all', $requests('/t2') === [],
    'requests: ' . count($requests('/t2')));
$check('an unverified reader produces no table', !str_contains($out, '<table'), $out);

$m = $fresh('someone@example.org');
$_SESSION = ['sso.verified_email' => 'someone.else@example.org'];
$out = $run($m, ['url' => "$BASE/t3", 'rows' => 'rows', 'auth' => 'kuber']);
$check('a session email that disagrees with the account on file asserts nobody',
    $requests('/t3') === [] && !str_contains($out, '<table'), $out);

$m = $fresh();
$m->user->authenticated = false;                      // signed out of this context
$out = $run($m, ['url' => "$BASE/t4", 'rows' => 'rows', 'auth' => 'kuber']);
$check('a reader not authenticated in this context asserts nobody',
    $requests('/t4') === [] && !str_contains($out, '<table'), $out);

// --- 3. no exchange must never mean "ask anyway" with some other token --------------------------
$m = $fresh();
unset($_SESSION['sso.access_token']);
$out = $run($m, ['url' => "$BASE/t5", 'rows' => 'rows', 'auth' => 'kuber']);
$check('no access token in the session: no request, no table',
    $requests('/t5') === [] && !str_contains($out, '<table'), $out);
$check('...and says the door gave no token', str_contains($out, 'the door gave no token'), $out);

$m = $fresh();
$_SESSION['sso.access_token'] = 'refused-by-the-door';
$out = $run($m, ['url' => "$BASE/t5b", 'rows' => 'rows', 'auth' => 'kuber']);
$check('the door refuses the exchange: no request, and the page survives',
    $requests('/t5b') === [] && !str_contains($out, '<table') && str_starts_with($out, '<!--'), $out);

$m = $fresh();
$m->settings['kuber.jwt_private_key'] = 'a-retired-signing-key';
$out = $run($m, ['url' => "$BASE/t5c", 'rows' => 'rows', 'auth' => 'kuber']);
$check('a kuber.jwt_private_key still in settings is not used: the exchanged token is sent',
    $requests('/t5c') === ['Bearer exchanged-for-kuber'], var_export($requests('/t5c'), true));

// --- 4. the refusals that are about the call, not the reader -----------------------------------
$m   = $fresh();
$out = $run($m, ['from' => 'x', 'auth' => 'kuber']);
// The reason is HTML-escaped into the comment, so the property name arrives as &amp;auth.
$check('&auth without &url is refused',
    str_contains($out, '&amp;auth is only meaningful') && !str_contains($out, '<table'), $out);

$m   = $fresh();
$out = $run($m, ['url' => 'http://kuber.example.com/rows', 'auth' => 'kuber']);
$check('a Bearer is never sent in clear over http to a public host',
    !str_contains($out, '<table') && str_contains($out, 'https'), $out);
// The positive control for that rule: the same call over https gets PAST the transport guard and
// fails later, on the network. Distinguished by which comment comes back.
$m   = $fresh();
$out = $run($m, ['url' => 'https://kuber.example.invalid/rows', 'auth' => 'kuber', 'urlTimeout' => 2]);
$check('https to the same host is allowed through the transport guard',
    !str_contains($out, 'https://kuber.example.invalid/rows') || !str_contains($out, 'must be'), $out);

// The internal zone is the setting estate.internal_zone, not a suffix typed in the snippet: http to
// a name in the declared zone passes the transport guard; the same name with no zone declared does not.
$m   = $fresh(); $m->settings['estate.internal_zone'] = '.corp.internal';
$out = $run($m, ['url' => 'http://kuber.corp.internal/rows', 'auth' => 'kuber', 'urlTimeout' => 2]);
$check('http to a name in the declared internal zone passes the transport guard',
    !str_contains($out, 'will not present a bearer credential in clear text'), $out);
$m   = $fresh();
$out = $run($m, ['url' => 'http://kuber.corp.internal/rows', 'auth' => 'kuber']);
$check('with no estate.internal_zone the same name is refused, and the refusal names the setting',
    str_contains($out, 'clear text') && str_contains($out, 'estate.internal_zone is not set'), $out);

// --- 5. kuber's 403 is the owner's blank -----------------------------------------------------------
$m   = $fresh();
$out = $run($m, ['url' => "$BASE/deny", 'rows' => 'rows', 'auth' => 'kuber']);
$check('a 403 renders no table', !str_contains($out, '<table'), $out);
$check('...and names the 403 in the source for whoever looks', str_contains($out, '403'), $out);

// --- 6. regressions: everything that worked before still does ----------------------------------
$m   = $fresh();
$out = $run($m, ['url' => "$BASE/t6", 'rows' => 'rows']);
$check('&url WITHOUT &auth still sends no Authorization header at all',
    $requests('/t6') === [''], 'header was: ' . var_export($requests('/t6'), true));
$check('&url without &auth still renders', str_contains($out, '<table'), $out);

$m = $fresh();
$m->resource->content = '<script type="application/ld+json" id="c">[{"name":"Alice","email":"alice@example.org"}]</script>';
$out = $run($m, ['from' => 'c']);
$check('&from still renders from the page', str_contains($out, 'Alice') && str_contains($out, '<table'), $out);

$m = $fresh();
$m->parser->uncacheable = false;
$out = $run($m, ['url' => "$BASE/t7", 'rows' => 'rows', 'auth' => 'kuber']);
$check('a cached call is still refused, and asks kuber nothing',
    $requests('/t7') === [] && str_contains($out, 'uncached'), $out);

printf("\n%d passed, %d failed\n", $pass, $fail);
exit($fail === 0 ? 0 : 1);
