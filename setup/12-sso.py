#!/usr/bin/env python3
"""
12 — sign-in wiring: every gated context through the estate's door (Chowkidar).

Creates the `sso.*` system settings and, per SSO-gated context, five public resources:
  - the login entry  (runs [[!GoogleSSOStart]])    -> branded sign-in screen -> the provider
  - the callback     (runs [[!GoogleSSOCallback]]) -> completes login, establishes the session
  - the logout entry (runs [[!GoogleSSOLogout]])   -> tears down the web session
  - the refusal page (runs [[!unauthorizedNotice]])-> says WHY a page was refused, to whom
  - the back-channel (runs [[!ssoBackchannelLogout]]) -> the door's sign-out call ends the session
and repoints login_page at the login entry, logout_page at the logout entry, and unauthorized_page
at the refusal page — the full SSO-only cutover (the Login package's form is retired). A blocked
anonymous visitor still reaches the branded sign-in; a blocked SIGNED-IN one now gets told that
their account is not a member, which is the sentence that ends the loop.

The snippets themselves live in common/snippets/ and are deployed by import.py (bench) /
apply-modx-elements.sh (prod). This script is the wiring (settings + resources + context
settings). Idempotent — safe to re-run.

SECRETS ARE NEVER HARD-CODED. Each context's client secret at the door comes from the environment
(MODX_SSO_OIDC_SECRET_<CTX>, below); unset MODX_SSO_OIDC leaves every context's sso.oidc_* untouched.
WHO MAY SIGN IN is not set here: it is the MODx user and its membership, and nothing else. The
  sso.allowed_emails / sso.allowed_domains list is retired; setup/02 deletes its rows.
Deploy knobs (env, with defaults):
  MODX_SSO_AUTO_PROVISION  — '1' to create a MODx user on first valid login, else unknown = denied (default 0)
  MODX_SSO_CONTEXTS        — comma-separated contexts to gate (default: family,corporate,worldview)
  MODX_SSO_CALLBACK_PATH   — url path of the callback (default: sso-callback)
  MODX_SSO_LOGIN_PATH      — url path of the login entry (default: sso-login)
  MODX_SSO_DENIED_PATH     — url path of the refusal page (default: sso-unauthorized)
  MODX_SSO_REPOINT         — '1' (default) to repoint login_page/unauthorized_page/logout_page

Run on the bench with the DB env (MODX_DB_*) as the other setup scripts. Clear cache afterwards.
"""
import os
import re
import pymysql

# One home for "which container is exempt from page protection" — setup/04 reads the same constant
# and refuses to protect a context that has no such container (it would lock the door from inside).
import settings_guard
from access_model import SUPPORT_ALIAS
from domains import db_config
from estate import PROTECTED_CONTEXTS

DB = db_config()

# The gated set is the PROTECTED set — one declaration, not two. It used to default to the literal
# 'family,corporate,worldview', which was this estate's context list living in the software repo
# (phase 1 of the estate split took the estate out of everything else) and, worse, a second list that could
# disagree with 04's: a context declared protected but absent from this literal gets its pages shut
# by 04 and its login_page left pointing at the retired form, which locks the door from the inside.
# That is exactly what happened to `claude`. The env var still overrides for a one-context run.
CONTEXTS      = [c.strip() for c in os.environ['MODX_SSO_CONTEXTS'].split(',') if c.strip()] \
                if os.environ.get('MODX_SSO_CONTEXTS') else list(PROTECTED_CONTEXTS)
