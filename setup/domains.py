#!/usr/bin/env python3
"""
domains — the estate's list of contexts, and the MODx database connection.

It no longer holds a host name. Which name a context answers to is infra's (claude-shared
design/modx-names-from-infra-skunkworks.md): config scripts/modx-environment.py derives each
installation's http_host and site_url from placement and tenants.yaml, the installation's
core/config/application.php carries them, and setup/apply-environment.php writes and checks them.
The prod and bench maps this module held, and the four scripts that bound and verified them, went
with that move.
"""
import os

from estate import DOMAINS

# Every context this estate serves. A context may be absent on an older pull — consumers skip
# contexts that do not exist in modx_context rather than creating them.
CONTEXTS = list(DOMAINS.get('contexts') or [])


def _socket_kwargs():
    """`{'unix_socket': path}` when MODX_DB_SOCKET names one, else `{}`.

    THE ONE DIFFERENCE BETWEEN A DEV BOX AND EVERY OTHER GROUND, and it is not a preference.
    dev-box.yml grants `skunkworks`@localhost on `modx`.* through MariaDB's unix_socket plugin,
    which decides who you are from the OS user on the far end of the socket and carries no
    secret at all. The `mysql` CLI finds that socket from host=localhost by itself. **pymysql does
    not** — it reads localhost as TCP 127.0.0.1, where the plugin cannot see the caller, and the
    answer is `(1698, "Access denied for user 'skunkworks'@'localhost'")`.

    So every python consumer of db_config() fails on a box using the grant the estate itself
    issued, and fails with an error that says ACCESS when the fault is ROUTE — which sends the
    reader to check privileges that are already correct. The bench's domain binder died exactly there on
    the first build of the devbox-fl bench.

    Opt-in and additive: unset, this returns `{}` and no existing ground moves by a byte. It
    chooses the transport only — MODX_DB_PASS is still required above and still travels, so a
    ground that authenticates by secret over a socket keeps working.
    """
    path = os.environ.get('MODX_DB_SOCKET')
    return {'unix_socket': path} if path else {}


def db_config():
    """
    MODx DB connection kwargs, from the environment. NO DEFAULTS for the credentials.

    They used to be a user and password, inline, in this function and repeated through ten scripts —
    a working password in source, in a repository about to be published. A default credential also
    decides what silence means: an unset MODX_DB_PASS would silently try somebody's dev password
    against whatever database it could reach. Refusing names the missing variable instead.
    """
    # SOCKET AUTHENTICATION NEEDS NO CREDENTIAL, AND DEMANDING ONE LOCKED EVERYBODY OUT.
    #
    # On a dev box the bench's MariaDB accounts use the **unix_socket** plugin: the OS user at the
    # far end of the socket IS the identity and there is no secret at all. The guard below demanded
    # MODX_DB_USER and MODX_DB_PASS anyway, so every caller had to supply a name and a password —
    # and `ops.sh restore_modx_dev` supplied them from the bench's own config.inc.php, which names
    # whoever installed the bench. Measured 2026-09-12 running it as `infra`:
    #
    #     pymysql.err.OperationalError: (1698, "Access denied for user 'skunkworks'@'localhost'")
    #     FAILED: bench-domains.py failed — bench left on prod domains, run it by hand
    #
    # It failed for every caller including skunkworks, because a password login against a
    # unix_socket account is refused whoever makes it. The owner, 2026-09-12: *"you have to fix
    # restore_modx_dev to work for everyone. no? othewrise nobody can edit modx."* ops.sh was fixed
    # the same evening; this is the other half — a suite or script that calls db_config() DIRECTLY
    # hits the same wall and gets the same misleading "Access denied", which sends the reader to
    # check privileges that are already correct.
    #
    # THE GUARD IS NOT WEAKENED, and that matters because of what it is for: a default credential
    # turns an unset variable into a silent connection attempt with somebody's dev password. There
    # is still NO default credential here. What is allowed is the case where no credential exists
    # to default to — MODX_DB_SOCKET names a socket, so the server authenticates by the OS user and
    # never reads a password. The user still defaults to nobody's guess: it is this process's own
    # OS user, which is the only identity the server will accept over that socket anyway.
    sock = os.environ.get('MODX_DB_SOCKET')
    if sock and not os.environ.get('MODX_DB_USER'):
        import getpass
        return dict(host=os.environ.get('MODX_DB_HOST', 'localhost'),
                    user=getpass.getuser(),
                    password='',
                    database=os.environ.get('MODX_DB_NAME', 'modx'),
                    charset='utf8mb4',
                    unix_socket=sock)
    missing = [k for k in ('MODX_DB_USER', 'MODX_DB_PASS') if not os.environ.get(k)]
    if missing:
        raise SystemExit(
            f"domains: {', '.join(missing)} not set. There is no default — a database credential "
            f"in source is a published credential, and a default one turns an unset variable into "
            f"a silent connection attempt. (If this database authenticates by unix_socket, set "
            f"MODX_DB_SOCKET instead and leave both of these unset: the OS user is the identity "
            f"and there is no password to supply.)"
        )
    return dict(host=os.environ.get('MODX_DB_HOST', 'localhost'),
                user=os.environ['MODX_DB_USER'],
                password=os.environ['MODX_DB_PASS'],
                database=os.environ.get('MODX_DB_NAME', 'modx'),
                charset='utf8mb4',
                **_socket_kwargs())
