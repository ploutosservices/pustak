<?php
/**
 * The bookkeeping-names plugin forwards the reader's OWN id_token from the door, verified first, and a
 * failure ends the session (the owner's ruling, 2026-08-03: "google token, not your session, decides the logged in user";
 * "if the validation fails at that time, they lose access to modx and to other site").
 *
 *   php tests/kuber-google-token.php
 *
 * Verification is kuber's own GoogleToken, vendored — not a re-implementation that could share a
 * bug with the thing it is checking. No network: the JWKS is injected, exactly as kuber's own
 * checker does it. Every refusal is exercised by inducing the fault, and a KNOWN-GOOD control
 * runs first, so a suite that can only fail is as visible as one that can only pass.
 */
require_once dirname(__DIR__) . '/common/lib/GoogleToken.php';
use Kuber\Core\GoogleToken;

$fail = 0; $ran = 0;
function t(string $name, $got, $want): void {
    global $fail, $ran; $ran++; $ok = ($got === $want);
    if (!$ok) $fail++;
    printf("  %-4s %-56s got=%s\n", $ok ? 'ok' : 'FAIL', $name, var_export($got, true));
}
function b64u(string $r): string { return rtrim(strtr(base64_encode($r), '+/', '-_'), '='); }

$key = openssl_pkey_new(['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
$d   = openssl_pkey_get_details($key);
$jwks = fn() => ['keys' => [[
    'kty' => 'RSA', 'kid' => 'k1', 'use' => 'sig', 'alg' => 'RS256',
    'n' => b64u($d['rsa']['n']), 'e' => b64u($d['rsa']['e']),
]]];
function mint(array $c, $key, string $kid = 'k1'): string {
    $h = b64u((string) json_encode(['alg' => 'RS256', 'typ' => 'JWT', 'kid' => $kid]));
    $p = b64u((string) json_encode($c));
    openssl_sign("$h.$p", $sig, $key, OPENSSL_ALGO_SHA256);
    return "$h.$p." . b64u($sig);
}
$AUD = 'modx-platform';
// The door's issuer, passed as every MODx caller passes it: the verifier's Google defaults
// are never reached from MODx, so this suite never exercises them.
$ISS = ['https://door.example.test/realms/dev'];
$base = fn(array $o = []) => array_merge([
    'iss' => $ISS[0], 'aud' => $AUD, 'sub' => '1',
    'email' => 'reader@example.com', 'email_verified' => true,
    'iat' => time() - 10, 'exp' => time() + 600,
], $o);

echo "== the control: a good token verifies (if this fails, nothing below means anything) ==\n";
t('good token -> the reader address',
  GoogleToken::verify(mint($base(), $key), [$AUD], $w, $jwks, $ISS), 'reader@example.com');

echo "== what MUST be refused — each is a way the page could be shown to the wrong person ==\n";
t('another application\'s audience',
  GoogleToken::verify(mint($base(['aud' => 'someone-else']), $key), [$AUD], $w, $jwks, $ISS), null);
t('EMPTY allow-list refuses (a deploy that forgot the setting)',
  GoogleToken::verify(mint($base(), $key), [], $w, $jwks, $ISS), null);
t('expired token',
  GoogleToken::verify(mint($base(['exp' => time() - 3600, 'iat' => time() - 7200]), $key), [$AUD], $w, $jwks, $ISS), null);
t('email_verified false',
  GoogleToken::verify(mint($base(['email_verified' => false]), $key), [$AUD], $w, $jwks, $ISS), null);
t('not the door\'s issuer',
  GoogleToken::verify(mint($base(['iss' => 'https://evil.example']), $key), [$AUD], $w, $jwks, $ISS), null);
$other = openssl_pkey_new(['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
t('signed by a key the door does not publish',
  GoogleToken::verify(mint($base(), $other), [$AUD], $w, $jwks, $ISS), null);
t('payload swapped, signature kept',
  (function () use ($base, $key, $AUD, $jwks) {
      $jwt = mint($base(), $key); [$h, $p, $s] = explode('.', $jwt);
      $p2 = b64u((string) json_encode($base(['email' => 'someone.else@example.com'])));
      return GoogleToken::verify("$h.$p2.$s", [$AUD], $w, $jwks, $ISS);
  })(), null);
t('not a JWT at all', GoogleToken::verify('rubbish', [$AUD], $w, $jwks, $ISS), null);
t('empty token (nothing in session)', GoogleToken::verify('', [$AUD], $w, $jwks, $ISS), null);

echo "== the callback keeps the reader's token, for an integration that sends it on ==\n";
$cb = file_get_contents(dirname(__DIR__) . '/common/snippets/GoogleSSOCallback.php');
t('the callback keeps the raw token', str_contains($cb, "\$_SESSION['sso.id_token'] ="), true);

printf("\n  %d checks, %d failed\n", $ran, $fail);
exit($fail === 0 ? 0 : 1);
