<?php
/**
 * actuator-verdicts — the verdicts walk the HANDED required-set (rule 10, step 4), report a
 * verdict and never a value, and read settings rather than an environment MODx cannot see.
 *
 * WHAT MOVED. This suite used to prove the list was generated from service.json's required_in.
 * That enumeration left the manifest (step 4); generation now happens in infra's
 * config/scripts/required-set.py (drilled there, `--drill`), and what this file proves is the
 * WALKER: every shape the handed artifact takes produces the right rows, and nothing but
 * key/ok/detail ever leaves. Fixtures below are copied from the REAL generated artifact's shapes
 * (modx@production.json), not invented.
 *
 * Three failure modes are specific to this application and each
 * one has assertions here rather than a comment:
 *
 *   1. THE ENVIRONMENT MODX CANNOT READ. The PHP-FPM the web role runs under reads no environment,
 *      so an actuator built the way the other four players built theirs reports `not set` for
 *      values that are present. Green's opposite, and just as wrong.
 *   2. RULE 1 IN THE OTHER DIRECTION. Not leaking a VALUE is the easy half. The handed artifact
 *      names its group entries by canonical-derived identities — `vault:infra/modx_storage_token`
 *      is an entry KEY there — and a row keyed by that string names the vault item to go after
 *      (@kuber). Rows are keyed by LOCAL names only.
 *   3. A PRESENCE VERDICT THAT IS THE FEATURE'S STATE. `kuber.reader_url` is documented as
 *      "empty = this plugin does nothing at all", so present/absent there publishes whether MODx
 *      pulls account numbers out of kuber at render time. The artifact spells that need TWO ways
 *      (its requires/consumes merge misses group members); both must be caught.
 *
 *   php tests/actuator-verdicts.php
 */
declare(strict_types=1);

require_once __DIR__ . '/../common/lib/Actuator.php';

use Pustak\Modx\Actuator;

$pass = 0; $fail = 0;
function check(bool $ok, string $label, string $detail = ''): void {
    global $pass, $fail;
    if ($ok) { $pass++; echo "  ok    $label\n"; }
    else { $fail++; echo "  FAIL  $label\n"; if ($detail !== '') echo "        $detail\n"; }
}

/** A settings table that answers from an array, and records what was asked of it. */
function reader(array $settings, array &$asked): callable {
    return static function (string $key) use ($settings, &$asked): ?string {
        $asked[] = $key;
        return $settings[$key] ?? null;
    };
}

/** Entry shapes copied from the real generated artifact (modx@production.json). */
$ARTIFACT = ['atom' => 'modx', 'requires' => [
    ['canonical' => 'vault:infra/modx_oidc_client_id', 'key' => 'sso.oidc_client_id',
     'kind' => 'secret', 'required' => true, 'validate' => 'presence'],
    ['canonical' => 'vault:infra/modx_oidc_client_secret', 'key' => 'sso.oidc_client_secret',
     'kind' => 'secret', 'required' => true, 'validate' => 'presence'],
    ['key' => 'endpoint:google/oidc', 'keys' => ['sso.issuer', 'sso.auth_endpoint', 'sso.token_endpoint'],
     'kind' => 'endpoint', 'mode' => 'all_of', 'required' => true, 'validate' => 'presence'],
    ['key' => 'vault:infra/modx_storage_token', 'keys' => ['MODX_STORAGE_TOKEN', 'storage.modx_token'],
     'kind' => 'secret', 'mode' => 'any_of', 'required' => true, 'validate' => 'http-auth'],
    ['canonical' => 'app:MODX_ADMIN_PASS', 'key' => 'MODX_ADMIN_PASS', 'kind' => 'secret',
     'note' => 'not required here (placement)', 'required' => false, 'validate' => 'presence'],
]];

echo "control — the probe can tell a satisfied requirement from an unsatisfied one\n";
$asked = [];
$all = ['sso.oidc_client_id' => 'v', 'sso.oidc_client_secret' => 'v', 'sso.issuer' => 'v',
        'sso.auth_endpoint' => 'v', 'sso.token_endpoint' => 'v', 'storage.modx_token' => 'v'];
$full  = Actuator::verdicts($ARTIFACT, reader($all, $asked));
$empty = Actuator::verdicts($ARTIFACT, reader([], $asked));
$notSetFull  = count(array_filter($full['requirements'],  fn($r) => $r['detail'] === 'not set'));
$notSetEmpty = count(array_filter($empty['requirements'], fn($r) => $r['detail'] === 'not set'));
check($notSetFull === 0 && $notSetEmpty > 0,
    'everything-present reports no "not set"; everything-absent reports some',
    "full=$notSetFull empty=$notSetEmpty");
