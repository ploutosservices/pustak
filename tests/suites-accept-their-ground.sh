#!/bin/bash
# suites-accept-their-ground — these tests must be able to run where the estate actually is.
#
# The bench was a MODx install on somebody's workstation, so every suite here could assume one
# machine held the schema, the docroot and the web server. The owner, 2026-08-12: "MODx is not needed
# on a local box for anything" — the bench became MODx staging on its own host, and infra measured
# what that did:
#
#     hanuman     /opt/modx/html          the docroot and the HTTP ground
#     shyam       the staging db name     THE SCHEMA IS ON ANOTHER MACHINE
#
# `lib.sh` ran `mysql -u … -p… "$DB_NAME"` with NO HOST, so it could only ever reach a database on
# the box running the test. No single ground satisfies both while the suites address localhost —
# which is why ten of twenty suites run nowhere, and why infra stopped before building the runner
# rather than build one that would report ten refusals forever.
#
# This is the static half of ask 3, and it exists because the fix is three lines that anybody could
# undo without noticing. It asserts the SHAPE, on any machine, with no database:
#
#   1. q() passes a host, and that host comes from the environment
#   2. the two suites that reached into /srv/local/modx read $MODX_ROOT instead
#   3. MODX_INSTALL_DIR is REFUSED rather than ignored
#
# On (3): infra's ask named the variable MODX_INSTALL_DIR. It is MODX_ROOT — already declared in
# service.json as `path:modx/docroot`, already read by jump-nav.php, 11-add-context.py and
# apply-environment.php. Two names for one fact is what rule 18 exists to stop, and the
# cost here is concrete rather than theoretical: a runner that sets one while the suites read the
# other gets a silent default and reports green against a machine nobody meant. So the second name
# is refused out loud, which turns a green-against-the-wrong-box into a one-line fix.
#
# KNOWN GAP, stated because it changes what a green line here is worth: the estate's shared
# drift-checker does NOT scan tests/lib.sh — a deliberately planted undeclared read there passes
# manifest-drift.sh. So the env vars this file asserts are not covered by that gate; this suite is
# the only thing watching them. Reported to infra.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
ok()   { PASS=$((PASS+1)); echo "  ok    $1"; }

echo "suites-accept-their-ground — the schema and the docroot may be on other machines"
echo

# ── 1. the database host comes from the environment ────────────────────────────────────────────
if [ ! -f tests/lib.sh ]; then
  fail "tests/lib.sh is missing — this suite can say nothing"
else
  code=$(sed -E 's@(^|[[:space:]])#.*@@' tests/lib.sh)
  if printf '%s' "$code" | grep -q 'DB_HOST=${MODX_DB_HOST:-'; then
    ok "lib.sh takes the database host from MODX_DB_HOST, with a default"
  else
    fail "lib.sh does not read MODX_DB_HOST" \
         "without it these suites can only ever reach a database on their own machine"
  fi
  qline=$(printf '%s' "$code" | grep -E '^q\(\)')
  if printf '%s' "$qline" | grep -q -- '-h "\$DB_HOST"'; then
    ok "and q() actually passes it to mysql (-h \"\$DB_HOST\")"
  else
    fail "q() does not pass a host to mysql" "read MODX_DB_HOST and never use it: $qline"
  fi
fi

