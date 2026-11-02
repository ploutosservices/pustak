"""
The access model — ONE declaration, imported by everything that writes or checks it.

`04-access-control.py` WRITES this model into a MODx database; `verify-file-protection.py` ASSERTS
that a database still matches it. They must never carry separate copies of the same facts: a
watcher that keeps its own list of contexts, group names or policy ids goes green on a model it no
longer describes, and a false green on file protection means the estate's documents are open while
the board says they are shut.

Import-safe on purpose — declarations only, no database connection, no side effects. `04` cannot be
imported (it does its work at module level), which is exactly why the shared facts live here.

WHAT IS AND IS NOT IN THIS FILE. This file is the access POLICY — the shape of the model,
and the switches that turn protection on and off. WHO the estate is for — its contexts, its people,
their groups and landing pages — is `estate.py`, and is re-exported below so every existing consumer
keeps importing it from here. The split exists because those two things have different audiences: an
outsider installing this software edits `estate.py` and never needs to read this file, while the
policy below is the same for every installation.
"""

from estate import (PROTECTED_CONTEXTS as CONTEXTS,   # the contexts setup/04 protects
                    ADMIN_USERNAME,
                    GROUPS)

PROTECTED = 'allContextProtected'                   # resource group: each context's home
OLD_NAMES = {'allContextMember': 'Members', PROTECTED: 'Protected'}

# ── FILE protection ───────────────────────────────────────────────────────────────
# THE SWITCH. True = every Static Resource needs a signed-in member of its own context; False +
# re-run of 04 = the whole thing lifted, memberships and grants dropped as a unit. This is the one
# step the owner consented on ("i can always unlock the doors"), and it is also what the verifier reads
# as INTENT — so unprotecting deliberately does not leave a monitor screaming forever.
PROTECT_FILES = True
FILE_CLASS = 'MODX\\Revolution\\modStaticResource'
FILE_GROUPS = {ctx: f'{ctx}ProtectedFiles' for ctx in CONTEXTS}

# ── PAGE protection (2026-07-27) ───────────────────────────────────────────────────────────────
# The same switch, one level up, and for the same reason the owner gave for the files: "i can always
# unlock the doors and it is a simpler option than finding doors to be locked."
#
# The old rule was "only home is protected, all others open". It was never true in practice — the
# three ids in allContextProtected were 13/27/41, the deleted 'home' twins, so the group protected
# nothing at all and every page in the estate answered an anonymous curl with 200. Measured, both
# directions: a static in a protected group returns 401, a document in no group returns 200.
#
# True = every PAGE needs a signed-in member of its own context, except the support subtree.
# False + a re-run of 04 lifts it in one step, memberships and grants dropped together.
PROTECT_PAGES = True
DOC_CLASS = 'MODX\\Revolution\\modDocument'

# The exception set, and it is mechanical rather than a list anyone maintains: each context has one
# top-level `support` container holding login, logout, sso-login, sso-logout, unauthorized, error,
# robots, search, userHome and public. Those must answer anonymously or nobody can sign in, reach
# the unauthorized page, or be redirected by the router — protecting them locks the door from the
# inside. Nothing is nested below them (checked), so "the container and its children" is the whole
# rule and a page added to support later is exempt automatically.
SUPPORT_ALIAS = 'support'

# ── MACHINE DOORS — the pages MODx's access model must NOT judge ───────────────────
# The second exception, and it is a different reason from `support`, so it is a different rule and
# not an extra alias in the container above.
#
# A `support` page must answer anonymously or nobody can SIGN IN. A machine door must answer
# anonymously or its OWN CODE never runs — and that code is the door. `/actuator/info` is admitted
# by a client certificate read in `common/snippets/actuatorInfo.php`, which refuses every caller it
# does not recognise with 401 and a fixed message. Page protection intercepts one layer above that
# and answers 302 to the sign-in page instead, for a valid certificate exactly as for none, so the
# element's own refusal is never reached and neither is its acceptance.
#
# THAT IS NOT A HYPOTHETICAL. Measured 2026-09-05 by
# infra from the ground that holds monitoring's certificate — nginx VERIFIED the chain and logged
# `dn="CN=monitoring@production"`, and MODx answered 302 to /sso-login regardless. Reproduced on a
# dev box the same way round: with the actuator rows present and 04 NOT yet run, `/actuator/info`
# answers 401 from the element; after 04 it answers `302 -> /sso-login?returnUrl=%2Factuator%2Finfo`.
#
# ONE OWNER, AND IT IS THE MANIFEST. `service.json` already declares which paths this application
# offers a MACHINE (`identity.routes`, P10) — that is the same fact, so it is read from there rather
# than restated here. Adding a route row to the manifest therefore un-protects that page, which is a
# real widening and is why it is bounded in BOTH directions:
#   - 04 PRINTS every row it exempts, by id and uri, so an exemption nobody meant is visible in the
#     deploy output rather than inferred from a count;
#   - `verify-file-protection.py` asserts both directions — a declared door that is IN the protected
#     group is drift (the door is shut), and a page that is open and is NOT a declared door is drift
#     (it serves to anyone). An undeclared page cannot become exempt by being open.
# A route row is not a licence on its own: the element behind it still has to refuse, and that is
# proven by `consumer-reach.sh` — the rule-21 artefact, which calls the door with each declared
# consumer's certificate and with none. Four owners, no overlap: this file declares the exemption,
# `verify-file-protection.py` asserts the database matches it, `tests/protect-on-save.sh` proves a
# manager save cannot re-shut it, and `consumer-reach.sh` proves the element still refuses.
MANIFEST = 'service.json'


