#!/usr/bin/env bash
# run-all.sh — every test in this directory, in order, with one verdict.
#
#     bash tests/run-all.sh
#     bash tests/run-all.sh --requirements    what a ground must provide, ASKED OF THE SUITES
#
# Order matters once: verify-protection-wrong-class refuses to run on a bench that already reports
# drift, so it goes first and its refusal is a statement about the bench rather than about the tests
# that follow. Everything else is independent.
#
# A suite that REFUSES (exit 2) is reported as such and does not count as a pass. That distinction is
# the point: "could not check" and "checked, and it is fine" are different answers, and a runner that
# prints a single green line for both is the thing these tests exist to prevent.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# The door's issuer, for the one PHP suite that discovers against the live provider
# (sso-provider-per-context.php): the ground's first context row says where it signs in. A ground
# that cannot answer leaves it unset and that suite skips the probe, aloud.
if [ -z "${MODX_DOOR_ISSUER:-}" ]; then
  MODX_DOOR_ISSUER=$(bash -c '. tests/lib.sh >/dev/null 2>&1; q "SELECT value FROM modx_context_setting WHERE \`key\`='"'"'sso.oidc_issuer'"'"' LIMIT 1;"' 2>/dev/null)
  export MODX_DOOR_ISSUER
fi

# ── the ground's PHP, not this machine's ───────────────────────────────────────────────────────
# infra ruled on 2026-08-13: on the staging ground the PHP that matters is the one
# INSIDE the MODx container, and they render MODX_PHP_RUN='docker exec -i modx-staging php'. This
# repository ignored that variable entirely — the eight php suites were launched with a bare `php`,
# which on that host is either the wrong runtime or none.
#
# PATH FORM, DELIBERATELY: `$PHP_RUN tests/x.php`, never `$PHP_RUN < tests/x.php`. Measured
# 2026-08-13: all eight suites read their own location (__DIR__, dirname(), relative require) and
# `php < file` sets __FILE__ to "Standard input code", so every one of them would fail to find the
# files it checks. The path form means the ground must make this checkout visible to whatever runs
# the PHP — for a container, a read-only bind-mount at the same path. That is a property of the
# ground.
PHP_RUN=${MODX_PHP_RUN:-php}
REPO=$(pwd)

# EVERY php suite runs on the ground's PHP, and by ABSOLUTE path.
#
# Two measurements from hanuman, 2026-08-14, replacing two guesses of mine in one day:
#   * `docker exec … php tests/jump-nav.php` -> "Could not open input file". The container starts
#     in its own WORKDIR, so a relative path is resolved against the wrong directory even with the
#     checkout mounted. Absolute, and the mount puts it at the same path on both sides.
#   * storage-identity and sso-provider-per-context died exit 255 under the HOST's php:
#     "thrown in common/lib/StorageIdentity.php:57" and "SsoConfig.php:193" — CURLOPT_SSLCERT and
#     curl_init(). The host PHP has no curl extension; the container's does, because it serves the
#     site. A suite that exercises the site's library must run on the PHP that runs the site.
# So the earlier split (bootstrap vs not) was the wrong axis. The axis is: does it exercise the
# APPLICATION. All eight do.

