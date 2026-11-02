#!/usr/bin/env python3
"""bench-open-reading — let an anonymous visitor READ a bench, and put it back.

WHY THIS EXISTS, stated plainly because it removes a protection.

A bench reached at `localhost:<port>` over an ssh forward has no way to sign anyone in: the door's
client for a context names the context's own address as its callback, and localhost is not it. So
the front-end `sso-login` answers "Single
sign-on is not configured", and every page carrying page protection returns the unauthorized page
instead of itself. The owner, 2026-08-20, opening the bench: *"not delivering anything on 8314"*. He
was right: a reviewing surface that can show four anonymous pages out of 1,545 is not one.

WHAT IT CHANGES. Exactly one thing, and only for resource groups you name: the ANONYMOUS
principal (user group 0) is moved from `Load Only` to `Load, List and View` on that group. No
user is created, no password exists, no policy is edited, no resource moves, and the group's other
grants are untouched — so a signed-in reader sees precisely what they saw before.

WHAT IT COSTS, and this is the half a caller must not skip: a bench in this state NO LONGER PROVES
THAT PROTECTION WORKS. That is one of the two things a bench is for. So it prints what it did in
words, it is reversible in one command, and `--check` will tell you which state a bench is in
before you trust a protection result measured on it.

**BENCH ONLY, mechanically.** It refuses unless the context's `site_url` names a loopback address:
a ground reachable by anyone else must never be opened this way, and asking the caller to be
careful is not a check. Production and staging both fail that test by construction.

    setup/bench-open-reading.py --check
    setup/bench-open-reading.py --open  --groups allContextProtected,worldviewProtectedFiles
    setup/bench-open-reading.py --close --groups allContextProtected,worldviewProtectedFiles
"""
import argparse
import os
import sys

import pymysql

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import domains  # noqa: E402

ANONYMOUS = 0
LOAD_ONLY = 'Load Only'
LOAD_LIST_VIEW = 'Load, List and View'
LOOPBACK = ('localhost', '127.0.0.1', '[::1]')


def loopback_only(cur):
    """Every context's site_url must point at loopback, or this is not a bench.

    The guard is the GROUND, not a flag the caller passes: `--i-know-what-im-doing` is a flag
    somebody eventually passes on the wrong box. A site_url naming a routable host means somebody
    other than the person at the keyboard can reach what this would open.
    """
    cur.execute("SELECT context_key, value FROM modx_context_setting WHERE `key` = 'site_url'")
    rows = cur.fetchall()
    if not rows:
        return False, "no context declares a site_url — refusing to guess what this ground is"
    bad = [f"{ctx}={url}" for ctx, url in rows
           if not any(f'//{h}' in (url or '') for h in LOOPBACK)]
    if bad:
        return False, "these contexts are NOT on loopback: " + ', '.join(bad)
    return True, f"{len(rows)} context(s), every site_url on loopback"


def policy_ids(cur):
    cur.execute("SELECT id, name FROM modx_access_policies WHERE name IN (%s, %s)",
                (LOAD_ONLY, LOAD_LIST_VIEW))
    by_name = {name: pid for pid, name in cur.fetchall()}
    for want in (LOAD_ONLY, LOAD_LIST_VIEW):
        if want not in by_name:
            raise SystemExit(f"bench-open-reading: this MODx has no '{want}' policy — refusing to "
                             f"invent one. Nothing changed.")
    return by_name[LOAD_ONLY], by_name[LOAD_LIST_VIEW]


def group_rows(cur, names):
    cur.execute("SELECT id, name FROM modx_documentgroup_names")
    known = {name: gid for gid, name in cur.fetchall()}
    missing = [n for n in names if n not in known]
    if missing:
        raise SystemExit(f"bench-open-reading: no resource group named {missing} on this ground. "
                         f"Known: {sorted(known)}. Nothing changed.")
    return [(known[n], n) for n in names]


def report(cur, load_only, view):
    cur.execute("""SELECT g.name, a.policy FROM modx_access_resource_groups a
                   JOIN modx_documentgroup_names g ON g.id = a.target
                   WHERE a.principal = %s ORDER BY g.name""", (ANONYMOUS,))
    rows = cur.fetchall()
    if not rows:
        print("  anonymous holds no grant on any resource group")
    for name, pol in rows:
        state = 'OPEN  (Load, List and View)' if pol == view else \
                'closed (Load Only)' if pol == load_only else f'policy {pol}'
        print(f"  {name:32} {state}")
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', action='store_true')
    mode.add_argument('--open', action='store_true')
    mode.add_argument('--close', action='store_true')
    ap.add_argument('--groups', help='comma-separated resource group names')
    a = ap.parse_args()

    conn = pymysql.connect(**domains.db_config())
    cur = conn.cursor()

    ok, why = loopback_only(cur)
    print(f"ground: {why}")
    if not ok and not a.check:
        raise SystemExit("bench-open-reading: REFUSING — this is not a loopback bench. "
                         "Nothing changed.")

    load_only, view = policy_ids(cur)

    if a.check:
        print("anonymous read state:")
        report(cur, load_only, view)
        return 0

    if not a.groups:
        raise SystemExit("bench-open-reading: --groups is required — name the resource groups "
                         "rather than opening whatever exists.")
    names = [n.strip() for n in a.groups.split(',') if n.strip()]
    targets = group_rows(cur, names)
    want = view if a.open else load_only

    changed = 0
    for gid, name in targets:
        cur.execute("""SELECT id, policy FROM modx_access_resource_groups
                       WHERE principal = %s AND target = %s""", (ANONYMOUS, gid))
        existing = cur.fetchall()
        if not existing:
            cur.execute("""INSERT INTO modx_access_resource_groups
                           (target, principal_class, principal, authority, policy, context_key)
                           VALUES (%s, 'MODX\\\\Revolution\\\\modUserGroup', %s, 9999, %s, '')""",
                        (gid, ANONYMOUS, want))
            changed += 1
            print(f"  {name}: grant CREATED -> {'open' if a.open else 'closed'}")
            continue
        for rid, pol in existing:
            if pol == want:
                print(f"  {name}: already {'open' if a.open else 'closed'}")
                continue
            cur.execute("UPDATE modx_access_resource_groups SET policy = %s WHERE id = %s",
                        (want, rid))
            changed += 1
            print(f"  {name}: policy {pol} -> {want} ({'OPENED' if a.open else 'closed'})")

    conn.commit()
    print(f"\n{changed} grant(s) changed.")
    if a.open and changed:
        print("THIS BENCH NO LONGER PROVES THAT PROTECTION WORKS. Anyone who can reach the port\n"
              "reads every page in the named groups. Put it back with --close before measuring\n"
              "anything about access, and clear the MODx cache either way.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
