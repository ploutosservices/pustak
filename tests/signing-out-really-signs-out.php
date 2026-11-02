<?php
/**
 * signing-out-really-signs-out.php — what the sign-out actually ends, and what it says.
 *
 *     php tests/signing-out-really-signs-out.php
 *
 * The owner, 2026-08-14: *"i cannot logout when manager is logged in. not sure if that is a feature or
 * a bug"*. It is a bug, and it had two halves.
 *
 * THE HALF THAT WAS TRUE FOR EVERYONE. `GoogleSSOLogout` removed the context token and nothing
 * else, leaving every key the SSO callback had written in the session — `sso.verified_email`,
 * which tableRenderer's `&auth` asserts to kuber, and `sso.id_token`, which the bookkeeping-names
 * plugin presents. Signing out left an identity behind that this estate would still vouch for.
 *
 * THE MANAGER HALF. Since 2026-10-24 the sign-out ends the manager too (the owner: "either sign me
 * out or show me the button to sign out. you leave me hanging"); before, it was left open.
 *
 * WHY THIS SUITE IS STATIC. Both halves are session behaviour inside a running MODx, and asserting
 * them for real needs a browser, a manager login and a Google sign-in. What can be asserted here
 * is that the code does the two things it must and does not do the one it must not — and those are
 * exactly the properties that would rot silently, because nothing about the old code LOOKED wrong.
 * Every check below is drilled: each fails when its line is removed.
 */

$pass = 0;
$fail = 0;
function ok(string $l): void   { global $pass; $pass++; echo "  ok    $l\n"; }
function bad(string $l, string $d = ''): void {
    global $fail; $fail++; echo "  FAIL  $l\n"; if ($d !== '') echo "        $d\n";
}
function check(bool $c, string $l, string $d = ''): void { $c ? ok($l) : bad($l, $d); }

$root = dirname(__DIR__);
// Comment lines stripped before anything is located: three checks of mine were fooled by their own
// documentation on 2026-08-14, and this file documents heavily on purpose.
$code = function (string $rel) use ($root): string {
    $lines = file($root . '/' . $rel, FILE_IGNORE_NEW_LINES);
    return implode("\n", array_filter($lines, fn($l) => !preg_match('#^\s*(//|\*|/\*|\{\*)#', $l)));
};

$logout = $code('common/snippets/GoogleSSOLogout.php');
$start  = $code('common/snippets/GoogleSSOStart.php');

echo "signing-out-really-signs-out — the sign-out ends the identity, and ends at the door\n\n";

// ── 1. the identity this site issued is dropped ────────────────────────────────────────────────
foreach (['sso.verified_email', 'sso.id_token', 'sso.id_token_exp'] as $key) {
    check(strpos($logout, "'$key'") !== false,
          "logout drops $key",
          "it survives a sign-out, and downstream still vouches for the reader with it");
}

// ── 2. and it ENDS the manager session too ─────────────────────────────────────────────────────
// The owner, 2026-10-24: "either sign me out or show me the button to sign out. you leave me
// hanging." Shared session (production): ended here through the manager's own logout events.
// Separate sessions: the browser is sent through the manager first (adminDoor ?pustak-signout).
check(preg_match("#removeSessionContext\\(\\s*['\"]mgr['\"]#", $logout) === 1,
      'it ends a manager session that shares the site session', 'a manager session survives the sign-out');
check(strpos($logout, "invokeEvent('OnBeforeManagerLogout'") !== false && strpos($logout, "invokeEvent('OnManagerLogout'") !== false,
      "  through the manager's own logout events");
check(strpos($logout, "pustak-signout") !== false,
      '  and sends the browser through the manager first when its session is a separate cookie');
check(strpos($logout, "isAuthenticated('mgr')") !== false && strpos($logout, 'LOG_LEVEL_WARN') !== false,
      '  and logs one that did not end');

// ── 3. the way back is the door's sign-in page (#1428; door-standard-login.md §2) ──────────────
// MODx draws no signed-out screen of its own: the door returns the browser to the sign-in entry with
// reason=signed_out, and the entry forwards it as chowkidar_reason so the door says it.
check(strpos($logout, "'post_logout_redirect_uri'") !== false && strpos($logout, 'reason=signed_out') !== false,
      'the sign-out names the way back: the sign-in entry with reason=signed_out');
check(strpos($start, "'chowkidar_reason'") !== false,
      'the sign-in entry passes the reason on to the door');
check(strpos($start, 'kc_idp_hint') === false,
      '  and never pre-selects a provider, which would sign the person straight back in');
check(strpos($start, 'getChunk(') === false && strpos($logout, 'sso=out') === false,
      'no signed-out card of MODx\'s own is drawn or asked for');

// ── 5. the sign-in page must not bounce a merely-KNOWN user ────────────────────────────────────
// The owner, testing this on production: 'with manager open, when i sign out, i go to home'. The
// sign-out was correct; GoogleSSOStart's loop guard was not. It redirected anyone getUser()
// returned — and a manager session returns him — so the page he was sent to forwarded him onward
// before it could render what it had to say. The guard has to ask whether the visitor is authenticated in
// THIS context, which is exactly what the sign-out just undid.
$start = $code('common/snippets/GoogleSSOStart.php');
check(strpos($start, 'isAuthenticated(') !== false,
      "the sign-in page's loop guard asks isAuthenticated(context)",
      'a bare getUser() check bounces anyone with any session, including a manager one');
check(!preg_match('#if \s*\(\s*\$current\s*&&\s*\(int\)\s*\$current->get\(.id.\)\s*>\s*0\s*\)#', $start),
      '  and not merely whether a user is known',
      'the old shape is back: known != entitled to this context');

echo "\n  $pass passed, $fail failed\n";
exit($fail === 0 ? 0 : 1);
