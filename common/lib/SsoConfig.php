<?php
/**
 * SsoConfig — this context's client at the estate's sign-in door (Chowkidar), and nothing else.
 *
 * ONE PROVIDER, THE DOOR, on every context and every name, production's public ones included
 * (Chowkidar 2030 step 4, #1380; claude-shared design/chowkidar-step4-skunkworks-apps.md). The rule
 * this class used to enforce — "internal names use the estate provider, public names use Google" —
 * is gone with Google: the door has a public name and verifies its own tokens with published keys.
 *
 * WHY A CLASS RATHER THAN TWO COPIES OF THE SAME `getOption` CALLS. GoogleSSOStart builds the
 * authorization redirect and GoogleSSOCallback exchanges the code, and the client id and the
 * redirect_uri MUST be identical in both or every sign-in fails with a mismatch and no useful message.
 *
 * PER CONTEXT: one MODx serves four contexts, each its own client at the door, so every setting is
 * read through `$modx->getOption()`, which resolves a context setting over the system value.
 *
 * Settings, all readable as context settings:
 *   sso.oidc_issuer            the door realm's issuer, exactly as it appears in `iss`
 *   sso.oidc_auth_endpoint     authorization endpoint
 *   sso.oidc_token_endpoint    token endpoint
 *   sso.oidc_userinfo_endpoint OPTIONAL; read only if the id_token carries no email
 *   sso.oidc_jwks_uri          OPTIONAL; the door's published signing keys. Absent, it is read
 *                              from the issuer's discovery document.
 *   sso.oidc_client_id         this context's client at the door
 *   sso.oidc_client_secret     its secret
 */
declare(strict_types=1);

class SsoConfig
{
    /** @var string always 'oidc': the door. Kept as a field because callers and the actuator read it. */
    public $provider = 'oidc';
    public $authEndpoint = '';
    public $tokenEndpoint = '';
    public $userinfoEndpoint = '';
    /** @var string the door's JWKS endpoint. */
    public $jwksUri = '';
    public $clientId = '';
    public $clientSecret = '';
    /** @var string[] every spelling of `iss` that is acceptable for this provider. */
    public $issuers = [];
    /**
     * @var string non-empty when this context CANNOT sign anyone in, and why — a short sentence for
     *             the log. The caller turns it into a coded refusal; this class never renders.
     */
    public $fault = '';

    /**
     * Resolve the provider for the CURRENT context — or for a named one, when handed its modContext
     * (`$modx->getContext($key)`): the manager runs in `mgr` and asks for the site's context it is
     * served on (adminDoor). Both answer getOption() the same way.
     *
     * @param modX|modContext $modx
     */
    public static function forContext($modx): self
    {
        $c = new self();
        $c->authEndpoint     = trim((string) $modx->getOption('sso.oidc_auth_endpoint'));
        $c->tokenEndpoint    = trim((string) $modx->getOption('sso.oidc_token_endpoint'));
        $c->userinfoEndpoint = trim((string) $modx->getOption('sso.oidc_userinfo_endpoint'));
        $c->jwksUri          = trim((string) $modx->getOption('sso.oidc_jwks_uri'));

        $c->clientId         = trim((string) $modx->getOption('sso.oidc_client_id'));
        $c->clientSecret     = trim((string) $modx->getOption('sso.oidc_client_secret'));
        $issuer              = trim((string) $modx->getOption('sso.oidc_issuer'));
        $c->issuers          = $issuer !== '' ? [$issuer] : [];
        // NOT REQUIRED AS A SETTING — DISCOVERED IF ABSENT.
        //
        // A later change made the signature check mandatory, and my first cut made the JWKS URL a sixth
        // setting somebody had to render. That is the wrong shape twice over: a conforming OIDC
        // client DISCOVERS a provider from its issuer rather than being hand-fed six URLs, and
        // making it a setting turned "verify the token" into a change request on another agent
        // — a gate on work that was otherwise finished.
        //
        // So: the setting wins when it is set (deterministic, no network, and how production
        // would be pinned), and the issuer's own discovery document answers when it is not. A
        // provider that publishes neither cannot be verified against, and THAT is the fault —
        // which is a true statement about the provider rather than about our configuration.
        if ($c->jwksUri === '' && $issuer !== '') {
            $c->jwksUri = self::discoverJwks($issuer);
        }


        // EVERY field, named individually. "SSO is not configured" is the sentence this whole
        // estate spent 2026-08-11 removing from another application; a missing setting
        // must say which one.
        $missing = [];
        foreach ([
            'sso.oidc_issuer'         => $issuer,
            'sso.oidc_auth_endpoint'  => $c->authEndpoint,
            'sso.oidc_token_endpoint' => $c->tokenEndpoint,
            'sso.oidc_client_id'      => $c->clientId,
            'sso.oidc_client_secret'  => $c->clientSecret,
        ] as $k => $v) {
            if ($v === '') { $missing[] = $k; }
        }
        if ($missing) {
            $c->fault = 'this context has no client at the sign-in door — these are empty: '
                      . implode(', ', $missing);
        }
        return $c;
    }

    /**
     * Read `jwks_uri` out of an issuer's discovery document.
     *
     * Cached in APCu when it is there, for an hour — the URL is a property of the provider and
     * does not move between requests, and a sign-in already makes two calls without adding a third
     * every time. Where APCu is absent the fetch simply happens; correctness does not depend on the
     * cache, which is the only safe way to depend on one.
     *
     * Returns '' on any failure. The caller turns that into a named fault; it must never turn into
     * "skip verification", which is why nothing here has a fallback that produces a usable path.
     */
    private static function discoverJwks(string $issuer): string
    {
        return self::discover($issuer, 'jwks_uri');
    }

