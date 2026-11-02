# lib.sh — shared by the bench tests. Source it; do not run it.
#
# Everything here exists because of a specific way one of these tests lied.

# --- the database ------------------------------------------------------------------------------
DB_USER=${MODX_DB_USER:-$(id -un)}   # the OS user unless named: under socket auth that IS the identity
# No default, ever: a database credential in source is a published credential.
#
# But EXIT 2, not 1 — and this was `${MODX_DB_PASS:?...}`, which exits 1. run-all.sh's own header
# promises that "could not check" and "checked, and it is fine" are different answers and that a
# refusal is reported as a refusal. A shell with no MODX_DB_PASS made six bench suites print
# `6 failed, 0 refused to run`, which reads as six broken suites and is a lie about the tree: they
# never executed a single assertion. The distinction the runner exists to draw was defeated by the
# parameter expansion that guards its own credential. (skunkworks 2026-08-04, found by running the
# suite twice with a control rather than by reading it.)
DB_NAME=${MODX_DB_NAME:-modx}

# A PASSWORD IS NOT WHAT THIS GUARD IS FOR — A WORKING CONNECTION IS (2026-09-12).
#
# The guard above demanded MODX_DB_PASS and refused without it, which was right when every bench
# account had a password. On a dev box it does not: the MariaDB account authenticates by the
# **unix_socket** plugin, so the OS user at the far end of the socket IS the identity and there is
# no password to supply. The demand therefore locked EVERY caller out of ten suites — including the
# one whose own name the account carries — and "refused for want of a variable" is
# indistinguishable, in a summary line, from "this ground cannot be checked". Ten refusals stood
# for weeks and were read as a property of the ground.
#
# infra hit the same wall in `restore_modx_dev` the same week and fixed it the same way
# (config ccb0794, "socket authentication needs no credential, and demanding one locked everyone
# out"). This is that fix on the suite side, and the shape matters: the guard now asks the DATABASE
# whether it will answer, rather than asking the shell whether a variable is set. A probe cannot be
# satisfied by typing something — which is what the old one could be, and `MODX_DB_PASS=anything`
# against socket auth produced 55 confident failures, none of them about the tree.
#
# Order: an explicit password wins if one is given (a real remote ground). Otherwise, locally, try
# the socket as the OS user. A default DB_USER of a fixed account name is wrong under socket auth for the same
# reason — the identity is whoever is running, so it is read from `id -un` and not guessed.
# AND ONLY OVER THE SOCKET, WHICH MEANS ONLY FOR HOST `localhost`. 127.0.0.1 and ::1 are TCP
# addresses: the client does not reach for the socket, so a unix_socket account cannot authenticate
# there at all. Treating them as local would produce a refusal blaming the account for the
# transport.
DB_PASS=${MODX_DB_PASS:-}
if [ -z "$DB_PASS" ]; then
  case "${MODX_DB_HOST:-localhost}" in
    localhost)
      DB_USER=${MODX_DB_USER:-$(id -un)}
      if ! mysql -h localhost -u "$DB_USER" "$DB_NAME" -N -B -e 'SELECT 1' >/dev/null 2>&1; then
        echo "REFUSING: no MODX_DB_PASS, and socket authentication as '$DB_USER' was refused by" >&2
        echo "          database '$DB_NAME', so no assertion in this suite has run." >&2
        echo "          Tried: mysql -h localhost -u $DB_USER $DB_NAME -e 'SELECT 1'" >&2
        echo "          This is a statement about the shell, not about the tree." >&2
        exit 2
      fi
      MODX_DB_SOCKET_AUTH=1
      # AND EXPORT IT FOR THE PYTHON THE SUITES CALL. setup/04-access-control.py is the REPAIR step
      # of protect-on-save's drill, and it refuses without a credential — correctly, since a default
      # one is a published one. Without this line it refused on every ground that authenticates by
      # socket, the drill's repair silently did nothing, and the bench was left with the plugin
      # DISABLED and a binding deleted: 17 of 34 arms failing from then on, every run, for a reason
      # that was neither the plugin's nor the tree's. Named `MODX_DB_SOCKET` because that is the
      # name domains.py reads.
      if [ -z "${MODX_DB_SOCKET:-}" ]; then
        MODX_DB_SOCKET=$(mysql -h localhost -u "$DB_USER" -N -B -e 'SELECT @@socket' 2>/dev/null)
        [ -n "$MODX_DB_SOCKET" ] && export MODX_DB_SOCKET
      fi
      # NAME ONLY, NOT THE USER — and that is not a detail. domains.py takes its socket path
      # ONLY when MODX_DB_SOCKET is set AND MODX_DB_USER is NOT, because under socket auth the
      # identity is the OS user and a named one would be a second answer to the same question.
      # Exporting MODX_DB_USER here therefore turned the socket branch OFF and put the caller
      # straight back into "MODX_DB_PASS not set" — measured, 2026-09-12.
      export MODX_DB_NAME="$DB_NAME"
      ;;
    127.0.0.1|::1)
      echo "REFUSING: no MODX_DB_PASS, and MODX_DB_HOST is '$MODX_DB_HOST' — a TCP address, so the" >&2
      echo "          client never reaches for the unix socket and socket authentication cannot" >&2
      echo "          apply. Use MODX_DB_HOST=localhost for socket auth, or set MODX_DB_PASS." >&2
      echo "          No assertion in this suite has run." >&2
      exit 2
      ;;
    *)
      echo "REFUSING: MODX_DB_PASS is not set and MODX_DB_HOST is not local, so socket" >&2
      echo "          authentication cannot apply and no assertion in this suite has run." >&2
      echo "          This is a statement about the shell, not about the tree." >&2
      exit 2
      ;;
  esac
