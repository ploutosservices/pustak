"""
estate.py — THE LOADER. It holds no estate.

WHAT CHANGED AND WHY (the owner, 2026-08-01: *"the repo needs to be clean of estate"* /
*"an estate file can update the basic config file and rest can be driven from there"*).

Until today this file WAS the estate: three contexts, three real people, their groups and their
landing pages, written inline. An earlier change had already separated it from the installer scripts, which was
the right first move and not enough — a declaration living inside the software repository is still
the software carrying somebody's estate around. It also made the repository unlicensable: you
cannot give away code that has a family's names in it.

So the split is now the one the owner described. **The software ships a generic default. An estate file
overlays it. Everything downstream reads the result and knows nothing about estates.**

    no MODX_ESTATE set        -> the DEFAULT below: no contexts, no users, no groups.
                                 A stock install produces an empty, working, generic estate.
                                 This is the install-from-nothing path and it stays proven.

    MODX_ESTATE=/path/to.json -> that file is loaded and overlaid on the default.
                                 It must exist and parse, or this refuses. A named estate that
                                 silently falls back to the empty one would install a stranger's
                                 software over somebody's data and report success.

Every consumer keeps its existing import (`from estate import CONTEXTS, USERS, ...`) — the names
and their shapes are unchanged, so nothing downstream had to be rewritten to make the repository
clean. That is deliberate: a seam that forces thirty edits is a seam that gets reverted.

THE FORMAT is `estate.example.json`, which is generic and committed here as documentation. The real
estate file is NOT in this repository and must never be added to it; `.gitignore` refuses
`estate.json` for that reason.

Import-safe: declarations only, no database connection, no side effects beyond reading one file.
"""
import json
import os

# ── The generic default: what this software installs when nobody has declared an estate ─────────
# Empty on purpose. A default context list would be somebody's guess at what an estate contains,
# and a default user would be an account nobody asked for. `web` is MODX's own context, which
# always exists and which 01 only relabels — so it is the one thing that must have a value.
_DEFAULT = {
    'web_context': {'name': 'Web', 'description': 'MODX default context', 'rank': 1,
                    'site_name': 'MODX'},
    'contexts': {},
    'admin_username': None,     # resolved below: MODX's own installer names it, not us
    'users': [],
    'groups': {},
    'domains': {'contexts': []},   # host names are infra's, never the estate's
    'system_settings': {},   # estate-specific MODx system settings, applied by setup/02
    'context_renames': [],   # [[old, new], ...] — keys this estate is moving; see below
    'identifiers': [],       # regexes naming this estate (its addresses, hosts, people): the software
                             # must never carry one — tests/estate-clean.sh and regenerate-docroot.sh scan for them
}

ESTATE_FILE = os.environ.get('MODX_ESTATE')
_RETIRED_KEYS = {'home_overrides'}


def _load():
    """The default, overlaid with the estate file when one is named. Refuses rather than guesses."""
    data = json.loads(json.dumps(_DEFAULT))          # deep copy; the default is never mutated
    if not ESTATE_FILE:
        return data
    if os.path.isdir(ESTATE_FILE):
        # The estate is a FILE. Pointing this at the estate CHECKOUT is the near-miss a ground
        # gets wrong (2026-08-13), and it is worse than a typo: the variable IS set, so
        # nothing reads as unconfigured, and the message below would have said the directory
        # "does not exist" while `ls` showed it there.
        inner = os.path.join(ESTATE_FILE, 'estate.json')
        raise SystemExit(
            f"estate: MODX_ESTATE names '{ESTATE_FILE}', which is a DIRECTORY.\n"
            f"        The estate is a file, not the checkout that holds it.\n"
            + (f"        Set MODX_ESTATE={inner}\n" if os.path.isfile(inner) else
               f"        Expected {inner}, and there is no such file in it.\n")
        )
    if not os.path.isfile(ESTATE_FILE):
        raise SystemExit(
            f"estate: MODX_ESTATE names '{ESTATE_FILE}', which does not exist.\n"
            f"        Refusing rather than falling back to the empty default — installing the\n"
            f"        generic estate over a named one is how you overwrite somebody's data and\n"
            f"        get told it worked."
        )
    try:
        with open(ESTATE_FILE) as fh:
            declared = json.load(fh)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"estate: {ESTATE_FILE} is not valid JSON — {exc}")
    # A key beginning with `_` is a comment. JSON has none, and a declaration file with nowhere to
    # write down WHY a value is what it is becomes a list of literals nobody dares change.
    declared = {k: v for k, v in declared.items() if not k.startswith('_')}
    # A RETIRED key is read and ignored, never refused. `home_overrides` left the schema when
    # a user's home moved to the MODx manager; refusing it broke every ground whose estate checkout
    # had not yet been updated — staging's converge and restore both stopped on it (2026-10-05).
    # Ignoring it is safe: nothing reads it, and the checkout catches up on its next pull.
    for k in _RETIRED_KEYS & set(declared):
        print(f"estate: {ESTATE_FILE} still declares retired key {k!r} — ignored")
        declared.pop(k)
    unknown = set(declared) - set(_DEFAULT)
    if unknown:
        raise SystemExit(
            f"estate: {ESTATE_FILE} declares unknown key(s) {sorted(unknown)}.\n"
            f"        Known keys: {sorted(_DEFAULT)}. A misspelled key that was ignored would\n"
            f"        install an estate missing exactly the thing you thought you had declared."
        )
    data.update(declared)
    return data


