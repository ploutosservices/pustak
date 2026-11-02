#!/usr/bin/env python3
"""widest-group-derives — the group that may enter EVERY context is derived, not hand-listed.

THE DEFECT THIS CLOSES. `estate.json` named `allContextMember`'s contexts literally:

    "allContextMember": [["family", "corporate", "worldview", "claude"], ["alice"]]

beside `domains.contexts`, which listed the same four. So a fifth context could be declared,
installed, and served, and the one group that is supposed to see everything would not cover it —
until somebody remembered to edit a second place. There was no field to ask and no check that could
go red: both lists were well-formed, and MODx would happily grant three contexts to a group whose
name promises all of them. That is the estate's recurring shape — a hand-kept copy of a fact that
has an owner elsewhere — and it was mine.

WHAT IS ASSERTED:
  - a group whose contexts are the single token `*` covers every context `domains.contexts`
    declares;
  - ADDING a context to `domains.contexts` widens that group with NO edit to `groups` — the
    property the fix exists for, and the one a hand-listed group fails;
  - an explicit list is still honoured exactly, so a group meant to see one site keeps seeing one;
  - `*` beside a named context REFUSES at import, because one of the two would be silently
    ignored;
  - `*` with no declared contexts REFUSES, rather than granting a group nothing under a name that
    says everything.

A known-answer control runs first. Reads only: this stands up no database.

    python3 tests/widest-group-derives.py
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

PASS = 0
FAIL = 0


def check(ok, label, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  ok    {label}")
    else:
        FAIL += 1
        print(f"  FAIL  {label}")
        if detail:
            print(f"        {detail}")


def groups_for(declared_contexts, groups_block):
    """Import setup/estate against a throwaway estate file and return (rc, GROUPS, stderr).

    A SUBPROCESS PER CASE: `estate.py` reads MODX_ESTATE at import time and caches it, so re-importing in one process would keep the first
    estate and the test would assert many times about one file while appearing to cover many.
    """
    contexts = {c: {"name": c.title(), "description": "", "rank": 2 + i,
                    "site_name": c.title(), "protected": True, "home": "home"}
                for i, c in enumerate(declared_contexts)}
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "estate.json"
        p.write_text(json.dumps({
            "web_context": {"name": "Web", "description": "", "rank": 1, "site_name": "T"},
            "contexts": contexts,
            "admin_username": "t",
            "users": [], "groups": groups_block, "system_settings": {},
            "domains": {"contexts": list(declared_contexts)},
        }))
        code = ("import sys, json; sys.path.insert(0, %r); import estate; "
                "print(json.dumps({k: v[0] for k, v in estate.GROUPS.items()}))"
                % str(REPO / "setup"))
        r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                           env={**os.environ, "MODX_ESTATE": str(p)})
        out = json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None
        return r.returncode, out, (r.stderr or "").strip()


print("widest-group-derives — the widest group follows the estate's own context list\n")

FOUR = ["family", "corporate", "worldview", "platform"]
FIVE = FOUR + ["newtenant"]

# ── control ────────────────────────────────────────────────────────────────────────────────────
rc, got, err = groups_for(FOUR, {"oneSite": [["corporate"], []]})
check(rc == 0 and got is not None, "control: the harness can import estate at all", err)
check(got == {"oneSite": ["corporate"]},
      "control: an explicit list is returned exactly as written", json.dumps(got))

# ── `*` covers every declared context ──────────────────────────────────────────────────────────
rc, got, err = groups_for(FOUR, {"allContextMember": [["*"], ["alice"]]})
check(rc == 0 and got == {"allContextMember": FOUR},
      "`*` covers every context domains.contexts declares", json.dumps(got) or err)

# ── THE DONE: a context added to the list widens the group with no edit to `groups` ────────────
rc, got, err = groups_for(FIVE, {"allContextMember": [["*"], ["alice"]]})
check(rc == 0 and got == {"allContextMember": FIVE},
      "a context ADDED to the list appears in the widest group, groups untouched",
      json.dumps(got) or err)

# ── an explicit list does NOT widen, which is what makes the token mean something ──────────────
rc, got, err = groups_for(FIVE, {"allContextMember": [FOUR, ["alice"]]})
check(rc == 0 and got == {"allContextMember": FOUR},
      "an explicit list stays narrow when the estate grows — the failing shape, kept visible",
      json.dumps(got) or err)

# ── `*` beside a name refuses ──────────────────────────────────────────────────────────────────
rc, got, err = groups_for(FOUR, {"mixed": [["*", "corporate"], []]})
check(rc != 0 and "never both" in err,
      "`*` beside a named context REFUSES at import", f"rc={rc} {err[:160]}")

# ── `*` with nothing declared refuses ──────────────────────────────────────────────────────────
rc, got, err = groups_for([], {"allContextMember": [["*"], []]})
check(rc != 0 and "granted NOTHING" in err,
      "`*` with no declared contexts REFUSES rather than granting nothing",
      f"rc={rc} {err[:160]}")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