CALLBACK_PATH = os.environ.get('MODX_SSO_CALLBACK_PATH', 'sso-callback').strip('/')
LOGIN_PATH    = os.environ.get('MODX_SSO_LOGIN_PATH', 'sso-login').strip('/')
LOGOUT_PATH   = os.environ.get('MODX_SSO_LOGOUT_PATH', 'sso-logout').strip('/')
# unauthorized_page USED TO BE login_page, and that is the loop. Signed out, sending a
# refused visitor to sign in is right. Signed IN and not a member of the context, it is a bounce
# between two pages that each expect the other to explain, and neither ever does: GoogleSSOStart
# returns a signed-in caller to site_start, site_start is userHome, userHome routes at a protected
# page, and the refusal starts again. A separate resource is what lets the refusal say something.
DENIED_PATH   = os.environ.get('MODX_SSO_DENIED_PATH', 'sso-unauthorized').strip('/')
REPOINT       = os.environ.get('MODX_SSO_REPOINT', '1') == '1'
# THE DOOR'S BACK-CHANNEL SIGN-OUT ADDRESS, and NOT a variable: it is declared in service.json
# identity.routes (the door is told it, and access_model reads it from there), so an override here
# could only make the page and its declaration disagree. Created in every gated context; one whose
# sso.provider is not oidc answers 400 from the snippet. design/back-channel-logout-skunkworks.md.
BACKCHANNEL_PATH = 'sso-backchannel-logout'

conn = pymysql.connect(**DB)
cur = conn.cursor()

# Photograph every settings row before this pass touches anything, and
# REFUSE THE COMMIT if a setting that had a value no longer does. Three times on
# 2026-08-12 a pass here emptied settings nobody asked it to touch (the MODX_SSO_OIDC
# set, the outward-facing settings, merged elements) and every one was found by somebody
# stumbling into it rather than by the pass saying anything. A loss rolls the whole pass
# back and exits 1, so the estate is as it was; a removal this pass MEANS to make is
# declared with g.allow(scope, context, key). Drilled in tests/settings-guard.py.
g = settings_guard.start(conn, '12-sso')


def set_setting(key, value, xtype='textfield'):
    """Upsert a system setting. value=None means 'leave existing untouched, create empty if absent'."""
    cur.execute("SELECT value FROM modx_system_settings WHERE `key`=%s", (key,))
    row = cur.fetchone()
    if row:
        if value is not None:
            cur.execute("UPDATE modx_system_settings SET value=%s WHERE `key`=%s", (value, key))
        return
    cur.execute("INSERT INTO modx_system_settings (`key`,value,xtype,namespace,area) "
                "VALUES (%s,%s,%s,'sso','sso')", (key, value if value is not None else '', xtype))


# --- settings ---------------------------------------------------------------------------------
set_setting('sso.auto_provision',       os.environ.get('MODX_SSO_AUTO_PROVISION', '0'), 'combo-boolean')
# THE GROUP AN AUTO-PROVISIONED USER LANDS IN, and it was a literal naming a group that does not
# exist. `04-access-control.py` RENAMES a legacy `Members` group to `allContextMember` (its
# OLD_NAMES map), so on any estate built by this repo the name written here matches nothing.
# GoogleSSOCallback only logs a WARN when the lookup misses, so the visible symptom is a user who
# signs in successfully and can read nothing — the failure with no error in it.
#
# value=None keeps the contract above: production, where this row already holds 'Members' and no
# env is set, is not touched by this change at all.
_PROVISION_GROUP = os.environ.get('MODX_SSO_PROVISION_USERGROUP')
if _PROVISION_GROUP:
    cur.execute("SELECT name FROM modx_membergroup_names WHERE name=%s", (_PROVISION_GROUP,))
    if not cur.fetchone():
        cur.execute("SELECT name FROM modx_membergroup_names ORDER BY name")
        known = ', '.join(r[0] for r in cur.fetchall()) or '(none)'
        raise SystemExit(
            f"12-sso: MODX_SSO_PROVISION_USERGROUP names '{_PROVISION_GROUP}', which is not a user\n"
            f"        group on this ground. Groups here: {known}.\n"
            f"        Refusing rather than writing it: a provisioned user would join no group, read\n"
            f"        nothing, and the only trace would be a WARN in the MODx log.")
set_setting('sso.provision_usergroup',  _PROVISION_GROUP)
set_setting('sso.callback_path',        CALLBACK_PATH)

# --- the bench's system trio (sso.auth_endpoint/token_endpoint/issuer) is RETIRED ---------------
# It pointed the Google path at a bench provider. There is no Google path now: every context signs
# in at the door through sso.oidc_* below. MODX_SSO_IDP is no longer read; rows a ground still holds
# are inert (SsoConfig never reads them).
print(f'Settings ensured (contexts={CONTEXTS}, callback=/{CALLBACK_PATH}, login=/{LOGIN_PATH}, repoint={REPOINT}).')


