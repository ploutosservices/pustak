<?php
/**
 * GENERATED — a pinned copy of the bookkeeping application's GoogleToken.php (the version recorded
 * in service.json's component row), accepted by its owner for publication. Do not edit.
 *
 * VENDORED, not re-implemented: MODx validates the reader's Google id_token before passing it on,
 * and the verifier that is already proven against Google's live keys is the owner's. A second
 * implementation of one fact would be a fork; this is a pinned copy with an owner, so defects go
 * to the owner. verify() takes an optional $issuers list, so the installation's own OIDC provider
 * is verified by this verifier too; Google callers are unchanged.
 *
 * Refresh: copy the file, bump the version in the component row. Never edit here.
 */
declare(strict_types=1);

namespace Kuber\Core;

/**
 * Verify a Google-minted OpenID id_token INDEPENDENTLY, and return the email in it.
 *
 * Why this exists: a calling application (a CMS page, say) hands over the reader's Google
 * token, and gets back the name of the object it asked about.
 *
 * The alternative — and what `reader.php` accepted first — is that the calling app signs
 * its own assertion saying who the reader is, and kuber trusts that app's word. This is
 * the move away from that: verify, do not trust, and it is the caller's job to bring a good
 * token. The caller forwards the reader's own token; kuber checks it against Google and
 * takes the address FROM THE TOKEN.
 *
 * What that buys, concretely: no keypair to place in kuber's environment, nothing to
 * rotate, and no second app whose compromise mints a valid kuber identity.
 *
 * WHAT IS CHECKED, and nothing here is optional:
 *   - RS256 signature against the key Google's JWKS publishes under the token's `kid`
 *   - `iss` is Google's (either spelling Google uses)
 *   - `aud` is one of OUR allow-listed client ids  -- an id_token is minted FOR a client,
 *     so without this any Google token from any application on the internet would pass
 *   - `exp` in the future, `iat` not implausibly ahead (small skew allowed)
 *   - `email` present and `email_verified` true
 *
 * The header's `alg` is deliberately never dispatched on: verification is always
 * RSA-SHA256, which is what makes algorithm confusion structurally impossible. Same rule
 * as Crypto::jwtVerify() -- do not "fix" it by reading alg out of the header.
 *
 * FAILING CLOSED IS THE DEFAULT. An empty audience allow-list refuses every token rather
 * than accepting any, and an unreachable JWKS with no usable cache refuses rather than
 * skipping the signature. Every refusal names its reason for the log and says nothing to
 * the caller.
 */
class GoogleToken {

    /** Both spellings appear in Google's own id_tokens; both are Google. */
    private const ISSUERS  = ['accounts.google.com', 'https://accounts.google.com'];
    private const JWKS_URL = 'https://www.googleapis.com/oauth2/v3/certs';

    /** Clock skew tolerated on exp/iat, seconds. */
    private const SKEW = 60;

    /** Cache floor/ceiling for the JWKS, seconds. Google's own max-age is ~6h. */
    private const CACHE_MIN = 300;
    private const CACHE_MAX = 86400;