    /**
     * The door's logout endpoint for this context, or '' where the door publishes none. Read
     * from the issuer's discovery document like the JWKS URL, and only when a sign-out asks.
     * claude/shared/design/modx-door-session.md.
     */
    public function endSessionEndpoint(): string
    {
        if (!$this->issuers) { return ''; }
        return self::discover($this->issuers[0], 'end_session_endpoint');
    }

    /**
     * The person's door token EXCHANGED at the door for one addressed to `$audience` (Keycloak
     * Standard Token Exchange V2, as measured against the door: audience AND scope audience-<callee>), with
     * this context's own client credentials. '' when the door refuses or cannot be reached — a call
     * on the person's behalf then does not happen; it never falls back to the person's own token.
     * claude/shared/design/chowkidar-step4-skunkworks-apps.md §1 (build B).
     */
    public function exchangeFor(string $accessToken, string $audience): string
    {
        if ($accessToken === '' || $this->tokenEndpoint === '' || $this->clientId === '') { return ''; }
        $ch = curl_init($this->tokenEndpoint);
        curl_setopt_array($ch, [
            CURLOPT_POST           => true,
            CURLOPT_POSTFIELDS     => http_build_query([
                'grant_type'         => 'urn:ietf:params:oauth:grant-type:token-exchange',
                'subject_token'      => $accessToken,
                'subject_token_type' => 'urn:ietf:params:oauth:token-type:access_token',
                'audience'           => $audience,
                // The sign-in's own scope rides along (GoogleSSOStart asks 'openid email profile'). An
                // exchange asking only 'audience-<callee>' REPLACES the scope of this client's door
                // session, and every refresh after it comes back without openid, so with no id_token
                // and ssoRenew ends the session. Measured on the dev door 2026-10-23: before an
                // exchange, refresh scope 'openid email profile' with an id_token; after one with scope
                // 'audience-kuber', 'email profile' and no id_token, also when the refresh asks openid.
                // With the sign-in's scope here, refresh is unchanged and aud is still the callee.
                'scope'              => 'openid email profile audience-' . $audience,
                'client_id'          => $this->clientId,
                'client_secret'      => $this->clientSecret,
            ]),
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => 8,
            CURLOPT_HTTPHEADER     => ['Accept: application/json'],
        ]);
        $body = curl_exec($ch);
        $http = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);
        $j = ($http === 200 && is_string($body)) ? json_decode($body, true) : null;
        return is_array($j) ? (string) ($j['access_token'] ?? '') : '';
    }

    /** One field of an issuer's discovery document, cached as discoverJwks describes. */
    private static function discover(string $issuer, string $field): string
    {
        $key = 'sso.' . $field . '.' . md5($issuer);
        if (function_exists('apcu_fetch')) {
            $hit = apcu_fetch($key, $ok);
            if ($ok && is_string($hit) && $hit !== '') { return $hit; }
        }
        $url = rtrim($issuer, '/') . '/.well-known/openid-configuration';
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => 6,
            CURLOPT_HTTPHEADER     => ['Accept: application/json'],
        ]);
        $body = curl_exec($ch);
        $http = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);
        if ($http !== 200 || !is_string($body)) { return ''; }
        $d = json_decode($body, true);
        $uri = is_array($d) ? trim((string) ($d[$field] ?? '')) : '';
        if ($uri !== '' && function_exists('apcu_store')) { apcu_store($key, $uri, 3600); }
        return $uri;
    }

    /**
     * The public callback URL for this context. ONE definition, because every conforming
     * provider compares the redirect_uri sent at authorisation with the one sent at
     * token exchange, and the two files that build it each carried their own copy with a comment
     * asking the next person to keep them identical.
     *
     * @param modX|modContext $modx
     */
    public static function redirectUri($modx): string
    {
        $path = trim((string) $modx->getOption('sso.callback_path') ?: 'sso-callback', '/');
        // FROM site_url, WHOLE — not the scheme from site_url and the authority from http_host.
        //
        // Those two are the same string on production and on staging, so this reads as a
        // refactor there and IS byte-identical (tests/sso-provider-per-context.php asserts both
        // fixtures unchanged). They are NOT the same on the local instance, and the reason is
        // structural rather than incidental: `http_host` is the context-RESOLUTION key and must
        // stay `<ctx>.modx.<internal zone>` — 12-sso.py:288-304 refuses to write oidc settings against a
        // public host, this class refuses at request time, and regenerate-seed.sh refuses to build
        // a seed from a ground whose http_host is not in that zone. Meanwhile the address a
        // BROWSER can reach is `localhost:<port>`, which is what site_url says.
        //
        // Building the callback from http_host therefore sent the browser to a name it cannot
        // resolve, and the sign-in could not complete. Measured 2026-08-20.
        //
        // site_url is already the authority every other link on the page is built from
        // (GoogleSSOStart, GoogleSSOCallback and GoogleSSOLogout all use it or makeUrl(...,'full')),
        // so this makes the callback agree with them rather than introducing a new rule.
        $site = rtrim((string) $modx->getOption('site_url'), '/');
        if ($site === '' || parse_url($site, PHP_URL_HOST) === null) {
            // A context with no usable site_url is a misconfiguration, not a case to guess through.
            // Fall back to the old construction so the URL is at least well-formed, and let the
            // provider's own redirect_uri check be the thing that refuses.
            $scheme = parse_url((string) $modx->getOption('site_url'), PHP_URL_SCHEME) ?: 'https';
            return $scheme . '://' . $modx->getOption('http_host') . '/' . $path;
        }
        return $site . '/' . $path;
    }
}
