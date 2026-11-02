#!/usr/bin/env bash
# protect-on-save.sh — a page created in the manager is protected before anyone can read it.
#
#     bash tests/protect-on-save.sh
#
# WHAT IS UNDER TEST. `setup/04-access-control.py` converges access control at DEPLOY time, and a
# manager save triggers no job at all — so until the `protectOnSave` plugin existed, a page the owner
# wrote was public until the next deploy of anything. That is not theoretical: on 2026-07-29
# a fund balance sheet written that afternoon returned 200 to an anonymous request on production.
#
# THE ASSERTION THAT MATTERS IS THE LAST ONE IN EACH BLOCK: an anonymous request gets 401. Every
# other check here — the membership row, the group id — could pass with the page still serving. A
# membership without a covering grant is not protection, it is a black hole, and only a request can
# tell the two apart.
#
# THE OTHER DIRECTION IS WORSE, AND IT IS CHECKED TOO. Protecting the `support` subtree locks the
# door from the inside: an anonymous request to a protected sign-in page goes 401 -> unauthorized
# (sso-login) -> 401 until PHP dies at its memory limit and the server answers 500. So a page
# created under `support` must come out anonymous AND still answer 200.
#
# Resources are created through **MODX's own create processor**, not by INSERT: the event is the
# thing under test, and an INSERT fires nothing. The processor runs as the sudo admin in the mgr
# context, which is what a manager save is.
#
# BENCH ONLY. Creates four resources and removes them, restores `access.model` byte-for-byte.
set -uo pipefail

IP=${MODX_TEST_IP:-127.0.0.1}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TAG=protect-probe-$$

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_repo
require_bench

echo "protectOnSave — a resource is protected at save time, not at deploy time"

SETTING=$(q "SELECT value FROM modx_system_settings WHERE \`key\`='access.model';")
if [ -z "$SETTING" ]; then
  echo "REFUSING TO RUN: system setting \`access.model\` is absent, so the plugin cannot act and" >&2
  echo "this suite would report a green about a mechanism that is not installed. Run" >&2
  echo "setup/04-access-control.py first." >&2
  exit 2
fi
GID=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["page_group_id"])' <<<"$SETTING")
CTXS=$(python3 -c 'import json,sys; print(" ".join(json.loads(sys.stdin.read())["contexts"]))' <<<"$SETTING")
ALIAS_SUPPORT=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["support_alias"])' <<<"$SETTING")

