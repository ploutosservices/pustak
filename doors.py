#!/usr/bin/env python3
"""doors.py — MODx publishes every door it offers and who may call each. Constitution rule 21.

WHY THIS FILE IS NOT AN IMPORT OF THE SHARED LIBRARY. `services/_rule21/doors_lib.py` walks a
Python handler's AST. MODx is PHP, and its handlers are ELEMENTS — snippet and plugin bodies that
live in `modx_site_snippets.snippet` and `modx_site_plugins.plugincode`, database columns, whose
repository copies are the files beside this one. There is nothing for that library to import. The
OUTPUT is kept byte-compatible with it — same field names, same types — because four services
already publish that shape and a fifth answering differently is the defect whois spent a rewrite
removing.

THE TWO HALVES OF A MODX DOOR LIVE IN TWO PLACES, and pretending otherwise is how this file would
lie:

    WHO MAY CALL IT   is in the element's own source, in this repository. Mechanical, read below.
    WHERE IT ANSWERS  is a RESOURCE in the MODx database — the estate. "The repo carries no estate"
                      (the owner, 2026-08-01), so a path written into this file would be a second copy
                      of somebody else's fact and would rot the first time a page moved.

So the listing is keyed by ELEMENT and its `path` is filled from a MODx database when one is
reachable (`--db`, or MODX_DOORS_DSN), and is `estate-bound` when one is not. A run with no
database is honest and incomplete; it never invents a path. Which of the two you got is on the row.

THE DOOR IS READ OUT OF THE ELEMENT'S OWN CODE — a small vocabulary of call names, not a map of
paths, so an element that stops checking its caller cannot keep a door it no longer has:

    Application::acceptedClient   identity:estate-CA client certificate (nginx verifies the chain)
    GoogleToken::verify           the READER'S OWN id_token from the door, verified here
    isAuthenticated               a signed-in MODx session in this context
    none of these                 `open:` — a finding when it should not be, true when it should

AND THE CALL COUNTS ONLY WHEN THE ELEMENT REFUSES ON IT. The first version of this file took any
of the three as a door, and four of fourteen elements disproved that within a minute of pointing it
at the real tree:

  · GoogleSSOStart calls isAuthenticated to REDIRECT a visitor who is already signed in — the
    opposite of refusing an anonymous one.
  · GoogleSSOLogout calls it to say "you are still signed into the manager" in the page it renders.
  · tableRenderer calls it inside its &auth branch to name the READER it fetches as; with nobody
    signed in it renders a message and the page is still served.
  · the bookkeeping-names plugin calls it and, per the owner's own rule for that plugin — "if not logged in, display
    blank" — returns silently. A blank cell is not a refusal.

So a guard is a caller-establishing call PLUS a refusal in the same element ($send(401), a 401/403
status, sendUnauthorizedPage). What that correction reveals is the useful fact and it is not what I
expected: MODX HAS EXACTLY ONE DOOR OF ITS OWN, /actuator/info. Everything else is a page served
under MODx's resource access control — contexts and resource groups — and the elements are
fragments rendered inside a page whose readability was already decided before they ran.

WHAT A HUMAN SUPPLIES is the smallest thing: a REASON for each element that establishes no caller
of its own. Most of them are correct: a page fragment inherits MODx's resource access control, and
the sign-in flow cannot require a session because it is what creates one. An open door is lawful;
an UNEXPLAINED one is what an audit flags.

    doors.py                     print the listing
    doors.py --json              the same, as data
    doors.py --check             exit 1 on an open door with no reason, or a reason with no element
    doors.py --db mysql://...    resolve where each element is served from a MODx database
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
COMMON = os.path.join(HERE, "common")

# Call names that establish WHO IS CALLING. Names, not paths.
GUARDS = {
    "Application::acceptedClient":
        "identity:estate-CA client certificate (nginx sets X-Client-Identity from a verified chain)",
    "GoogleToken::verify":
        "token:the reader's own id_token from the sign-in door, verified here against the door's keys",
    "isAuthenticated":
        "session:person (a signed-in MODx session in this context)",
}

# THE ONLY HAND-WRITTEN FACTS IN THIS FILE: why an element that proves nothing about its caller is
# allowed to. Keyed by element name, because that is what this repository owns.
OPEN_REASONS = {
    "GoogleSSOStart":
        "the sign-in flow itself — it cannot require a session, it is what creates one. Its "
        "isAuthenticated call REDIRECTS a visitor who is already signed in; it refuses nobody. "
        "What it must not do is trust anything the caller says, and it does not: the verification "
        "is GoogleSSOCallback's, against the door's keys.",
    "GoogleSSOCallback":
        "reached with a code from the door and nothing else. It establishes the caller rather than "
        "checking one, so it has no door by construction; the audience check inside it is the "
        "boundary (a token minted for another application must not authenticate its holder here).",
    "GoogleSSOLogout":
        "ends a session. A door that refuses an anonymous caller would leave someone half signed "
        "out with no way to finish. Its isAuthenticated('mgr') call does not guard anything — it "
        "decides whether the page says 'still signed into the manager'.",
    "deliverStorageFile":
        "guarded by MODX'S OWN resource access control, not by code in the element: it is bound to "
        "a resource, and whether that resource is readable is decided by the context and resource "
        "group before this plugin runs. Writing a second check here would be a second copy of an "
        "access decision that already has an owner.",
    "protectOnSave": "not a door at all — it fires on OnDocFormSave inside the manager, where the "
                     "caller is already an authenticated manager user.",
    "tableRenderer": "renders inside a page and is reached only as that page is; it is a CALLER of "
                     "other doors rather than a door. Its &auth path names the person reading the "
                     "page and, with nobody signed in, renders a message — the page is still "
                     "served, so the check decides content and not admission.",
    "ssoRenew": "a CALLER, not a door. For a reader already signed in to this context it "
                "trades their renewal key for a new id_token and verifies it; with no reader it "
                "returns silently. A renewal the provider refuses ENDS the session — the "
                "next page then asks them to sign in — so it removes access, it never admits.",
    "ssoBackchannelLogout": "the door's back-channel sign-out (service.json identity.routes "
                            "/sso-backchannel-logout). The caller is the identity door, which presents "
                            "no certificate and no session, so no caller is established; what admits a "
                            "request is a logout_token signed under the door's published keys for this "
                            "context's client, else 400 — and it only ever ENDS sessions, never opens one.",
    "ipaddr": "a page fragment; prints the visitor's own address.",
    "jumpNav": "a page fragment; builds navigation from resources the reader can already see.",
    "loginWidget": "a page fragment on the sign-in page — it renders the button that starts the flow.",
    "TopLevelParent": "a page fragment; resolves a resource's top-level ancestor for navigation.",
    "unauthorizedNotice": "the page a refused reader is sent to. It must answer an unauthenticated "
                          "caller — that is who is looking at it.",
    "userHome": "a page fragment; resolves where a signed-in reader's home is.",
}
# An install's own elements beyond the published enhancement declare their reasons the same way in
# doors.local.json beside this file ({name: reason}), which only that install holds.
_LOCAL_REASONS = os.path.join(HERE, "doors.local.json")
if os.path.isfile(_LOCAL_REASONS):
    OPEN_REASONS.update(json.load(open(_LOCAL_REASONS)))

_CALL = {
    "Application::acceptedClient": re.compile(r"Application::acceptedClient\s*\("),
    "GoogleToken::verify": re.compile(r"GoogleToken::verify\s*\("),
    "isAuthenticated": re.compile(r"->isAuthenticated\s*\("),
}

# A REFUSAL, spelled every way this repository spells it. Without one in the same element, a
# caller-establishing call decides what the element DISPLAYS, not who may reach the page.
_REFUSES = re.compile(r"\$send\s*\(\s*40[13]|http_response_code\s*\(\s*40[13]|sendUnauthorizedPage")


def _elements():
    """Every element this repository owns, as (name, kind, source). The FILES are the elements —
    the same bytes that are loaded into the database columns by apply-modx-elements.sh."""
    out = []
    for kind, sub in (("snippet", "snippets"), ("plugin", "plugins")):
        d = os.path.join(COMMON, sub)
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if fn.endswith(".events"):          # a plugin's event binding, not its body
                continue
            name = fn[:-4] if fn.endswith(".php") else fn
            with open(os.path.join(d, fn), encoding="utf-8", errors="replace") as fh:
                out.append((name, kind, fh.read()))
    return out


def _served_at(dsn):
    """Which resource URIs invoke each element, read from a MODx database. The estate answering for
    itself. Returns {} when no database is given — never a guess."""
    if not dsn:
        return {}
    import urllib.parse
    import pymysql                                     # only needed on the --db path
    u = urllib.parse.urlparse(dsn)
    conn = pymysql.connect(host=u.hostname or "127.0.0.1", port=u.port or 3306,
                           user=urllib.parse.unquote(u.username or ""),
                           # pragma: allowlist secret — the parsed DSN's own field, never a value
                           password=urllib.parse.unquote(u.password or ""),  # pragma: allowlist secret
                           database=(u.path or "/modx").lstrip("/"))
    served = {}
    with conn.cursor() as cur:
        cur.execute("SELECT context_key, uri, content FROM modx_site_content WHERE published = 1")
        for ctx, uri, content in cur.fetchall():
            for m in re.finditer(r"\[\[!?([A-Za-z_][A-Za-z0-9_]*)", content or ""):
                served.setdefault(m.group(1), set()).add(f"{ctx}:/{uri or ''}")
    conn.close()
    return {k: sorted(v) for k, v in served.items()}


def listing(dsn=None):
    served = _served_at(dsn)
    rows, undeclared_open = [], []
    for name, kind, src in _elements():
        refuses = bool(_REFUSES.search(src))
        doors = sorted({d for call, d in GUARDS.items()
                        if _CALL[call].search(src)} ) if refuses else []
        if doors:
            door = " + ".join(doors)
        else:
            why = OPEN_REASONS.get(name)
            door = f"open:{why}" if why else "open:UNDECLARED"
            if not why:
                undeclared_open.append(name)
        rows.append({"path": name, "kind": kind,
                     "methods": ["GET"] if kind == "snippet" else ["EVENT"],
                     "served_at": served.get(name, "estate-bound" if dsn is None else []),
                     "door": door, "guarded": bool(doors)})
    rows.sort(key=lambda x: x["path"])
    stale = [n for n in OPEN_REASONS if n not in {r["path"] for r in rows}]
    return {"service": "modx", "routes": rows, "count": len(rows),
            "guarded": sum(1 for r in rows if r["guarded"]),
            "undeclared_open": undeclared_open, "stale_reasons": stale}


def main():
    ap = argparse.ArgumentParser(description="modx: every door and who may call it (rule 21)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--check", action="store_true",
                    help="exit 1 on an open door with no reason, or a reason with no element")
    ap.add_argument("--db", default=os.environ.get("MODX_DOORS_DSN"),
                    help="mysql://USER:PASSWORD@host/db — resolve where each element is served")  # pragma: allowlist secret
    a = ap.parse_args()
    d = listing(a.db)
    if a.json:
        print(json.dumps(d, indent=2))
    else:
        for r in d["routes"]:
            at = r["served_at"]
            at = at if isinstance(at, str) else (", ".join(at) if at else "not on any published page")
            print(f"  {r['kind']:8s} {r['path']:22s} {r['door']}")
            print(f"           {'':22s} served at: {at}")
        print(f"\n{d['count']} element(s); {d['guarded']} guarded, "
              f"{d['count'] - d['guarded']} open")
    if a.check:
        bad = False
        for p in d["undeclared_open"]:
            print(f"FAIL: {p} establishes no caller and no reason is declared for it. An open door "
                  f"is lawful; an UNEXPLAINED one is what an audit flags. Add it to "
                  f"OPEN_REASONS with why.", file=sys.stderr)
            bad = True
        for p in d["stale_reasons"]:
            print(f"FAIL: a reason is declared for {p} and no such element exists — the listing "
                  f"describes a door that is not there.", file=sys.stderr)
            bad = True
        if bad:
            return 1
        print("check: every element is either guarded or open with a stated reason.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
