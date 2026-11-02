#!/usr/bin/env python3
"""estate-get.py — print one value from the estate file, for the shell scripts in setup/.

    python3 setup/estate-get.py domains.contexts            # MODX_ESTATE names the estate file

The estate's facts (its contexts) live in one file; a shell script that needs one
reads it here rather than typing it, so the software carries no estate. A missing file or key
REFUSES (exit 2) and says which — a guessed value would point a guard at the wrong machine.
A list prints one item per line.
"""
import json
import os
import sys

if len(sys.argv) != 2:
    sys.exit("usage: estate-get.py <dotted.key>")
path = (os.environ.get('MODX_ESTATE') or '').strip()
if not path or not os.path.isfile(path):
    print(f"estate-get: MODX_ESTATE does not name the estate file ({path or 'unset'}); "
          f"cannot read {sys.argv[1]}", file=sys.stderr)
    sys.exit(2)
value = json.load(open(path))
for part in sys.argv[1].split('.'):
    if not isinstance(value, dict) or part not in value:
        print(f"estate-get: {path} declares no {sys.argv[1]}", file=sys.stderr)
        sys.exit(2)
    value = value[part]
if isinstance(value, list):
    print('\n'.join(str(v) for v in value))
elif isinstance(value, (str, int, float)) and str(value).strip():
    print(value)
else:
    print(f"estate-get: {sys.argv[1]} in {path} is empty or not a scalar", file=sys.stderr)
    sys.exit(2)