# ── 2. no suite reaches into a hardcoded docroot ────────────────────────────────────────────────
# /srv/local is a dev-box convention. It does not exist on hanuman, where the docroot now
# lives — and the log-directory assertion in clear-cache-reaches-contexts.sh had a second clause
# that PASSES when there is no cache directory at all, so on that ground it would have gone green
# precisely because it was looking at the wrong machine.
#
# TWO EXEMPTIONS, both narrow and both stated rather than silently coded:
#   - the literal appearing as MODX_ROOT's DEFAULT: `${MODX_ROOT:-/srv/local/modx}` or
#     `getenv('MODX_ROOT') ?: '/srv/local/modx'`. The ask asks for defaults that leave a dev-box run
#     unchanged, so the default is the deliverable, not the defect.
#     MATCHED AS THE DEFAULT EXPRESSION, not as "the line mentions MODX_ROOT". The first version of
#     this exempted the whole line, and a drill proved it worthless: replacing ONE of the two
#     $MODX_ROOT references on the log-directory line with the old literal left the word MODX_ROOT
#     still on the line, and the check stayed green over a genuine hardcode.
#   - this file, which must contain the literal in order to search for it. Exempted by NAME, not by
#     a cleverness that would also exempt a real one.
scan_hardcoded() {
  local f
  for f in tests/*.sh tests/*.php tests/*.py; do
    [ -f "$f" ] || continue
    case "$f" in tests/suites-accept-their-ground.sh) continue ;; esac
    sed -E 's@(^|[[:space:]])#.*@@; s@//.*@@' "$f" \
      | grep -nF '/srv/local/modx' \
      | grep -vE "MODX_ROOT:-/srv/local/modx|MODX_ROOT'\\) *\\?: *'/srv/local/modx'" \
      | sed "s|^|$f:|"
  done
}

# The scheme scanner, same shape and same two exemptions: comments, and this file.
scan_scheme_literals() {
  local f
  for f in tests/*.sh; do
    [ -f "$f" ] || continue
    case "$f" in tests/suites-accept-their-ground.sh|tests/lib.sh) continue ;; esac
    sed -E 's@(^|[[:space:]])#.*@@' "$f" \
      | grep -nE ':80:|http://\$(HOST|host|ctx)' | sed "s|^|$f:|"
  done
}
hard=$(scan_hardcoded)
if [ -z "$hard" ]; then
  ok "no suite hardcodes /srv/local/modx outside a comment"
else
  fail "a suite still hardcodes the docroot" "$hard"
fi

# The control. Without it, the check above passes just as happily over a directory with no suites
# in it, or a stripper that deletes every line.
probe=$(mktemp tests/_probe-XXXX.sh)
printf 'x=/srv/local/modx/index.php\n' > "$probe"
planted=$(scan_hardcoded | grep "$(basename "$probe")" || true)
rm -f "$probe"
[ -n "$planted" ] && ok "control: the scan does find a planted hardcoded docroot" \
                  || fail "control: the scan MISSED a planted hardcoded docroot — the result above means nothing"

# And a comment mentioning the old path must NOT fail it: several files explain the move at length.
probe=$(mktemp tests/_probe-XXXX.sh)
printf '# this used to be /srv/local/modx and is not any more\n' > "$probe"
planted=$(scan_hardcoded | grep "$(basename "$probe")" || true)
rm -f "$probe"
[ -z "$planted" ] && ok "control: a comment naming the old path does not fail it" \
                  || fail "control: a comment about the old path is being read as code"

# ── 2b. the scheme and port are DECLARED, not hardcoded ────────────────────────────────────────
# Six suites requested `http://$HOST` on `:80`. MODx staging is https — `:80` 301s to `:443` — so
# curl without -L hands back the redirect page and every body assertion reads it: six suites red,
# none of them about the code. The scheme's one home is each context's `site_url`, which infra
# derives; the suites read it from there through lib.sh's origin_of().
lit=$(scan_scheme_literals)
if [ -z "$lit" ]; then
  ok "no suite hardcodes http:// or :80 for its own host"
else
  fail "a suite hardcodes the scheme or port" "$lit"
fi

probe=$(mktemp tests/_probe-XXXX.sh)
printf 'curl --resolve "$HOST:80:$IP" "http://$HOST/x"\n' > "$probe"
planted=$(scan_scheme_literals | grep "$(basename "$probe")" || true)
rm -f "$probe"
[ -n "$planted" ] && ok "control: the scan does find a planted http/:80 request" \
                  || fail "control: the scan MISSED a planted http/:80 request — the result above means nothing"

# origin_of() is PURE, so it is drilled here with literal inputs rather than waiting for a ground.
# The four cases are the ones the estate can actually produce: a bench declaring http, staging
# declaring https, an explicit port, and a value it must refuse rather than guess at.
# EACH CASE IN ITS OWN PROCESS. The first version sourced lib.sh into THIS shell to reach
# origin_of — which also ran lib.sh's `export MODX_ROOT=...`, so the MODX_INSTALL_DIR refusal three
# checks below stopped firing and reported the guard as broken. A check that changes the
# environment the later checks are about is the same defect as a check that supplies its own
# condition; both were in this file today.
# ── EVERY sub-shell below runs in a SCRUBBED environment ───────────────────────────────────────
# These checks ask what lib.sh does with a given set of variables. On a dev box the shell has
# none of them, so `MODX_DB_PASS=probe bash -c ...` asked exactly that. ON A REAL GROUND IT DOES
# NOT: the staging runner exports MODX_DB_*, MODX_ROOT, MODX_ESTATE and MODX_PHP_RUN, the
# sub-shell inherits them, and four checks in this file went red on hanuman's first run —
# 'MODX_INSTALL_DIR was accepted', 'a remote host was accepted with the dev box's defaults',
# 'the local path changed' — none of which were true of lib.sh. They were true of the shell.
#
# So `probe` strips every MODX_* and sets only what the case is about. A check that passes on a
# dev box and fails on a ground is testing the shell, which is the defect this whole suite is
# about (measured 2026-08-14 from the ground's own journal).
# This suite runs standalone (it is ABOUT lib.sh, so it cannot source it and inherit the very
# behaviour under test). It still needs a name for "php, here on this machine" — same word the
# suites use, so the bare-php scanner below is not special-cased for its own file.
local_php() { php "$@"; }

probe() {                      # probe VAR=VAL ... -- <shell code>
  local clean=() args=("$@") i=0
  while IFS='=' read -r v _; do
    case $v in MODX_*) clean+=(-u "$v") ;; esac
  done < <(env)
  local sets=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do sets+=("$1"); shift; done
  shift                                            # the --
  env "${clean[@]}" "${sets[@]}" bash -c "$@"
}

origin_case() { # <site_url> <expected> ; expected "" means it must REFUSE (return 1)
  local got rc
  got=$(probe MODX_DB_PASS=probe -- '. tests/lib.sh >/dev/null 2>&1; origin_of "$1"' _ "$1"); rc=$?
  if [ -z "$2" ]; then
    [ $rc != 0 ] && ok "origin_of refuses ${1:-<empty>}" \
                 || fail "origin_of accepted ${1:-<empty>} and returned '$got'" \
                         "a caller would then speak the wrong scheme at a real edge"
    return
  fi
  [ "$got" = "$2" ] && ok "origin_of '$1' -> $got" \
                    || fail "origin_of '$1' -> '$got', expected '$2'"
}
origin_case "http://family.modx.internal.test/"        "http 80"
origin_case "https://claude.modx.internal.test/"       "https 443"
origin_case "https://claude.modx.internal.test:8443/"  "https 8443"
origin_case "claude.modx.internal.test"                ""
origin_case ""                                 ""

# ── 3. the second name for the docroot is refused, not ignored ─────────────────────────────────
out=$(probe MODX_DB_PASS=probe MODX_INSTALL_DIR=/opt/modx/html -- '. tests/lib.sh' 2>&1)
rc=$?
if [ $rc = 2 ] && printf '%s' "$out" | grep -q 'MODX_ROOT'; then
  ok "MODX_INSTALL_DIR alone is REFUSED (exit 2) and the refusal names MODX_ROOT"
else
  fail "MODX_INSTALL_DIR was accepted or ignored (exit $rc)" \
       "a runner that sets it and gets a silent default reports green against another machine
$out"
fi
out=$(probe MODX_DB_PASS=probe MODX_INSTALL_DIR=/opt/modx/html MODX_ROOT=/opt/modx/html \
      -- '. tests/lib.sh; echo "root=$MODX_ROOT"' 2>&1)
if printf '%s' "$out" | grep -q 'root=/opt/modx/html'; then
  ok "and with MODX_ROOT also set it proceeds, using MODX_ROOT"
else
  fail "setting both did not proceed on MODX_ROOT" "$out"
fi

# ── 4. MODX_ROOT reaches the php children, which read it with getenv() ─────────────────────────
# MODX_ROOT IS DELIBERATELY NOT PASSED IN. The first version of this check set it on the command
# line — which exports it by itself, so the check passed whether or not lib.sh said `export`, and a
# drill removing the export left it green. Letting lib.sh supply its own default is the only way to
# see whether lib.sh exported it.
out=$(probe MODX_DB_PASS=probe -- '. tests/lib.sh; local_php -r "echo getenv(\"MODX_ROOT\");"' 2>&1)
if [ "$out" = "/srv/local/modx" ]; then
  ok "MODX_ROOT is EXPORTED — a php child reads it (getenv), not just the shell"
else
  fail "MODX_ROOT does not reach a php child: '$out'" \
       "protect-on-save.sh builds its require path from getenv(); unexported it becomes '/index.php'"
fi

# ── 5. a REMOTE schema must be named, never defaulted ──────────────────────────────────────────
# Found 2026-08-13 by `run-all.sh --requirements`: the suites make a ground set MODX_DB_PASS and
# nothing else, and the other two fall back to a dev box's own database (`modx`) and user
# (the dev-box account). On staging — where the schema is `modx_staging` — that is not a broken run, which is
# the danger: if a database called `modx` exists on that server the suites go GREEN against it and
# the summary line is indistinguishable from a real pass. Local keeps its defaults; remote must say
# what it means.
out=$(probe MODX_DB_PASS=probe MODX_DB_HOST=modx-staging.db.internal.test -- '. tests/lib.sh' 2>&1)
rc=$?
if [ $rc = 2 ] \
   && printf '%s' "$out" | grep -q 'MODX_DB_NAME' \
   && printf '%s' "$out" | grep -q 'MODX_DB_USER'; then
  ok "a REMOTE MODX_DB_HOST with no schema named is REFUSED, naming both variables"
else
  fail "a remote host was accepted with the dev box's defaults (exit $rc)" \
       "database 'modx' as the dev-box user on somebody else's server is a green run against the
wrong estate
$out"
fi

# The other direction, and it is the half that matters: named, it must PROCEED. A guard that
# refuses everything would pass the check above while making the ground unbuildable.
out=$(probe MODX_DB_PASS=probe MODX_DB_HOST=modx-staging.db.internal.test MODX_DB_NAME=modx_staging \
      MODX_DB_USER=modx_staging -- '. tests/lib.sh; echo "through name=$DB_NAME user=$DB_USER"' 2>&1)
if printf '%s' "$out" | grep -q 'through name=modx_staging user=modx_staging'; then
  ok "  and with both named it proceeds, on the values given"
else
  fail "naming the schema did not get past the guard" "$out"
fi

# A LOCAL run is untouched — the whole point of scoping this to a remote host.
out=$(probe MODX_DB_PASS=probe -- '. tests/lib.sh; echo "local name=$DB_NAME user=$DB_USER"' 2>&1)
if printf '%s' "$out" | grep -q "local name=modx user=$(id -un)"; then
  ok "  and a LOCAL run still gets the dev-box defaults, unchanged"
else
  fail "the local path changed — a dev-box run must be byte-for-byte what it was" "$out"
fi

# ── 6. the ground's PHP is used, and the form it is invoked in ─────────────────────────────────
# On staging the PHP that matters is the container's, rendered as MODX_PHP_RUN. Before
# 2026-08-13 this repository did not read that variable at all — the ground could rule whatever it
# liked and the runner would still call a bare `php`.
#
# NOT by running run-all.sh: this suite IS one of the suites run-all.sh runs, and the first version
# of this check called `run-all.sh --requirements` from inside it — which ran this suite again, for
# ever. Found by it hanging, 2026-08-13. So the wiring is read where it is declared, and the
# variable's effect is probed on one small php file of this check's own making.
# A WRAPPER, not an env var: the first version set GROUND_PHP_MARK to prove the wrapper ran, and
# manifest-drift.sh failed the tree for an undeclared variable — correctly, since a test inventing
# an env name is exactly the drift it watches for. The wrapper prints its own mark instead, so
# nothing new is declared anywhere (2026-08-13).
wrap=$(mktemp); mark=$(mktemp)
printf '#!/bin/sh\nprintf through-the-ground\nexec php "$@"\n' > "$wrap"; chmod +x "$wrap"
printf '<?php\n' > "$mark"
out=$(probe MODX_PHP_RUN="$wrap" -- 'PHP_RUN=${MODX_PHP_RUN:-php}; $PHP_RUN "$1"' _ "$mark" 2>&1)
rm -f "$wrap" "$mark"
if [ "$out" = "through-the-ground" ]; then
  ok "MODX_PHP_RUN is what launches a php suite (a wrapper reaches it)"
else
  fail "MODX_PHP_RUN did not launch the php: '$out'" \
       "the ground rules which PHP runs the suites; a bare php ignores that ruling"
fi

# WHICH suites go to the ground's PHP: ALL of them, by ABSOLUTE path.
#
# This check has now been wrong twice, and both corrections came from the ground rather than from
# reading. First it accepted any wiring at all. Then it asserted "only jump-nav.php, because only
# jump-nav bootstraps MODx" — a guess about the axis. hanuman's journal, 2026-08-14, measured the
# real one: storage-identity and sso-provider-per-context died exit 255 on the HOST's php with
# fatals at common/lib/StorageIdentity.php:57 and SsoConfig.php:193 — CURLOPT_SSLCERT and
# curl_init(), which that php has no extension for. A suite that exercises the SITE's library
# needs the php that runs the site, whether or not it boots MODx first.
#
# Absolute, because `docker exec … php tests/x.php` answered "Could not open input file": the
# container starts in its own WORKDIR, and the ro mount puts this checkout at the same path on
# both sides, so $REPO/tests/x.php resolves identically here and there.
php_suites=$(grep -cE '^  "[^"]*tests/[a-z-]+\.php"' tests/run-all.sh)
via_ground=$(grep -cE '^  "\$PHP_RUN \$REPO/tests/[a-z-]+\.php"' tests/run-all.sh)
if [ "$php_suites" = "$via_ground" ] && [ "$php_suites" -gt 0 ]; then
  ok "  and every php suite goes to the ground's php by absolute path ($via_ground of $php_suites)"
else
  fail "php suites are not all on the ground's php by absolute path ($via_ground of $php_suites)" \
       "$(grep -nE '^  \"[^\"]*tests/[a-z-]+\.php\"' tests/run-all.sh | head -4)"
fi

# The path form is the half that decides whether the ruling can work at all: every php suite reads
# its own location, so the ground must hand it a path it can see. Measured 2026-08-13: `php < file`
# sets __FILE__ to 'Standard input code'.
# CODE ONLY — the first version of this check read the whole file and matched the COMMENT two
# screens up that explains why stdin is wrong. A check that its own documentation can fail is not
# a check (2026-08-13).
if ! sed 's/#.*//' tests/run-all.sh | grep -qE '\$PHP_RUN *<'; then
  ok "  and PATH-form, never stdin — __FILE__ would become 'Standard input code'"
else
  fail "run-all.sh pipes a suite into PHP on stdin" \
       "all eight php suites use __DIR__/dirname/relative require; stdin breaks every one"
fi

if [ "$(probe -- 'PHP_RUN=${MODX_PHP_RUN:-php}; echo $PHP_RUN')" = "php" ]; then
  ok "  and with MODX_PHP_RUN unset it is a bare php, as it always was"
else
  fail "the default changed" "a dev-box run must be byte-for-byte what it was"
fi

# ── 7. no bash suite calls a bare `php` ────────────────────────────────────────────────────────
# The ground's first run failed protect-on-save five times with "the create processor made a page
# — processor returned no id". Nothing was wrong with the protection: create() piped its script
# into a bare `php`, so on hanuman the HOST's php was asked to bootstrap a MODx that lives in a
# container. Five red lines about protection, on a ground where protection had never been tested.
#
# CODE ONLY, and both helpers are allowed: modx_php (must run where MODx is) and local_php (must
# run here — the `php -S` fixture server, kuber's Crypto.php). Wrapping the second kind would move
# the fixture server away from the port the test then curls, so this check must not push people
# toward one answer: it asks that the choice be MADE, not that it be modx_php.
# Comments AND BOTH kinds of quoted string are stripped before scanning: the first version of this
# check matched the word `php` inside its OWN ok/fail message and failed the tree for its own
# documentation. Twice in one day for that shape (2026-08-14).
bare=$(for f in tests/*.sh; do
         sed -e 's/#.*//' -e 's/"[^"]*"//g' -e "s/'[^']*'//g" "$f" \
           | grep -nE '(^|[^A-Za-z_$./-])php[[:space:]]' \
           | grep -vE 'modx_php|local_php|PHP_RUN' | grep -v '<?php' | sed "s|^|$f:|"
       done)
