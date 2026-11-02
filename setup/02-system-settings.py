#!/usr/bin/env python3
import os
import re
import pymysql
from domains import db_config
from estate import SYSTEM_SETTINGS

DB = db_config()
conn = pymysql.connect(**DB)
cur = conn.cursor()

# ── The estate title bar's two configured values ──────────────────────────────────────
# MODx elements are the SAME BYTES on every ground — apply-modx-elements.sh deploys one file to
# bench, staging and production alike — so nothing per-ground can be baked into a chunk. The render
# point that does exist is a system setting read as [[++key]], which is the shape dev's spec names
# for this application (claude/shared/design/estate-title-bar.md).
#
# estate_cdn_url  WHERE THE ESTATE CDN IS. Infra's fact, not Library's: the day it moves, this one
#                 value moves. Taken from the environment when the caller supplies it, so a ground
#                 can be told rather than assume. Without it the ground KEEPS the value it already
#                 holds (the software carries no estate's address); a fresh install with neither
#                 gets none, and the line printed below says which of the three it was.
# estate_env      WHICH GROUND THIS IS. It decides the bar's colour and its word, so a wrong value
#                 is a person acting on the wrong ground. The default is 'development' ON PURPOSE:
#                 an unset value then shows amber and the word DEVELOPMENT — visibly wrong — rather
#                 than inheriting production's indigo and production's silence, which is the failure
#                 that cannot be seen.
cur.execute("SELECT value FROM modx_system_settings WHERE `key`='estate_cdn_url'")
_held = ((cur.fetchone() or [''])[0] or '').strip()
ESTATE_CDN_SOURCE = 'environment' if os.environ.get('ESTATE_CDN_URL') else ('kept' if _held else 'none')
ESTATE_CDN_URL = os.environ.get('ESTATE_CDN_URL') or _held
# estate_env_color  THE COLOUR OF THE ENVIRONMENT THIS GROUND IS IN. Infra renders
#                 ESTATE_ENV_COLOR from one row per ENVIRONMENT (config 995846df); topNavBar puts
#                 it on the bar as the custom property --estate-env-color, which every colour rule
#                 in the shared stylesheet reads BEFORE any environment name. So a new environment
#                 costs infra one row and costs this repo nothing, which is the whole rule.
#                 EMPTY IS NOT A COLOUR: infra renders the empty string for an environment with no
#                 row, and an empty setting makes the chunk write no property at all, so the bar
#                 falls through to --estate-env-undeclared — the red that says nobody declared this
#                 ground. Writing `--estate-env-color: ` instead would be a declaration of nothing
#                 that still beats the fallback, which is the failure this exists to prevent.
ESTATE_ENV_COLOR = (os.environ.get('ESTATE_ENV_COLOR') or '').strip()
if ESTATE_ENV_COLOR and not re.fullmatch(r'#[0-9A-Fa-f]{3,8}|[a-z]{3,20}|(rgb|hsl)a?\([0-9,.%\s/]+\)', ESTATE_ENV_COLOR):
    raise SystemExit(f"ESTATE_ENV_COLOR={ESTATE_ENV_COLOR!r} is not a CSS colour this will put in "
                     "a style attribute: a hex, a plain colour word, or rgb()/hsl().")
# AN ENVIRONMENT NAME IS AN OPAQUE STRING. The owner, 2026-09-20: "the only environment name i
# cannot change is production. that is the only name that can be hardcoded. all others are free form
# string. i should be allowed to have a million different env names, called env1 env2 to
# env1000000." This refused anything but three names until that day, so a ground called env1 could
# not be stood up. The name is not interpreted here at all; the one check left is that it can be
# printed — it lands in an HTML attribute and as the bar's word — and that is about the characters,
# never about which names exist.
ESTATE_ENV = (os.environ.get('MODX_ESTATE_ENV') or '').strip()
if ESTATE_ENV and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', ESTATE_ENV):
    raise SystemExit(f"MODX_ESTATE_ENV={ESTATE_ENV!r} cannot be printed in the title bar: letters, "
                     "digits, dot, underscore and hyphen only. Any NAME is accepted.")
