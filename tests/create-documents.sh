#!/usr/bin/env bash
# create-documents.sh — Library's new pages are born from git.
#
#     bash tests/create-documents.sh
#
# Drills setup/create-documents.php against claude-shared design/modx-page-births-skunkworks.md
# section 6, on the bench, signed in for real at the door for the one check that needs a reader:
#
#   three entries — one nested under a parent born in the same run, one alias ending in digits — are
#   created, published, held back from an anonymous caller and served with their body when signed in
#   a second run prints only `exists` and the row count does not move
#   refused, writing nothing: a missing parent, an unknown template, an entry with no body, two
#   entries with one URI (two templates cannot share a name: modx_site_templates holds it unique)
#   a page in the recycle bin holding the URI prints `exists … DELETED` and nothing is born
#   the same alias under another parent: the identity is the URI MODx computes, so it is `exists`
#   where this ground's use_alias_path is 0 and a new page where it is 1
#
# CREATE_DOCS names another creator, so each check can be seen red against a broken copy.
# BENCH ONLY: it writes pages and removes them; require_bench refuses anywhere else.
set -uo pipefail

HOST=${MODX_TEST_HOST:-}
IP=${MODX_TEST_IP:-127.0.0.1}
CTX=${MODX_TEST_CTX:-platform}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CREATE_DOCS=${CREATE_DOCS:-$REPO/setup/create-documents.php}
TAG=zzbirth

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -n "$HOST" ] || HOST=$(ctx_host "$CTX") || exit 2
read -r SCHEME PORT < <(host_origin "$HOST")
DOOR=$(host_door "$HOST") || exit 2

require_repo
require_bench
require_nonprod_door

echo "pages born from git (context $CTX)"

TPL=$(q "SELECT templatename FROM modx_site_templates ORDER BY id LIMIT 1;")
[ -n "$TPL" ] || { echo "REFUSING TO RUN: this ground has no template" >&2; exit 2; }
ALIAS_PATH=$(q "SELECT value FROM modx_system_settings WHERE \`key\`='use_alias_path';")
# The payload where MODx's own PHP can read it — inside a container that is MODX_ROOT/core/cache.
PAY="$MODX_ROOT/core/cache/$TAG-payload.json"

cleanup() {
  local ids
  ids=$(q "SELECT id FROM modx_site_content WHERE alias LIKE '$TAG%';" | tr '\n' ',' | sed 's/,$//')
  if [ -n "$ids" ]; then
    q "DELETE FROM modx_document_groups WHERE document IN ($ids);
       DELETE FROM modx_site_tmplvar_contentvalues WHERE contentid IN ($ids);
       DELETE FROM modx_site_content WHERE id IN ($ids);" >/dev/null 2>&1
  fi
  modx_php -r '@unlink($argv[1]);' -- "$PAY" >/dev/null 2>&1
  rm -f "$tmp/cookies" 2>/dev/null
  modx_php "$REPO/clear-cache.php" >/dev/null 2>&1 || true
}
tmp=$(mktemp -d); chmod 700 "$tmp"
trap 'cleanup; rm -rf "$tmp"' EXIT
cleanup

rows() { q "SELECT COUNT(*) FROM modx_site_content;"; }
# run <payload json>  -> sets OUT (stdout+stderr) and RC
# The payload is written BY THE GROUND'S PHP, not by this shell: on staging core/cache is the
# container's (www-data's), and the host's `>` was refused "Permission denied" (2026-11-01), so every
# check ran against no payload. The deploy verb places it as the ground's user for the same reason.
run() {
  printf '%s' "$1" | modx_php -r 'exit(file_put_contents($argv[1], stream_get_contents(STDIN)) === false ? 1 : 0);' -- "$PAY" \
    || { OUT="REFUSING: the ground's PHP could not write the payload $PAY"; RC=2; return; }
  OUT=$(modx_php -- "$MODX_ROOT" "$PAY" < "$CREATE_DOCS" 2>&1); RC=$?
}
entry() {  # entry <alias> <parent> [template] [body] -> one JSON object
  python3 -c 'import json,sys; a,p,t,b,c=sys.argv[1:6]
e={"context":c,"alias":a,"parent":0 if p=="0" else p,"pagetitle":a,"template":t,"published":1,"hidemenu":1}
if b!="-": e["body"]=b
print(json.dumps(e))' "$1" "$2" "${3:-$TPL}" "${4:-<p>body of $1</p>}" "$CTX"
}
list() { local IFS=,; printf '[%s]' "$*"; }

