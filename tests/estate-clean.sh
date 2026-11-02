#!/bin/bash
# estate-clean — this repository is SOFTWARE. It must contain nobody's estate.
#
# THE RULE (the owner, 2026-08-01): "the repo needs to be clean of estate", and the mechanism he named:
# "an estate file can update the basic config file and rest can be driven from there."
#
# Words do not survive a fresh agent. This is the enforcement. It fails the moment somebody puts an
# estate value back into the software — a real person, a real address, a real credential — which is
# exactly how the declaration ended up inline the first time: one value at a time, each reasonable.
#
# It also proves the loader BOTH WAYS, because a check that can only pass is worse than no check:
# every refusal below is exercised by inducing the fault and asserting the non-zero exit.
set -u
cd "$(dirname "$0")/.."
REPO="$PWD"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok    $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; }
check(){ if [ "$1" = 1 ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "== the software carries no estate =="

# 1. No database credential anywhere. The old default was a working password, in twenty files.
#    Only a LITERAL default counts: `${MODX_DB_PASS:-...}` or a quoted second argument. A shell
#    expansion that passes the variable THROUGH is the correct pattern and must not be flagged —
#    a check that cries wolf gets deleted, and then it protects nothing.
CRED='os\.environ\.get\((["'"'"'])MODX_DB_PASS\1, *["'"'"'][^"'"'"']|\$\{MODX_DB_PASS:-[^}]|mysql(dump)?[^|;]* -p[a-zA-Z0-9]'
HITS=$(grep -rnE "$CRED" --include=*.py --include=*.sh --include=*.php . 2>/dev/null \
       | grep -v 'tests/estate-clean.sh' | wc -l)
check $([ "$HITS" -eq 0 ] && echo 1 || echo 0) "no database credential has a literal default" \
      "$(grep -rnE "$CRED" --include=*.py --include=*.sh --include=*.php . 2>/dev/null | grep -v estate-clean | head -3)"

# 2. No estate identifier in the software directories.
#    The kuber hostname added 2026-08-04: it was inline SEVEN TIMES in
#    common/chunks/kuber.js, one screen below the corp address phase 1 replaced, and this check
#    went green over every one of them because the pattern did not name it. A list of literals is
#    only as good as the last person to extend it — which is why the check below is the enforcement
#    and this comment is not.
#
#    `install/` AND `seat/` ARE NOT EXCLUDED — THEY ARE NOT HERE (phase 3, 2026-08-10). Both
#    were excluded for months as "the estate's own content, moving to the estate repository in
#    phase 2", and the exclusion did what every exclusion does: it made this check silent exactly
#    where the estate was. `install/modx-docroot.tar.gz` carried EIGHT estate addresses for eleven
#    days — seven kuber hosts and one corp host in a July build of a docroot asset — while source
#    was fixed and this suite was green. They now live in the estate repository, so there is
#    nothing to exclude and nothing to grep: check 10 below asserts that directly, because
#    "the directory is gone" and "the directory is excluded" look identical from inside a green run.
#
#    The estate repository's own copies are NOT checked here, deliberately. `seat/documents` is his
#    writing — his pages, his addresses — and a check that forbade estate identifiers in his content
#    would forbid his content. The tarball is a binary a grep cannot open; that half is enforced
#    where it is built (`setup/regenerate-docroot.sh` aborts and deletes it).
# The identifiers are the ESTATE's (estate.json `identifiers`), so the software names none of them.
IDS=$(python3 "$REPO/setup/estate-get.py" identifiers 2>/dev/null | paste -sd'|' -)
SEARCH=(setup common tests *.py)
# A checker that names the literals it forbids matches itself. This file was already excluded
# wholesale for that reason; setup/regenerate-docroot.sh now carries the same list (it enforces it
# on the built tarball, which a grep cannot open). Excluding that FILE would blind this check to a
# real address added to it later, so only the pattern DECLARATION line is dropped — one line, named.
SELF="estate-clean\.sh|:[0-9]+:ESTATE_IDS="
if [ -z "$IDS" ]; then
  check 0 "the estate declares its identifiers (estate.json identifiers) — with none, nothing can be scanned for" "MODX_ESTATE=${MODX_ESTATE:-unset}"
else
  HITS=$(grep -rniE --binary-files=without-match "$IDS" "${SEARCH[@]}" 2>/dev/null | grep -vE "$SELF" | wc -l)
  check $([ "$HITS" -eq 0 ] && echo 1 || echo 0) "no estate identifier in setup/ common/ tests/ *.py" \
        "$(grep -rniE --binary-files=without-match "$IDS" "${SEARCH[@]}" 2>/dev/null | grep -vE "$SELF" | head -3)"
fi

# 10. The estate's own directories are GONE from this repository, not merely excluded from a grep.
#     Phase 3 removed them; if a `seat/` or `install/` reappears here — restored by a stray checkout,
#     recreated by a script that still writes into $REPO — every check above goes on passing while
#     the software carries somebody's estate again. This is the one assertion that can tell the
#     difference between "clean" and "not looking".
for d in seat install; do
  if [ -e "$REPO/$d" ]; then
    bad "$d/ is back in the software repository" \
        "It moved to the estate repository in phase 3. Something here recreated it."
  else
    ok "$d/ is not in this repository (it is the estate's)"
  fi
done

# 3. The real estate file can never be committed.
git check-ignore -q estate.json && ok "estate.json is gitignored" || bad "estate.json is gitignored"

echo "== the loader, proven both ways =="

load() { env -u MODX_ESTATE -u MODX_ADMIN_USER "$@" python3 -c \
         'import sys; sys.path.insert(0,"setup"); import estate; print(len(estate.CONTEXTS), len(estate.USERS))' 2>&1; }

# 4. No estate named -> a generic, EMPTY estate. This is the install-from-nothing path.
OUT=$(load); RC=$?
check $([ "$RC" = 0 ] && [ "$OUT" = "0 0" ] && echo 1 || echo 0) \
      "no MODX_ESTATE installs a generic empty estate" "rc=$RC out=$OUT"

# 5. A named estate that is not there must REFUSE, never fall back to the empty one.
OUT=$(env MODX_ESTATE=/nonexistent/estate.json python3 -c \
      'import sys; sys.path.insert(0,"setup"); import estate' 2>&1); RC=$?
check $([ "$RC" != 0 ] && echo 1 || echo 0) \
      "a missing estate file refuses (never falls back)" "rc=$RC out=$OUT"

# 5b. MODX_ESTATE pointed at the CHECKOUT rather than the file must refuse AND say which it is.
#     Measured 2026-08-13: the directory form is set, so nothing reads as unconfigured, and
#     the old message told the operator a directory they could see "does not exist". A ground that
#     renders the wrong one of these two paths must be told which one it rendered.
mkdir -p "$WORK/checkout"; echo '{"contexts":{}}' > "$WORK/checkout/estate.json"
OUT=$(env MODX_ESTATE="$WORK/checkout" python3 -c \
      'import sys; sys.path.insert(0,"setup"); import estate' 2>&1); RC=$?
check $([ "$RC" != 0 ] && grep -q 'DIRECTORY' <<<"$OUT" && echo 1 || echo 0) \
      "the estate CHECKOUT refuses, naming it a directory" "rc=$RC out=$OUT"
check $(grep -qF "$WORK/checkout/estate.json" <<<"$OUT" && echo 1 || echo 0) \
      "  and the refusal names the file to set instead" "out=$OUT"

# 5c. Same directory, no estate.json inside it: the refusal must say THAT, not offer a path that
#     is not there. Otherwise the operator sets what it printed and gets the next refusal.
mkdir -p "$WORK/emptydir"
OUT=$(env MODX_ESTATE="$WORK/emptydir" python3 -c \
      'import sys; sys.path.insert(0,"setup"); import estate' 2>&1); RC=$?
check $([ "$RC" != 0 ] && grep -q 'no such file' <<<"$OUT" && echo 1 || echo 0) \
      "an estate directory with no estate.json says so" "rc=$RC out=$OUT"

# 6. A misspelled key must REFUSE — silently ignoring it installs an estate missing the very thing
#    the author thought they had declared.
echo '{"contexts":{},"conntexts":{}}' > "$WORK/typo.json"
OUT=$(env MODX_ESTATE="$WORK/typo.json" python3 -c \
      'import sys; sys.path.insert(0,"setup"); import estate' 2>&1); RC=$?
check $([ "$RC" != 0 ] && echo 1 || echo 0) "a misspelled key refuses" "rc=$RC out=$OUT"

# 7. A context absent from domains.contexts must REFUSE — infra names no host for it, so it would
#    install and then resolve nowhere, which looks like a DNS fault for as long as anyone believes it.
cat > "$WORK/nohost.json" <<'JSON'
{"contexts": {"a": {"name":"A","description":"","rank":2,"site_name":"A","protected":true}},
 "domains": {"contexts": []}}
JSON
OUT=$(env MODX_ESTATE="$WORK/nohost.json" python3 -c \
      'import sys; sys.path.insert(0,"setup"); import estate' 2>&1); RC=$?
check $([ "$RC" != 0 ] && echo 1 || echo 0) "a context absent from domains.contexts refuses" "rc=$RC out=$OUT"

# 8. The shipped example must actually load — documentation that does not work is worse than none.
OUT=$(env MODX_ESTATE="$REPO/setup/estate.example.json" python3 -c \
      'import sys; sys.path.insert(0,"setup"); import estate, domains; print(len(estate.CONTEXTS), len(domains.CONTEXTS))' 2>&1); RC=$?
check $([ "$RC" = 0 ] && [ "$OUT" = "2 2" ] && echo 1 || echo 0) \
      "setup/estate.example.json loads and routes" "rc=$RC out=$OUT"

# 9. db_config refuses without credentials, and works with them. Both directions.
#
# MODX_DB_SOCKET IS SCRUBBED TOO, AND FORGETTING IT MADE THIS ARM GREEN FOR THE WRONG REASON — or
# rather RED for one, on 2026-09-12. Socket authentication needs no credential, so where that name
# is exported db_config correctly does NOT refuse, and this assertion measured the caller's shell
# instead of the code. `-u MODX_DB_USER -u MODX_DB_PASS` was written when a password was the only
# way in. Same lesson as WHOAMI in a sibling application's seam suite: declining to set a variable does not
# remove one the caller supplies, and a negative control has to scrub every route to the thing it
# is proving impossible.
OUT=$(env -u MODX_DB_USER -u MODX_DB_PASS -u MODX_DB_SOCKET python3 -c \
      'import sys; sys.path.insert(0,"setup"); import domains; domains.db_config()' 2>&1); RC=$?
check $([ "$RC" != 0 ] && echo 1 || echo 0) "db_config refuses with no credentials and no socket" "rc=$RC"
OUT=$(env MODX_DB_USER=u MODX_DB_PASS=p python3 -c \
      'import sys; sys.path.insert(0,"setup"); import domains; print(domains.db_config()["user"])' 2>&1); RC=$?
check $([ "$RC" = 0 ] && [ "$OUT" = "u" ] && echo 1 || echo 0) "db_config reads the environment" "rc=$RC out=$OUT"

echo
echo "  passed $PASS   failed $FAIL"
[ "$FAIL" -eq 0 ]