def support_id(ctx):
    """The context's top-level `support` container — the parent every auth page must sit under.

    Found by the SAME rule setup/04 uses, deliberately: 04 exempts `support` and its children from
    page protection and protects everything else. A sign-in page created outside that container is
    therefore protected by 04, and an anonymous request loops
    401 -> unauthorized_page (this very page) -> 401 … until PHP exhausts its memory limit and the
    server answers 500. Nobody can ever sign in.

    That is not hypothetical: this function exists because a from-nothing install did exactly that
    on 2026-07-28. Before it, the INSERT below hardcoded `parent=0`. The live estate was
    never affected — its auth pages were placed under `support` by the migration, not by this
    script, which is why this went unseen for as long as it did.
    """
    cur.execute("SELECT id FROM modx_site_content WHERE context_key=%s AND alias=%s "
                "AND parent=0 AND deleted=0", (ctx, SUPPORT_ALIAS))
    row = cur.fetchone()
    if not row:
        raise SystemExit(f'{ctx}: no top-level `{SUPPORT_ALIAS}` container — refusing to create the '
                         f'SSO pages, because setup/04 would then protect the sign-in page itself '
                         f'and no anonymous visitor could ever log in. Run 03-resources-skeleton.py '
                         f'first.')
    return row[0]


def ensure_resource(ctx, path, snippet, pagetitle):
    """Create-or-update a public, uncacheable, uri-pinned resource running `snippet` in `ctx`.
    Returns the resource id.

    NOTE on re-runs: an existing page is matched by uri and its `parent` is deliberately NOT
    rewritten. Pages already in the right place stay put, and a page someone has deliberately moved
    is not dragged back. Only newly created pages get the `support` parent.
    """
    content = f'[[!{snippet}]]'
    cur.execute("SELECT id FROM modx_site_content WHERE context_key=%s AND uri=%s", (ctx, path))
    row = cur.fetchone()
    if row:
        rid = row[0]
        cur.execute("UPDATE modx_site_content SET content=%s, cacheable=0, published=1, deleted=0, "
                    "uri_override=1, uri=%s, alias=%s, hidemenu=1, searchable=0 WHERE id=%s",
                    (content, path, path, rid))
        print(f'  {ctx}: updated {path} (id={rid})')
        return rid
    cur.execute(
        "INSERT INTO modx_site_content "
        "(type, pagetitle, longtitle, menutitle, description, alias, uri, uri_override, "
        " template, content_type, parent, context_key, published, hidemenu, menuindex, "
        " searchable, cacheable, richtext, createdby, createdon, publishedon, publishedby, content) "
        "VALUES ('document',%s,'','','',%s,%s,1, 0,1, %s,%s, 1,1,0, 0,0,0, 1,UNIX_TIMESTAMP(),UNIX_TIMESTAMP(),1, %s)",
        (pagetitle, path, path, support_id(ctx), ctx, content))
    rid = cur.lastrowid
    print(f'  {ctx}: created {path} (id={rid}) under `{SUPPORT_ALIAS}`')
    return rid


def set_ctx(ctx, key, value):
    cur.execute("SELECT 1 FROM modx_context_setting WHERE context_key=%s AND `key`=%s", (ctx, key))
    if cur.fetchone():
        cur.execute("UPDATE modx_context_setting SET value=%s WHERE context_key=%s AND `key`=%s", (value, ctx, key))
    else:
        cur.execute("INSERT INTO modx_context_setting (context_key,`key`,value,xtype) VALUES (%s,%s,%s,'textfield')",
                    (ctx, key, value))


