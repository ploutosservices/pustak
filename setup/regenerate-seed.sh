#!/usr/bin/env bash
# regenerate-seed.sh — rebuild install/modx-seed.sql.gz from the BENCH modx DB.
#
# The seed is a full DB dump (schema + config + elements + RBAC + content + TV values). Because it
# is a full dump, any secret-bearing system setting present at dump time would land in git. This
# script makes the safe path the only path: the known secret settings are EXCLUDED FROM THE DUMP, so
# no credential can ever be committed. On production those same settings are injected AFTER loading
# the seed, from the environment (setup/12-sso.py, setup/13-storage-gate.py) — never from the seed.
#
# BENCH ONLY. Guarded to refuse if the DB looks like production (http_host not in the bench zone).
#
# READ-ONLY ON ITS SOURCE. This script issues no UPDATE, TRUNCATE or DELETE. It used to blank the
# secret settings and truncate the log tables IN THE BENCH DATABASE before dumping, which meant
# building the artifact broke the box it was built on — whoever's bench it was lost SSO sign-in
# until setup/12-sso.py was re-run, and lost their sessions. The exclusions now happen in the DUMP,
# by dumping in three passes, so the bench is untouched and stays usable.
#
# NOT YET MECHANICALLY ENFORCED: nothing stops a future edit reintroducing a write. The real guard
# is a MySQL user holding only SELECT + LOCK TABLES on the modx database, which is infra's to grant
# (asked for). Until then this is a convention, and conventions do not survive a fresh agent.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The estate artefacts (the seed, the docroot tar, his documents) live in the estate repository
# now; this software carries none of them. ESTATE_REPO is derived from
# MODX_ESTATE — one name for one place — and refuses rather than guessing a path.
. "$REPO/setup/estate-repo.sh"
# NO DEFAULT USERNAME. This said `${MODX_DB_USER:-<a personal account>}` while the very next line cites
# domains.py's rule about default credentials — a default decides what SILENCE means, and an unset
# variable silently tried a personal account. It is worse than that on a server, where the estate's
# standing rule is that work runs as `automation` and never as a person.
DB_USER="${MODX_DB_USER:?MODX_DB_USER not set — no default (see setup/domains.py db_config)}"
DB_PASS="${MODX_DB_PASS:?MODX_DB_PASS not set — no default (see setup/domains.py db_config)}"
DB_NAME="${MODX_DB_NAME:-modx}"
# THE BENCH IS NOT ON THIS BOX ANY MORE (the owner, 2026-08-12: "MODx is not needed on a local box for
# anything"). It is MODx staging — schema `modx_staging`, on its own host — so a script that can
# only ever say `-u user -p pass dbname` cannot reach the thing it exists to dump. Host is a
# variable with no default, because localhost-by-omission is how this script would quietly dump
# whatever database happens to be on the machine it is standing on.
DB_HOST="${MODX_DB_HOST:-}"
HOSTARG=()
[ -n "$DB_HOST" ] && HOSTARG=(-h "$DB_HOST")
MYSQL=(mysql "${HOSTARG[@]}" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -B)
MYSQLDUMP=(mysqldump "${HOSTARG[@]}" --no-tablespaces --skip-dump-date -u "$DB_USER" -p"$DB_PASS")