def machine_door_uris():
    """The `uri` of every route this application declares as a machine door, from `service.json`.

    REFUSES rather than returning an empty set when the manifest cannot be read or parsed. An empty
    set is not a safe default here: it is exactly today's broken state — every declared door back
    inside `allContextProtected`, answering a sign-in redirect to its own consumer — and it would
    arrive silently, in the middle of an otherwise successful converge. Same argument as 04's
    empty-estate guard: a model that cannot read its own declaration must stop, not assume.

    A leading `/` is stripped because that is how `modx_site_content.uri` stores it; MODx routes on
    that column and nothing else (`alias` is only the last segment somebody typed).
    """
    import json
    import os
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', MANIFEST)
    try:
        with open(path, encoding='utf-8') as fh:
            manifest = json.load(fh)
    except (OSError, ValueError) as exc:
        # RuntimeError and NOT SystemExit, deliberately: `verify-file-protection.py` guards its
        # import with `except Exception` to answer 2 = COULD NOT RUN, and SystemExit is a
        # BaseException, so it would slip past that guard and be reported as 1 = DRIFT. "The
        # manifest is unreadable" and "the database has drifted" are different answers and this
        # file must not blur them (the same distinction run-all.sh draws between refused and failed).
        raise RuntimeError(
            f'access_model: cannot read the machine-door declaration from {MANIFEST} ({exc}). '
            f'REFUSING rather than declaring none: no declared doors means every machine door is '
            f'protected as an ordinary page, which answers the estate a sign-in redirect instead '
            f'of the element behind it. That is a state to stop on, not to converge.'
        ) from exc
    routes = ((manifest.get('identity') or {}).get('routes') or [])
    # A row whose `served_by` is a plugin is answered on OnPageNotFound, with no resource at its
    # path (estateBrand, /.well-known/estate-brand.json) — there is no row to exempt or bind.
    return tuple(sorted({str(r.get('path', '')).lstrip('/')
                         for r in routes if str(r.get('path', '')).strip('/')
                         and not str(r.get('served_by', '')).startswith('plugin:')}))


MACHINE_DOORS = machine_door_uris()

UG = 'MODX\\Revolution\\modUserGroup'
POL_LOAD = 3                          # Load Only            (resolve + hit the login page)
POL_VIEW = 4                          # Load, List and View  (a member opens it)

# ── SAVE-TIME protection ────────────────────────────────────────────────────────────────
# 04 converges every resource at once, at deploy time. That leaves a window a job cannot close: a
# page created or undeleted in the MODx manager triggers no job at all, so it is public until the
# next deploy of anything. This is what that window looks like — a fund balance sheet, written that
# afternoon, returning 200 to an anonymous request on production.
#
# The plugin below closes it at the only moment that can: the save. It is installed and bound by 04,
# so "converge access control" remains one verb and the enforcement can never be older than the
# declaration it enforces.
PLUGIN_NAME = 'protectOnSave'
PLUGIN_EVENTS = ('OnDocFormSave',        # create, update, and update-from-grid (all three
                                         # processors set $afterSaveEvent to it)
                 'OnResourceUndelete',   # the recycle bin, and the undelete path inside Update
                 'OnResourceDuplicate')  # duplicate() copies memberships, so a copy of a SUPPORT
                                         # page arrives carrying no protection at all

# THE BRIDGE, and the reason there is still one declaration. The plugin is PHP and this file is
# Python, so the model is rendered into a MODx system setting on every run of 04 and the plugin
# reads it from there. `verify-file-protection.py` asserts the setting still says what this file
# says, which makes drift a red on the 6-hourly monitor rather than a discovery.
SETTING_KEY = 'access.model'


def declaration(page_group_id, file_group_ids):
    """The model as the MODx side reads it — written by 04, asserted by the verifier, read by the
    plugin. Ids are passed in because they are facts about one database, not about the model.

    Everything the plugin needs is here and nothing it needs is anywhere else: if a value has to be
    hardcoded in the plugin, it belongs in this dict instead.
    """
    return {
        'protect_pages': bool(PROTECT_PAGES),
        'protect_files': bool(PROTECT_FILES),
        'contexts':      sorted(CONTEXTS),
        'support_alias': SUPPORT_ALIAS,
        # The uris, not the ids: a machine door is bound to a different resource id on every ground
        # (1583 on the estate, and nothing at all on a dev box that has not been given the rows), so
        # an id here would be a fact about one database written into the model of all of them.
        'machine_doors': list(MACHINE_DOORS),
        'doc_class':     DOC_CLASS,
        'file_class':    FILE_CLASS,
        'page_group':    PROTECTED,
        'page_group_id': int(page_group_id),
        'file_groups':   {c: FILE_GROUPS[c] for c in sorted(CONTEXTS)},
        'file_group_ids': {c: int(file_group_ids[c]) for c in sorted(CONTEXTS)},
    }
