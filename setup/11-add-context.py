#!/usr/bin/env python3
"""11 — Add a new MODx context end to end (reusable, idempotent).

Creates a context + its settings + a startup document + anonymous access, so a fresh context
resolves by host and serves a page. This is the codified "add a context" process (rehearsed on
the bench; infra runs the prod-side DNS/vhost + this script on the container).

ROUTING (2026-09-15): name->context is the EDGE's, not this script's. `config.context.php`
is one line requiring EdgeContext.php, which takes the context from the X-Tenant header nginx sets
from the name's tenant (config scripts/tenants.yaml). A fresh context serves once the
edge sends its key; until then its names answer the estate's 404. This script writes the DB rows
only: context + settings + startup doc + uri + anon access. (It used to patch a host map into
config.context.php under PATCH_CONFIG_CONTEXT=1; there is no map any more.)

The context to add and its host come from CTX_KEY / CTX_HOST; neither has a default. The host is the
caller's, from infra's derivation, and setup/apply-environment.php rewrites http_host and
site_url from the installation's application.php after this.

ACCESS MODEL — declared, not assumed. A context whose estate entry says `protected: true`
is built in the PROTECTED shape: `site_start` is its `userHome` (so an anonymous hit on the context
root is redirected to sign in, as the other protected contexts are), and `protected_page` +
`nav_root_id` name its landing page so 04 and the userHome snippet have a home to send a member to.
A context with no entry, or `protected: false`, keeps the OPEN-within-internal shape: anonymous gets
Load Only, no Protected resources, every page renders without a per-user login, and the network
(internal-only) is the boundary.

GATING ONE IS THREE SCRIPTS, NOT ONE, and getting that wrong has happened here before: declare it protected
in the estate file, then run **12** (the SSO doors — sso-login/callback/logout, and login_page +
unauthorized_page repointed at them) and **04** (the access model) and this script again. 04 alone
shuts the pages while `login_page` still names the retired form login, which locks the door from the
inside: the estate is SSO-only, so that page can authenticate nobody.

The old text here said "run the 04 access model for this context" and that is the sentence the
`claude` context was built on — it served 200 to the open internet for as long as it existed.
"""
import os
import sys, re, time, pymysql
from domains import db_config
import settings_guard
from estate import PROTECTED_CONTEXTS, CONTEXTS as CONTEXT_SPEC   # whether THIS context is gated is declared, not passed in

DB = db_config()

def _required(name, why):
    # RAISED, not returned: `x or SystemExit(...)` evaluates to the exception object, and a context
    # whose key was that message was once written to the database.
    v = (os.environ.get(name) or '').strip()
    if not v:
        raise SystemExit(f'11-add-context: {name} not set — {why}')
    return v


CTX_KEY  = _required('CTX_KEY', 'the context to add has no default')
# WHAT the context is comes from the estate, never from a default: a context the estate does not
# declare is refused, so a production run can only create a context somebody declared and reviewed.
# The environment may still override a name for a one-off bench run.
_SPEC = CONTEXT_SPEC.get(CTX_KEY) or sys.exit(
    f'REFUSING: context {CTX_KEY!r} is not declared in the estate (MODX_ESTATE). Declare it in '
    f'estate.json first. Nothing written.')
CTX_NAME = os.environ.get('CTX_NAME') or _SPEC.get('name') or CTX_KEY
CTX_DESC = os.environ.get('CTX_DESC') or _SPEC.get('description', '')
CTX_HOST = _required('CTX_HOST', 'the host has no default')          # infra's; apply-environment.php rewrites it
CTX_SITENAME = os.environ.get('CTX_SITENAME') or _SPEC.get('site_name') or CTX_NAME
TEMPLATE_NAME = os.environ.get('CTX_TEMPLATE', 'page.public')      # a template NAME (clean, no nav dep); ids differ per database
# No default: /srv/local/modx was the dev bench and it stopped existing when the bench
# became staging (2026-08-14). A guessed docroot addresses a MODx nobody runs.
MODX_ROOT = os.environ.get('MODX_ROOT') or sys.exit(
    'REFUSING: MODX_ROOT is not set — no docroot to add a context to. Nothing written.')         # docroot (for the config.context.php patch)
UG = 'MODX\\Revolution\\modUserGroup'
POL_LOAD = 3                                                        # Load Only — renders public pages for anonymous

# The startup document body (this context's landing page). The owner owns it after first pull via the
# seat; this is only the seed so the context serves something meaningful on day one.
STARTUP_HTML = os.environ.get('CTX_STARTUP_HTML') or (
    f"<h1>{CTX_NAME} — notes</h1>\n"
    "<p>Working notes surface. Pages live here so nothing has to be carried in your head.</p>\n"
    "<p>Add pages under this context; edit their content in VSCode through the seat and deploy.</p>")