# ── The door, PER CONTEXT ───────────────────────────────────────────────────────────────────────
# Every gated context signs in at the estate's door (Chowkidar 2030 step 4), each as its own
# client. WRITTEN AS CONTEXT SETTINGS, NEVER SYSTEM SETTINGS: one MODx serves four contexts, and
# `$modx->getOption()` resolves a context setting over the system value, so per-context is the
# mechanism.
#
# MODX_SSO_OIDC=<issuer base>  — the door realm. ITS ENDPOINTS ARE NOT WRITTEN HERE ANY MORE:
#                                sso.provider, sso.oidc_issuer, the four endpoints and the client id are
#                                infra's derivation (config scripts/modx-environment.py), carried in the
#                                installation's application.php and written by setup/apply-environment.php,
#                                which runs after this. Writing them here too made two writers of one row
#                                (this file wrote the door's discovery names, the environment its own).
#                                What only this file holds is each context's SECRET.
# MODX_SSO_OIDC_CONTEXTS       — comma-separated contexts to give a secret (default: every gated one).
# MODX_SSO_OIDC_SECRET_<CTX>   — that context's client secret. Required per context.
#   <CTX> is the context key upper-cased with every character outside A-Z0-9 as `_`:
#   family-alice -> FAMILY_ALICE. A context key may carry a hyphen since the estate keys,
#   and `MODX_SSO_OIDC_SECRET_FAMILY-ALICE` is a name no shell can export, so the first restore
#   after the rename refused on a secret nobody could have handed it (2026-09-22).
OIDC = os.environ.get('MODX_SSO_OIDC', '').strip().rstrip('/')
if OIDC:
    # EVERY GATED CONTEXT, unless told fewer.
    targets = [c.strip() for c in os.environ.get('MODX_SSO_OIDC_CONTEXTS', '').split(',') if c.strip()] \
              or list(CONTEXTS)
    if not targets:
        raise SystemExit(
            "12-sso: MODX_SSO_OIDC is set but this run gates no context."
        )
    unknown = [c for c in targets if c not in CONTEXTS]
    if unknown:
        raise SystemExit(f"12-sso: MODX_SSO_OIDC_CONTEXTS names contexts this run does not gate: {unknown}")
    for c in targets:
        ev = re.sub(r'[^A-Z0-9]', '_', c.upper())
        secret = os.environ.get(f'MODX_SSO_OIDC_SECRET_{ev}', '').strip()
        if not secret:
            raise SystemExit(
                f"12-sso: no MODX_SSO_OIDC_SECRET_{ev} for context '{c}'.\n"
                f"        Each context is its own client at the provider; there is no shared secret\n"
                f"        to fall back to, and inventing one would make every internal context the\n"
                f"        same client."
            )
        set_ctx(c, 'sso.oidc_client_secret', secret)
        print(f'  {c}: sso.oidc_client_secret written (the endpoints and client id are the environment\'s)')
else:
    print('  sso.oidc_* untouched (MODX_SSO_OIDC unset) — each context keeps the door client it has')

# --- per-context resources + wiring -----------------------------------------------------------
for ctx in CONTEXTS:
    cur.execute("SELECT 1 FROM modx_context WHERE `key`=%s", (ctx,))
    if not cur.fetchone():
        print(f'  {ctx}: context absent, skipped')
        continue
    ensure_resource(ctx, CALLBACK_PATH, 'GoogleSSOCallback', 'SSO callback')
    login_id  = ensure_resource(ctx, LOGIN_PATH,  'GoogleSSOStart',  'Sign in')
    logout_id = ensure_resource(ctx, LOGOUT_PATH, 'GoogleSSOLogout', 'Sign out')
    denied_id = ensure_resource(ctx, DENIED_PATH, 'unauthorizedNotice', 'Access refused')
    ensure_resource(ctx, BACKCHANNEL_PATH, 'ssoBackchannelLogout', 'Back-channel sign-out')
    if REPOINT:
        set_ctx(ctx, 'login_page', str(login_id))
        set_ctx(ctx, 'unauthorized_page', str(denied_id))
        set_ctx(ctx, 'logout_page', str(logout_id))
        print(f'  {ctx}: login_page -> {login_id}, unauthorized_page -> {denied_id}, '
              f'logout_page -> {logout_id}')

g.commit()
cur.close()
conn.close()
print('SSO wiring complete. Clear the MODx cache (php clear-cache.php) after this.')
