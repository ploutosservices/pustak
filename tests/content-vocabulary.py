#!/usr/bin/env python3
"""content-vocabulary — the words our MODx gives an author stay words.

docs/content-vocabulary.md is the list. This holds it to three things:
  1. every word marked `ours` has its element in common/ — chunks/<word>.html, snippets/<word>.php —
     so renaming or deleting an element a page uses goes red before it deploys;
  2. every tag in the estate's pages is a word in the list, so a page cannot lean on a word nobody
     promised to keep;
  3. the estate's Formatting page shows the list as written (tools/vocabulary-page.py --check).

    python3 tests/content-vocabulary.py --tree-only    1 only: this checkout, no estate (--before-apply)
    MODX_ESTATE=<modx-estate>/estate.json python3 tests/content-vocabulary.py    1 and 2

Exit 0 pass, 1 fail, 2 refused (the list unreadable, or the estate not named for check 2).
"""
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
KINDS = {'chunk', 'snippet', 'field', 'setting', 'link', 'placeholder'}
ELEMENT = {'chunk': ('chunks', '.html'), 'snippet': ('snippets', '.php')}
# [[ then an optional ! (uncached), then the sigil that says the kind, then the name.
TAG = re.compile(r'\[\[!?(~|\$|\*|\+\+|\+|%)?([A-Za-z][A-Za-z0-9_.-]*|(?<=~)\d+)')
SIGIL = {'~': 'link', '$': 'chunk', '*': 'field', '++': 'setting', '+': 'placeholder', None: 'snippet'}
WRITTEN = {kind: sig or '' for sig, kind in SIGIL.items()}

passed = failed = 0


def check(ok, label, detail=''):
    global passed, failed
    if ok:
        passed += 1
        print(f'  ok    {label}')
    else:
        failed += 1
        print(f'  FAIL  {label}')
        if detail:
            print(f'        {detail}')


def table():
    """The list's rows in its own order: [{word, kind, whose, parameters, renders}]. The generator of
    Formatting's section (tools/vocabulary-page.py) reads the list through this, so it is parsed once."""
    rows, seen = [], False
    for line in (REPO / 'docs' / 'content-vocabulary.md').read_text().splitlines():
        cells = [c.strip() for c in line.strip().strip('|').split('|')] if line.startswith('|') else None
        if not cells:
            continue
        if cells[:3] == ['word', 'kind', 'whose']:
            seen = True
            continue
        if not seen or set(cells[0]) <= {'-'}:
            continue
        if len(cells) != 5 or cells[1] not in KINDS:
            print(f'REFUSED: docs/content-vocabulary.md row is not word | kind | whose | parameters | renders: {line}')
            sys.exit(2)
        rows.append(dict(zip(('word', 'kind', 'whose', 'parameters', 'renders'), cells)))
    if not rows:
        print('REFUSED: docs/content-vocabulary.md holds no table')
        sys.exit(2)
    return rows


def vocabulary():
    return {(r['word'], r['kind']): r['whose'] for r in table()}


def main():
    words = vocabulary()
    print(f'content-vocabulary: {len(words)} words, {sum(w == "ours" for w in words.values())} ours')
    estate_root = None
    if os.environ.get('MODX_ESTATE', '').strip() and os.path.isfile(os.environ['MODX_ESTATE'].strip()):
        estate_root = Path(os.environ['MODX_ESTATE'].strip()).resolve().parent
    for (word, kind), whose in sorted(words.items()):
        if whose == 'estate':
            # the estate's own content: never in common/ (two files would be the body of one row),
            # and in the estate's estate-elements/chunks/ when the estate is at hand
            check(kind == 'chunk' and not (REPO / 'common' / 'chunks' / f'{word}.html').exists(),
                  f'estate chunk {word} is not in common/chunks/')
            if estate_root:
                check((estate_root / 'seat' / 'estate-elements' / 'chunks' / f'{word}.html').is_file(),
                      f'  and is in modx-estate seat/estate-elements/chunks/')
            continue
        if whose != 'ours':
            continue
        if kind not in ELEMENT:
            check(False, f'{word}: ours is a chunk or a snippet', f'kind is {kind}')
            continue
        d, ext = ELEMENT[kind]
        check((REPO / 'common' / d / f'{word}{ext}').is_file(), f'{kind} {word} is in common/{d}/',
              f'common/{d}/{word}{ext} is missing — a page that uses [[{WRITTEN[kind]}{word}]] would render nothing')

    if '--tree-only' not in sys.argv:
        estate = os.environ.get('MODX_ESTATE', '').strip()
        if not estate or not os.path.isfile(estate):
            print('REFUSED: MODX_ESTATE does not name the estate file; the pages cannot be read (--tree-only skips them)')
            sys.exit(2)
        root = Path(estate).resolve().parent
        files = subprocess.run(['git', '-C', str(root), 'ls-files', '-z', 'seat/documents'],
                               capture_output=True, text=True, check=True).stdout.split('\0')
        unknown, n = {}, 0
        for rel in filter(None, files):
            n += 1
            for sig, name in TAG.findall((root / rel).read_text(errors='replace')):
                key = ('~', 'link') if sig == '~' else (name, SIGIL[sig or None])
                if key not in words:
                    unknown.setdefault(key, rel)
        check(not unknown, f'every tag in {n} pages is a word in the list',
              '; '.join(f'[[{WRITTEN[k[1]]}{k[0]}]] ({k[1]}) first in {v}' for k, v in sorted(unknown.items())))
        # 3. the list as Formatting shows it is the list as written here (design-vocabulary-on-formatting.md)
        page = root / 'seat' / 'documents' / 'platform' / 'formatting-1587.html'
        gen = subprocess.run([sys.executable, str(REPO / 'tools' / 'vocabulary-page.py'), '--check', str(page)],
                             capture_output=True, text=True)
        check(gen.returncode == 0, 'Formatting shows the list as written',
              (gen.stdout + gen.stderr).strip() + ' — run tools/vocabulary-page.py on the page and commit it')

    print(f'\n{passed} passed, {failed} failed')
    return 0 if failed == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