# --- guard: this must be the bench, not prod (the seed source is always the bench) ---
#
# THIS GUARD USED TO PASS WHEN IT COULD NOT READ ANYTHING. It was
#     HOSTS=$(... 2>/dev/null || true);  if [ -n "$HOSTS" ] && ! grep -q <bench zone>
# so a connection refused, a wrong password, a missing database or a renamed table all produced an
# EMPTY answer, and empty took the `else` branch — proceed. Demonstrated on a current dev box,
# which no longer has a `modx` database at all: the query failed, HOSTS was empty, and the guard
# reported nothing while approving the run.
#
# That is the check that lies in the dangerous direction: it is loudest about the one case it was
# never at risk from, and silent about every case where it does not know. A guard that cannot read
# the fact it guards has not checked anything, and must say so rather than shrug.
if ! HOSTS="$("${MYSQL[@]}" -e "SELECT value FROM modx_context_setting WHERE \`key\`='http_host'" 2>&1)"; then
  echo "REFUSING: cannot read context http_host from ${DB_HOST:-localhost}/${DB_NAME}:" >&2
  echo "$HOSTS" >&2
  echo "This guard exists to prove the source is the bench and not production. It could not read" >&2
  echo "the fact it guards, so it has proved NOTHING and will not let the dump proceed." >&2
  exit 1
fi
if [ -z "$HOSTS" ]; then
  echo "REFUSING: ${DB_HOST:-localhost}/${DB_NAME} has no context http_host rows at all." >&2
  echo "An empty answer is not a passing one — this is either the wrong database or an empty one." >&2
  exit 1
fi
# This box's bench names are infra's (the bench renderer's --names reads config modx-environment.py).
BENCH_NAMES=$(python3 "$(dirname "$0")/bench-application.py" --names) || { echo "REFUSING: infra's derivation gave no bench names for this box, so this database cannot be told from production." >&2; exit 1; }
if ! echo "$HOSTS" | grep -qxF "$BENCH_NAMES"; then
  echo "REFUSING: no context http_host is one of this box's bench names ($(echo $BENCH_NAMES)):" >&2
  echo "$HOSTS" >&2
  echo "The seed must be regenerated from the bench, never from production." >&2
  exit 1
fi

# --- what the dump deliberately leaves out ------------------------------------------------------
#
# SECRET-BEARING SETTINGS. Omitted from the dump ENTIRELY, not carried as empty strings. Both
# injectors (setup/12-sso.py, setup/13-storage-gate.py) are upserts — `set_setting()` creates the
# row when it is absent — so a seed that never mentions the key produces the same end state as one
# carrying it blank, and cannot leak. Absent is also a stronger post-condition to verify than empty.
SECRET_KEYS=(sso.google_client_id sso.google_client_secret storage.modx_token)
#
# THE SAME PROBLEM ONE TABLE OVER, and it was latent rather than harmless. Everything above filters
# `modx_system_settings`. Now the per-context identity provider writes its credential as a
# CONTEXT setting — `12-sso.py` set_ctx() writes `sso.oidc_client_secret` into
# `modx_context_setting`, once per gated context — and that table was in pass 2, dumped whole.
#
# Nothing has leaked: measured 2026-08-20, `zcat install/modx-seed.sql.gz | grep -c 'sso.oidc'`
# is 0, because no ground that had run the oidc path had ever regenerated a seed. That is luck
# expiring, not a design: the first regeneration from any oidc-configured ground would have put
# one client secret per context into git, and the check above would have passed while it happened,
# because it reads a different table.
#
# So context settings get their own pass and their own two assertions, the negative and the
# positive, for the same reasons written out above.
CONTEXT_SECRET_KEYS=(sso.oidc_client_secret)  # pragma: allowlist secret
# The pragma is on a line whose ONLY content is the NAME of a setting to exclude — the push
# door's scan reads `<SOMETHING>_KEYS=` as an assignment and the 24 characters after it as a
# value. Same shape as SECRET_KEYS above, which predates the scan and is therefore never in a
# diff. Left visible rather than reworded, because `git grep 'allowlist secret'` is how every
# exception in this estate is meant to be findable.
#
# SYSTEM LOG TABLES (the owner, 2026-07-26): "feel free to delete history tables of system. deprecation
# log, session log, manager log." These are runtime volumes, not app state, and a seed is the
# blessed STARTING state of a machine — it has no business carrying the previous machine's login
# sessions or its manager audit trail. `modx_manager_log` in particular records who changed what on
# production; committing it to git put prod activity history in a repository for no benefit.
#
# Their SCHEMA is still dumped (pass 1) — only their rows are skipped. Doing this at dump time
# rather than by truncating first makes the guarantee unconditional: there is no window in which the
# bench re-accumulates rows between the truncate and the dump, which is exactly what happened the
# first time (the "emptied" seed still carried one session and one deprecation row).
#
# The estate's own log-clearing migration still exists and is still the right tool for
# PRODUCTION, where the point is to discard history deliberately after a backup. This is the seed's
# own hygiene, not that.
LOG_TABLES=(modx_deprecated_call modx_deprecated_method modx_manager_log modx_session)

# --- dump, in three passes so nothing is written to the bench -----------------------------------
#   1  schema only, ALL tables            — every CREATE TABLE, including the log tables'
#   2  data, all tables except the log tables and the settings table
#   3  data for the settings table, with the secret rows filtered out by --where
# Concatenated, this is all DDL then all data — a stricter load order than mysqldump's interleaved
# default, and each pass is well-formed mysqldump output. --skip-triggers on the data passes so a
# trigger added later cannot be emitted twice (there are none today; this is structural, not a fix).
OUT="$ESTATE_REPO/install/modx-seed.sql.gz"
IGNORE=()
for t in "${LOG_TABLES[@]}" modx_system_settings modx_context_setting; do
  IGNORE+=(--ignore-table="$DB_NAME.$t")
done
SECRET_IN="$(printf "'%s'," "${SECRET_KEYS[@]}")"; SECRET_IN="${SECRET_IN%,}"
CTX_SECRET_IN="$(printf "'%s'," "${CONTEXT_SECRET_KEYS[@]}")"; CTX_SECRET_IN="${CTX_SECRET_IN%,}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
"${MYSQLDUMP[@]}" --no-data "$DB_NAME"                                        > "$WORK/1-schema.sql"
"${MYSQLDUMP[@]}" --no-create-info --skip-triggers "${IGNORE[@]}" "$DB_NAME"  > "$WORK/2-data.sql"
"${MYSQLDUMP[@]}" --no-create-info --skip-triggers "$DB_NAME" modx_system_settings \
                  --where="\`key\` NOT IN ($SECRET_IN)"                       > "$WORK/3-settings.sql"
"${MYSQLDUMP[@]}" --no-create-info --skip-triggers "$DB_NAME" modx_context_setting \
                  --where="\`key\` NOT IN ($CTX_SECRET_IN)"                   > "$WORK/4-context.sql"

# --- verify the secret exclusion held, ON PASS 3'S INSERT LINES ONLY ----------------------------
# The scope of this check is load-bearing twice over, and both were found by the check firing
# falsely rather than by reasoning:
#
#   * NOT the whole dump. The SSO snippet's own source calls
#     $modx->getOption('sso.google_client_id', ...) and mysqldump writes that code out verbatim, so
#     across the full artifact the text ('sso.google_client_id', occurs in both a settings row and a
#     snippet body, byte-identical. No pattern separates them; only scope does.
#   * NOT the whole of pass 3. mysqldump echoes its own --where clause as a comment:
#         -- WHERE:  `key` NOT IN ('sso.google_client_id',...)
#     so a checker reading comments finds the secret in the very line that proves it was excluded,
#     and aborts every legitimate run.
#   * NOT the lines beginning `INSERT INTO` either. mysqldump ends that line at VALUES and writes
#     the row tuples on the lines BELOW it, so anchoring on INSERT selects a header carrying no
#     data — every key reads as missing and the secret reads as absent. That version passed its
#     secret check for the wrong reason, which is the failure mode worth naming.
#
# Dropping comment and blank lines leaves LOCK/INSERT/UNLOCK and the row tuples — settings data and
# nothing else. Verified against controls: real data -> 0 missing keys and 3 secrets absent; a row
# with a secret spliced in -> caught; a single key removed -> reported missing.
grep -vE '^(--|/\*!|$)' "$WORK/3-settings.sql" > "$WORK/3-rows.sql" || true
for k in "${SECRET_KEYS[@]}"; do
  if grep -qF "('$k'," "$WORK/3-rows.sql"; then
    echo "ABORT: secret setting '$k' survived the --where filter — nothing written." >&2
    exit 1
  fi
done
# ...and the filter must not have dropped anything ELSE. A quoting slip in the IN list would filter
# far more than three rows, and a seed missing its settings would install a broken estate. So assert
# the positive too: every non-secret key the database holds must appear in the pass. Checked key by
# key rather than by counting rows — a multi-row INSERT is one line, so rows cannot be counted
# without parsing SQL, and a count that is wrong in the safe direction is the check that lies.
"${MYSQL[@]}" -e "SELECT CONCAT('(''', \`key\`, ''',') FROM modx_system_settings \
                  WHERE \`key\` NOT IN ($SECRET_IN)" > "$WORK/expected-keys.txt"
MISSING=0
while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  grep -qF "$pat" "$WORK/3-rows.sql" || { echo "  missing setting: $pat" >&2; MISSING=$((MISSING+1)); }
done < "$WORK/expected-keys.txt"
if [ "$MISSING" -ne 0 ]; then
  echo "ABORT: $MISSING setting(s) absent from the dump — nothing written." >&2
  exit 1
fi
echo "settings: $(wc -l < "$WORK/expected-keys.txt") keys carried, ${#SECRET_KEYS[@]} secrets excluded"

# --- the same two assertions on pass 4, for the same reasons -------------------------------------
# Scope is load-bearing here too, and differently: a context setting row is
# ('<context_key>','<key>','<value>'), so the key is the SECOND field and the `('$k',` anchor used
# above would never match. Anchor on `,'$k',` instead. Comments and the echoed --where clause are
# dropped first, exactly as in pass 3 — mysqldump writes its filter into the output, so a checker
# that reads comments finds the secret in the line that proves it was excluded.
grep -vE '^(--|/\*!|$)' "$WORK/4-context.sql" > "$WORK/4-rows.sql" || true
for k in "${CONTEXT_SECRET_KEYS[@]}"; do
  if grep -qF ",'$k'," "$WORK/4-rows.sql"; then
    echo "ABORT: secret context setting '$k' survived the --where filter — nothing written." >&2
    exit 1
  fi
done
# ...and nothing else was dropped. Keyed by (context_key, key), because the same key name exists
# once per context and a bare key would pass on one context while another was silently missing.
"${MYSQL[@]}" -e "SELECT CONCAT(',''', \`key\`, ''',') FROM modx_context_setting \
                  WHERE \`key\` NOT IN ($CTX_SECRET_IN) GROUP BY \`key\`" > "$WORK/expected-ctx.txt"
CTX_MISSING=0
while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  grep -qF "$pat" "$WORK/4-rows.sql" || { echo "  missing context setting: $pat" >&2; CTX_MISSING=$((CTX_MISSING+1)); }
done < "$WORK/expected-ctx.txt"
if [ "$CTX_MISSING" -ne 0 ]; then
  echo "ABORT: $CTX_MISSING context setting(s) absent from the dump — nothing written." >&2
  exit 1
fi
echo "context settings: $(wc -l < "$WORK/expected-ctx.txt") distinct keys carried, ${#CONTEXT_SECRET_KEYS[@]} secret(s) excluded"

cat "$WORK/1-schema.sql" "$WORK/2-data.sql" "$WORK/3-settings.sql" "$WORK/4-context.sql" | gzip > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"

# --- verify the rest on the shipped artifact ----------------------------------------------------
# Every table must still be CREATEd and no log table may carry a row. Both are unambiguous on the
# whole dump: table names are line-anchored, unlike the settings values checked above.
TABLE_COUNT="$("${MYSQL[@]}" -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB_NAME'")"
DUMPED_TABLES="$(zcat "$OUT" | grep -c '^CREATE TABLE ' || true)"
if [ "$DUMPED_TABLES" != "$TABLE_COUNT" ]; then
  echo "ABORT: dump has $DUMPED_TABLES CREATE TABLE statements, database has $TABLE_COUNT — removing $OUT." >&2
  rm -f "$OUT"; exit 1
fi
for t in "${LOG_TABLES[@]}"; do
  if zcat "$OUT" | grep -q "^INSERT INTO \`$t\` "; then
    echo "ABORT: log table '$t' carries rows in the dump — removing $OUT." >&2
    rm -f "$OUT"; exit 1
  fi
done
# And on the SHIPPED artifact, not just the pass: the one check that cannot be fooled by a
# concatenation slip. If a future edit ever puts modx_context_setting back into pass 2, the pass-4
# assertions above still pass — they read pass 4 — and the secret rides in pass 2. This reads the
# gzip that is about to be committed.
for k in "${CONTEXT_SECRET_KEYS[@]}" "${SECRET_KEYS[@]}"; do
  if zcat "$OUT" | grep -vE '^(--|/\*!|$)' | grep -qF "'$k'"; then
    echo "ABORT: '$k' is present in the SHIPPED seed — removing $OUT." >&2
    rm -f "$OUT"; exit 1
  fi
done
echo "verified: $DUMPED_TABLES tables, no secret settings, no secret context settings, no log rows"

echo "seed regenerated: $OUT"
sha256sum "$OUT"
echo "Remember to update the sha256 in docs/production-install.md."