fi

# THE SCHEMA IS NOT ALWAYS ON THE MACHINE RUNNING THE TEST. This was
# `mysql -u … -p… "$DB_NAME"` with no host, so it could only ever reach a database on the local
# box — which was true while a bench meant a MODx install on somebody's workstation, and stopped
# being true the day the bench became staging. infra measured it on hanuman: the docroot and the
# HTTP ground are there, the staging database name resolves to shyam, and no single machine satisfies
# both while these suites address localhost. That is the whole reason ten of twenty suites run
# nowhere. Default `localhost`, so a dev-box run is byte-for-byte what it was.
DB_HOST=${MODX_DB_HOST:-localhost}

# AND THE DEFAULTS ABOVE STOP APPLYING THE MOMENT THE SCHEMA IS SOMEWHERE ELSE.
#
# The default user and `modx` are dev-box conveniences from when the bench was a MODx install on this
# machine. Point MODX_DB_HOST at another host and they become a hazard rather than a convenience:
# a ground that sets only MODX_DB_PASS — which is the only variable the suites make anybody set —
# addresses database `modx` as the dev-box user ON THE STAGING SERVER, and staging's schema is
# `modx_staging`. If a database called `modx` happens to exist there, every suite runs GREEN
# against the wrong one and says so in a summary line nobody can tell apart from a real pass.
#
# Found 2026-08-13 by `run-all.sh --requirements`, not by reading: the suites name MODX_DB_PASS
# and never name the other two, because a default means nobody is ever asked. A default decides
# what SILENCE means, and silence must not mean "some other estate's database".
#
# So: local keeps its defaults and a dev-box run is unchanged. A REMOTE host must name the schema
# and the user it means.
case "$DB_HOST" in
  localhost|127.0.0.1|::1) ;;
  *)
    missing=""
    [ -z "${MODX_DB_NAME:-}" ] && missing="$missing MODX_DB_NAME"
    [ -z "${MODX_DB_USER:-}" ] && missing="$missing MODX_DB_USER"
    if [ -n "$missing" ]; then
      echo "REFUSING: MODX_DB_HOST is '$DB_HOST' — a database on another machine — and$missing" >&2
      echo "          $([ $(echo $missing | wc -w) -gt 1 ] && echo 'are' || echo 'is') not set." >&2
      echo "          No assertion in this suite has run. The defaults for those two (database" >&2
      echo "          'modx', the dev-box user) describe a dev box, and using them against another" >&2
      echo "          host would read whatever schema of that name happens to be there — a green" >&2
      echo "          run against an estate nobody meant. Name the schema you mean." >&2
      exit 2
    fi
    ;;