conn = pymysql.connect(**DB); cur = conn.cursor()
from templates import template_id
TEMPLATE = template_id(cur, TEMPLATE_NAME)

# Photograph every settings row before this pass touches anything, and
# REFUSE THE COMMIT if a setting that had a value no longer does. Three times on
# 2026-08-12 a pass here emptied settings nobody asked it to touch (the MODX_SSO_OIDC
# set, the outward-facing settings, merged elements) and every one was found by somebody
# stumbling into it rather than by the pass saying anything. A loss rolls the whole pass
# back and exits 1, so the estate is as it was; a removal this pass MEANS to make is
# declared with g.allow(scope, context, key). Drilled in tests/settings-guard.py.
g = settings_guard.start(conn, '11-add-context')


def one(q, a=()):
    cur.execute(q, a); r = cur.fetchone(); return r[0] if r else None


# 1) context row (rank after the current max)
if not one("SELECT `key` FROM modx_context WHERE `key`=%s", (CTX_KEY,)):
    rank = (one("SELECT MAX(rank) FROM modx_context") or 0) + 1
    cur.execute("INSERT INTO modx_context (`key`,name,description,rank) VALUES (%s,%s,%s,%s)",
                (CTX_KEY, CTX_NAME, CTX_DESC, rank))
    print(f"  created context: {CTX_KEY} (rank {rank})")
else:
    print(f"  context exists: {CTX_KEY}")

# 2) startup (home) document in this context (idempotent by alias+context)
#
# Idempotent by alias was not enough. The alias is `<ctx>-home`, so re-running this against a
# context whose landing page was since RENAMED matches nothing and seeds a second, empty one —
# measured on `claude` (landing page `notes`), where the duplicate then became protected_page for
# the whole access model. A context that already holds a page of its own does not need a seed, so
# the guard is existence of content, not of one alias.
home_alias = f"{CTX_KEY}-home"
home_id = one("SELECT id FROM modx_site_content WHERE context_key=%s AND alias=%s", (CTX_KEY, home_alias))
existing_content = one("SELECT COUNT(*) FROM modx_site_content WHERE context_key=%s", (CTX_KEY,)) or 0
if not home_id and existing_content:
    home_id = one("SELECT id FROM modx_site_content WHERE context_key=%s AND parent=0 "
                  "AND alias<>'support' ORDER BY menuindex, id LIMIT 1", (CTX_KEY,))
    print(f"  context already has {existing_content} resources — no startup document seeded "
          f"(landing page resolves below, id={home_id})")
elif not home_id:
    cur.execute("""INSERT INTO modx_site_content
        (type,pagetitle,longtitle,alias,description,published,template,context_key,content,
         richtext,searchable,cacheable,createdon,menuindex,hidemenu)
        VALUES ('document',%s,%s,%s,'',1,%s,%s,%s,0,1,1,%s,0,0)""",
        (CTX_NAME, f"{CTX_NAME} — notes", home_alias, TEMPLATE, CTX_KEY,
         STARTUP_HTML, int(time.time())))
    home_id = cur.lastrowid
    print(f"  created startup document: {home_alias} (id={home_id})")
else:
    print(f"  startup document exists: {home_alias} (id={home_id})")

# a NULL uri is unroutable (404). Root resource under use_alias_path -> uri = alias.
cur.execute("UPDATE modx_site_content SET uri=%s WHERE id=%s AND (uri IS NULL OR uri='')",
            (home_alias, home_id))