suites=(
  "bash tests/manifest-drift.sh"
  "$PHP_RUN $REPO/tests/application-badge.php"
  "$PHP_RUN $REPO/tests/storage-identity.php"
  "$PHP_RUN $REPO/tests/estate-identity-on-the-ground.php"
  "bash tests/simplesearch-untouched.sh"
  "$PHP_RUN $REPO/tests/actuator-verdicts.php"
  "$PHP_RUN $REPO/tests/actuator-typed.php"
  "$PHP_RUN $REPO/tests/context-base.php"
  "$PHP_RUN $REPO/tests/standing-and-term.php"
  "$PHP_RUN $REPO/tests/diagnostics.php"
  "bash tests/estate-clean.sh"
  "bash tests/verify-protection-wrong-class.sh"
  "$PHP_RUN $REPO/tests/tableRenderer-auth.php"
  "$PHP_RUN $REPO/tests/tableRenderer-backlog-record.php"
  "bash tests/clear-cache-reaches-contexts.sh"
  "bash tests/head-favicon.sh"
  "$PHP_RUN $REPO/tests/jump-nav.php"
  "$PHP_RUN $REPO/tests/tenant-jumps.php"
  "bash tests/protect-on-save.sh"
  "bash tests/create-documents.sh"
  "bash tests/protected-absorb.sh"
  "bash tests/context-protection.sh"
  "bash tests/element-names-bind.sh"
  "bash tests/sso-verified-email.sh"
  "$PHP_RUN $REPO/tests/sso-provider-per-context.php"
  "$PHP_RUN $REPO/tests/unauthorized-names-itself.php"
  "$PHP_RUN $REPO/tests/signing-out-really-signs-out.php"
  "$PHP_RUN $REPO/tests/edge-context.php"
  "python3 tests/widest-group-derives.py"
  "python3 tests/settings-guard.py"
  "python3 tests/element-body-db-form.py"
  "bash tests/pull-direction.sh"
  "bash tests/suites-accept-their-ground.sh"
  "bash tests/failures-name-themselves.sh"
  "python3 p12-import.py"
  "python3 tests/addition-reviewed.py"
  "$PHP_RUN $REPO/tests/apply-environment.php"
  "python3 tests/content-vocabulary.py"
  "bash tests/publish-clean.sh"
  "python3 tests/app-name-from-manifest.py"
  "bash tests/before-apply-touches-nothing.sh"
  "$PHP_RUN $REPO/tests/kuber-google-token.php"
  "bash tests/auth-end-to-end.sh"
  "bash tests/signed-in-bar.sh"
  "bash tests/jump-slot.sh"
  "bash tests/sso-renew.sh"
  "bash tests/backchannel-logout.sh"
  "bash tests/admin-door.sh"
  "bash tests/estate-brand.sh"
  "bash tests/unknown-address-refused.sh"
  "bash tests/ground-is-the-shipped-version.sh"
)
# AND THE SUITES OF WHAT AN INSTALL ADDS. A part this repository carries beyond the published
# enhancement has its suite named in tests/local.list (one command per line, $PHP_RUN and $REPO as
# above), which only that install holds — so the published list names nothing it does not ship.
if [ -f "$REPO/tests/local.list" ]; then
  while IFS= read -r s; do
    case "$s" in ''|'#'*) continue ;; esac
    s=${s//'$PHP_RUN'/$PHP_RUN}; suites+=("${s//'$REPO'/$REPO}")
  done < "$REPO/tests/local.list"
fi

# ── --before-apply: what a DEPLOY may run, on any ground, before it applies ─────
#
# A deploy verb runs as `automation` on the ground it deploys to, and on production that ground
# holds production's schema. Most suites above are BENCH suites: tests/lib.sh addresses
# ${MODX_DB_NAME:-modx} at localhost by socket, and protect-on-save creates and removes resources
# through MODX's own processors. Run by a production deploy, that is a write to production data
# (infra's objection, 2026-10-06). So a deploy does not run the whole list; it runs THIS
# one, and nothing in it may reach anything but this checkout and a temporary directory.
#
# HOW A SUITE GETS ON THIS LIST, and why the list is short. Each one passed with no network, the
# database socket hidden and every MODX_* variable removed (tests/before-apply-touches-nothing.sh
# proves that on every run of the bench list), AND names no database, socket, container, docroot
# or URL in its own text. Several suites pass the first test and fail the second — they use a
# database or a URL when the ground offers one — and they stay off: estate-clean, settings-guard,
# actuator-verdicts, storage-identity, suites-accept-their-ground,
# sso-provider-per-context. A suite is added here only after both are true of it.
#
# THE MODE IS STRICT where the bench list is lenient: a suite that REFUSES (exit 2) is red here,
# because a carrier that passes on "could not check" is a gate that fails open. Every suite runs
# with an empty environment (PATH and a temporary HOME only), so a ground's MODX_DB_* or MODX_ROOT
# cannot reach it whatever the verb's shell holds. MODX_PHP_RUN is honoured for the php suites, as
# the bench list honours it, because the PHP that matters is the ground's.
before_apply=(
  "$PHP_RUN $REPO/tests/tenant-jumps.php"
  "$PHP_RUN $REPO/tests/actuator-typed.php"
  "$PHP_RUN $REPO/tests/application-badge.php"
  "$PHP_RUN $REPO/tests/context-base.php"
  "$PHP_RUN $REPO/tests/standing-and-term.php"
  "$PHP_RUN $REPO/tests/diagnostics.php"
  "$PHP_RUN $REPO/tests/edge-context.php"
  "$PHP_RUN $REPO/tests/unauthorized-names-itself.php"
  "$PHP_RUN $REPO/tests/signing-out-really-signs-out.php"
  "$PHP_RUN $REPO/tests/kuber-google-token.php"
  "$PHP_RUN $REPO/tests/tableRenderer-backlog-record.php"
  "python3 tests/widest-group-derives.py"
  "python3 tests/element-body-db-form.py"
  "bash tests/pull-direction.sh"
  "bash tests/failures-name-themselves.sh"
  "python3 p12-import.py"
  "python3 tests/addition-reviewed.py"
  "$PHP_RUN $REPO/tests/apply-environment.php"
  "python3 tests/content-vocabulary.py --tree-only"
  "python3 tests/app-name-from-manifest.py"
)

if [[ "${1:-}" == --before-apply-list ]]; then
  printf '%s\n' "${before_apply[@]}"; exit 0
fi

if [[ "${1:-}" == --before-apply ]]; then
  home=$(mktemp -d); trap 'rm -rf "$home"' EXIT
  ok=0; red=(); n=0
  for s in "${before_apply[@]}"; do
    n=$((n+1))
    out=$(env -i PATH="$PATH" HOME="$home" $s 2>&1); rc=$?
    last=$(printf '%s' "$out" | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-160)
    printf -- '--- %s: exit %d | %s\n' "${s##*/}" "$rc" "$last"
    if [[ $rc == 0 ]]; then ok=$((ok+1)); else
      red+=("${s##*/}")
      printf '%s\n' "$out" | grep -E '^\s*(FAIL|REFUS)' | head -20 | sed 's/^/    /'
    fi
  done
  printf '\nbefore-apply: %d of %d suite(s) green\n' "$ok" "$n"
  if [[ ${#red[@]} -gt 0 ]]; then
    printf 'RED (a refusal counts as red here): %s\n' "${red[*]}"
    exit 1
  fi
  exit 0
fi

# ── --requirements: the ground contract, asked of the suites themselves ────────────────────────
#
# infra was asked to build a ground these suites can run on. The list of what that ground must
# provide was prose in a ticket append, written by me, and prose in a ticket is a SECOND source
# that is free to disagree with the code — the exact shape this repository keeps being bitten by.
#
# So this asks the suites. Every MODX_* variable is removed from the environment and each suite is
# run: what it prints when it refuses IS its requirement, stated by the code that enforces it, and
# it cannot drift from the code because it is produced by running the code.
#
# It also enforces the rule the refusals exist for: a suite that refuses without naming a
# variable or a path is reported as a DEFECT here, because "REFUSING" with no cause tells whoever
# is building the ground nothing at all.
if [[ "${1:-}" == --requirements ]]; then
  unset_args=()
  while IFS='=' read -r v _; do
    [[ $v == MODX_* ]] && unset_args+=(-u "$v")
  done < <(env)

  echo "What a ground must provide, asked of the suites (every MODX_* removed from the env):"
  echo
  vars=""; mute=0; lied=0
  for s in "${suites[@]}"; do
    # PEEL: a suite names the FIRST thing it is missing, not all of them. So it is re-run with a
    # placeholder standing in for what it just named, until it stops refusing. The placeholder is
    # deliberately a value that cannot work anywhere — if a suite goes GREEN on it, the suite is
    # not checking what it claims to, and that is reported here rather than discovered on the
    # ground.
    want=""; extra=(); round=0
    while [[ $round -lt 8 ]]; do
      out=$(env "${unset_args[@]}" "${extra[@]}" $s 2>&1); rc=$?
      [[ $rc -ne 2 ]] && break
      named=$(printf '%s\n' "$out" | grep -oE 'MODX_[A-Z_]+' | sort -u)
      paths=$(printf '%s\n' "$out" | grep -oE '(^|[ =])/[a-z0-9/._-]{4,}' | tr -d ' =' | sort -u)
      # A database error is a NAMED cause, not a mute one: it quotes the schema or the user the
      # suite tried, which is exactly what somebody building the ground needs to see. Counting it
      # as mute made this mode cry defect on five suites that were answering perfectly well — the
      # classifier was wrong, not the suites (skunkworks, 2026-08-13, found by running it).
      dberr=$(printf '%s\n' "$out" | grep -oE "ERROR [0-9]+ .*" | head -1)
      if [[ -z $named && -z $paths && -n $dberr ]]; then
        printf '  %-42s %s\n' "${s#* }" "reached the database and it answered:"
        printf '  %-42s   %s\n' "" "$dberr"
        want="DBERR"; break
      fi
      if [[ -z $named && -z $paths ]]; then
        mute=$((mute+1))
        printf '  %-42s %s\n' "${s#* }" "— REFUSES WITHOUT NAMING ANYTHING —"
        printf '  %-42s   %s\n' "" "$(printf '%s' "$out" | head -1)"
        want="MUTE"; break
      fi
      new_one=0
      for v in $named; do
        [[ " $want " == *" $v "* ]] && continue
        want="$want $v"; extra+=("$v=REQUIREMENTS_PROBE"); new_one=1
      done
      [[ -n $paths && " $want " != *" $paths "* ]] && want="$want $paths"
      [[ $new_one -eq 0 ]] && break            # nothing new to offer: stop rather than spin
      round=$((round+1))
    done
    [[ $want == MUTE || $want == DBERR ]] && continue
    [[ -z $want ]] && continue                 # ran without a ground: nothing to state
    if [[ $rc -eq 0 ]]; then
      lied=$((lied+1))
      printf '  %-42s %s\n' "${s#* }" "PASSED on placeholder values —$want"
    else
      printf '  %-42s %s\n' "${s#* }" "$want"
    fi
    vars="$vars $want"
  done

  echo
  echo "  distinct:$(printf '%s' "$vars" | tr ' ' '\n' | grep '^MODX_' | sort -u | tr '\n' ' ')"
  rc_out=0
  if [[ $mute -gt 0 ]]; then
    echo
    echo "  $mute suite(s) REFUSED WITHOUT NAMING what they need — a ground cannot be built from"
    echo "  that, and a person reading it learns only that something is wrong."
    rc_out=1
  fi
  if [[ $lied -gt 0 ]]; then
    echo
    echo "  $lied suite(s) PASSED with REQUIREMENTS_PROBE as their credentials. A suite that goes"
    echo "  green on a value that cannot work is not checking what it says it checks."
    rc_out=1
  fi
  exit $rc_out
fi

# A SUITE THAT CANNOT RUN WHERE MODx IS IN A CONTAINER is listed as not run here, with its reason,
# and counted nowhere. sso-renew's stand-in kuber reader listens on THIS machine's loopback,
# which a containerised MODx cannot reach, so on staging it refused every night and its refusal
# turned the whole job red — the alert re-fired every four hours for a ground fact, not a defect.
# Kept out of the counts rather than passed: the renewal is proven on a bench, not here, and the
# summary says so on every run. --requirements above still asks it what a ground must provide.
not_here=()
if [ -n "${MODX_PHP_RUN:-}" ]; then
  keep=()
  for s in "${suites[@]}"; do
    case "$s" in
      "bash tests/sso-renew.sh") not_here+=("sso-renew.sh (its stand-in kuber reader is on this machine's loopback; MODx is in a container)") ;;
      "bash tests/backchannel-logout.sh") not_here+=("backchannel-logout.sh (its stub door keys are on this machine's loopback; MODx is in a container)") ;;
      "bash tests/admin-door.sh") not_here+=("admin-door.sh (its stub door is on this machine's loopback; MODx is in a container)") ;;
      "bash tests/before-apply-touches-nothing.sh") not_here+=("before-apply-touches-nothing.sh (its sandbox is a user namespace, where the container's PHP cannot be reached through sudo docker; the deploy verb runs --before-apply itself)") ;;
      *) keep+=("$s") ;;
    esac
  done
  suites=("${keep[@]}")
