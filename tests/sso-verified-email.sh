#!/usr/bin/env bash
# sso-verified-email.sh — sign in for real, then assert the session says WHO signed in.
#
#     bash tests/sso-verified-email.sh
#
# WHAT IS UNDER TEST. tableRenderer's `&auth` asserts a reader's Google-verified email to
# kuber. It takes that address from `$_SESSION['sso.verified_email']`, which GoogleSSOCallback
# stamps at the moment Google's answer is accepted — deliberately NOT from the MODx user's profile,
# because a profile email is whatever a manager typed, and `sub` claims something stronger than
# that: an identity provider verified this person. If the stamp is missing, every &auth call renders
# blank; if it is wrong, MODx asserts the wrong person to kuber. Neither is visible on the page.
#
# WHY THIS IS AN INTEGRATION TEST AND NOT A UNIT ONE. The claim is about what a real sign-in leaves
# in a real session. Stubbing MODx's session, user lookup and token exchange would test my model of
# three systems. This drives the actual flow against the door's non-production realm — which holds
# test users precisely so sign-in is exercisable without production — and then reads the session
# out of the database.
#
# WHAT IT NEEDS: this box's MODx bench, its vhost, and the context's sso.oidc_* rows at the door. It
# creates one session row and removes it again. It writes nothing else.
set -uo pipefail

HOST=${MODX_TEST_HOST:-}   # empty: the context's live http_host, read after lib.sh
IP=${MODX_TEST_IP:-127.0.0.1}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CTX=$(python3 "$REPO/setup/estate-get.py" domains.contexts | head -1)   # the estate's first context
[ -n "$HOST" ] || HOST=$(ctx_host "$CTX") || exit 2

# The scheme and port are DECLARED, not assumed — see lib.sh origin_of(). This REFUSES if the
# ground cannot tell it which, rather than speaking http at an https edge and reporting the 301
# as a failure of the page.
read -r SCHEME PORT < <(host_origin "$HOST")
DOOR=$(host_door "$HOST") || exit 2

require_repo
require_bench
require_nonprod_door

echo "GoogleSSOCallback — the session records the verified identity"


# Resolved from the database, never spelled here: whose account this is is not a fact belonging to
# a test file. Any active user with an address will do — auto_provision is off, so the address must
# already map to one.
# modUserProfile's table is modx_user_attributes, not modx_user_profile — the class name and the
# table name differ, and guessing the second from the first is how this failed its first run.
reader=$(drill_reader)   # a machine identity, never a person
if [ -z "$reader" ]; then
  echo "REFUSING TO RUN: drill_reader could not seat the suites' machine identity on this ground." >&2
  exit 2
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
jar="$tmp/cookies"
C=(curl -sS --resolve "${DOOR%%:*}:$PORT:$IP" -b "$jar" -c "$jar" -m 10)

# 1. sso=go is what fires the redirect (the bare page renders a branded card with a button).
loc=$("${C[@]}" -o /dev/null -w '%{redirect_url}' "$SCHEME://$DOOR/sso-login?sso=go")
check "$([ -n "$loc" ] && echo 1 || echo 0)" "sso-login redirects to the provider" "got: '$loc'"

# 2–3. Sign in as that address at the door, by the test user's password.
cb=$(idp_sign_in "$loc" "$reader")
check "$(has "$cb" 'code=')" "signing in yields an authorization code" "got: '$cb'"
[ -z "$cb" ] && { summary; exit 1; }

# 4. MODx completes the exchange server-side and establishes the session.
# `"${cb/http:\/\/$HOST/http://$HOST}"` was here: a parameter substitution replacing a string
# with ITSELF, so byte-for-byte this is the same request. It went when the literal http did.
code=$("${C[@]}" -o /dev/null -w '%{http_code}' "$cb")
check "$([ "$code" = 302 ] && echo 1 || echo 0)" "the callback completes and redirects" "HTTP $code"

sid=$(awk '/PHPSESSID/ {print $7}' "$jar" | tail -1)
check "$([ -n "$sid" ] && echo 1 || echo 0)" "a MODx session exists" "cookie jar: $(cat "$jar")"
[ -z "$sid" ] && { summary; exit 1; }

data=$(q "SELECT data FROM modx_session WHERE id='$sid';")
# The control that proves this probe can see anything at all: the session must hold the MODx login
# too. Without it, an empty or wrong 'data' would make the assertions below fail for a reason that
# has nothing to do with what is under test. `<context>.user.token` is the discriminator — it is
# written only when a user is established; an anonymous session carries modx.user.0.* and no token,
# which is why matching on `modx.user` alone passed over a signed-OUT session on the first run.
check "$(has "$data" 'user.token')" \
      "the session row is readable and holds the MODx login" "data: ${data:0:200}"
check "$(has "$data" 'sso.verified_email')" \
      "the session records that the identity was provider-verified" "data: ${data:0:400}"
check "$(has "$data" "$reader")" \
      "and it is the address that signed in" "data: ${data:0:400}"

q "DELETE FROM modx_session WHERE id='$sid';" >/dev/null 2>&1

summary