cleanup() {
  local ids
  ids=$(q "SELECT id FROM modx_site_content WHERE alias LIKE '$TAG%';" | tr '\n' ',' | sed 's/,$//')
  if [ -n "$ids" ]; then
    q "DELETE FROM modx_document_groups WHERE document IN ($ids);" >/dev/null 2>&1
    q "DELETE FROM modx_site_content WHERE id IN ($ids);" >/dev/null 2>&1
  fi
  q "UPDATE modx_system_settings SET value='$(printf '%s' "$SETTING" | sed "s/'/''/g")' WHERE \`key\`='access.model';" >/dev/null 2>&1
  modx_php "$REPO/clear-cache.php" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# Create through the manager's own processor. Prints the new id, or nothing on refusal — the caller
# checks, because a processor that declines returns a message rather than raising.
create() {   # create <context> <alias> <parent>
  # Inputs as ARGV, not env: docker exec does not carry this shell's environment inside (lib.sh).
  modx_php -d error_reporting=E_ALL -- "$MODX_ROOT" "$1" "$2" "$3" <<'PHP' 2>/dev/null
<?php
define('MODX_API_MODE', true);
// argv[1], not getenv: `docker exec` carries none of this shell's environment into the
// container, so getenv('MODX_ROOT') there would answer about the container's own env — empty on
// the ground, and the refusal below would blame MODX_ROOT for a value the suite was given
// correctly. The suite passes what it was handed and the message names what it actually tried.
$root = $argv[1] ?? '';
if (!$root || !is_file($root . '/index.php')) {
    fwrite(STDERR, "REFUSING: MODX_ROOT is '" . var_export($root, true) . "' and has no index.php\n");
    exit(2);
}
require_once $root . '/index.php';
$modx->initialize('mgr');
[, , $ctx, $alias, $parent] = $argv + [null, null, null, null, 0];
$modx->user = $modx->getObject(MODX\Revolution\modUser::class, ['sudo' => 1]);   // the install's administrator
$r = $modx->runProcessor('resource/create', [
    'context_key' => $ctx,
    'pagetitle'   => $alias,
    'alias'       => $alias,
    'parent'      => (int) $parent,
    'template'    => 3,
    'published'   => 1,
    'content'     => 'probe',
    'class_key'   => 'MODX\\Revolution\\modDocument',
]);
$o = $r ? $r->getObject() : null;
echo (is_array($o) && !empty($o['id'])) ? (int) $o['id'] : '';
PHP
}

# Save an EXISTING page through the manager's own update processor — the same OnDocFormSave the
# create path fires, which is the event under test in block (2b). A bare UPDATE would fire nothing.
resave() {   # resave <id> <context> <alias>
  modx_php -d error_reporting=E_ALL -- "$MODX_ROOT" "$1" "$2" "$3" <<'PHP' 2>/dev/null
<?php
define('MODX_API_MODE', true);
$root = $argv[1] ?? '';
if (!$root || !is_file($root . '/index.php')) {
    fwrite(STDERR, "REFUSING: MODX_ROOT is '" . var_export($root, true) . "' and has no index.php\n");
    exit(2);
}
require_once $root . '/index.php';
$modx->initialize('mgr');
[, , $id, $ctx, $alias] = $argv + [null, null, 0, null, null];
$modx->user = $modx->getObject(MODX\Revolution\modUser::class, ['sudo' => 1]);   // the install's administrator
$r = $modx->runProcessor('resource/update', [
    'id'          => (int) $id,
    'context_key' => $ctx,
    'pagetitle'   => $alias,
    'alias'       => $alias,
    'template'    => 3,
    'published'   => 1,
    'content'     => 'probe',
    'class_key'   => 'MODX\\Revolution\\modDocument',
]);
$o = $r ? $r->getObject() : null;
echo (is_array($o) && !empty($o['id'])) ? (int) $o['id'] : '';
PHP
}

member() {  # member <id> -> 1 if in the protected group
  local n; n=$(q "SELECT COUNT(*) FROM modx_document_groups WHERE document=$1 AND document_group=$GID;")
  [ "$n" = 1 ] && echo 1 || echo 0
}

# The URL is READ from the resource, never assembled here. `use_alias_path` is 0 on this estate, so
# a page under `support` is served at `/alias` and not at `/support/alias` — assembling the path by
# hand asserted a 404 and read as a protection failure on a page that was serving perfectly.
uri_of() { q "SELECT uri FROM modx_site_content WHERE id=$1;"; }

# ── (1) a page created in a gated context is protected, and answers 401 ────────────────────────
for ctx in $CTXS; do
  alias="$TAG-$ctx"
  id=$(create "$ctx" "$alias" 0)
  check "$([ -n "$id" ] && echo 1 || echo 0)" \
        "$ctx: the create processor made a page" "processor returned no id"
  [ -n "$id" ] || continue

  check "$(member "$id")" \
        "$ctx: ...and protectOnSave put it in the protected group at save time" \
        "id $id is not in resource group $GID — the window the 2026-07-29 incident found is still open"

  # THE ONE THAT MATTERS. No cache clear first, deliberately: the plugin is responsible for making
  # its own write visible, and a test that clears the cache for it would pass over a plugin that
  # does not.
    read -r scheme port < <(ctx_origin "$ctx")
    door=$(ctx_door "$ctx") || exit 2
    url="$scheme://$door/$(uri_of "$id")"
    read -r code location < <(curl -sS --resolve "${door%%:*}:$port:$IP" -m 10 -o /dev/null \
                                 -w '%{http_code} %{redirect_url}' "$url")
  # 401 OR A REDIRECT TO SIGN-IN — and this is a correction, not a loosening.
  #
  # The suite demanded exactly 401 because that is what the old bench answered: a bench whose
  # contexts had no sign-in page to send anyone to. Staging answers 302 to the context's own
  # sign-in page, which is not a weaker outcome — it is the outcome just made
  # correct on both grounds, and a signed-out visitor arriving at a protected page SHOULD be
  # offered the sign-in rather than a bare refusal.
  #
  # What must never happen is 200, and that is asserted first and separately, so a future ground
  # that starts serving the page cannot pass by changing the shape of its refusal. A 302 is only
  # accepted when it goes to the context's sign-in — a redirect to the page itself, or to another
  # protected page, is the loop the owner met on 2026-08-12 and it fails here.
  served=0
  [ "$code" = 200 ] && served=1
  check "$([ "$served" = 0 ] && echo 1 || echo 0)" \
        "$ctx: ...and an anonymous request does NOT get the page" "got $code — it was SERVED"
  case "$code" in
    401) verdict=1 ;;
    30[1237])
      case "$location" in
        *sso-login*|*login*) verdict=1 ;;
        *) verdict=0 ;;
      esac ;;
    *) verdict=0 ;;
  esac
  check "$verdict" \
        "$ctx: ...and it is refused or sent to sign-in, with no cache clear" \
        "got $code${location:+ -> $location} — expected 401, or a 30x to this context sign-in"
done

# ── (2) the support subtree stays anonymous — the direction that ends in a 500 ─────────────────
ctx=$(echo "$CTXS" | awk '{print $1}')
support=$(q "SELECT id FROM modx_site_content WHERE context_key='$ctx' AND alias='$ALIAS_SUPPORT' AND parent=0 AND deleted=0;")
check "$([ -n "$support" ] && echo 1 || echo 0)" \
      "$ctx: the support container resolves mechanically, by alias" "no top-level '$ALIAS_SUPPORT'"

if [ -n "$support" ]; then
  alias="$TAG-support"
  id=$(create "$ctx" "$alias" "$support")
  check "$([ -n "$id" ] && echo 1 || echo 0)" "$ctx: a page was created under support" "no id"
  if [ -n "$id" ]; then
    check "$([ "$(member "$id")" = 0 ] && echo 1 || echo 0)" \
          "$ctx: ...and it was NOT protected" \
          "protecting the support subtree loops 401 -> sso-login -> 401 until PHP dies"
    read -r scheme port < <(ctx_origin "$ctx")
    door=$(ctx_door "$ctx") || exit 2
    code=$(curl -sS --resolve "${door%%:*}:$port:$IP" -m 10 -o /dev/null -w '%{http_code}' \
                "$scheme://$door/$(uri_of "$id")")
    check "$([ "$code" = 200 ] && echo 1 || echo 0)" \
          "$ctx: ...and it answers an anonymous request 200" "got $code"
  fi
fi

# ── (2b) THE OTHER EXEMPTION: a declared MACHINE DOOR stays anonymous across a save ───
# A support page must answer anonymously or nobody can sign in. A machine door must answer
# anonymously or its own CODE never runs — and that code is the door. `/actuator/info` reads a
# client certificate in `common/snippets/actuatorInfo.php` and refuses everyone else with 401; page
# protection sits one layer above it and answers 302 to the sign-in page instead, for a valid
# certificate exactly as for none. That was measured by infra on 2026-09-05,
# from the ground that holds monitoring's certificate.
#
# 04 converges the exemption at deploy time. THIS is the half 04 cannot cover: a manager save fires
# no job, so if the plugin does not know about machine doors it re-shuts the door the next time
# anybody touches that page — and nothing would notice until the monitor lost its actuator.
#
# THE DOOR IS DECLARED BY URI AND THE PROBE PAGE'S URI IS ONLY KNOWN AFTER IT EXISTS, so the page is
# created first, its own uri is added to the rendered declaration, and it is SAVED AGAIN. That also
# exercises the direction that matters more: the plugin must REMOVE a membership that is already
# there, not merely decline to add one. The declaration is restored at the end of the block and by
# the exit trap, byte-for-byte, exactly as block (4) does.
alias="$TAG-door"
id=$(create "$ctx" "$alias" 0)
check "$([ -n "$id" ] && echo 1 || echo 0)" "$ctx: a page was created to stand in for a door" "no id"
if [ -n "$id" ]; then
  check "$(member "$id")" \
        "$ctx: ...it is protected while it is an ordinary page" \
        "id $id was already exempt before anything declared it a door — this block would prove nothing"

  door_uri=$(uri_of "$id")
  declared=$(python3 -c 'import json,sys; m=json.loads(sys.argv[1]); m.setdefault("machine_doors",[]).append(sys.argv[2]); m["machine_doors"]=sorted(set(m["machine_doors"])); print(json.dumps(m,sort_keys=True))' "$SETTING" "$door_uri")
  q "UPDATE modx_system_settings SET value='$(printf '%s' "$declared" | sed "s/'/''/g")' WHERE \`key\`='access.model';" >/dev/null
  clear_cache
  resave "$id" "$ctx" "$alias" >/dev/null

  check "$([ "$(member "$id")" = 0 ] && echo 1 || echo 0)" \
        "$ctx: ...and once /$door_uri is a declared machine door, saving it TAKES the protection off" \
        "id $id is still in group $GID — a manager save re-shuts the door and the estate's own monitor gets a sign-in page"

  # And the mirror, so the exemption cannot be "the plugin stopped protecting anything". Undeclared
  # again, the same save must put it straight back.
  q "UPDATE modx_system_settings SET value='$(printf '%s' "$SETTING" | sed "s/'/''/g")' WHERE \`key\`='access.model';" >/dev/null
  clear_cache
  resave "$id" "$ctx" "$alias" >/dev/null
  check "$(member "$id")" \
        "$ctx: ...and undeclared again, the same save protects it" \
        "id $id stayed exempt with nothing declaring it — the exemption is not reading the declaration"

  q "DELETE FROM modx_document_groups WHERE document=$id;" >/dev/null
  q "DELETE FROM modx_site_content WHERE id=$id;" >/dev/null
  clear_cache
fi

# ── (3) an undelete re-protects ────────────────────────────────────────────────────────────────
# The 2026-07-29 incident's second page was one the owner had just undeleted, so this is not a hypothetical path. The
# membership is stripped first, which is what a delete/undelete cycle leaves behind.
alias="$TAG-undelete"
id=$(create "$ctx" "$alias" 0)
if [ -n "$id" ]; then
  q "DELETE FROM modx_document_groups WHERE document=$id;" >/dev/null
  q "UPDATE modx_site_content SET deleted=1 WHERE id=$id;" >/dev/null
  check "$([ "$(member "$id")" = 0 ] && echo 1 || echo 0)" \
        "a deleted page with its membership stripped is the starting state" "already protected"

  modx_php -- "$MODX_ROOT" "$id" <<'PHP' >/dev/null 2>&1
<?php
define('MODX_API_MODE', true);
// argv[1], not getenv: `docker exec` carries none of this shell's environment into the
// container, so getenv('MODX_ROOT') there would answer about the container's own env — empty on
// the ground, and the refusal below would blame MODX_ROOT for a value the suite was given
// correctly. The suite passes what it was handed and the message names what it actually tried.
$root = $argv[1] ?? '';
if (!$root || !is_file($root . '/index.php')) {
    fwrite(STDERR, "REFUSING: MODX_ROOT is '" . var_export($root, true) . "' and has no index.php\n");
    exit(2);
}
require_once $root . '/index.php';
$modx->initialize('mgr');
$modx->user = $modx->getObject(MODX\Revolution\modUser::class, ['sudo' => 1]);   // the install's administrator
$modx->runProcessor('resource/undelete', ['id' => (int) ($argv[2] ?? 0)]);
PHP
  check "$(member "$id")" \
        "undeleting it protects it again" \
        "id $id came back out of the recycle bin public — the 2026-07-29 incident's second page"
fi

# ── (4) the switch: protect_pages false and the plugin does nothing at all ─────────────────────
# The owner's condition on all of this was that unprotecting stays one step ("i can always unlock the
# doors"). The switch lives in access_model.py; what the plugin reads is the rendered declaration,
# so that is what is flipped here.
off=$(python3 -c 'import json,sys; m=json.loads(sys.stdin.read()); m["protect_pages"]=False; print(json.dumps(m,sort_keys=True))' <<<"$SETTING")
q "UPDATE modx_system_settings SET value='$(printf '%s' "$off" | sed "s/'/''/g")' WHERE \`key\`='access.model';" >/dev/null
clear_cache
alias="$TAG-switchoff"
id=$(create "$ctx" "$alias" 0)
check "$([ -n "$id" ] && echo 1 || echo 0)" "with protect_pages off, a page still saves" "no id"
[ -n "$id" ] && check "$([ "$(member "$id")" = 0 ] && echo 1 || echo 0)" \
      "...and the plugin does nothing at all" \
      "id $id was protected against the declaration — the one-step unprotect is broken"

# Put the declaration back NOW, and take this page with it, rather than leaving both to the exit
# trap: the block below asserts that the verifier is green before it induces anything, and this page
# is a real unprotected page in a gated context — which is drift, correctly reported. A test still
# holding its own fault fails that control and makes every assertion after it meaningless.
[ -n "$id" ] && q "DELETE FROM modx_site_content WHERE id=$id;" >/dev/null
q "UPDATE modx_system_settings SET value='$(printf '%s' "$SETTING" | sed "s/'/''/g")' WHERE \`key\`='access.model';" >/dev/null
clear_cache

# ── (5) the enforcement is itself watched ──────────────────────────────────────────────────────
# A plugin that silently stops being installed, enabled, bound, or current is the same exposure with
# a better disguise, and the thing that would notice is `verify-file-protection.py` — the read-only
# checker infra's 6-hourly monitor runs. So each of those four states is INDUCED here and the
# verifier must go red. A checker is only worth its green if it has been seen to fail.
# ── THE DRILL BELOW BREAKS THIS GROUND ON PURPOSE, SO IT ASKS THE GROUND FIRST ─────────────────
#
# Everything after this point DISABLES the plugin, DELETES a binding, EDITS a body and FLIPS the
# declaration, to prove the monitor sees each. On a bench that is the point. On any other ground it
# is an outage, and until 2026-09-12 nothing here refused: `lib.sh` can address a remote
# MODX_DB_HOST (staging), the same file records that the staging database name resolves to SHYAM — the
# production box — and its own comment warns that a caller naming the host and not the schema
# reaches database `modx` there. Production was measured on 2026-09-12 in exactly the state steps 1
# and 2 below leave behind.
#
# THE GUARD IS A PROPERTY OF THE DATA, NOT A VARIABLE SOMEBODY REMEMBERS. A bench has had its
# context hostnames set to this box's own bench names, which infra's modx-environment.py derives for
# this machine (the bench renderer's --names) — the restore verb writes them every time,
# and no production or staging ground holds them.
# A flag like MAY_BREAK=1 would be forgotten in exactly the case that matters.
hosts=$(q "SELECT value FROM modx_context_setting WHERE \`key\`='http_host';")
bench_names=$(python3 "$REPO/setup/bench-application.py" --names) || bench_names=''
notbench=$( { printf '%s\n' "$hosts" | grep -vxF "${bench_names:-(none)}" || true; } | grep -c . || true)
# A ground whose contexts are named, none of them a bench name, is a REAL ground, and on a real ground
# this block must never run: that is not "could not check", it is the suite's own rule (2026-11-01).
# So the checks above are the verdict there, and the block is named as not run — as run-all names a
# suite a container ground cannot host. A ground with no names at all is still refused: it cannot be told.
if [ -n "$hosts" ] && [ -z "$( { printf '%s\n' "$hosts" | grep -xF "${bench_names:-(none)}" || true; } )" ]; then
  echo "  not run on this ground: the induced-drift block (bench only — it disables the plugin and"
  echo "          deletes a binding). No context here carries a bench name; the checks above are the verdict."
  summary
  exit $?
fi
if [ -z "$hosts" ] || [ "$notbench" != 0 ]; then
  echo "  REFUSING the induced-drift block: this ground does not look like a bench." >&2
  echo "          Every context's http_host must be one of this box's bench names ($(echo ${bench_names:-none derived})) —" >&2
  echo "          infra's modx-environment.py names them and the restore verb writes them. Found:" >&2
  printf '            %s\n' $hosts >&2
  echo "          The block after this point disables the plugin and deletes a binding, which on a" >&2
  echo "          real ground is an outage. Nothing was induced and nothing was repaired." >&2
  summary
  exit 2
fi

# The repair below is 04-access-control.py, which refuses with no estate file. Measured 2026-10-31:
# run with MODX_ESTATE unset, this block disabled the plugin and then could not put it back.
if [ ! -f "${MODX_ESTATE:-}" ]; then
  echo "  REFUSING the induced-drift block: MODX_ESTATE names no estate file, so its repair" >&2
  echo "          (setup/04-access-control.py) could not run. Nothing was induced." >&2
  summary
  exit 2
fi

verifier() { (cd "$REPO/setup" && python3 verify-file-protection.py --quiet >/dev/null 2>&1); echo $?; }
# THE REPAIR MUST BE CHECKED, AND THIS IS THE WHOLE OF THE 2026-09-12 FINDING.
#
# This was `(cd $REPO/setup && python3 04-access-control.py >/dev/null 2>&1)` — output, errors AND
# exit status all discarded. The block below DISABLES the plugin and DELETES a binding on purpose,
# to prove the monitor sees each; `converge` is what puts them back. On any ground that
# authenticates by socket, 04 refused for want of a credential and this function swallowed the
# refusal, so:
#
#   * nothing was repaired, and the suite said nothing about it;
#   * the last arm went red with "the repair is not one step", which blames the repair for being
#     multi-step rather than for not having run;
#   * THE BENCH WAS LEFT BROKEN — plugin disabled, OnResourceDuplicate deleted — so every later run
#     failed 17 of its 34 arms from the first block, and verify-protection-wrong-class refused
#     because the ground was already drifting. A day was spent reading that as a live defect.
#
# A drill that breaks a ground owns putting it back, and a repair nobody checks is not a repair. So
# this reports the failure and ABORTS: continuing would mutate a ground it has already failed to
# restore, and each further mutation makes the residue harder to read.
converge() {
  local out rc=0
  out=$( cd "$REPO/setup" && python3 04-access-control.py 2>&1 ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail=$((fail+1))
    echo "  FAIL  the drill's REPAIR failed, and this ground is now left as the drill broke it"
    echo "        04-access-control.py exit $rc: $(printf '%s' "$out" | tail -2)"
    echo "        Re-run 04 by hand before trusting anything else on this bench."
    summary
    exit 1
  fi
}

check "$([ "$(verifier)" = 0 ] && echo 1 || echo 0)" \
      "the verifier is green before anything is induced" \
      "it is already reporting drift, so nothing below would mean anything"
# ...and a drill on a drifting ground would only add to the drift: stop before inducing anything.
if [ "$(verifier)" != 0 ]; then summary; exit 1; fi

pid=$(q "SELECT id FROM modx_site_plugins WHERE name='protectOnSave';")

q "UPDATE modx_site_plugins SET disabled=1 WHERE id=$pid;" >/dev/null
check "$([ "$(verifier)" = 1 ] && echo 1 || echo 0)" \
      "a DISABLED plugin is drift" "the monitor would stay green with the window reopened"
converge

q "DELETE FROM modx_site_plugin_events WHERE pluginid=$pid AND event='OnResourceDuplicate';" >/dev/null
check "$([ "$(verifier)" = 1 ] && echo 1 || echo 0)" \
      "a MISSING event binding is drift" "a duplicate of a support page would arrive unprotected"
converge

q "UPDATE modx_site_plugins SET plugincode=CONCAT(plugincode,' ') WHERE id=$pid;" >/dev/null
check "$([ "$(verifier)" = 1 ] && echo 1 || echo 0)" \
      "a plugin body EDITED in the manager is drift" "a second master, which is the thing git deploys exist to prevent"
converge

q "UPDATE modx_system_settings SET value=REPLACE(value,'\"protect_pages\": true','\"protect_pages\": false') WHERE \`key\`='access.model';" >/dev/null
check "$([ "$(verifier)" = 1 ] && echo 1 || echo 0)" \
      "a declaration that no longer matches access_model.py is drift" \
      "the plugin would enforce a policy nobody declared"
converge

check "$([ "$(verifier)" = 0 ] && echo 1 || echo 0)" \
      "and re-running 04 puts every one of them back" "the repair is not one step"

summary
