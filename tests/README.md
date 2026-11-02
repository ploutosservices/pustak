# tests — what is checked, and where it must be run

    MODX_ROOT=/srv/local/modx \
    MODX_ESTATE=$HOME/gitea/work-products/modx-estate/estate.json \
    bash tests/run-all.sh          # everything, one verdict

**NAME THE GROUND OR SUITES REFUSE, AND A REFUSAL IS THE RESULT NOBODY INVESTIGATES.** On a bench
box, a bare `bash tests/run-all.sh` refused SIX suites on 2026-09-12 — and every one of those
refusals was about the caller's shell, not about the tree:

| what was missing | suites | what it printed |
|---|---|---|
| `MODX_DB_PASS` | 6 | "MODX_DB_PASS is not set" — and the bench account authenticates by **socket** and has no password at all. Fixed in `lib.sh`: the guard now asks the database whether it will answer, so on a dev box neither variable is needed |
| `MODX_ESTATE` | 2 | "his Search pages live in the estate", "'claude' is not declared protected in the estate MODX_ESTATE names" — the estate FILE, not the checkout |

21 passed / 0 failed / 10 refused became **29 passed / 1 failed / 2 refused**, and the one failure
had been hidden behind a refusal for weeks. `run-all.sh --requirements` asks the suites
themselves what a ground must provide; it is the list to read before concluding that a suite cannot
run here.

The first tests in this repo. They exist because the features they cover fail *silently by design*:
a page that cannot establish who is reading it renders **blank**, and blank is also the correct
output for "nobody is signed in". Looking at the page cannot tell those two apart, so something else
has to.

| Run | What it proves | Where |
|---|---|---|
| `php tests/tableRenderer-auth.php` | the `&auth` logic and the token it mints — verified by **kuber's own `Crypto::jwtVerify()`**, with the header read off a real socket | anywhere with PHP + kuber's checkout |
| `bash tests/verify-protection-wrong-class.sh` | `verify-file-protection.py` reports a membership of the wrong kind, in both directions | **bench only** |
| `bash tests/clear-cache-reaches-contexts.sh` | after `clear-cache.php`, a changed setting is what a real page renders | **bench only** |
| `bash tests/head-favicon.sh` | every context declares the application's mark (the veena), and every URL it names exists on cdn | **bench only**, read-only |
| `bash tests/protect-on-save.sh` | a page created or undeleted in the manager refuses an anonymous request — **401, or a redirect to its context's sign-in** — before any job runs, the `support` subtree still answers 200, and the verifier goes red on each way the enforcement can silently stop | **bench only** |
| `bash tests/sso-verified-email.sh` | a real sign-in leaves `sso.verified_email` in the session — the one fact `&auth` asserts | **bench only**, needs the vhost + the door's dev realm |
| `bash tests/auth-end-to-end.sh` | a real page, a real signed-in reader, a Bearer arriving at a real listener, and an anonymous reader asking nothing | **bench only**, same |
| `bash tests/suites-accept-their-ground.sh` | these suites can address a schema and a docroot that are **not on the machine running them** — `MODX_DB_HOST` reaches `q()`, no suite hardcodes the docroot, and `MODX_INSTALL_DIR` is refused rather than ignored | **anywhere**, no database |
| `python3 tests/element-body-db-form.py` | the three writers of an element body — `04-access-control.py`, `apply-modx-elements.sh` and the verifier that compares them — store and expect the **same bytes**, so a correct deploy cannot report drift | **anywhere**, no database |
| `python3 tests/settings-guard.py` | a setup pass that empties a setting **cannot commit it** — it rolls back and exits 1 — and each of the four passes that write settings still ends at the guard | **anywhere**: builds its own two tables in a private sqlite file, or in a real schema with `MODX_DRILL_DSN` |

`tests/lib.sh` holds the shared parts: `q`, `check`, `summary`, the refusals, and `clear_cache`.

## Three rules these follow, and none of them is decoration

**Every checker is run against a known answer before its unknown ones are believed.** A negative
assertion ("no request was made", "the token was refused") is worthless unless the same machinery can
be shown producing the positive. So the wrong-key case sits beside the right-key case, and the
"no request" cases sit beside one that logs a request. `auth-end-to-end.sh` passed on its first run;
it was believed only after the session stamp was removed and it went red in four places.

**They refuse rather than degrade.** No kuber checkout means the token would be checked by a copy of
their verifier instead of the real one — the suite exits 2 rather than quietly dropping the check
(`ALLOW_NO_KUBER=1` overrides, knowingly). An `sso.oidc_auth_endpoint` that is not a non-production
realm of the door means signing in as somebody for real; exit 2. A `kuber.jwt_private_key` already present means a real key is here
and would be overwritten with a throwaway; exit 2. A bench that already reports protection drift
cannot distinguish an induced fault from the one already there; exit 2. `run-all.sh` counts a refusal
separately from a pass, because "could not check" is not "checked, and it is fine".

**No step of a test may fail silently.** Every one of these was written with `>/dev/null` on a
command whose failure looked exactly like success, and one of them cost an hour: `php
"$REPO/clear-cache.php"` where `$REPO` had resolved to `/` printed "Could not open input file" into
`/dev/null`, so the cache was never cleared, and MODx was suspected for a fault in the harness.
`clear_cache` now reads its own output and aborts, and `require_repo` refuses before any of it.

## The two-second lie, worth knowing outside these tests

`clear-cache.php` regenerates MODx's caches as PHP files, and PHP-FPM serves those through opcache,
which re-checks a file's timestamp at most once every `opcache.revalidate_freq` seconds — **2** here.
So for up to two seconds after a cache clear, a web request compiles the old file and **a setting
that is unquestionably in the database reads as empty.**

It is reproducible from a script every time and never by hand, because typing the same commands
takes longer than the window. Anything that changes a setting and then verifies **over HTTP** must
wait it out (`clear_cache` does). A verifier that reads the database — `setup/verify-*.py`, and
infra's monitors — is unaffected, which is why nobody had met this before.

## The bench tests write, and clean up after themselves

Between them they create one session, half a dozen pages, one throwaway system setting and one
throwaway signing key, and remove all of it. `protect-on-save.sh` goes further: it induces four
faults in the installed access enforcement and re-runs `setup/04-access-control.py` after each, so it
both *breaks* and *repairs* the bench's access control on every run — which is also the assertion
that the repair is one step. They are for the dev bench and refuse to run against anything that
looks like production.

## Never `| grep -q` a response

`check "$(echo "$body" | grep -qF needle && echo 1 || echo 0)"` is a race, not an assertion, as soon
as `$body` is a whole page: `grep -q` exits on the first match, `echo` is still writing, bash's
`echo` takes SIGPIPE, the command substitution yields nothing, and `check ""` reads as **FAIL on a
response that is correct**. The earlier the needle sits in the page, the likelier the false failure —
so `<head>` assertions are the worst affected.

Measured 2026-07-30 on a 43,401-byte page whose bytes were byte-identical across 15 fetches: the same
assertions failed in a *different* combination on every run, including a control that looked for
`<title>`. Use `has` / `hasnt` / `hasre` from `lib.sh` — bash's own matching, no fork, no pipe.

## Pin the host, always

A bench name in the internal zone is not guaranteed to reach the box you are on — a stale name can
answer from another ground entirely, a different docroot and a different database, so an edit made
here can be "verified" against a box that never saw it. Every request in these tests reads its
scheme and door off the context's own `site_url` (a port on a port-door bench) and is pinned with
`--resolve <door>:<port>:$IP` (`127.0.0.1` by default). That pin is the only reason a green run
says anything about *this* box.
