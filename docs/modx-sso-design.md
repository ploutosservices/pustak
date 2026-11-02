# MODx Google SSO — design & build

Replaces MODx form login with Google (OpenID Connect) sign-in across the intranet contexts.
This is the modx-login leg of the identity seam: one Google login, each tower serves
your data. Login **identifies**; per-resource access stays enforced by MODx RBAC on every
request ("wall, not curtain") — a valid Google login is never itself a grant.

Baseline form-login/RBAC model: `docs/modx-login-design.md`. This doc is the SSO layer on top.

## Topology (why it's multi-domain)

Each context is a separate public domain; the edge names the context (nginx sets `X-Tenant` from
the name's `upstream_key` and `EdgeContext.php` reads HTTP_X_TENANT; internal IP, https
terminated at infra's edge — setup/10):

| context      | production domain            |
|--------------|------------------------------|
| family       | home.example.org             |
| corporate    | corp.example.com             |
| worldview    | intranet.example.net         |
| platform     | claude.example.com           |

The one home for this binding is infra's: `shared/cmdb/placement.yaml` (`site: true` names on `modx.detail.<env>`), derived by `config/scripts/modx-environment.py`.

Separate domains ⇒ separate session cookies ⇒ **one OAuth redirect URI per gated domain**, and
login establishes a session in the context the user is on (same as the current form login; SSO
does not change the cross-context session behaviour, it reuses `addSessionContext`).

## Flow (authorization-code / server-side)

1. Anonymous hits a protected page → RBAC → `unauthorized_page` → the **sso-login** resource
   (`[[!GoogleSSOStart]]`), which stores a session `state` (CSRF) + `nonce`, and 302s the browser
   to Google's consent screen with `redirect_uri = https://<domain>/sso-callback`.
2. Google returns the browser to **sso-callback** (`[[!GoogleSSOCallback]]`) with `code` + `state`.
3. Callback verifies `state`, exchanges `code` for tokens at Google's token endpoint **over TLS,
   authenticated with the client secret** — so the `id_token` arrives directly from Google over an
   authenticated channel (per Google's guidance signature re-verification is then not required; we
   still validate `aud`/`iss`/`exp`/`nonce` as defense in depth).
4. Require `email_verified`, then apply the **optional** allow-list clamp (off by default; see below).
5. **The gate:** map the verified email → MODx user (via `modUserProfile.email`). Unknown user →
   denied (`sso.auto_provision=0`). So access = "a valid active MODx user whose profile email is
   your Google login" — plain MODx access control, managed in the manager, no separate list.
6. `addSessionContext($ctx)` + fire `OnWebLogin` → redirect to the stored same-site `returnUrl`
   (deep-link return-to-original), else the `userHome` router.

Requires server egress to `accounts.google.com` / `oauth2.googleapis.com` (the token exchange).

## Elements (in this repo)

- `common/snippets/GoogleSSOStart.php`    — builds the authorize URL, sets state/nonce, redirects.
- `common/snippets/GoogleSSOCallback.php` — the steps 3–6 above (the security-critical piece).
- `setup/12-sso.py` — idempotent wiring: creates `sso.*` settings, the `sso-login`, `sso-callback`,
  `sso-logout` and `sso-unauthorized` resources per gated context (public, uncacheable,
  `uri_override` pins the path), and repoints
  each context's `login_page`/`unauthorized_page` at its sso-login. Secrets come from env, never
  hard-coded; a re-run never blanks a configured secret.

Deploy path is the normal one: snippets via `apply-modx-elements.sh`; `setup/12-sso.py`
run on the ground with the real env.

*"Skunkworks never writes prod"* stood here until 2026-09-12 and is no longer the rule — see
**`workflow.md` → Who may do what**, which owns this fact. `setup/12-sso.py` remains infra's: it is
a script run on the box rather than a committed ref a deploy carries, which is the reason it is on
that document's *Nobody may* list and not a permission granted to somebody else.

## Config (system settings, namespace `sso`)

| setting                   | source / value |
|---------------------------|----------------|
| `sso.google_client_id`    | shared `project_sso` web-client id (Vaultwarden) — env `MODX_SSO_CLIENT_ID` |
| `sso.google_client_secret`| shared `project_sso` secret — env `MODX_SSO_CLIENT_SECRET` |
| `sso.auto_provision`      | `0` = unknown email denied (default); `1` = create user on first valid login |
| `sso.provision_usergroup` | user-group new users join (default `Members`) |
| `sso.callback_path`       | url path of the callback (default `sso-callback`) — single-sources the redirect_uri |

## Go-live gates (this cannot round-trip on the bench — the bench domains aren't Google-registered)

- **The owner (human gate):**
  1. Access is plain MODx: create the person's MODx user (profile email = their Google login) and
     put them in the right resource group — in the manager, never infra, never a separate list.
     `sso.auto_provision` stays **0**: SSO NEVER creates a MODx user; an unknown email is denied.
  2. Redirect URIs — DONE (2026-07-16): the three below are registered on the shared `project_sso`
     client (one per gated domain, byte-exact):
     `https://home.example.org/sso-callback`,
     `https://corp.example.com/sso-callback`,
     `https://intranet.example.net/sso-callback`.
- **infra:** confirm the prod MODx server has egress to Google's token/JWKS endpoints; ensure each
  gated domain's https edge proxies `/sso-callback` + `/sso-login` to MODx; deploy the two snippets
  + run `setup/12-sso.py` with the real env; set the two secrets from Vaultwarden via the Ansible
  env path (not by hand).
- **decision:** existing users are matched by profile email — confirm the intranet users' emails
  are their Google (Workspace) emails, or turn on `auto_provision` for first-login self-creation.

## Verified on the bench (faltu-1), 2026-07-16

- MODx 3.2.2 API grounded against core: `modUser::addSessionContext` is the login primitive
  (same call the form Login processor uses) + `OnWebLogin`; `getObject('modUserProfile'/'modUser'
  /'modUserGroup'/'modUserGroupMember')` aliases resolve; email→profile→user lookup works.
- Both snippets `php -l` clean and execute with no PHP errors.
- **GoogleSSOStart, live:** `/sso-login` on the family context's bench host (internal zone) 302s to the correct Google
  authorize URL — right client_id, `redirect_uri=https://<that host>/sso-callback`,
  `response_type=code`, `scope=openid email profile`, random session-bound state+nonce, `hd` hint.
- **GoogleSSOCallback, live:** missing/forged `state` → clean HTTP 403 + logged reason, no crash.
- **Not bench-testable (go-live only):** the real Google code exchange, real-account domain lock,
  provisioning, and session establishment via a browser round-trip — needs a registered redirect
  URI on a Google-reachable https edge (the gates above).