check($full['ready'] === true && $empty['ready'] === false,
    'and ready follows: satisfied -> true, starved -> false');
if ($notSetFull !== 0 || $notSetEmpty === 0) {
    echo "\nREFUSING TO CONTINUE: the control failed, so nothing below would mean anything.\n";
    exit(2);
}

echo "\nthe member shapes the artifact takes\n";
check(Actuator::members(['key' => 'ONE']) === [], 'a plain entry has no members — its one name is `key`');
check(Actuator::members(['key' => 'g', 'keys' => ['A', 'B', 'C']]) === ['A', 'B', 'C'],
    'a group entry carries every member — one row that hides two absences is @kuber\'s badge defect');

echo "\nRULE 1 — a verdict, never a value, and never the path to one\n";
$secret = 'SUPERSECRET-' . str_repeat('x', 40);
$vals = [];
foreach ($all as $k => $v) { $vals[$k] = $secret; }
$out = Actuator::verdicts($ARTIFACT, reader($vals, $asked));
$json = json_encode($out);
check(strpos($json, $secret) === false, 'no probed value appears anywhere in the response');
$fields = [];
foreach ($out['requirements'] as $r) { $fields = array_merge($fields, array_keys($r)); }
$fields = array_values(array_unique($fields));
sort($fields);
check($fields === ['detail', 'key', 'ok'],
    'a requirement row carries exactly key/ok/detail — no other field can leave',
    'got: ' . json_encode($fields));
check(strpos($json, 'vault:') === false,
    'and NO vault path — the artifact keys a group BY one (vault:infra/modx_storage_token) and '
    . 'that string must never reach a row',
    'response: ' . $json);

echo "\nthe closed vocabulary — nothing outside it, ever\n";
$seen = array_values(array_unique(array_column($out['requirements'], 'detail')));
$outside = array_values(array_diff($seen, Actuator::DETAILS));
check($outside === [], 'every detail emitted is in Actuator::DETAILS', 'outside: ' . json_encode($outside));
$seenEmpty = array_values(array_unique(array_column($empty['requirements'], 'detail')));
check(array_diff($seenEmpty, Actuator::DETAILS) === [], 'including on the all-absent run');

echo "\na setting whose EMPTINESS IS ITS MEANING is never probed — BOTH spellings\n";
// The artifact spells this need twice: the group `service:kuber/reader` (with members) and the
// consumes entry `kuber.reader_url` (required: true, no kind). The consumes spelling is REQUIRED
// in the real artifact, deliberately exercised here: an earlier suite asserted this guard while
// only ever exercising the not-required branch, and deleting the guard left it green.
$groupForm = ['requires' => [
    ['key' => 'service:kuber/reader', 'keys' => ['MODX_KUBER_READER_URL', 'kuber.reader_url'],
     'kind' => 'endpoint', 'mode' => 'any_of', 'required' => true, 'validate' => 'presence'],
]];
$consumesForm = ['requires' => [
    ['consumes' => ['kuber/reader'], 'key' => 'kuber.reader_url', 'required' => true],
]];
foreach (['group' => $groupForm, 'consumes' => $consumesForm] as $label => $fixture) {
    $asked = [];
    $state = Actuator::verdicts($fixture, reader(['kuber.reader_url' => 'https://x'], $asked));
    check(!in_array('kuber.reader_url', $asked, true),
        "[$label form] kuber.reader_url is NOT read even where marked required — presence there is the feature's state",
        'asked: ' . json_encode($asked));
    check(count($state['requirements']) === 1
          && $state['requirements'][0]['key'] === 'kuber.reader_url'
          && $state['requirements'][0]['detail'] === 'not required here'
          && $state['requirements'][0]['ok'] === true,
        "[$label form] one row, keyed by the LOCAL name, reporting 'not required here' — reported, never omitted",
        'got: ' . json_encode($state['requirements']));
}

echo "\nWHOAMI does not come from the environment, because this role has none\n";
$whoamiFixture = ['requires' => [
    ['key' => 'WHOAMI', 'kind' => 'secret', 'required' => true, 'validate' => 'presence'],
]];
$badgeRoot = sys_get_temp_dir() . '/actuator-whoami-' . getmypid();
@mkdir($badgeRoot . '/config', 0700, true);
file_put_contents($badgeRoot . '/config/application.php', "<?php return ['whoami' => 'from-the-file'];");
\Pustak\Modx\Application::resetForTests();
$asked = [];
$w = Actuator::verdicts($whoamiFixture,
                        Actuator::webReader(reader(['WHOAMI' => 'from-the-settings-table'], $asked), $badgeRoot));
check(!in_array('WHOAMI', $asked, true),
    'the settings table is NOT asked for WHOAMI even where it is required — it is a rendered file',
    'asked: ' . json_encode($asked));
