#!/usr/bin/env python3
"""Render a development bench's core/config/application.php (docs/apply-environment.md).

Infra's modx-web role renders this file for the installations it runs; a bench on a dev box has no
writer, so this is it. It keeps every key the file already holds and replaces two:
`environment` ('development') and `settings`, which setup/apply-environment.php then writes.

    MODX_ROOT=<bench docroot> MODX_ESTATE=<modx-estate>/estate.json \\
        python3 setup/bench-application.py [--dry-run]

What it declares, and from where:
  infra's  everything infra's config scripts/modx-environment.py --env dev --machine <this box> prints:
           each context's http_host, site_url and sign-in rows, and the system keys whose dev
           values the declarations hold (kuber, Munshi, storage, census, whois, privacy, the door).
           MODx types no host name of its own.
  the bench's own  estate_env, error_log_filepath (from MODX_ROOT), new_folder/new_file_permissions
           (law 2.5: the bench is every agent's), estate.tenant_apps_file, modxsearch.ask_url (the
           bench's own modxsearch-local, which infra leaves out on dev), estate_env_color when
           ESTATE_ENV_COLOR is set (infra's colour row); per context base_url '/' and session_name,
           one cookie per context.
One setup on every environment (the owner's ruling: every environment uses the setup codified in
pustak): nginx sets X-Tenant and serves each context by its name. This file goes when infra's
renderer writes development's application.php too.
"""
import argparse
import json
import os
import re
import socket
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import domains  # noqa: E402

# The bench's own estate search: pm2 modxsearch-local on modxsearch's registered dev number (config
# scripts/ports.yaml, devbox env dev, 8305, reached_by direct). Infra's script leaves the key out on dev
# (the bench row declares no name), and unmanaged the setting keeps whatever a restore brought —
# production's search service, which refuses a bench reader's token (measured 2026-10-13: "sign in first").
BENCH_MODXSEARCH_ASK = 'http://127.0.0.1:8305/v1/ask'
# Infra's derivation, in the config checkout beside this one.
CONFIG = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), 'config')
DERIVE = os.path.join(CONFIG, 'scripts', 'modx-environment.py')


def derived():
    """Infra's values for THIS machine's installation (modx-environment.py --env dev --machine <it>):
    every context's names and sign-in rows, and the system keys the declarations hold dev values for."""
    machine = socket.gethostname().split('.')[0]
    r = subprocess.run([sys.executable, DERIVE, '--env', 'dev', '--machine', machine],
                       capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"REFUSED: {DERIVE} --env dev --machine {machine} exited {r.returncode}: "
                         f"{r.stderr.strip()}. Nothing was written.")
    out = json.loads(r.stdout)
    missing = [c for c in domains.CONTEXTS if c not in out.get('contexts', {})]
    if missing:
        raise SystemExit(f"REFUSED: infra's derivation names no {missing} on {machine}. Nothing was written.")
    return out


def sign_in():
    """[issuer, OpenBao address, 'ctx,ctx,…'] for the bench's sign-in: the issuer and the contexts
    holding a door client from infra's derivation, the dev OpenBao from config scripts/ports.yaml
    (the one service: openbao, env: dev row with a name). Refuses on none or two."""
    import yaml
    d = derived()
    issuer = (d.get('system') or {}).get('sso.issuer')
    if not issuer:
        raise SystemExit("REFUSED: infra's derivation names no sso.issuer for this box.")
    ctxs = [c for c, v in d['contexts'].items() if v.get('sso.oidc_client_id')]
    rows = []
    def walk(n):
        if isinstance(n, dict):
            if n.get('service') == 'openbao' and n.get('env') == 'dev' and n.get('name') and n.get('port'):
                rows.append(f"https://{n['name']}:{n['port']}")
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)
    walk(yaml.safe_load(open(os.path.join(CONFIG, 'scripts', 'ports.yaml'))))
    if len(set(rows)) != 1:
        raise SystemExit(f"REFUSED: config scripts/ports.yaml gives {sorted(set(rows)) or 'no'} dev OpenBao, not one.")
    return [issuer, rows[0], ','.join(ctxs)]


def php_str(s):
    return "'" + str(s).replace('\\', '\\\\').replace("'", "\\'") + "'"


def php(v, ind=1):
    if isinstance(v, dict):
        pad = '    ' * ind
        rows = ''.join(f"{pad}{php_str(k)} => {php(x, ind + 1)},\n" for k, x in v.items())
        return '[\n' + rows + '    ' * (ind - 1) + ']'
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    return php_str(v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--names', action='store_true',
                    help="print this machine's bench names, one per line, and write nothing")
    ap.add_argument('--sign-in', action='store_true',
                    help="print the door's issuer, the dev OpenBao address and the signed-in contexts "
                         "(one per line, contexts comma-joined), for the bench's sign-in setup")
    a = ap.parse_args()
    if a.names:
        print('\n'.join(v['http_host'] for v in derived()['contexts'].values()))
        return 0
    if a.sign_in:
        print('\n'.join(sign_in()))
        return 0
    root = (os.environ.get('MODX_ROOT') or '').rstrip('/')
    if not root or not os.path.isfile(f'{root}/config.core.php'):
        raise SystemExit(f"REFUSED: no config.core.php under '{root or '(MODX_ROOT unset)'}'. Nothing was written.")
    path = f'{root}/core/config/application.php'

    current = {}
    if os.path.isfile(path):
        out = subprocess.run(['php', '-r', 'echo json_encode(include $argv[1]);', path],
                             capture_output=True, text=True, check=True).stdout
        current = json.loads(out) or {}
        if not isinstance(current, dict):
            raise SystemExit(f'REFUSED: {path} does not return an array. Nothing was written.')

    infra = derived()
    system = dict(infra.get('system') or {})
    system.setdefault('modxsearch.ask_url', BENCH_MODXSEARCH_ASK)
    system.update({
        'estate_env': 'development',
        'error_log_filepath': f'{root}/core/logs/',
        'new_folder_permissions': '0775',
        'new_file_permissions': '0664',
        # The tenant-apps list infra hands this host, at the path staging and production use too.
        'estate.tenant_apps_file': f'{root}/core/config/tenant-apps.json',
    })
    colour = (os.environ.get('ESTATE_ENV_COLOR') or '').strip()
    if colour:
        system['estate_env_color'] = colour
    contexts = {ctx: dict(infra['contexts'][ctx], base_url='/',
                          session_name='PHPSESSID' + re.sub(r'[^A-Za-z0-9]', '', ctx))
                for ctx in domains.CONTEXTS}

    doc = {k: v for k, v in current.items() if k not in ('environment', 'settings')}
    doc['environment'] = 'development'
    doc['settings'] = {'system': system, 'contexts': contexts}
    text = ('<?php\n// Rendered by modx setup/bench-application.py. The keys other than environment\n'
            '// and settings were in the file before and are kept as they were.\nreturn ' + php(doc) + ';\n')
    if a.dry_run:
        print(text.replace(str(current.get('whoami', '\0')), '(not printed)'))
        return 0
    with open(path + '.new', 'w') as f:
        f.write(text)
    subprocess.run(['php', '-l', path + '.new'], check=True, capture_output=True)
    os.replace(path + '.new', path)
    print(f"bench-application: wrote {path}: environment development, "
          f"{len(system)} system and {sum(map(len, contexts.values()))} context value(s), "
          f"kept {', '.join(sorted(k for k in doc if k not in ('environment', 'settings'))) or 'nothing'}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