_E = _load()


# ── Contexts ────────────────────────────────────────────────────────────────────────────────────
# The contexts `setup/01-contexts-users.py` creates, and how each presents itself. A context added
# later to a running estate is NOT declared here — that is `setup/11-add-context.py`, a separate
# act on purpose (the owner: "adding a context is a separate process").
#
# `protected` marks a context whose documents and static files are access-controlled by `setup/04`.
# A context serving public pages is declared protected=False and simply does not appear in groups.
CONTEXTS = {k: dict(v) for k, v in _E['contexts'].items()}

# MODX's own `web` context always exists; 01 only relabels it.
WEB_CONTEXT = dict(_E['web_context'])

PROTECTED_CONTEXTS = [k for k, v in CONTEXTS.items() if v.get('protected')]


# ── Where the estate REPOSITORY is ───────────────────────────────────────────────
# `seat/` (his documents) and `install/` (the seed, the docroot tar, the migration maps) left this
# software repository for the estate repository. Scripts here that need one of those artefacts ask
# for it through `estate_path()`.
#
# It is DERIVED, not a second variable: the estate repository is the directory the estate file lives
# in. A `MODX_ESTATE_REPO` beside `MODX_ESTATE` would be two names for one place, free to disagree —
# the defect shape this ticket spent phase 1 removing.
#
# None when no estate is named, so `import estate` still works on the install-from-nothing path.
# The refusal happens when a path is actually ASKED FOR, which is the only moment at which
# not knowing matters.
ESTATE_REPO = os.path.dirname(os.path.abspath(ESTATE_FILE)) if ESTATE_FILE else None


def estate_path(*parts):
    """A path inside the estate repository. Refuses rather than guessing one."""
    if not ESTATE_REPO:
        raise SystemExit(
            "estate: this needs an artefact from the estate repository (" + os.path.join(*parts) +
            ") and MODX_ESTATE is not set.\n"
            "        seat/ and install/ live in the estate repository since the estate split. There is\n"
            "        no default path — a guessed one turns an unset variable into a silent read of\n"
            "        the wrong tree, which is how a deploy reports success having written nothing."
        )
    return os.path.join(ESTATE_REPO, *parts)


# ── A protected context must name its HOME ───────────────────────────────────────────────
# `04` resolves the context's landing page from the `protected_page` context setting and falls back
# to `nav_root_id`; when neither resolves it prints a WARN and carries on. That warning is the whole
# defect: the context is protected, an anonymous visitor is refused, and a signed-in MEMBER has
# nowhere to be sent — their `homePages` entry for that context is simply missing, and `userHome`
# routes them nowhere. It is invisible from outside, because the outside is refused either way.
#
# It happened to `claude` on production exactly as described, and the reason it could happen is that
# the home lived only in a database setting written once by `setup/03` — a fact with no home in the
# declaration. Declaring it makes the next context unable to repeat it. `home` is an ALIAS, not an
# id: ids are facts about one database and this file is about the estate.
_homeless = sorted(k for k, v in CONTEXTS.items() if v.get('protected') and not v.get('home'))
if _homeless:
    raise SystemExit(
        f"estate: {', '.join(_homeless)} declare(s) `protected: true` with no `home`.\n"
        f"        A protected context with no landing page refuses anonymous callers correctly and\n"
        f"        then has nowhere to send a member who signs in — setup/04 warns and continues, so\n"
        f"        nothing fails and nobody notices (measured on production). `home` is the\n"
        f"        ALIAS of the page a member lands on, e.g. \"home\"."
    )


# ── The one invariant this loader enforces ───────────────────────────────────────────────
# A context can be given a domain here and never be declared above. Nothing went red when that
# happened: `claude` sat in `domains.contexts` and the old production name map with no `contexts` entry, so it
# was never in PROTECTED_CONTEXTS, `04` built it no groups, and it answered 200 with its content to
# anybody on the internet for as long as the name resolved. The declaration read complete either
# way, which is what made it survive — the missing key IS the access decision, taken by omission.
#
# So: publishing a context and declaring one are now the same act. `protected: false` is a perfectly
# good answer and stays available — it is a decision somebody wrote down and another agent can
# review. Silence is not.
_published = set(_E['domains'].get('contexts') or [])
_undeclared = sorted(_published - set(CONTEXTS) - {'web'})
if _undeclared:
    raise SystemExit(
        f"estate: {', '.join(_undeclared)} appear(s) under `domains` but not under `contexts`.\n"
        f"        A context with a domain and no declaration gets no access model at all — it\n"
        f"        serves its content to anyone who can resolve the name, and nothing reports it\n"
        f"        (`claude` did exactly this). Declare it with `protected: true`, or with\n"
        f"        `protected: false` if it is genuinely public — either is fine, and silence is\n"
        f"        not one of them."
    )