esac
# One query function, two authentications. Under socket auth `-p` must be ABSENT rather than empty:
# `-p""` sends an empty password and the account refuses it, which is the failure this whole block
# exists to stop being mistaken for a broken tree.
if [ -n "${MODX_DB_SOCKET_AUTH:-}" ]; then
  # THE HOST IS STILL PASSED. `-h localhost` is what makes the client choose the socket, and
  # tests/suites-accept-their-ground.sh refuses a q() that reads MODX_DB_HOST and then ignores it —
  # correctly, because that is the shape of every bug where a suite silently addresses the wrong
  # machine. It caught this function ten minutes after it was written.
# (definitions start at column 0 on purpose: suites-accept-their-ground.sh reads this
#  function with `grep -E "^q\(\)"`, and an indented one is invisible to it.)
q() { mysql -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -N -B -e "$1"; }
else
q() { mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -B -e "$1"; }
fi

# --- WHICH PHP, and it is two different questions -----------------------------------------------
# On the staging ground the PHP that can bootstrap MODx is the one INSIDE the modx
# container (MODX_PHP_RUN='docker exec -i modx-staging php'). The bash suites had a bare `php`
# in eight places, so on that ground they asked the HOST's php to load a MODx that is not there —
# protect-on-save's create() returned no id and the suite read as five protection failures on a
# ground where nothing had been tested at all (hanuman journal, 2026-08-14).
#
# The two are not interchangeable and wrapping the wrong one is worse than wrapping neither:
#
#   modx_php   anything that bootstraps MODx — clear-cache.php, a create processor, a settings
#              read. It must run WHERE MODX IS.
#   local_php  php used as a tool of the test itself — the `php -S` fixture server that stands in
#              for an OIDC provider, a signature check against kuber's Crypto.php. These must run
#              HERE, on the machine running the suite; sending them into the container would move
#              the server away from the port the test then curls.
#
# VALUES GO IN AS ARGUMENTS, NOT ENV: `docker exec -i` does not carry the caller's environment
# into the container, so `FOO=1 modx_php <<PHP` would silently lose FOO while reading identically.
# A script fed on stdin still receives $argv (measured), so the scripts take their inputs there.
modx_php()  { ${MODX_PHP_RUN:-php} "$@"; }
local_php() { php "$@"; }

# --- the install directory, and the one name it has ---------------------------------------------
# infra's ask named this MODX_INSTALL_DIR. It is MODX_ROOT: that variable already exists, is already
# declared in service.json as `path:modx/docroot`, and is already what jump-nav.php, 11-add-context
# and apply-environment read. A second name for one fact is the thing rule 18 exists to
# stop, and the cost of two names is not theoretical — it is a verb that sets one while the suites
# read the other, which is a green run against a machine nobody meant.
#
# So MODX_INSTALL_DIR is REFUSED rather than quietly ignored. A verb that sets it and gets a silent
# default is the exact failure this ticket is about; a verb that sets it and gets a refusal naming
# the right variable is fixed in one line.
if [ -n "${MODX_INSTALL_DIR:-}" ] && [ -z "${MODX_ROOT:-}" ]; then
  echo "REFUSING: MODX_INSTALL_DIR is set and MODX_ROOT is not." >&2
  echo "          This repository has ONE name for the docroot and it is MODX_ROOT (service.json," >&2
  echo "          path:modx/docroot). Honouring both would let a runner set one while the suites" >&2
  echo "          read the other, and report green against a machine nobody meant. Set MODX_ROOT." >&2
  exit 2
fi
# EXPORTED, not just set: protect-on-save.sh reads it with getenv() inside a php heredoc, and a
# shell variable that is not exported reaches php as false — which concatenates to '/index.php'
# and would look for MODX at the filesystem root. The php side refuses on an empty value for the
# same reason; a path built from a missing variable is the shape that cost an hour on
# clear-cache.php ('Could not open input file', discarded to /dev/null).
export MODX_ROOT=${MODX_ROOT:-/srv/local/modx}

# --- no client certificate at the door ----------------------------------------------------------
# The suites sign in by the test user's password (idp_sign_in) and present no certificate. They once
# presented this box's estate certificate on every hop (for the mock's act-as); the
# non-production door now answers an estate-CA certificate with nginx's 400 "The SSL certificate
# error" before it serves its form (measured 2026-10-28: discovery 200 without, 400 with
# skunkworks@dev), and MODx never asked for one.