# estate_weather_url  THE ESTATE'S OWN WEATHER PAGE, on the CDN beside the bar's script (2026-09-24).
#                 The owner: "Build the weather page on cdn.example.org and point MODx's weather icon at
#                 it." It was Data's /weather on each ground, which needed infra to place a
#                 different address per ground and still left the bench and staging with a
#                 page only the mesh could reach. The page runs entirely in the reader's browser, so
#                 one public address serves every ground; it is derived from the CDN address rather
#                 than placed, and there is nothing left for a ground to be told.
ESTATE_WEATHER_URL = f"{ESTATE_CDN_URL.rstrip('/')}/estate/weather/" if ESTATE_CDN_URL else ''
# error_log_filepath  WHERE MODX WRITES ITS ERROR LOG. MODx's default is
#                 core/cache/logs/, and every cache clear — each deploy, the role's handler, a manager
#                 clear — runs rm -rf core/cache/*, so the log only ever held what happened since the
#                 last clear and night-desk's read of production answered with no lines at all.
#                 modX::_initContext reads this setting at context init as an ABSOLUTE directory
#                 (core/src/Revolution/modX.php:2655), so the value is derived from the ground's own
#                 MODX_ROOT, which every settings verb already hands this file (infra,
#                 2026-10-05). No MODX_ROOT, no guess: the row is left as the ground holds it.
# estate_app_name  THE NAME A PERSON SEES for this application, in the title bar, on the sign-in
#                 card and on the not-authorised page. Typed once, in this repository's manifest
#                 (service.json identity.display_name), and read from there; the three places render
#                 the setting, so a rename is one edit to the manifest and a settings converge. The
#                 owner, 2026-10-07: "is there way to eliminate duplication". No name, no guess.
import json  # noqa: E402
_MANIFEST = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'service.json')
ESTATE_APP_NAME = str((json.load(open(_MANIFEST)).get('identity') or {}).get('display_name') or '').strip()
if not ESTATE_APP_NAME or not re.fullmatch(r"[^<>&\"'`]{1,40}", ESTATE_APP_NAME):
    raise SystemExit(f"REFUSING: {_MANIFEST} identity.display_name is {ESTATE_APP_NAME!r} — the title bar "
                     "needs a printable name of 1-40 characters with no markup. Nothing was written.")
MODX_ROOT = (os.environ.get('MODX_ROOT') or '').strip()
ERROR_LOG_FILEPATH = f"{MODX_ROOT.rstrip('/')}/core/logs/" if MODX_ROOT else ''
print(f"estate bar: cdn={ESTATE_CDN_URL or '(none)'} ({ESTATE_CDN_SOURCE})")
if ERROR_LOG_FILEPATH:
    print(f"error log: {ERROR_LOG_FILEPATH}error.log (from MODX_ROOT)")
else:
    print('error log: MODX_ROOT is unset, so error_log_filepath is left as it stands on this ground')
print(f"estate bar: weather={ESTATE_WEATHER_URL} (from the CDN address)")
print(f"estate bar: colour={ESTATE_ENV_COLOR or 'NOT SET — the bar falls back to the stylesheet'}"
      f" ({'environment' if ESTATE_ENV_COLOR else 'unset'})")
if ESTATE_ENV:
    print(f"estate bar: env={ESTATE_ENV} (environment)")
else:
    # NO GUESS, AND NO DEFAULT. Nothing on a MODx ground says which world it is: estate.json is one
    # file for all of them and a hostname is a name, not a property of the ground. A default
    # of 'development' would paint production amber and a default of 'production' would let staging
    # wear production's silence, which is the failure a sibling application's EnvBanner was written to end. So
    # this writes NOTHING and says so: the row keeps whatever the ground already holds, and a ground
    # that has never been told renders the bar's default colour with no word. Rendering
    # MODX_ESTATE_ENV per ground is infra's, and it is one export in each of the two settings verbs
    # that already know which world they are applying to.
    print('estate bar: env NOT SET — MODX_ESTATE_ENV is unset, so estate_env is left as it stands '
          'on this ground and no environment is guessed')

