#!/usr/bin/env python3
"""settings-guard — proves setup/settings_guard.py refuses a pass that empties a setting.

Three times in one day a setup pass cleared settings nobody asked it to touch, and every one was
found by a person or an agent stumbling into it rather than by the pass reporting anything. The
guard is the answer; this is the proof it works, and it is the half that matters, because a guard
nobody has watched go red is a decoration.

IT RUNS ON A DEV BOX, deliberately. Ten of this repository's twenty suites refuse for want of a
bench and that refusal is correct — "could not check" and "checked, and it is fine" are
different answers. But a guard proven only where infra has not built the ground yet is a guard
proven nowhere. This one can be proven honestly here, because it needs a database with two tables
in it, not a MODx.

WHICH ENGINE, AND IT SAYS SO IN ITS OWN OUTPUT. By default it builds the two tables in a private
sqlite file and drops it. That is not the engine the passes use, so the difference is printed on
every run rather than buried here: what the guard executes is two plain SELECTs and a rollback,
which both engines implement identically, but nobody should have to read this file to know which
one a green line came from. Point it at the real thing to remove the gap:

    MODX_DRILL_DSN='mysql://user@/schema?unix_socket=/var/run/mysqld/mysqld.sock'  python3 tests/settings-guard.py

On this dev box that is not possible today and the reason is not a defect in the drill: the account
holds no CREATE grant (the box is infra's), so there is no schema it may build tables
in. On the staging ground infra was asked for, there is.

EVERY DRILL IS A REAL PASS: it opens a connection, writes through it, and ends at the guard. The
guard is never handed a hand-made dictionary — that would prove the comparison and not the thing
the passes actually do.
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "setup"))
import settings_guard                                                        # noqa: E402

PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  ok    {msg}")


def bad(msg, detail=""):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {msg}")
    for line in str(detail).splitlines():
        print(f"        {line}")


SCHEMA = [
    """CREATE TABLE modx_context_setting (
         context_key varchar(100) NOT NULL, `key` varchar(50) NOT NULL,
         value text, xtype varchar(75) NOT NULL DEFAULT 'textfield',
         PRIMARY KEY (context_key,`key`))""",
    """CREATE TABLE modx_system_settings (
         `key` varchar(50) NOT NULL, value text,
         xtype varchar(75) NOT NULL DEFAULT 'textfield',
         PRIMARY KEY (`key`))""",
]

SEED = [
    ("family", "sso.provider", "oidc"), ("family", "http_host", "family.modx.internal.test"),
    ("family", "login_page", "1500"), ("family", "unauthorized_page", "1579"),
    ("worldview", "sso.provider", "oidc"), ("worldview", "http_host", "worldview.modx.internal.test"),
    ("claude", "sso.provider", "oidc"), ("claude", "site_url", "https://claude.modx.internal.test/"),
]
SEED_SYS = [("sso.issuer", "https://door.app.internal.test/realms/dev"),
            ("sso.auth_endpoint", "https://door.app.internal.test/realms/dev/protocol/openid-connect/auth")]


class Sqlite:
    """A private file, dropped at the end. Nothing it touches belongs to anybody."""

    engine = "sqlite3 (NOT the engine the passes use — see the header)"

    def __init__(self):
        import sqlite3
        self._path = tempfile.mktemp(suffix=".settings-guard-drill.sqlite")
        self._mod = sqlite3
        self._mk()

    def _mk(self):
        conn = self._mod.connect(self._path)
        cur = conn.cursor()
        for stmt in SCHEMA:
            cur.execute(stmt.replace("varchar", "text").replace("(100)", "").replace("(50)", "")
                        .replace("(75)", ""))
        conn.commit()
        conn.close()

    def connect(self):
        conn = self._mod.connect(self._path)
        conn.isolation_level = ""            # explicit transactions, so rollback means something
        return conn

    def drop(self):
        try:
            os.unlink(self._path)
        except FileNotFoundError:
            pass


class MySQL:
    engine = "MySQL — the engine the passes use"

    def __init__(self, dsn):
        import urllib.parse

        import pymysql
        u = urllib.parse.urlparse(dsn)
        q = dict(urllib.parse.parse_qsl(u.query))
        self._kw = dict(user=u.username or os.environ.get("USER"), database=u.path.lstrip("/"),
                        charset="utf8mb4")
        if u.password:
            self._kw["password"] = u.password
        if q.get("unix_socket"):
            self._kw["unix_socket"] = q["unix_socket"]
        else:
            self._kw["host"] = u.hostname or "127.0.0.1"
            if u.port:
                self._kw["port"] = u.port
        self._mod = pymysql
        self._mk()

    def _mk(self):
        conn = self._mod.connect(**self._kw)
        cur = conn.cursor()
        cur.execute("DROP TABLE IF EXISTS modx_context_setting")
        cur.execute("DROP TABLE IF EXISTS modx_system_settings")
        for stmt in SCHEMA:
            cur.execute(stmt + " ENGINE=InnoDB")
        conn.commit()
        conn.close()

    def connect(self):
        return self._mod.connect(**self._kw)

    def drop(self):
        conn = self._mod.connect(**self._kw)
        cur = conn.cursor()
        cur.execute("DROP TABLE IF EXISTS modx_context_setting")
        cur.execute("DROP TABLE IF EXISTS modx_system_settings")
        conn.commit()
        conn.close()


def q(sql, engine_is_sqlite):
    return sql.replace("%s", "?") if engine_is_sqlite else sql


def seed(ground):
    conn = ground.connect()
    cur = conn.cursor()
    lite = isinstance(ground, Sqlite)
    for ctx, key, val in SEED:
        cur.execute(q("INSERT INTO modx_context_setting (context_key,`key`,value) "
                      "VALUES (%s,%s,%s)", lite), (ctx, key, val))
    for key, val in SEED_SYS:
        cur.execute(q("INSERT INTO modx_system_settings (`key`,value) VALUES (%s,%s)", lite),
                    (key, val))
    conn.commit()
    conn.close()


def reset(ground):
    conn = ground.connect()
    cur = conn.cursor()
    cur.execute("DELETE FROM modx_context_setting")
    cur.execute("DELETE FROM modx_system_settings")
    conn.commit()
    conn.close()
    seed(ground)


def run_pass(ground, body, allow=None):
    """A real pass: connect, write, end at the guard. Returns (committed, printed output)."""
    import contextlib
    import io
    conn = ground.connect()
    cur = conn.cursor()
    g = settings_guard.start(conn, "drill")
    if allow:
        g.allow(*allow)
    buf = io.StringIO()
    committed = False
    try:
        with contextlib.redirect_stdout(buf):
            body(cur)
            g.commit()
        committed = True
    except SystemExit:
        committed = False
    finally:
        conn.close()
    return committed, buf.getvalue()


def value_of(ground, ctx, key):
    conn = ground.connect()
    cur = conn.cursor()
    cur.execute(q("SELECT value FROM modx_context_setting WHERE context_key=%s AND `key`=%s",
                  isinstance(ground, Sqlite)), (ctx, key))
    row = cur.fetchone()
    conn.close()
    return None if row is None else row[0]


def count_sso(ground):
    conn = ground.connect()
    cur = conn.cursor()
    cur.execute("SELECT COUNT(*) FROM modx_context_setting WHERE `key`='sso.provider' "
                "AND context_key IN ('family','worldview')")
    n = cur.fetchone()[0]
    conn.close()
    return n


# Every pass in this repository that writes a context or system setting. It is a LITERAL list, and
# that is deliberate: deriving it by grepping for the table name would quietly shrink the moment
# somebody wrapped a write in a helper, and a check that decides its own scope can always decide
# it is finished. Adding a pass here is a deliberate act; so is removing one, and removing one
# without removing the pass is the thing this is watching for.
GUARDED_PASSES = ["11-add-context.py", "12-sso.py"]

SETUP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "setup")


def wired():
    """Every guarded pass must END at the guard, not at a bare conn.commit()."""
    for name in GUARDED_PASSES:
        path = os.path.join(SETUP, name)
        if not os.path.exists(path):
            bad(f"{name} is in the guarded list and is not on disk",
                "this check cannot say anything about a file that is not there")
            continue
        src = open(path, encoding="utf-8").read()
        # Comments stripped, so the explanatory block above each call is not what satisfies this.
        code = "\n".join(ln.split("#")[0] for ln in src.splitlines())
        if "settings_guard.start(" not in code:
            bad(f"{name} writes settings and never starts the guard")
            continue
        if "conn.commit()" in code:
            bad(f"{name} still ends at a bare conn.commit()",
                "the guard only refuses what it is asked to commit — a direct commit walks past it")
            continue
        if "g.commit()" not in code:
            bad(f"{name} starts the guard and never commits through it",
                "the pass would write nothing at all")
            continue
        ok(f"wiring: {name} commits through the guard")


def main():
    dsn = os.environ.get("MODX_DRILL_DSN")
    try:
        ground = MySQL(dsn) if dsn else Sqlite()
    except Exception as exc:                                              # noqa: BLE001
        print(f"REFUSING: could not build the drill ground ({type(exc).__name__}: {exc}).\n"
              f"          No assertion below has run — this is a statement about the shell,\n"
              f"          not about the tree.")
        return 2

    print("settings-guard — a pass that empties a setting must not be able to commit it")
    print(f"  ground: {ground.engine}\n")
    seed(ground)
    lite = isinstance(ground, Sqlite)

    try:
        # 1. the honest pass: adds one setting, changes another, loses nothing
        def honest(cur):
            cur.execute("UPDATE modx_context_setting SET value='google' "
                        "WHERE context_key='claude' AND `key`='sso.provider'")
            cur.execute("INSERT INTO modx_context_setting (context_key,`key`,value) "
                        "VALUES ('corporate','sso.provider','oidc')")
        done, out = run_pass(ground, honest)
        if done:
            ok("a pass that adds and changes settings commits — neither is a loss")
        else:
            bad("the guard refused an honest pass", out)
        if value_of(ground, "claude", "sso.provider") == "google":
            ok("and the change it made is committed (claude sso.provider = google)")
        else:
            bad("the honest pass's write did not land",
                f"value is {value_of(ground, 'claude', 'sso.provider')!r}")
        reset(ground)

        # 2. THE INCIDENT: a pass deletes the SSO settings and says nothing
        def wipe_sso(cur):
            cur.execute("DELETE FROM modx_context_setting WHERE `key`='sso.provider' "
                        "AND context_key IN ('family','worldview')")
        done, out = run_pass(ground, wipe_sso)
        if done:
            bad("a pass DELETED two sso.provider rows and the guard let it commit", out)
        else:
            ok("a pass that deletes sso.provider is refused")
            for line in out.splitlines():
                if "REFUSING" in line or "row deleted" in line:
                    print(f"          {line.strip()}")
        if count_sso(ground) == 2:
            ok("and NOTHING WAS WRITTEN: both rows are still there, the estate is as it was")
        else:
            bad(f"refused, but only {count_sso(ground)} of 2 rows survived",
                "a guard that reports a loss it has already written is a louder version of the "
                "problem — somebody still repairs it by hand, which is what happened all three times")
        reset(ground)

        # 2b. AND IT ROLLED BACK EXPLICITLY — which the check above cannot tell you.
        #
        # This check was written first as part of 2 and it was a check that lies: an uncommitted
        # transaction is discarded when the connection closes, so "both rows are still there"
        # passes whether or not the guard rolls anything back. Proven by mutation: deleting the
        # rollback() call left the suite 9/9 green. It is a separate drill now, and it watches the
        # call rather than the outcome — the outcome is the same either way, which is precisely
        # why the first version of this could not see it.
        #
        # It matters because sys.exit(1) is not the only way out. A caller that catches SystemExit,
        # or the `with` form, keeps the connection — and there the difference between rolled-back
        # and merely-uncommitted is the difference between a clean session and a poisoned one.
        class Spy:
            def __init__(self, real):
                self._real, self.rollbacks, self.commits = real, 0, 0

            def cursor(self):
                return self._real.cursor()

            def rollback(self):
                self.rollbacks += 1
                self._real.rollback()

            def commit(self):
                self.commits += 1
                self._real.commit()

        real = ground.connect()
        spy = Spy(real)
        g = settings_guard.start(spy, "drill-rollback")
        spy.cursor().execute("DELETE FROM modx_context_setting WHERE `key`='sso.provider'")
        try:
            import contextlib
            import io
            with contextlib.redirect_stdout(io.StringIO()):
                g.commit()
        except SystemExit:
            pass
        real.close()
        if spy.rollbacks == 1 and spy.commits == 0:
            ok("and it called rollback() explicitly, and never commit() (1 rollback, 0 commits)")
        else:
            bad(f"the guard refused without rolling back "
                f"({spy.rollbacks} rollback(s), {spy.commits} commit(s))",
                "an uncommitted transaction is discarded at close, so the estate survives either "
                "way — but a caller that keeps the connection is left holding the deletion")
        reset(ground)

        # 3. emptied, not deleted — the shape the outward-facing settings took
        def empty_hosts(cur):
            cur.execute("UPDATE modx_context_setting SET value='' WHERE `key`='http_host'")
        done, out = run_pass(ground, empty_hosts)
        if done:
            bad("a pass emptied every http_host and the guard let it commit", out)
        else:
            ok("a pass that empties a value without deleting the row is refused")
        reset(ground)

        # 4. system settings are watched too, not only context settings
        def drop_issuer(cur):
            cur.execute("DELETE FROM modx_system_settings WHERE `key`='sso.issuer'")
        done, out = run_pass(ground, drop_issuer)
        if done:
            bad("a pass deleted a SYSTEM setting and the guard let it commit", out)
        else:
            ok("a system setting is watched too (sso.issuer)")
        reset(ground)

        # 5. a DECLARED removal goes through — or the guard becomes a thing people route around
        def drop_declared(cur):
            cur.execute("DELETE FROM modx_context_setting WHERE context_key='family' "
                        "AND `key`='login_page'")
        done, out = run_pass(ground, drop_declared, allow=("context", "family", "login_page"))
        if done:
            ok("a removal the pass DECLARES is allowed through")
        else:
            bad("a declared removal was refused — the guard is unusable and will be disabled", out)
        reset(ground)

        # 6. the control: without it, every ok above is consistent with a guard that refuses all
        done, out = run_pass(ground, lambda cur: None)
        if done:
            ok("control: a pass that changes nothing commits — it is not refusing everything")
        else:
            bad("control: the guard refused a pass that did nothing", out)

        # 7. the second control: a photograph of an empty schema finds no losses, ever
        conn = ground.connect()
        seen = len(settings_guard.photograph(conn))
        conn.close()
        if seen >= 10:
            ok(f"control: the guard photographed {seen} settings rows before any pass ran")
        else:
            bad(f"control: the guard saw only {seen} rows — it is not reading the tables",
                "green over an empty haystack is worse than red")

        # 8. THE WIRING, and it is the half that rots. Everything above proves the guard works;
        # none of it proves a pass uses it. A pass that writes settings and ends at a bare
        # conn.commit() is exactly the state this repository was in this morning, and nothing
        # would have said so.
        wired()
    finally:
        ground.drop()

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