# --- signing in at the estate sign-in door (the mock is retired) -------------------------------
# idp_sign_in <authorize-url> <address> -> prints the callback URL carrying the code, or nothing.
# Uses the suite's own curl array C (its cookie jar, --resolve and certificate), so the door's
# session cookie rides the same jar as MODx's. The door (design/estate-sign-in.md §2) serves
# Keycloak's kc-form-login and takes the realm user's password: on a box with a vault, from
# skunkworks' collection under the name infra declared; on a ground with no vault, from
# the pair infra renders (below). An agent signs in AS the test user by its password — no act-as
# outside production. The only form accepted is the door's; any other page is a refusal that names it.
idp_sign_in() {
  local loc=$1 who=$2 form action realm pw
  form=$("${C[@]}" "$loc")
  action=$(printf '%s' "$form" | grep -o 'id="kc-form-login"[^>]*action="[^"]*"' | head -1 | sed 's/.*action="//; s/"$//')
  [ -n "$action" ] || { echo "idp_sign_in: the provider did not serve the door's sign-in form: $(printf '%s' "$form" | sed 's/<[^>]*>/ /g' | tr -s ' \n' ' ' | head -c 200)" >&2; return 1; }
  realm=$(printf '%s' "$loc" | sed -n 's#.*/realms/\([^/]*\)/.*#\1#p')
  # A GROUND WITH NO VAULT (staging): infra renders the realm users' addresses and passwords
  # into /etc/modx-staging-tests.env — MODX_DOOR_USER with MODX_DOOR_PASSWORD (the drill reader) and  # pragma: allowlist secret
  # MODX_DOOR_OUTSIDER with MODX_DOOR_OUTSIDER_PASSWORD (an address MODx does not know). A suite  # pragma: allowlist secret
  # that signs in as anyone else FAILS naming the variables, rather than presenting the wrong
  # person's password.
  if [ -n "${MODX_DOOR_PASSWORD:-}" ] || [ -n "${MODX_DOOR_OUTSIDER_PASSWORD:-}" ]; then  # pragma: allowlist secret
    if [ "$who" = "${MODX_DOOR_USER:-}" ] && [ -n "${MODX_DOOR_PASSWORD:-}" ]; then  # pragma: allowlist secret
      pw=$MODX_DOOR_PASSWORD  # pragma: allowlist secret
    elif [ "$who" = "${MODX_DOOR_OUTSIDER:-}" ] && [ -n "${MODX_DOOR_OUTSIDER_PASSWORD:-}" ]; then  # pragma: allowlist secret
      pw=$MODX_DOOR_OUTSIDER_PASSWORD  # pragma: allowlist secret
    else
      echo "idp_sign_in: this ground renders passwords for MODX_DOOR_USER='${MODX_DOOR_USER:-}' and MODX_DOOR_OUTSIDER='${MODX_DOOR_OUTSIDER:-}', and this suite signs in as $who" >&2; return 1  # names the variables, carries no value; pragma: allowlist secret
    fi
  else
    pw=$(vault get "Keycloak (non-production sign-in door) — $realm user $who") && [ -n "$pw" ] \
      || { echo "idp_sign_in: no password in the vault for $who in realm '$realm', and no rendered MODX_DOOR_*PASSWORD names it" >&2; return 1; }  # pragma: allowlist secret
  fi
  # The password goes on stdin, never in argv, where any process listing on the box would show it.
  printf '%s' "$pw" | "${C[@]}" -o /dev/null -w '%{redirect_url}' -X POST \
    --data-urlencode "username=$who" --data-urlencode "password@-" --data-urlencode "credentialId=" \
    "${action//&amp;/&}"
}

# door_can_sign_in <address> -> 0 when this ground can present that address's password (a vault, or
# a rendered pair naming it); a suite that needs a second user REFUSES on 2 rather than failing as
# if MODx were wrong, which is what staging did nightly for the outsider.
door_can_sign_in() {
  if [ -n "${MODX_DOOR_PASSWORD:-}" ] || [ -n "${MODX_DOOR_OUTSIDER_PASSWORD:-}" ]; then  # pragma: allowlist secret
    { [ "$1" = "${MODX_DOOR_USER:-}" ] && [ -n "${MODX_DOOR_PASSWORD:-}" ]; } \
      || { [ "$1" = "${MODX_DOOR_OUTSIDER:-}" ] && [ -n "${MODX_DOOR_OUTSIDER_PASSWORD:-}" ]; }  # pragma: allowlist secret (both lines)
    return
  fi
  command -v vault >/dev/null
}