# ── People ──────────────────────────────────────────────────────────────────────────────────────
# The MODX manager account created by MODX's OWN installer (setup/config.xml `cmsadmin`), before
# any of our scripts run. We do not create it and cannot rename it — we only need to know what it
# is called, because it is a member of the all-context group.
#
# Getting this wrong used to be silent: `04` printed "WARN user <name> not found — skipped" and
# carried on, leaving the admin in no group at all on an estate whose every page requires
# membership. It is a hard failure naming the estate file.
#
# With no estate file, MODX_ADMIN_USER is consulted so an install-from-nothing can still place its
# own admin. No literal default: a wrong username here fails loudly at 04 rather than quietly.
ADMIN_USERNAME = _E['admin_username'] or os.environ.get('MODX_ADMIN_USER')

# Accounts `setup/01` creates: (username, fullname, email, sso_only).
# The username is the login identity for form login; the EMAIL is what Google SSO matches on
# (GoogleSSOCallback looks up modUserProfile by verified email), so for an SSO user the email must
# equal their Google account exactly. Group membership is NOT set here — `setup/04` owns that.
#
# Passwords: form login is uninstalled (SSO-only), so the stored hash never authenticates anyone.
# Seed users keep MODX_ADMIN_PASS for break-glass; SSO-only users get a random unusable secret.
USERS = [tuple(u) for u in _E['users']]

# group name -> (contexts it may enter, the users it starts with)
#
# A group's contexts are an explicit list, or the single token `*` meaning EVERY context this
# estate declares. `*` exists because the WIDEST group is the one that silently falls behind:
# `allContextMember` named its four contexts literally, beside `domains.contexts` naming the same
# four, so a fifth context could install, serve, and be invisible to the one group whose name
# promises all of them — with no field to ask and no check that could go red, because both lists
# were well-formed. It is derived from `domains.contexts`, which is
# MODx's own list door and the file infra's `check-tenants.py` already reads, so which contexts
# exist still has exactly one owner.
_ALL_CONTEXTS = '*'


def _group_contexts(name, ctxs):
    ctxs = list(ctxs)
    if _ALL_CONTEXTS not in ctxs:
        return ctxs
    named = [c for c in ctxs if c != _ALL_CONTEXTS]
    if named:
        raise SystemExit(
            f"estate: group {name!r} lists {_ALL_CONTEXTS!r} beside {named}. A group's contexts "
            f"are every context or a named few, never both — one of the two would be silently "
            f"ignored."
        )
    declared = list((_E['domains'] or {}).get('contexts') or [])
    if not declared:
        raise SystemExit(
            f"estate: group {name!r} asks for every context ({_ALL_CONTEXTS!r}) and "
            f"domains.contexts is empty, so it would be granted NOTHING under a name that says "
            f"everything. Declare the contexts, or list this group's contexts explicitly."
        )
    return declared


GROUPS = {name: (_group_contexts(name, v[0]), list(v[1])) for name, v in _E['groups'].items()}

# A user's landing page is not declared here: it is set in the MODx manager.

# Context keys this estate is MOVING, oldest first: [[old, new], ...]. An estate fact, not a
# software one — which keys a particular estate used to use is exactly the kind of thing that must
# not live in this repository (tests/estate-clean.sh). Consumed by setup/migrate-estate-keys.py,
# which needs the OLD key and cannot learn it from `contexts` because `contexts` already carries
# the new one. An estate with nothing to move declares nothing and the migration is a no-op.
CONTEXT_RENAMES = [tuple(pair) for pair in (_E.get('context_renames') or [])]


# The domain half of the declaration, consumed by domains.py. It lives in the same file because it
# is the same fact — which estate this is — and splitting one declaration across two files is how
# that kind of drift happens.
DOMAINS = dict(_E['domains'])

# MODx system settings that belong to THIS estate rather than to the software — a per-estate
# toggle, never an address (addresses are infra's, #1463; setup/02 skips one). setup/02 writes the generic list first and then these,
# so an estate can override a shipped default without the software knowing the estate exists.
SYSTEM_SETTINGS = dict(_E['system_settings'])


# ── Cross-check: every context declared is in domains.contexts ──────────────────────────────────
# domains.contexts is MODx's list door: infra's modx-environment.py names a host for each context in
# it, so a context missing from it installs and resolves nowhere. It may list MORE contexts than
# `contexts` — one is added by 11-add-context, not by 01 — so the relationship is containment.
# Enforced at import time because that failure looks like a DNS problem for as long as anyone is
# willing to believe that.
def _check_contexts_have_domains():
    declared = DOMAINS.get('contexts') or []
    if not declared and not CONTEXTS:
        return                                  # generic default: nothing to cross-check
    missing = [c for c in CONTEXTS if c not in declared]
    if missing:
        raise SystemExit(
            f"estate: context(s) {missing} are declared and absent from domains.contexts. Add "
            f"them there in {ESTATE_FILE or 'the estate file'}, or they will install and resolve "
            f"nowhere."
        )


_check_contexts_have_domains()