if [ -z "$bare" ]; then
  ok "no bash suite invokes a bare php — each call says WHERE it must run"
else
  fail "a bash suite calls php without saying where it must run" "$bare"
fi

# ── 8. clear-cache.php takes its docroot, and no file in this repo hardcodes the old bench ─────
# Four suites failed on the ground with "clear-cache.php failed:" and nothing else. The script
# said `require_once '/srv/local/modx/index.php'` — the dev bench that stopped existing when the
# bench became staging. A hardcoded docroot in a repository whose whole subject is "where does
# this run" is the defect this ticket exists for.
out=$(local_php clear-cache.php /definitely-not-a-docroot 2>&1); rc=$?
if [ $rc = 2 ] && printf '%s' "$out" | grep -q '/definitely-not-a-docroot' \
   && printf '%s' "$out" | grep -qi 'nothing was cleared'; then
  ok "clear-cache.php REFUSES a docroot that is not there, and names it"
else
  fail "clear-cache.php did not refuse a bad docroot (exit $rc)" "$out"
fi

# The DOCROOT, not everything under /srv/local: modx-snapshots/ is an agent work area on a dev
# box and is nobody's ground. So the pattern ends at the path, not at the prefix.
stale=$(grep -rnE '/srv/local/modx($|[^-a-zA-Z0-9])' \
          --include='*.php' --include='*.sh' --include='*.py' . \
        | sed -e 's/#.*//' -e 's|//.*||' | grep -vE 'tests/|docs/' \
        | grep -E '/srv/local/modx($|[^-a-zA-Z0-9])' || true)