# --- the suites' own reader: a machine identity, never a person ---------------------------------
# The suites signed in as the first active user with an email — on every bench and on staging that
# is the owner's own account, restored from production, by a password the door is about to refuse
# to people (D6). drill_address is a door test user that is no person; its MODx account is not in
# production, so every restore drops it and drill_reader puts it back: active, in allContextMember
# (every context's member group), no password a manager login could match. Prints the address.
# MODX_DRILL_READER names another machine identity the door already knows, for a ground where this
# one is not yet a door user. It must still be a machine identity, never a person.
drill_address=${MODX_DRILL_READER:-modx-drill@example.test}
drill_reader() {
  local id
  id=$(q "SELECT internalKey FROM modx_user_attributes WHERE email='$drill_address' LIMIT 1;")
  if [ -z "$id" ]; then
    id=$(q "INSERT INTO modx_users (username, password, salt, active, sudo, createdon)
              VALUES ('$drill_address', '', '', 1, 0, UNIX_TIMESTAMP());
            INSERT INTO modx_user_attributes (internalKey, fullname, email, address, comment)
              VALUES (LAST_INSERT_ID(), 'MODx Drill', '$drill_address', '', '');
            SELECT internalKey FROM modx_user_attributes WHERE email='$drill_address' LIMIT 1;")
  fi
  [ -n "$id" ] || { echo "drill_reader: could not create $drill_address on this ground" >&2; return 1; }
  q "UPDATE modx_users SET active=1 WHERE id=$id;
     INSERT INTO modx_member_groups (user_group, member, role, \`rank\`)
       SELECT g.id, $id, 1, 0 FROM modx_membergroup_names g WHERE g.name='allContextMember'
       AND NOT EXISTS (SELECT 1 FROM modx_member_groups m WHERE m.user_group=g.id AND m.member=$id);"
  printf '%s' "$drill_address"
}

# --- the scheme and port, which are DECLARED and were hardcoded ---------------------------------
# Every request in these suites was `--resolve "$HOST:80:$IP"` against `http://$HOST/…`. That was
# true while a bench meant plain http on somebody's workstation. MODx staging sits behind four
# estate-CA certificates now, `:80` 301s to `:443`, and MODx emits https itself —
# so those requests return the 301, `curl` without -L hands back the redirect page, and SIX suites
# would report failures that are about the scheme and not about the code. That is precisely what
# was warned of: addressing a bench that no longer exists rather than reporting a defect.
#
# The scheme is not a constant to swap, it is DECLARED: each context's `site_url`, which infra's
# modx-environment.py derives and setup/apply-environment.php writes. So the suites read it
# from the database rather than carrying a second copy — the same argument as ask 3's MODX_ROOT.

# origin_of <site_url> -> "<scheme> <port>". PURE: no database, no network, unit-drilled in
# tests/suites-accept-their-ground.sh. Returns 1 on anything it cannot read, so a caller can never
# silently proceed on a default that happens to be wrong.
origin_of() {
  local u=${1:-} scheme rest hostport port
  case "$u" in
    http://*)  scheme=http ;;
    https://*) scheme=https ;;
    *) return 1 ;;
  esac
  rest=${u#*://}; hostport=${rest%%/*}
  case "$hostport" in
    *:*) port=${hostport##*:} ;;
    *)   [ "$scheme" = https ] && port=443 || port=80 ;;
  esac
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s %s\n' "$scheme" "$port"
}

# ctx_origin <context> / host_origin <http_host> — the same fact, reached the two ways the suites
# know their target. http_host is the context-resolution key; site_url carries the scheme. Both are
# written by apply-environment.php from infra's derivation, so neither is a second home for anything.
ctx_origin() {
  local url; url=$(q "SELECT value FROM modx_context_setting WHERE context_key='$1' AND \`key\`='site_url';")
  origin_of "$url" || {
    echo "REFUSING: context '$1' has no readable site_url ('$url'), so this suite cannot know" >&2
    echo "          whether to speak http or https to it. Nothing has been asserted." >&2
    exit 2; }
}
# ctx_door <context> / host_door <http_host> — the HOST[:PORT] a request must be sent to, read off
# the same site_url that gives the scheme. On a named ground it is the http_host and nothing
# changes. A suite that types a name instead reaches the wrong ground and reports its 301 as a
# defect in the tree (2026-09-20, six suites).
ctx_door() {
  local url rest; url=$(q "SELECT value FROM modx_context_setting WHERE context_key='$1' AND \`key\`='site_url';")
  origin_of "$url" >/dev/null || {
    echo "REFUSING: context '$1' has no readable site_url ('$url'), so this suite cannot know" >&2
    echo "          which door to knock on. Nothing has been asserted." >&2
    exit 2; }
  rest=${url#*://}; printf '%s\n' "${rest%%/*}"
}
# The host a suite addresses by default is the context's LIVE http_host, read here — not
# `<ctx>.<bench zone>` typed in each suite. Staging's names are its own (<ctx>.staging.<zone>,
# rendered by the provisioner), and a typed default reached no context there.
ctx_host() {
  local h; h=$(q "SELECT value FROM modx_context_setting WHERE context_key='$1' AND \`key\`='http_host';")
  [ -n "$h" ] || {
    echo "REFUSING: context '$1' has no http_host in this database, so this suite cannot know which" >&2
    echo "          name to address. Set MODX_TEST_HOST, or bind the context." >&2
    exit 2; }
  printf '%s\n' "$h"
}
host_door() {
  local ctx; ctx=$(q "SELECT context_key FROM modx_context_setting WHERE \`key\`='http_host' AND value='$1' LIMIT 1;")
  [ -n "$ctx" ] || {
    echo "REFUSING: no context in this database answers to host '$1', so this suite cannot know" >&2
    echo "          its door. That is a statement about the ground, not about the tree." >&2
    exit 2; }
  ctx_door "$ctx"
}
host_origin() {
  local ctx; ctx=$(q "SELECT context_key FROM modx_context_setting WHERE \`key\`='http_host' AND value='$1' LIMIT 1;")
  [ -n "$ctx" ] || {
    echo "REFUSING: no context in this database answers to host '$1', so this suite cannot know" >&2
    echo "          its scheme. That is a statement about the ground, not about the tree." >&2
    exit 2; }
  ctx_origin "$ctx"
}

# --- assertions --------------------------------------------------------------------------------
pass=0; fail=0
check() {
  if [ "$1" = 1 ]; then pass=$((pass+1)); printf '  ok    %s\n' "$2"; return; fi
  fail=$((fail+1)); printf '  FAIL  %s\n' "$2"
  [ -n "${3:-}" ] && printf '          %s\n' "$3"
}
summary() { printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" = 0 ]; }

# --- searching a response, without the pipe that lies -------------------------------------------
# `check "$(echo "$body" | grep -qF needle && echo 1 || echo 0)"` is a RACE as soon as $body is a
# whole page. grep -q exits the instant it matches; echo is still writing; bash's echo takes SIGPIPE;
# the command substitution yields nothing at all, and `check ""` reads as FAIL on a response that is
# perfectly correct. The earlier in the page the needle sits, the likelier it is to fail — so the
# things worth asserting about a <head> are the worst affected.
#
# Measured 2026-07-30 on a 43,401-byte page whose bytes were identical across 15 fetches: the same
# assertions failed in a DIFFERENT combination on each run, including a control that grepped for
# `<title>`. Nothing was wrong with the page.
#
# So: match with bash itself. No fork, no pipe, no answer to lose. Use these, never `| grep -q`.
has()    { case "$1" in *"$2"*) echo 1 ;; *) echo 0 ;; esac; }   # literal substring
hasnt()  { case "$1" in *"$2"*) echo 0 ;; *) echo 1 ;; esac; }   # and its negation, stated once
hasre()  { if [[ $1 =~ $2 ]]; then echo 1; else echo 0; fi; }    # extended regex