# ── RETIRED SETTINGS: rows this file used to declare and now DELETES ──────────────────────────
# A row nobody declares any more must not simply be abandoned. This file upserts, so dropping a
# key from `settings` leaves it on every ground it was ever written to, where the next reader finds
# a value with no declaration behind it and cannot tell whether it is load-bearing. So a key leaves
# by being named HERE, and the same verb that wrote it removes it.
#
# `debug` and `error_reporting` were declared by this file from 2026-06-05 (e027e33, the first
# import of these scripts) with no reason recorded — the shape of a line written while setting a
# thing up and never revisited. The owner, 2026-09-20, on being shown they do nothing: "if we do not
# need it, can we remove it."
#
# THEY DO NOTHING ON 3.2.4, measured rather than assumed. `modX::setDebug('1')` matches none of
# true/'true'/'-1'/false/'false'/'0', falls to `intval(constant('1'))` = 0, and `if ($debug)` is
# false — no call is made (core/src/Revolution/modX.php:737-757). Nothing under core/src reads a
# setting named `error_reporting` at all.
#
# DELETED RATHER THAN SET TO '0', AND THE DIFFERENCE IS THE WHOLE POINT. '0' DOES match that
# branch and calls `error_reporting(0)`, which silences every PHP error on the ground — a real
# regression dressed as a tidy-up. An ABSENT row means `getOption('debug')` is null and
# `setDebug` is never called, which is exactly today's behaviour minus the misleading row.
#
# A RETIRE NEEDS A CACHE REFRESH, exactly as any settings change does: MODx serves settings from
# core/cache/system_settings/config.cache.php, so the row goes and the old value is still answered
# until the cache is rebuilt. Measured on the bench — after the DELETE, getOption('debug') still
# returned '1'; after clear-cache.php it returned NULL, with getDebug() false and error_reporting()
# 22527 both BEFORE and AFTER, which is the proof that removing the row changes no behaviour.
#
# `sso.allowed_emails` and `sso.allowed_domains`: the sign-in list that sat in front of the
# MODx user check. The owner, 2026-10-05, after a restore carried production's one-address list onto the
# bench and refused his other accounts: "let us say i want to get rid of this additional list" /
# "please do". GoogleSSOCallback no longer reads either, so the rows are deleted on every ground.
RETIRED = ('debug', 'error_reporting', 'sso.allowed_emails', 'sso.allowed_domains',
           # a second copy of the corporate context's own address; kuber.js reads the
           # context's site_url through contextBase, named by the estate's corp.context.
           'corp.base_url')

settings = [
    # key, value, xtype, area
    ('estate_cdn_url',      ESTATE_CDN_URL,       'textfield',      'site'),
    ('estate_env_color',    ESTATE_ENV_COLOR,     'textfield',      'site'),
    ('estate_weather_url',  ESTATE_WEATHER_URL,   'textfield',      'site'),
    ('estate_app_name',     ESTATE_APP_NAME,      'textfield',      'site'),
] + ([('estate_env',        ESTATE_ENV,           'textfield',      'site')] if ESTATE_ENV else []) + (
    [('error_log_filepath', ERROR_LOG_FILEPATH,   'textfield',      'system')] if ERROR_LOG_FILEPATH else []) + [
    ('friendly_urls',       '1',                  'combo-boolean',  'friendly_urls'),
    ('friendly_urls_strict','1',                  'combo-boolean',  'friendly_urls'),
    # use_alias_path=0 -> flat URLs (alias only, no parent path), matching the old sites
    # (/bank not /content/.../bank). Uniqueness is alias+extension; 05 source-prefixes on
    # conflict and carries content_type so a .pdf static resource stays distinct from the
    # same-alias HTML doc.
    ('use_alias_path',      '0',                  'combo-boolean',  'friendly_urls'),
    # container_suffix='' -> a container's URL is /vacation, not /vacation/. MODx appends this
    # suffix to the uri of any resource with isfolder=1 (modResource::getAliasPath), which is the
    # ONLY source of the trailing slash. Setting it empty is preferred over clearing isfolder:
    # auto_isfolder=1 makes MODx set a parent's isfolder back to 1 the moment a child is created,
    # so the isfolder route silently undoes itself, and isfolder still carries real meaning for the
    # manager tree and pdoMenu. Requires 07-regenerate-uris.php afterwards — the uri column is
    # stored, not derived, so a setting change alone does not move it.
    ('container_suffix',    '',                   'textfield',      'furls'),
    ('date_timezone',       'America/New_York',   'textfield',      'site'),
    # NO MANAGER EDITOR (the owner, 2026-09-14: "i do not edit or look at the content in editor").
    # This named 'codemirror' while no CodeMirror package was installed on any ground, so the
    # setting pointed at nothing and the manager fell back to a plain textarea anyway. Documents
    # are edited in git (seat/documents) and pushed; the manager is not an editing surface.
    ('which_editor',        '',                   'textfield',      'site'),
    ('use_editor',          '0',                  'combo-boolean',  'site'),
    # THE DASHBOARD FETCHES NOTHING FROM OUTSIDE (same day). Both feeds are public RSS pulled from
    # modx.com / feedburner on every manager dashboard load — an outbound call from a private
    # intranet for news nobody reads here. Upgrade notices reach us through the release tags
    # (docs/upgrades.md Phase 0), not the dashboard.
    ('feed_modx_news_enabled',     '0',           'combo-boolean',  'system'),
    ('feed_modx_security_enabled', '0',           'combo-boolean',  'system'),
    # NO UPLOAD LIMIT OF OURS (the owner, 2026-09-14: "i do not want a limit, if the protocol has a
    # limit, i will work with it"). MODx refuses a manager upload above upload_maxsize BEFORE PHP
    # or nginx see it, and it shipped at 2 MiB. Set to PHP_INT_MAX so the only ceilings in force
    # are the ground's own — php upload_max_filesize / post_max_size and nginx
    # client_max_body_size, infra's — and a refusal names one of those, not this row.
    ('upload_maxsize',      str(2**63 - 1),       'textfield',      'file'),
    ('password_min_length', '4',                  'numberfield',    'security'),
    ('use_context_resource_table', '0',           'combo-boolean',  'site'),
    ('cache_alias_map',    '1',                   'combo-boolean',  'cache'),
]

