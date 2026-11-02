#!/usr/bin/env python3
"""
config-context.py — WRITE the docroot's `config.context.php`: one line that hands the decision to
`EdgeContext.php`.

    python3 setup/config-context.py                  # print it
    python3 setup/config-context.py --write $MODX_ROOT
    python3 setup/config-context.py --check $MODX_ROOT   # compare, exit 1 on drift

WHAT THE FILE IS NOW (2026-09-15). Stock `index.php` requires `config.context.php` for a
context key. The key comes from `HTTP_X_TENANT`, which the EDGE sets and overwrites on every request —
nginx from the name's tenant on every ground, the bench included. The file is the same line on every profile, and it is the
line infra's `roles/modx-web` renders on staging and production:

    <?php return require MODX_CORE_PATH . 'components/pustak/lib/EdgeContext.php';

WHY THE MAP IS GONE. Until 2026-09-15 this file was an HTTP_HOST -> context map generated from
`estate.json`. The host is never read now — the owner, 2026-09-14: "someone else provides
mapping of domain to tenant" — so a map here would be a second owner of a fact the edge owns, and
one nothing reads. `EdgeContext.php` refuses a request with no valid header with the estate's 404
page; nothing falls through to `web` any more.

`--profile` is accepted and ignored, for a caller that still passes it; the render never depended on it.
"""
import argparse
import os
import sys

FILENAME = 'config.context.php'
LINE = "<?php return require MODX_CORE_PATH . 'components/pustak/lib/EdgeContext.php';\n"


def render():
    """The file, as text. The same line for every profile."""
    return LINE


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[1])
    ap.add_argument('--profile', help='ignored; the file is the same line everywhere')
    ap.add_argument('--write', metavar='DOCROOT', help='write the file into this docroot')
    ap.add_argument('--check', metavar='DOCROOT', help='compare the docroot copy with the one line')
    args = ap.parse_args()

    text = render()

    if args.check:
        path = os.path.join(args.check, FILENAME)
        if not os.path.isfile(path):
            print(f"config-context: {path} does not exist — generate it with --write", file=sys.stderr)
            return 1
        got = open(path, encoding='utf-8').read()
        if got.strip() == text.strip():
            print("config.context.php is the EdgeContext require")
            return 0
        print(f"config-context: {path} is not the EdgeContext require — it reads:", file=sys.stderr)
        for line in got.splitlines()[:6]:
            print(f"  {line}", file=sys.stderr)
        return 1

    if args.write:
        path = os.path.join(args.write, FILENAME)
        if not os.path.isdir(args.write):
            print(f"config-context: {args.write} is not a directory", file=sys.stderr)
            return 1
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write(text)
        print(f"wrote {path} (EdgeContext require)")
        return 0

    sys.stdout.write(text)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