fi

ok=0; bad=0; skipped=0; failed_names=(); refused_names=(); why=()
for s in "${suites[@]}"; do
  printf '\n=== %s\n' "$s"
  # The docroot travels as an ARGUMENT to every php suite: `docker exec` carries none of this
  # shell's environment inside, and a suite that reads getenv('MODX_ROOT') there gets nothing —
  # jump-nav refused for exactly that on the ground (2026-08-14). Suites that do not want it
  # ignore an extra argv entry.
  case "$s" in *".php") out=$($s "${MODX_ROOT:-}" 2>&1); rc=$? ;; *) out=$($s 2>&1); rc=$? ;; esac
  echo "$out" | sed 's/^/  /'
  # ONE LINE PER SUITE, ALWAYS. Four suites came back from the staging ground with a `===` header
  # and nothing after it across three runs (2026-08-14), and from here that is
  # indistinguishable between "the suite printed nothing" and "something between the suite and the
  # journal dropped it". This line is short enough to survive a journal rate limit and carries the
  # two facts that tell those apart: the exit code, and how much output the RUNNER saw.
  # AND THE LAST LINE OF A FAILURE, on the same line. Measured 2026-08-14: the ground's journal
  # DROPS whole suite bodies — estate-clean returned exit 0 with 19 lines and none of them arrived,
  # while this one-liner did. So a failing suite carries its own last line here, where it survives.
  last=""
  [ "$rc" != 0 ] && last=$(printf '%s' "$out" | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-160)
  printf -- '--- %s: exit %d, %d line(s) captured%s\n' "$s" "$rc" \
            "$(printf '%s' "$out" | grep -c '')" "${last:+ | last: $last}"
  case $rc in
    0) ok=$((ok+1)) ;;
    2) skipped=$((skipped+1)); refused_names+=("${s##*/}") ;;
    *) bad=$((bad+1)); failed_names+=("${s##*/}") ;;
  esac
  # WHY IT WAS RED, kept for the end (2026-11-01). The `last:` above is one line, and a FAIL sits
  # mid-suite: staging's document-creation suite failed with its FAIL above night-desk's 400-line window
  # and its last line the "N passed, M failed" count. Each FAIL with its detail line, and each
  # REFUSING line, is reprinted just before the summary, where the window always reaches.
  if [ "$rc" != 0 ]; then
    red=$(printf '%s\n' "$out" | grep -A1 -E '^[[:space:]]*FAIL[[:space:]]|REFUSING' | grep -v '^--$' | head -30 | cut -c1-300)
    why+=("why ${s##*/} (exit $rc):" "${red:-  (no FAIL or REFUSING line; the last line is above)}")
  fi
done

for w in "${why[@]}"; do printf '%s\n' "$w"; done

# THE SUMMARY NAMES THE RED ONES (2026-09-22). The staging ground's journal is read through
# night-desk q=job, which serves a run's LAST 400 lines, and one suite (login-card-renders, since
# removed) emitted ~740 lines of Fenom deprecation notices on the container's PHP. So for two nights staging reported
# "34 passed, 1 failed" while the one failing suite's own `---` line sat above the window, and
# nobody without a shell on the ground could say which suite it was. The last line always survives.
printf '\n%d suite(s) passed, %d failed, %d refused to run\n' "$ok" "$bad" "$skipped"
[ "$bad" != 0 ] && printf 'failed: %s\n' "${failed_names[*]}"
[ "$skipped" != 0 ] && printf 'refused: %s\n' "${refused_names[*]}"
for n in "${not_here[@]}"; do printf 'not run on this ground: %s\n' "$n"; done
[ "$bad" = 0 ] && [ "$skipped" = 0 ]