# 2b) support folder — the same skeleton setup/03 builds for every other context.
#
# A context is built COMPLETE, independent of how it is expected to be used. This script originally
# created only the startup document, on the reasoning that an open-within-internal context never
# serves a login or an unauthorized page. That was wrong twice over: the access model is not fixed
# (running the 04 model against this context gates it, and then the missing pages matter), and
# error_page has traffic regardless — a 404 in a context without one forwards to whatever the
# site-wide default happens to be, which after our renumbering is an unpublished resource.
#
# Parity with 03 is deliberate: same aliases, same templates, same unpublished+hidden support parent.
TMPL_FULL, TMPL_PUBLIC, TMPL_BLANK = (template_id(cur, n) for n in ('page.full', 'page.public', 'page.folder'))
# The logout page runs the SSO session-teardown snippet UNCACHED. setup/12 installs this on the
# gated contexts (family/corporate/worldview); a context 12 does not touch (like claude) still needs
# a working logout because the shared navbar renders [[!loginWidget]] everywhere and a cross-context
# session shows its logout button here. Session teardown is context-agnostic and never signs the user
# out of Google, only this site — so it is always correct to have, gated or not. Uncacheable so the
# teardown fires per request (claude's logout button was dead — empty + cacheable page).
SUPPORT_PAGES = [
    # alias,          pagetitle,      template,     cacheable, content
    ('login',         'Login',        TMPL_PUBLIC,  1, ''),
    ('logout',        'Logout',       TMPL_PUBLIC,  0, '[[!GoogleSSOLogout]]'),
    ('search',        'Search',       TMPL_FULL,    1, ''),
    ('unauthorized',  'Unauthorized', TMPL_PUBLIC,  1, ''),
    ('error',         'Error',        TMPL_PUBLIC,  1, ''),
    ('unavailable',   'Unavailable',  TMPL_PUBLIC,  1, ''),
    ('badip',         'Bad IP',       TMPL_PUBLIC,  1, ''),
    ('robots',        'Robots',       TMPL_BLANK,   1, 'User-agent: *\nDisallow: /'),
    # userHome runs the routing snippet, exactly as setup/03 populates it for the other contexts.
    # It was empty here, and on a PROTECTED context that is the context's front door (site_start):
    # an anonymous visitor got a blank 200 instead of the redirect to sign in. Uncached because the
    # snippet routes per signed-in user.
    ('userHome',      'User Home',    TMPL_FULL,    0, '[[!userHome]]\n'),
    ('public',        'Public',       TMPL_PUBLIC,  1, ''),
]

def ensure_doc(alias, pagetitle, template, parent, published, menuindex, cacheable=1, content=''):
    """Create-or-return a document by (context, alias, parent). Idempotent: re-running against an
    existing context fills gaps rather than duplicating. On an EXISTING doc it reconciles the
    content + cacheable to the declared value, so a context built by an older 11 (empty logout,
    cacheable=1) is repaired on re-run rather than left stale."""
    rid = one("SELECT id FROM modx_site_content WHERE context_key=%s AND alias=%s AND parent=%s",
              (CTX_KEY, alias, parent))
    if rid:
        cur.execute("UPDATE modx_site_content SET content=%s, cacheable=%s WHERE id=%s "
                    "AND (content<>%s OR cacheable<>%s)", (content, cacheable, rid, content, cacheable))
        return rid
    cur.execute("""INSERT INTO modx_site_content
        (type,pagetitle,longtitle,menutitle,description,alias,template,context_key,parent,
         published,hidemenu,menuindex,searchable,cacheable,createdon,publishedon,content)
        VALUES ('document',%s,%s,%s,'',%s,%s,%s,%s,%s,1,%s,1,%s,%s,%s,%s)""",
        (pagetitle, pagetitle, pagetitle, alias, template, CTX_KEY, parent,
         published, menuindex, cacheable, int(time.time()), int(time.time()), content))
    new_id = cur.lastrowid
    # uri: flat (use_alias_path=0) — alias only, no parent path. A NULL uri is unroutable.
    cur.execute("UPDATE modx_site_content SET uri=%s WHERE id=%s", (alias, new_id))
    print(f"  created support page: {alias} (id={new_id})")
    return new_id

sup_id = ensure_doc('support', 'Support', TMPL_BLANK, 0, 0, 2000)
sup = {'support': sup_id}
for alias, title, tmpl, cache, body in SUPPORT_PAGES:
    sup[alias] = ensure_doc(alias, title, tmpl, sup_id, 1, 0, cache, body)
print(f"  support folder ready: {CTX_KEY} (support id={sup_id}, {len(SUPPORT_PAGES)} pages)")

# 3) context settings (mirror an existing context's required keys)
#
# site_start differs by access shape and it is the one setting that decides what an anonymous
# visitor to the context ROOT gets. Open: the landing page itself, which is the point of an open
# context. Protected: `userHome`, which is anonymous (it lives under `support`) and redirects a
# signed-out caller to the sign-in page — the 302 the other protected contexts answer with. Leaving
# a protected context's site_start on a protected page instead answers 401 at the front door, which
# still refuses to serve the content but tells a first-time visitor nothing about how to get in.
PROTECTED = CTX_KEY in PROTECTED_CONTEXTS