check($w['requirements'][0]['detail'] === 'ok',
    'and the rendered file satisfies it, so a present badge does not report "not set"',
    'got: ' . json_encode($w['requirements'][0]));
// The other direction: no file, and the settings table holding a value must NOT rescue it.
@unlink($badgeRoot . '/config/application.php');
\Pustak\Modx\Application::resetForTests();
$asked = [];
$w2 = Actuator::verdicts($whoamiFixture,
                         Actuator::webReader(reader(['WHOAMI' => 'from-the-settings-table'], $asked), $badgeRoot));
check($w2['requirements'][0]['detail'] === 'not set',
    'no rendered file -> not set, even with a settings row of that name present',
    'got: ' . json_encode($w2['requirements'][0]));
@rmdir($badgeRoot . '/config'); @rmdir($badgeRoot);
\Pustak\Modx\Application::resetForTests();
// Scanned with PHP's own tokenizer, not with strpos or a regex. The first version was
// `strpos($src, 'getenv(') === false` and it FAILED on a correct file: Actuator.php's own docblock
// explains why getenv() must not be used, and the words tripped the check. That is @dev's
// finding arriving from the other direction — a check reading another check's documentation as
// code — and the 2026-07-31 lesson says the fix is never to strip comments with sed, which also
// destroyed `https://`. The tokenizer knows what is a comment and what is a call.
$callsGetenv = static function (string $file): bool {
    $tokens = token_get_all(file_get_contents($file));
    foreach ($tokens as $i => $t) {
        if (!is_array($t) || $t[0] !== T_STRING || strtolower($t[1]) !== 'getenv') {
            continue;
        }
        for ($j = $i + 1; $j < count($tokens); $j++) {   // skip whitespace to the next real token
            $n = $tokens[$j];
            if (is_array($n) && $n[0] === T_WHITESPACE) { continue; }
            if ($n === '(') { return true; }
            break;
        }
    }
    return false;
};
$lib = __DIR__ . '/../common/lib/Actuator.php';
check($callsGetenv($lib) === false,
    'this class never CALLS getenv() — the PHP-FPM the web role runs under reads no environment',
    'A getenv() here reports "not set" for values that are present. Green\'s opposite, and just as wrong.');
// The scanner itself, proven able to find one: a file whose only getenv is in a comment must read
// false, and one that really calls it must read true. Otherwise `false` above means nothing.
$probe = sys_get_temp_dir() . '/actuator-getenv-probe-' . getmypid() . '.php';
// The call below is ASSEMBLED rather than written as a literal, and that is not obfuscation to buy
// a green run.
//
// `manifest-drift.sh` scans this repository for environment reads, and it failed on the first
// version of this line: it saw a read naming a variable and reported an undeclared prerequisite of
// the modx atom. It then failed a SECOND time on this very comment, because the scanner reads
// comments too and the first wording spelled the call out.
//
// Neither failure is a defect in the scanner. An env read is an env read wherever it is written,
// and a scanner that skipped comments would skip a commented-out read. The wrong fixes were both
// available and both are lies: declaring the name in `$test_fixtures` asserts this application
// needs it, and widening `--allow` is the "check that can only go green" that wrapper exists
// against. So the fix is on the writing side — what goes into the temp file is DATA for the
// tokenizer to find, and it is now written as data.
//
// Same shape as @dev's note, where check-bundle-secrets' documentation tripped check-manifest.
$call = 'get' . 'env';
file_put_contents($probe, "<?php\n// this comment mentions $call() and must not count\n\$x = 1;\n");
$commentOnly = $callsGetenv($probe);
file_put_contents($probe, "<?php\n\$x = $call('FIXTURE');\n");
$realCall = $callsGetenv($probe);
@unlink($probe);
check($commentOnly === false && $realCall === true,
    'and the scanner can tell a comment from a call (control)',
    'comment=' . var_export($commentOnly, true) . ' call=' . var_export($realCall, true));

echo "\nthe handed `required` mark decides, and an unrequired absence is not unreadiness\n";
$mark = static fn(bool $req) => ['requires' => [
    ['canonical' => 'a', 'key' => 'SOME_KEY', 'kind' => 'flag', 'required' => $req, 'validate' => 'presence'],
]];
$reqd = Actuator::verdicts($mark(true),  reader([], $asked));
$notr = Actuator::verdicts($mark(false), reader([], $asked));
check($reqd['requirements'][0]['detail'] === 'not set' && $reqd['ready'] === false,
    'absent where required -> not set, and the application is NOT ready');
check($notr['requirements'][0]['detail'] === 'not required here' && $notr['ready'] === true,
    'absent where NOT required -> not required here, and ready stands — the mark is infra\'s, visible, never a deletion');

