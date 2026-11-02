#!/bin/bash
# publish-clean — the open-source tree this repository publishes stays publishable on every run.
#
# tools/publish-tree.sh refuses a tree that names an estate fact (the owner, an internal zone, a real
# address, a backlog reference, a retired credential, a file the list leaves out). Run only when
# someone published, it let over a hundred such lines pile up in three weeks, each harmless alone.
# Here it runs with the rest of the suite, against the working tree as it stands (committed or not),
# so the line that brings a fact back goes red the day it is written.
#
# The control plants one backlog reference in a copy of the archived tree and must see the gate
# refuse it: a gate that cannot go red is not a check.
set -u
cd "$(dirname "$0")/.."
REPO=$(pwd)
pass=0; fail=0
check() { if [ "$1" = 1 ]; then pass=$((pass+1)); echo "  ok    $2"
          else fail=$((fail+1)); echo "  FAIL  $2"; [ -n "${3:-}" ] && printf '%s\n' "$3" | sed 's/^/        /'; fi; }

command -v git >/dev/null || { echo "REFUSING: no git on this machine."; exit 2; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "REFUSING: $REPO is not a git checkout."; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# The working tree, uncommitted edits included: `git stash create` makes a commit object of them and
# changes nothing; with nothing uncommitted it prints nothing and HEAD is the tree.
ref=$(git -C "$REPO" stash create 2>/dev/null); ref=${ref:-HEAD}
out=$(bash "$REPO/tools/publish-tree.sh" --ref "$ref" --out "$T/tree" 2>&1); rc=$?
check "$([ $rc = 0 ] && echo 1 || echo 0)" "the published tree is clean" \
      "$(printf '%s\n' "$out" | grep -v '^publish-tree:' | head -20)
$(printf '%s\n' "$out" | tail -1)"

# Control: the same gate over a copy carrying one planted reference must refuse it.
if [ -d "$T/tree" ]; then
  cp -r "$T/tree" "$T/planted"; rm -rf "$T/planted/.git"
  printf '\n<!-- planted by tests/publish-clean.sh: see %s -->\n' "#""12""34" >> "$T/planted/README.md"
  planted=$(bash "$REPO/tools/publish-tree.sh" --ref "$ref" --scan "$T/planted" 2>&1); prc=$?
  check "$([ $prc != 0 ] && case "$planted" in *"README.md"*) echo 1;; *) echo 0;; esac || echo 0)" \
        "control: a planted backlog reference is refused" "$(printf '%s\n' "$planted" | tail -3)"
else
  check 0 "control: a planted backlog reference is refused" "no archived tree to plant in"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
