#!/usr/bin/env python3
"""app-name-from-manifest — the name a person sees is typed once, in service.json.

    python3 tests/app-name-from-manifest.py

The application's name (identity.display_name) appears in the title bar, on the sign-in card and on
the not-authorised page. Each of the three renders the system setting `estate_app_name`, which
setup/02 writes from the manifest. This holds that shut with no database: none of the three may
carry the name itself, each must read the setting, and setup/02 must take the value from the
manifest. The owner, 2026-10-07: "is there way to eliminate duplication".
"""
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
READERS = {
    'common/chunks/topNavBar.html': '[[++estate_app_name]]',
    'common/snippets/unauthorizedNotice.php': "getOption('estate_app_name')",
}
passed = failed = 0


def check(ok, label, detail=''):
    global passed, failed
    if ok:
        passed += 1
        print(f'  ok    {label}')
    else:
        failed += 1
        print(f'  FAIL  {label}' + (f'\n          {detail}' if detail else ''))


def literal_hits(text, name):
    return [n for n, line in enumerate(text.split('\n'), 1) if re.search(r'\b' + re.escape(name) + r'\b', line)]


print('app-name-from-manifest — the display name is typed once, in the manifest')
name = str((json.load(open(os.path.join(REPO, 'service.json'))).get('identity') or {}).get('display_name') or '')
check(bool(name.strip()), f'service.json declares identity.display_name ({name!r})')
if not name.strip():
    sys.exit(1)

for path, reader in READERS.items():
    text = open(os.path.join(REPO, path), encoding='utf-8').read()
    hits = literal_hits(text, name)
    check(not hits, f'{path} does not type the name', f'line(s) {hits}')
    check(reader in text, f'  and reads it: {reader}')

src = open(os.path.join(REPO, 'setup/02-system-settings.py'), encoding='utf-8').read()
check("'estate_app_name'" in src and "get('display_name')" in src and 'service.json' in src,
      'setup/02 writes estate_app_name from service.json identity.display_name')
check(not literal_hits(src, name), '  and does not type the name either')

# the control: the same check on a copy with the name planted must fail, or it proves nothing
planted = open(os.path.join(REPO, 'common/chunks/topNavBar.html'), encoding='utf-8').read() \
    .replace('[[++estate_app_name]]', name)
check(bool(literal_hits(planted, name)), 'control: a planted literal name is caught')

print(f'\n{passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