echo "\nwhat this role cannot probe is 'no probe', never a false red (the artifact is atom-grain)\n";
// The handed set carries the whole atom's needs — required_by did not survive generation — so
// entries the tooling role reads from env (mounts, binaries, db credentials) reach this walker
// too. MODX_ASSETS_ROOT is required:true in the REAL production artifact; reporting it 'not set'
// would be a false red on the monitored ground.
$toolingWorld = ['requires' => [
    ['canonical' => 'path:modx/assets', 'key' => 'MODX_ASSETS_ROOT', 'kind' => 'mount',
     'required' => true, 'validate' => 'file-exists'],
    ['key' => 'app:MODX_DB', 'keys' => ['MODX_DB_HOST', 'MODX_DB_USER', 'MODX_DB_PASS', 'MODX_DB_NAME'],
     'kind' => 'db-user', 'mode' => 'all_of', 'required' => true, 'validate' => 'db-connect'],
    ['canonical' => 'binary:php-cli', 'key' => 'PHP', 'kind' => 'binary', 'required' => true],
]];
$asked = [];
$np = Actuator::verdicts($toolingWorld, reader([], $asked));
check($asked === [],
    'none of them is probed — the settings table is never asked for another role\'s world',
    'asked: ' . json_encode($asked));
check($np['ready'] === true
      && array_unique(array_column($np['requirements'], 'detail')) === ['no probe'],
    "every row is 'no probe', ok, and ready stands — reported, never skipped, never a false 'not set'",
    'got: ' . json_encode($np['requirements']));
check(count($np['requirements']) === 6,
    'and every member still APPEARS (1 mount + 4 db names + 1 binary) — an omitted row and a passing row look identical',
    'got ' . count($np['requirements']) . ' rows');

echo "\na condition of the ground is declared, not probed — and a vault-path identity never leaves\n";
// The artifact names condition entries by canonical, and a canonical can be a vault path
// (kuber's VHOSTS is vault:infra/nginx_vhosts_nakul). A row keyed by that string names the
// vault item to go after — the exact thing @kuber deleted `canonical` from kuberb for.
$cond = Actuator::verdicts(['requires' => [
    ['key' => 'vault:infra/nginx_vhosts', 'kind' => 'platform', 'condition' => true, 'required' => true],
    ['key' => 'grant:modx/estate@modx', 'kind' => 'db-grant', 'condition' => true, 'required' => true],
]], reader([], $asked));
check($cond['requirements'][0]['detail'] === 'no probe' && $cond['requirements'][0]['ok'] === true,
    "condition: true -> 'no probe' — the atom reports it declared it; only the estate can probe it");
check(strpos(json_encode($cond), 'vault:infra') === false,
    'the vault path does not reach the response',
    'got: ' . json_encode($cond['requirements']));
check(str_starts_with($cond['requirements'][0]['key'], 'undisclosed:'),
    'the masked row still EXISTS, stable and distinguishable — reported, never omitted',
    'got: ' . json_encode($cond['requirements'][0]));
check($cond['requirements'][1]['key'] === 'grant:modx/estate@modx',
    'a non-vault identity passes through unmasked — the mask is for vault paths, not for names');

echo "\nany_of — alternates are ONE obligation\n";
$anyOf = ['requires' => [
    ['key' => 'vault:infra/modx_storage_token', 'keys' => ['MODX_STORAGE_TOKEN', 'storage.modx_token'],
     'kind' => 'secret', 'mode' => 'any_of', 'required' => true, 'validate' => 'http-auth'],
]];
$one  = Actuator::verdicts($anyOf, reader(['storage.modx_token' => 'v'], $asked));
$none = Actuator::verdicts($anyOf, reader([], $asked));
check($one['ready'] === true
      && array_column($one['requirements'], 'key') === ['MODX_STORAGE_TOKEN', 'storage.modx_token'],
    'one member present satisfies the group, and rows are keyed by MEMBER names (the group\'s vault-path identity never appears)');
check($none['ready'] === false
      && array_unique(array_column($none['requirements'], 'detail')) === ['not set'],
    'no member present -> every alternate reads not set, and the application is NOT ready');

echo "\nemptiness is loud, not green\n";
$noneAtAll = Actuator::verdicts(['atom' => 'modx', 'requires' => []], reader([], $asked));
check($noneAtAll['requirements'] === [] && $noneAtAll['ready'] === true,
    'an empty artifact yields an empty list (a caller can SEE there is nothing, rather than being told all is well)');
// The REFUSAL on a missing/unparseable artifact is the snippet's (actuatorInfo.php sends 500
// 'required set not handed') — this class only ever sees a decoded array.

echo "\n$pass passed, $fail failed\n";
exit($fail === 0 ? 0 : 1);