if [ -z "$stale" ]; then
  ok "  and no shipped file hardcodes the old bench path"
else
  fail "the old bench path is hardcoded in a shipped file" "$stale"
fi

# ── 9. a snippet file must not carry a PHP OPEN TAG ────────────────────────────────────────────
# MODx wraps a snippet's body in its own <?php, so a file that carries one produces
# "syntax error, unexpected token <" the moment the element is used — and it produces it at the
# DOOR, in the compiled cache file, not anywhere a reader would look. actuatorInfo carried one and
# I deployed it: the actuator answered a PHP parse error on both grounds until this was found
# (2026-08-14). Every other snippet in this directory starts with its docstring; that is the
# convention and it was invisible until it was violated.
tagged=$(for f in common/snippets/*.php; do
           head -c 5 "$f" | grep -q '<?php' && echo "$f"
         done)
if [ -z "$tagged" ]; then
  ok "no snippet carries a <?php open tag — MODx supplies it"
else
  fail "a snippet carries a PHP open tag" \
       "MODx wraps the body itself, so this is a parse error at the door: $tagged"
fi

# ── 10. a snippet may not call a modX method that does not exist ───────────────────────────────
# actuatorInfo called $modx->sendResponse() — no such method in MODX 3 — behind an @, which
# suppresses nothing: PHP fatals on an undefined method whatever the operator says. The door
# printed its JSON and then a fatal underneath it, and it took mounting the element on a real
# ground to find out (2026-08-14). One name is checked because one name was wrong; this is a
# tripwire for a known mistake, not a type checker.
badcall=$(sed 's|//.*||' common/snippets/*.php common/plugins/* 2>/dev/null \
          | grep -nE '\$modx->sendResponse\(' || true)
if [ -z "$badcall" ]; then
  ok "no element calls \$modx->sendResponse() — it does not exist in MODX 3"
else
  fail "an element calls a modX method that does not exist" "$badcall"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