# --- refusals ----------------------------------------------------------------------------------
# These tests write. They must never do it to production, and they must never run from a copy whose
# idea of the repo is wrong: `dirname/..` from /tmp resolves to `/`, and `php /clear-cache.php` then
# fails with "Could not open input file" — which, discarded to /dev/null, is indistinguishable from
# a cache that was cleared. An hour went into diagnosing MODx for exactly that.
require_repo() {
  [ -f "$REPO/clear-cache.php" ] || {
    echo "REFUSING TO RUN: no clear-cache.php under '$REPO' — run this from the repo." >&2; exit 2; }
}
# The estate's internal zone (estate.internal_zone, e.g. '.internal.example') — a name under it is
# not reachable from the internet, so a ground whose hosts all sit under it is not production.
internal_zone() { q "SELECT value FROM modx_system_settings WHERE \`key\`='estate.internal_zone';"; }
under_zone() {   # $1 a host or URL, $2 the zone: 0 when the host ends in the zone
  local h=${1#*://}; h=${h%%/*}; h=${h%%:*}
  [ -n "$2" ] && case "$h" in *"$2") return 0 ;; esac; return 1
}
require_bench() {
  local host zone; host=$(q "SELECT value FROM modx_system_settings WHERE \`key\`='http_host';"); zone=$(internal_zone)
  case "$host" in localhost|'') return 0 ;; esac
  under_zone "$host" "$zone" && return 0
  echo "REFUSING TO RUN: http_host is '$host', not under the internal zone '${zone:-unset}'. These tests write; bench only." >&2; exit 2
}
require_nonprod_door() {
  # What it protects is that a suite never signs in at PRODUCTION's door (it was named for
  # the mock until the mock was retired). The door's non-production realms (dev, staging) hold test users
  # only, so a context whose sso.oidc_auth_endpoint is one of them, or anything in the internal zone
  # or on loopback, may be driven; anything else refuses. The bench trio it also read is retired.
  local ctx_ep
  ctx_ep=$(q "SELECT value FROM modx_context_setting WHERE \`key\`='sso.oidc_auth_endpoint' LIMIT 1;")
  [ -n "$ctx_ep" ] || { echo "REFUSING TO RUN: no context on this ground has an sso.oidc_auth_endpoint — it signs nobody in." >&2; exit 2; }
  case "$ctx_ep" in
    */realms/dev/*|*/realms/staging/*|*127.0.0.1*|*localhost*) return 0 ;;
  esac
  under_zone "$ctx_ep" "$(internal_zone)" && return 0
  echo "REFUSING TO RUN: a context's sso.oidc_auth_endpoint is '$ctx_ep' — not a non-production realm of" >&2
  echo "the door. These suites sign in, and never at production's door." >&2; exit 2
}

# --- the cache, and the two-second lie ----------------------------------------------------------
# clear-cache.php regenerates MODx's caches as PHP FILES. PHP-FPM serves those through opcache, and
# opcache re-checks a file's timestamp at most once every `opcache.revalidate_freq` seconds — 2 on
# this box. So for up to two seconds after a cache clear, a web request compiles the OLD file and a
# setting that is unquestionably in the database reads as empty.
#
# That is not a hypothesis. Measured 2026-07-29: DB 1704 bytes, config.cache.php containing the key,
# and a signed-in request reporting length 0 — reproducible in the test, never reproducible by hand,
# because typing the same commands takes longer than two seconds. The same fault would hit any
# script that changes a setting and then verifies over HTTP; a verifier that reads the database
# (setup/verify-*.py) is unaffected, which is why this had never been seen.
#
# So: clear, then wait out the revalidation window before believing anything served over HTTP.
clear_cache() {
  local out freq
  # ON STDIN, with the docroot as an argument: the script is a REPO file and the container mounts
  # the docroot, not this checkout. Fed on stdin it needs no mount at all, and it
  # reads nothing relative to its own location, so this is the whole of what it needs.
  out=$(modx_php -- "$MODX_ROOT" < "$REPO/clear-cache.php" 2>&1) || { echo "clear-cache.php failed: $out" >&2; exit 2; }
  case "$out" in *"Cache cleared"*) ;; *) echo "clear-cache.php said: $out" >&2; exit 2 ;; esac
  # modx_php, not local_php: the revalidation window that matters belongs to the PHP that
  # SERVES the site. On a ground where that is a container, this box's ini says nothing about it.
  freq=$(modx_php -r 'echo (int) ini_get("opcache.revalidate_freq");' 2>/dev/null)
  [ -n "$freq" ] && [ "$freq" -gt 0 ] 2>/dev/null || freq=2
  sleep "$((freq + 1))"
}