# --- 1. three born -----------------------------------------------------------------------------
P="$TAG-parent"; K="$TAG-child"; D="$TAG-record-0001"
before=$(rows)
run "$(list "$(entry "$P" 0)" "$(entry "$K" "$CTX/$P")" "$(entry "$D" 0)")"
check "$([ "$RC" = 0 ] && echo 1 || echo 0)" "three entries: the creator exits 0" "rc $RC: $OUT"
check "$(has "$OUT" "created $CTX/$P (id ")" "the parent is born" "$OUT"
check "$(has "$OUT" "created $CTX/$K (id ")" "the child, under a parent born in the same run, is born" "$OUT"
check "$(has "$OUT" "created $CTX/$D (id ")" "an alias ending in digits is born under its own name" "$OUT"
check "$([ "$(rows)" = $((before + 3)) ] && echo 1 || echo 0)" "exactly three rows were added" "$before -> $(rows)"
pid=$(q "SELECT id FROM modx_site_content WHERE context_key='$CTX' AND alias='$P' AND deleted=0;")
check "$([ -n "$pid" ] && [ "$(q "SELECT parent FROM modx_site_content WHERE alias='$K';")" = "$pid" ] && echo 1 || echo 0)" \
      "the child's parent is the parent's id" "parent id '$pid'"
check "$([ "$(q "SELECT COUNT(*) FROM modx_site_content WHERE alias LIKE '$TAG%' AND published=1;")" = 3 ] && echo 1 || echo 0)" \
      "all three are published" "$(q "SELECT alias,published FROM modx_site_content WHERE alias LIKE '$TAG%';" | tr '\n' ' ')"
check "$([ "$(q "SELECT COUNT(DISTINCT document) FROM modx_document_groups WHERE document IN (SELECT id FROM modx_site_content WHERE alias LIKE '$TAG%');")" = 3 ] && echo 1 || echo 0)" \
      "protectOnSave put each in a document group" ""

# The reader's view: anonymous gets no body, the signed-in reader gets it.
reader=$(drill_reader) || exit 2
jar="$tmp/cookies"
C=(curl -sS --resolve "${DOOR%%:*}:$PORT:$IP" -b "$jar" -c "$jar" -m 10)
uri=$(q "SELECT uri FROM modx_site_content WHERE alias='$K';")
anon=$(curl -sS --resolve "${DOOR%%:*}:$PORT:$IP" -m 10 -w '\n%{http_code}' "$SCHEME://$DOOR/$uri")
check "$([ "${anon##*$'\n'}" != 200 ] && [ "$(hasnt "$anon" "body of $K")" = 1 ] && echo 1 || echo 0)" \
      "an anonymous caller is not served the child's body" "status ${anon##*$'\n'}"
loc=$("${C[@]}" -o /dev/null -w '%{redirect_url}' "$SCHEME://$DOOR/sso-login?sso=go")
cb=$(idp_sign_in "$loc" "$reader")
[ -n "$cb" ] && "${C[@]}" -o /dev/null "$cb"
page=$("${C[@]}" -w '\n%{http_code}' "$SCHEME://$DOOR/$uri")
check "$([ "${page##*$'\n'}" = 200 ] && [ "$(has "$page" "body of $K")" = 1 ] && echo 1 || echo 0)" \
      "signed in, the child answers 200 with its body" "status ${page##*$'\n'}"

# --- 2. the second run writes nothing --------------------------------------------------------------
before=$(rows)
run "$(list "$(entry "$P" 0)" "$(entry "$K" "$CTX/$P")" "$(entry "$D" 0)")"
check "$([ "$RC" = 0 ] && [ "$(grep -c '^exists ' <<<"$OUT")" = 3 ] && [ "$(hasnt "$OUT" created)" = 1 ] && echo 1 || echo 0)" \
      "a second run prints three exists lines and no created" "rc $RC: $OUT"
check "$([ "$(rows)" = "$before" ] && echo 1 || echo 0)" "and the row count did not move" "$before -> $(rows)"

# A parent that already exists on the ground resolves by its URI to its id (the other branch).
run "$(list "$(entry "$TAG-child2" "$CTX/$P")")"
check "$([ "$RC" = 0 ] && [ "$(q "SELECT parent FROM modx_site_content WHERE alias='$TAG-child2';")" = "$pid" ] && echo 1 || echo 0)" \
      "a child under a parent that already exists gets that parent's id" "rc $RC: $OUT"

# --- 3. refusals write nothing -----------------------------------------------------------------------
refused() {  # refused <label> <payload> <expected text>
  local before; before=$(rows)
  run "$2"
  check "$([ "$RC" = 1 ] && [ "$(has "$OUT" "$3")" = 1 ] && [ "$(has "$OUT" 'nothing was written')" = 1 ] \
           && [ "$(rows)" = "$before" ] && echo 1 || echo 0)" "refused, nothing written: $1" "rc $RC: $OUT"
}
refused "a missing parent"         "$(list "$(entry "$TAG-n1" 0)" "$(entry "$TAG-n2" "$CTX/$TAG-nowhere")")" "is not an undeleted page here"
refused "an unknown template"      "$(list "$(entry "$TAG-n1" 0)" "$(entry "$TAG-n2" 0 "$TAG-no-such")")" "matches 0 templates"
refused "an entry with no body"    "$(list "$(entry "$TAG-n1" 0)" "$(entry "$TAG-n2" 0 "$TPL" -)")" "field 'body' is missing"
refused "two entries, one URI"     "$(list "$(entry "$TAG-n1" 0)" "$(entry "$TAG-n1" 0)")" "is also entry"

# A context this ground does not have yet: that entry waits (named, nothing written for it) and the
# others in the same run are still born.
before=$(rows)
w=$(python3 -c 'import json,sys; print(json.dumps({"context":sys.argv[1]+"-no-ctx","alias":sys.argv[1]+"-w","parent":0,"pagetitle":"w","template":sys.argv[2],"published":1,"hidemenu":1,"body":"<p>w</p>"}))' "$TAG" "$TPL")
run "$(list "$w" "$(entry "$TAG-beside" 0)")"
check "$([ "$RC" = 0 ] && [ "$(has "$OUT" "waiting $TAG-no-ctx/$TAG-w")" = 1 ] && [ "$(has "$OUT" "created $CTX/")" = 1 ] \
         && [ "$(rows)" = $((before + 1)) ] && echo 1 || echo 0)" \
      "a page whose context this ground lacks waits; the page beside it is born" "rc $RC: $OUT"

# --- 4. the recycle bin and the identity ---------------------------------------------------------
q "UPDATE modx_site_content SET deleted=1 WHERE alias='$D';" >/dev/null
before=$(rows)
run "$(list "$(entry "$D" 0)")"
check "$([ "$RC" = 0 ] && [ "$(has "$OUT" "exists $CTX/")" = 1 ] && [ "$(has "$OUT" DELETED)" = 1 ] \
         && [ "$(rows)" = "$before" ] && echo 1 || echo 0)" \
      "a page in the recycle bin holds its URI: exists … DELETED, nothing born" "rc $RC: $OUT"
before=$(rows)
run "$(list "$(entry "$P" "$CTX/$P")")"
if [ "${ALIAS_PATH:-0}" = 1 ]; then
  check "$([ "$RC" = 0 ] && [ "$(has "$OUT" created)" = 1 ] && [ "$(rows)" = $((before + 1)) ] && echo 1 || echo 0)" \
        "the same alias under another parent is another URI here (use_alias_path 1): born" "rc $RC: $OUT"
else
  check "$([ "$RC" = 0 ] && [ "$(has "$OUT" "exists $CTX/$P ")" = 1 ] && [ "$(rows)" = "$before" ] && echo 1 || echo 0)" \
        "the same alias under another parent is the same URI here (use_alias_path 0): exists" "rc $RC: $OUT"
fi

summary