    /**
     * Verify $jwt and return the verified email address, or null.
     *
     * @param string        $jwt          the raw id_token
     * @param array         $allowedAud   client ids kuber accepts; EMPTY refuses everything
     * @param string|null   $why          set to the specific reason on refusal (for the log)
     * @param callable|null $jwksSource   returns the JWKS as an array; defaults to Google.
     *                                    Injected by check-google-token.php so the claim and
     *                                    signature rules are provable with no network.
     * @param array|null    $issuers      issuer values accepted; defaults to Google's two.
     *                                    A caller verifying the estate's own OIDC provider
     *                                    passes its issuer (with its JWKS in $jwksSource) —
     *                                    one verifier for every provider (a vendored copy
     *                                    re-pins from this file, never forks).
     */
    public static function verify(string $jwt, array $allowedAud, ?string &$why = null,
                                  ?callable $jwksSource = null, ?array $issuers = null): ?string {
        $why = null;

        // An unset allow-list is a misconfiguration, not a licence. Refuse first, so a
        // deploy that forgets the setting cannot silently accept the whole internet.
        if (!$allowedAud) { $why = 'no audience allow-list configured'; return null; }

        $parts = explode('.', $jwt);
        if (count($parts) !== 3) { $why = 'not a three-part JWT'; return null; }
        [$h64, $p64, $s64] = $parts;

        $header = json_decode(self::b64urlDecode($h64) ?: '', true);
        if (!is_array($header)) { $why = 'unreadable header'; return null; }
        $kid = $header['kid'] ?? null;
        if (!is_string($kid) || $kid === '') { $why = 'header names no kid'; return null; }

        // The signature is checked BEFORE any claim is believed. The kid selects which
        // published key to try and nothing more -- an attacker choosing it can only
        // choose which key fails.
        $jwks = $jwksSource ? $jwksSource() : self::googleJwks($why);
        if ($jwks === null) return null;              // $why already set
        $pem = self::pemForKid($jwks, $kid);
        if ($pem === null) { $why = "no published key for kid '$kid'"; return null; }

        $sig = self::b64urlDecode($s64);
        if ($sig === false || $sig === '') { $why = 'empty or unreadable signature'; return null; }
        if (openssl_verify("$h64.$p64", $sig, $pem, OPENSSL_ALGO_SHA256) !== 1) {
            $why = 'signature does not verify'; return null;
        }

        $c = json_decode(self::b64urlDecode($p64) ?: '', true);
        if (!is_array($c)) { $why = 'unreadable payload'; return null; }

        $acceptedIssuers = $issuers ?? self::ISSUERS;
        if (!in_array($c['iss'] ?? '', $acceptedIssuers, true)) {
            $why = "issuer not accepted: " . var_export($c['iss'] ?? null, true); return null;
        }

        // RFC 7519 allows aud to be a string or an array of strings; Google sends a string.
        $aud = $c['aud'] ?? null;
        $auds = is_string($aud) ? [$aud] : (is_array($aud) ? $aud : []);
        if (!array_intersect($auds, $allowedAud)) {
            $why = 'audience is not allow-listed'; return null;
        }

        $now = time();
        if (!isset($c['exp']) || !is_int($c['exp']) || $c['exp'] + self::SKEW < $now) {
            $why = 'expired or no exp'; return null;
        }
        // A token stamped in the future is either a broken clock or a forgery attempt with
        // a key we should not have accepted; either way it is not something to serve on.
        if (isset($c['iat']) && is_int($c['iat']) && $c['iat'] - self::SKEW > $now) {
            $why = 'issued in the future'; return null;
        }

        $email = $c['email'] ?? null;
        if (!is_string($email) || $email === '') { $why = 'token carries no email'; return null; }
        // Google sends this as a bool, but has historically sent the string "true" through
        // some paths. Accept both spellings of true and NOTHING else.
        $verified = $c['email_verified'] ?? null;
        if ($verified !== true && $verified !== 'true') {
            $why = "email '$email' is not verified by Google"; return null;
        }

        return $email;
    }

    /**
     * Google's published signing keys, cached on disk.
     *
     * The cache is not an optimisation -- it is what stops a page render depending on a
     * network round trip to Google, and what keeps kuber answering through a brief
     * outage. A stale cache is preferred to no answer ONLY for signature keys, which
     * rotate on the order of days: serving on a key Google published yesterday is sound,
     * because a token signed with it was still signed by Google.
     */
    private static function googleJwks(?string &$why): ?array {
        return self::cachedJwks(self::JWKS_URL, sys_get_temp_dir() . '/kuber-google-jwks.json', 'Google', $why);
    }

    /**
     * An OIDC issuer's published keys, found the way a conforming client finds them: the
     * issuer's own discovery document names `jwks_uri`. Cached on disk per issuer
     * exactly as Google's are, so a page render does not depend on the round trip.
     *
     * For reader.php's declared non-Google issuers — the estate sign-in door. Whether an issuer
     * may be trusted at all is the CALLER's decision; this only fetches what it publishes.
     */
    public static function issuerJwks(string $issuer, ?string &$why = null): ?array {
        $issuer = rtrim($issuer, '/');
        $cache  = sys_get_temp_dir() . '/kuber-oidc-jwks-' . substr(hash('sha256', $issuer), 0, 16) . '.json';
        if (is_readable($cache)) {
            $c = json_decode((string) file_get_contents($cache), true);
            if (is_array($c) && isset($c['keys'], $c['expires']) && $c['expires'] > time()) return $c;
        }
        $ctx  = stream_context_create(['http' => ['timeout' => 5, 'ignore_errors' => true]]);
        $doc  = json_decode((string) @file_get_contents("$issuer/.well-known/openid-configuration", false, $ctx), true);
        $uri  = is_array($doc) ? ($doc['jwks_uri'] ?? null) : null;
        if (!is_string($uri) || $uri === '') {
            // A stale cache still serves, as for Google: keys rotate on the order of days.
            if (is_readable($cache) && ($c = json_decode((string) file_get_contents($cache), true)) && isset($c['keys'])) return $c;
            $why = "$issuer publishes no jwks_uri and no cache"; return null;
        }
        return self::cachedJwks($uri, $cache, $issuer, $why);
    }

