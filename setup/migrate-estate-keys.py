#!/usr/bin/env python3
"""migrate-estate-keys — MODx's contexts take the estate's tenant keys.

WHY A ONE-SHOT AND NOT `21-rename-context` RUN BY HAND, ONCE PER PAIR. A task dispatched to a ground
carries NO argv and NO environment of the caller's: what runs is the manifest entry's
own command. So the pairs cannot be passed in — and they are not written here either, because WHICH
keys a particular estate is moving is an estate fact and this repository carries no estate
(tests/estate-clean.sh). They are `context_renames` in the estate file, read below. An estate that
declares none makes this a no-op.

WHAT IT DOES, in order, and it stops at the first failure:

  1. `21-rename-context` for each pair. That verb owns the rename — the rows in every table that
     holds a context key, the derived `<ctx>ProtectedFiles` name, the settings photograph that must
     match exactly under the new key, and the refusals. One transaction per rename.
  2. The NAMES. A context's http_host and site_url are infra's: the ground's
     application.php holds them under the new key once infra renders it, and
     setup/apply-environment.php writes them. This step runs it when MODX_ROOT names the docroot.

  3. NOT the access converge. `setup/04` must run after this, and it already does: every deploy
     verb that carries this software runs it, snapshot-guarded. Running it here as well would
     converge the access model twice for one change.

IDEMPOTENT. A second run finds both contexts already renamed, says so, and exits 0.

    python3 setup/migrate-estate-keys.py
    python3 setup/migrate-estate-keys.py --dry-run     count everything, write nothing
"""
import os
import subprocess
import sys

from estate import CONTEXT_RENAMES

HERE = os.path.dirname(os.path.abspath(__file__))
DRY = '--dry-run' in sys.argv

PAIRS = CONTEXT_RENAMES


def rename(old, new):
    env = {**os.environ, 'CTX_FROM': old, 'CTX_TO': new}
    cmd = [sys.executable, os.path.join(HERE, '21-rename-context.py')] + (['--dry-run'] if DRY else [])
    r = subprocess.run(cmd, env=env, cwd=HERE)
    return r.returncode


print('migrate-estate-keys: MODx takes the estate tenant keys'
      f"{'  (DRY RUN)' if DRY else ''}")
if not PAIRS:
    print('  this estate declares no context_renames — nothing to do.')
    sys.exit(0)

for old, new in PAIRS:
    print(f'\n── {old} -> {new}')
    rc = rename(old, new)
    if rc != 0:
        sys.exit(f'\nmigrate-estate-keys: {old} -> {new} exited {rc}. STOPPING — nothing after this '
                 f'point has run, and that rename left the ground as it was.')

# ── the names, from this ground's application.php (infra's render) ─────────────────────────────
root = os.environ.get('MODX_ROOT')
print()
if not root:
    print('  MODX_ROOT unset — the names are not written here; run setup/apply-environment.php on the docroot.')
elif DRY:
    print('  (dry run: apply-environment not run)')
else:
    r = subprocess.run(['php', os.path.join(HERE, 'apply-environment.php')], cwd=HERE)
    if r.returncode != 0:
        sys.exit(f'\nmigrate-estate-keys: apply-environment exited {r.returncode}. The renames are '
                 f'COMMITTED and the names are not written — this ground answers to the old '
                 f'names until that is fixed.')

print('\nmigrate-estate-keys: done. setup/04 (the access converge) must run after this, and the '
      'deploy verb that carried this software runs it.')