# THE LANDING PAGE, resolved rather than assumed. `home_id` above is the startup document this
# script creates on a fresh context — correct on day one and wrong on every re-run against a
# context whose landing page has since been renamed or replaced (measured: re-running this on
# `claude`, whose landing page is `notes`, created a second empty `claude-home` and pointed the
# whole access model at it). Order: an existing protected_page, then an existing site_start that
# still names a page of this context, then the startup document. Stable across re-runs, because
# once protected_page is set the first rule keeps returning it.
def _resolve_landing():
    for key in ('protected_page', 'site_start'):
        val = one("SELECT value FROM modx_context_setting WHERE context_key=%s AND `key`=%s",
                  (CTX_KEY, key))
        if val and str(val).isdigit():
            rid = int(val)
            owner = one("SELECT context_key FROM modx_site_content WHERE id=%s", (rid,))
            # site_start on a protected context is its userHome, which is not a landing page
            if owner == CTX_KEY and rid not in (sup_id, *sup.values()):
                return rid
    return home_id


LANDING_ID = _resolve_landing()
settings = {'http_host': CTX_HOST, 'site_url': f'http://{CTX_HOST}/', 'base_url': '/',
            'site_name': CTX_SITENAME,
            'site_start': str(sup['userHome'] if PROTECTED else home_id),
            # the support pages, same keys 03 sets for every other context
            'error_page':        str(sup['error']),
            'search_page':       str(sup['search']),
            'bad_ip':            str(sup['badip']),
            'public_page':       str(sup['public'])}
if PROTECTED:
    # 04 resolves the context's landing page as protected_page, falling back to nav_root_id, and
    # WARNS (does not fail) when neither resolves — a protected context with no home leaves every
    # member's homePages entry missing and the userHome snippet with nowhere to send them.
    settings['protected_page'] = str(LANDING_ID)
    settings['nav_root_id'] = str(LANDING_ID)
    # THE THREE DOOR KEYS ARE 12'S ON A PROTECTED CONTEXT, AND THIS SCRIPT MUST NOT WRITE THEM.
    # They used to be set here unconditionally to the Login package's form pages. 12 then repoints
    # them at the SSO entry — so running 11 after 12, which is exactly what converging an existing
    # context looks like, silently handed the front door back to a login form that authenticates
    # nobody (form login is uninstalled estate-wide). Measured on `claude`: the context root 302'd
    # to /login instead of /sso-login. One key, one owner.
    print(f"  login/logout/unauthorized left to setup/12 (protected context)")
else:
    settings['unauthorized_page'] = str(sup['unauthorized'])
    settings['login_page'] = str(sup['login'])
    settings['logout_page'] = str(sup['logout'])
# Folder URLs (<context>/<folder>/<page>) when the estate declares them for this context; MODx reads
# use_alias_path per context (modResource::getAliasPath asks the page's own context).
if 'use_alias_path' in (CONTEXT_SPEC.get(CTX_KEY) or {}):
    settings['use_alias_path'] = '1' if CONTEXT_SPEC[CTX_KEY]['use_alias_path'] is True else '0'
# The sign-in door's logo for this context (estateBrand serves it). On a protected context 04 also
# converges it; an open context has only this pass.
if (CONTEXT_SPEC.get(CTX_KEY) or {}).get('logo', '').startswith('https://'):
    settings['site_logo'] = CONTEXT_SPEC[CTX_KEY]['logo']
for k, v in settings.items():
    if one("SELECT 1 FROM modx_context_setting WHERE context_key=%s AND `key`=%s", (CTX_KEY, k)):
        cur.execute("UPDATE modx_context_setting SET value=%s WHERE context_key=%s AND `key`=%s", (v, CTX_KEY, k))
    else:
        cur.execute("INSERT INTO modx_context_setting (context_key,`key`,value,xtype) VALUES (%s,%s,%s,'textfield')",
                    (CTX_KEY, k, v))
print(f"  settings applied: {CTX_KEY} -> {CTX_HOST}")

# 4) anonymous access (Load Only) so pages render without login
if not one("SELECT id FROM modx_access_context WHERE target=%s AND principal=0", (CTX_KEY,)):
    cur.execute("INSERT INTO modx_access_context (target,principal_class,principal,authority,policy) "
                "VALUES (%s,%s,0,9999,%s)", (CTX_KEY, UG, POL_LOAD))
    print(f"  anonymous Load access granted on {CTX_KEY}")
else:
    print(f"  anonymous access exists on {CTX_KEY}")

g.commit(); cur.close(); conn.close()

# 5) routing is the edge's: nothing to write in the docroot.
print(f"  routing: the edge must send X-Tenant: {CTX_KEY} for this context's names (nginx, from config scripts/tenants.yaml).")

print("add-context complete. Clear the MODx cache next.")