    private static function cachedJwks(string $url, string $cache, string $who, ?string &$why): ?array {
        $now   = time();

        $stale = null;
        if (is_readable($cache)) {
            $c = json_decode((string) file_get_contents($cache), true);
            if (is_array($c) && isset($c['keys'], $c['expires'])) {
                if ($c['expires'] > $now) return $c;      // fresh
                $stale = $c;                              // usable if the fetch fails
            }
        }

        $ctx = stream_context_create(['http' => ['timeout' => 5, 'ignore_errors' => true],
                                      'https' => ['timeout' => 5]]);
        $body = @file_get_contents($url, false, $ctx);
        if ($body === false) {
            if ($stale) return $stale;
            $why = "$who JWKS unreachable and no cache"; return null;
        }
        $jwks = json_decode($body, true);
        if (!is_array($jwks) || !isset($jwks['keys']) || !is_array($jwks['keys'])) {
            if ($stale) return $stale;
            $why = "$who JWKS unreadable and no cache"; return null;
        }

        // Honour Google's own max-age rather than inventing a TTL, clamped both ways.
        $ttl = self::CACHE_MIN;
        foreach ($http_response_header ?? [] as $line) {
            if (preg_match('/^cache-control:.*max-age=(\d+)/i', $line, $m)) {
                $ttl = max(self::CACHE_MIN, min(self::CACHE_MAX, (int) $m[1]));
            }
        }
        $jwks['expires'] = $now + $ttl;
        // Write via a temp file + rename so a concurrent reader never sees a half file.
        $tmp = $cache . '.' . getmypid();
        if (@file_put_contents($tmp, json_encode($jwks)) !== false) @rename($tmp, $cache);
        return $jwks;
    }

    /** The PEM for one published key, or null when the kid is not among them. */
    private static function pemForKid(array $jwks, string $kid): ?string {
        foreach ($jwks['keys'] ?? [] as $k) {
            if (($k['kid'] ?? null) !== $kid) continue;
            // Only RSA signing keys are usable here; anything else is refused rather
            // than guessed at.
            if (($k['kty'] ?? null) !== 'RSA') return null;
            $n = self::b64urlDecode((string) ($k['n'] ?? ''));
            $e = self::b64urlDecode((string) ($k['e'] ?? ''));
            if ($n === false || $e === false || $n === '' || $e === '') return null;
            return self::rsaPem($n, $e);
        }
        return null;
    }

    /**
     * Build a PEM public key from a JWK's raw modulus and exponent.
     *
     * PHP has no JWK reader, so the SubjectPublicKeyInfo DER is assembled by hand:
     *
     *   SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { SEQUENCE { n, e } } }
     *
     * check-google-token.php proves this exactly: it takes a real keypair, expresses it
     * as a JWK, converts it back with this function, and compares to the PEM openssl
     * itself exports. Byte-identical or the check fails -- there is no room for a
     * conversion that merely looks right.
     */
    private static function rsaPem(string $n, string $e): string {
        $rsa = self::der(0x30, self::derInt($n) . self::derInt($e));
        $alg = self::der(0x30, self::der(0x06, "\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01") . self::der(0x05, ''));
        $spki = self::der(0x30, $alg . self::der(0x03, "\x00" . $rsa));
        return "-----BEGIN PUBLIC KEY-----\n"
             . chunk_split(base64_encode($spki), 64, "\n")
             . "-----END PUBLIC KEY-----\n";
    }

    /** One DER TLV. */
    private static function der(int $tag, string $body): string {
        $len = strlen($body);
        if ($len < 0x80) $lenBytes = chr($len);
        else { $b = ltrim(pack('N', $len), "\x00"); $lenBytes = chr(0x80 | strlen($b)) . $b; }
        return chr($tag) . $lenBytes . $body;
    }

    /** A DER INTEGER: unsigned, so a leading high bit needs a 0x00 or it reads negative. */
    private static function derInt(string $bytes): string {
        $bytes = ltrim($bytes, "\x00");
        if ($bytes === '') $bytes = "\x00";
        if (ord($bytes[0]) & 0x80) $bytes = "\x00" . $bytes;
        return self::der(0x02, $bytes);
    }

    private static function b64urlDecode(string $d): string|false {
        return base64_decode(strtr($d, '-_', '+/') . str_repeat('=', (4 - strlen($d) % 4) % 4));
    }
}