# THE LOCAL BENCH IS EVERY AGENT'S (law 2.5). MODx creates its cache directories and files
# with these modes, and the defaults (0755 / 0644) leave everything it writes to whichever OS user
# the bench runs as, so another agent could not clear what the bench had cached. Infra made the
# existing tree group-writable; these keep what MODx creates AFTERWARDS group-writable too. Written
# only on the development world: staging and production are single-owner grounds and keep MODx's
# defaults. restore_modx_dev re-runs this file with the development world, so a restore keeps them.
if ESTATE_ENV == 'development':
    settings += [
        ('new_folder_permissions', '0775', 'textfield', 'file'),
        ('new_file_permissions',   '0664', 'textfield', 'file'),
    ]

# Estate-declared settings land after the shipped ones, so a declaration can override a default.
#
# The outward links (kuber, census, whois, the privacy page) are no longer the estate's: infra
# derives them per ground and setup/apply-environment.php writes them. An address the estate
# still declares is skipped and named, never written, so a second owner cannot win.
_links = sorted(k for k, v in SYSTEM_SETTINGS.items() if str(v).startswith(('http://', 'https://')))
if _links:
    print(f"  skipped estate address(es), infra's to write: {', '.join(_links)}")
settings += [(k, v, 'textfield', 'site') for k, v in SYSTEM_SETTINGS.items() if k not in _links]

for key, value, xtype, area in settings:
    cur.execute("SELECT `key` FROM modx_system_settings WHERE `key`=%s", (key,))
    if cur.fetchone():
        cur.execute(
            "UPDATE modx_system_settings SET value=%s, editedon=NOW() WHERE `key`=%s",
            (value, key)
        )
        print(f'  updated: {key} = {value}')
    else:
        cur.execute(
            "INSERT INTO modx_system_settings (`key`, value, xtype, namespace, area, editedon) VALUES (%s,%s,%s,'core',%s,NOW())",
            (key, value, xtype, area)
        )
        print(f'  inserted: {key} = {value}')

for key in RETIRED:
    cur.execute("DELETE FROM modx_system_settings WHERE `key`=%s", (key,))
    print(f'  retired: {key}' if cur.rowcount else f'  retired: {key} (already absent)')

conn.commit()

# ONE SESSION COOKIE PER CONTEXT, ON THE BENCH ONLY. Every bench context answers on its own
# localhost port, and a browser keeps ONE cookie jar for localhost whatever the port — so all four
# contexts shared one PHPSESSID, and one tab's requests could disturb a sign-in in progress on
# another (the owner, 2026-10-05: 'state mismatch' on :8312). MODx starts the session AFTER the
# context's settings load (core/src/Revolution/modX.php:602-605, session_name read at 2863), so a
# context setting gives each port its own cookie. Staging and production answer each context on its
# own host name, where cookies are already apart, and get no row.
if ESTATE_ENV == 'development':
    cur.execute("SELECT `key` FROM modx_context WHERE `key` <> 'mgr'")
    for (ctx,) in cur.fetchall():
        name = 'PHPSESSID' + re.sub(r'[^A-Za-z0-9]', '', ctx)
        cur.execute("SELECT 1 FROM modx_context_setting WHERE context_key=%s AND `key`='session_name'", (ctx,))
        if cur.fetchone():
            cur.execute("UPDATE modx_context_setting SET value=%s WHERE context_key=%s AND `key`='session_name'",
                        (name, ctx))
        else:
            cur.execute("INSERT INTO modx_context_setting (context_key, `key`, value, xtype, namespace, area) "
                        "VALUES (%s,'session_name',%s,'textfield','core','session')", (ctx, name))
        print(f'  session cookie for {ctx}: {name} (development only)')
    conn.commit()

# Blank the HTML content-type extension -> documents render with no .html suffix (flat).
cur.execute("UPDATE modx_content_type SET file_extensions='' WHERE file_extensions IN ('.html','html')")
print(f'  blanked HTML content-type extension ({cur.rowcount} row)')
conn.commit()

cur.close()
conn.close()
print('Done.')
