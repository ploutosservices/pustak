<?php
/**
 * actuator-typed — every answer /actuator/info gives leaves through a declared schema, the
 * contract document is rendered from that same schema, and the check can go red. (constitution P14)
 *
 * P14: a layer publishes the SHAPE of every answer, generated from its own code; a door whose
 * answer is untyped is undeclared — untyped meaning it admits any answer: no schema, an empty
 * one, or an object that admits every key. tests/actuator-verdicts.php proves WHAT the verdicts
 * say; nothing proved the shape they arrive in, so a renamed key would have failed no suite and
 * been found by the monitor.
 *
 * WHAT IS TESTED IS THE SNIPPET'S OWN CODE. The contract and its validator live in a marked block
 * in common/snippets/actuatorInfo.php (the snippet says why there and not in common/lib). This
 * suite extracts that block and runs it — the same way tests/diagnostics.php runs the inline log
 * reader — so there is no second copy of the schema here to drift.
 *
 *   php tests/actuator-typed.php                   0 = typed, and the document matches · 1 = named
 *   php tests/actuator-typed.php --control         three induced faults — MUST go red on each
 *   php tests/actuator-typed.php --write-contract  re-render docs/actuator.openapi.json
 */
declare(strict_types=1);

// ── --drive: ONE REQUEST THROUGH THE WHOLE SNIPPET, in a process of its own ──────────────────
// The snippet ends every request with exit, so each drive is a child of this suite. $modx is
// stubbed to exactly what the snippet touches; the libraries, application.php and the handed
// required-set are real files in a scratch core directory the parent made.
if (($argv[1] ?? '') === '--drive') {
    [, , $core, $report, $cn, $mutation] = array_pad($argv, 6, '');
    define('MODX_CORE_PATH', $core . '/');
    if ($cn !== '-') { $_SERVER['HTTP_X_CLIENT_IDENTITY'] = "CN=$cn"; }
    if ($report !== 'info') { $_GET['report'] = $report; }
    register_shutdown_function(static function () use ($core) {
        file_put_contents("$core/status", (string) http_response_code());
    });
    $modx = new class($core) {
        private string $core;
        public function __construct(string $core) { $this->core = $core; }
        public function getParser() {
            return new class { public function isProcessingUncacheable() { return true; } };
        }
        public function getOption($key, $options = null, $default = null) {
            return ['table_prefix' => 'modx_', 'cache_path' => $this->core . '/cache/',
                    'settings_version' => '3.2.4-pl', 'sso.oidc_client_id' => 'present',
                    'storage.base_url' => 'https://storage.example', 'log_level' => 1][$key] ?? $default;
        }
        public function getVersionData() { return ['full_version' => '3.2.4-pl']; }
        public function prepare($sql) {
            return new class {
                public function execute() { return true; }
                public function fetchAll($mode = null) {
                    return [['name' => 'edgeAddress', 'len' => '2048', 'sha1' => str_repeat('a', 40)]];
                }
            };
        }
    };
    $code = (string) file_get_contents(__DIR__ . '/../common/snippets/actuatorInfo.php');
    if ($mutation === 'extra-key') {
        // The induced fault: the info report grows a key the contract does not name.
        $code = str_replace("\$out['role'] = 'web';", "\$out['role'] = 'web'; \$out['debug'] = 'leak';", $code, $n);
        if ($n !== 1) { fwrite(STDERR, "the mutation found no line to change\n"); exit(3); }
    }
    eval($code);
    exit(4);   // the snippet always exits through $send; reaching here is itself a failure
}

require_once __DIR__ . '/../common/lib/Actuator.php';
require_once __DIR__ . '/../common/lib/Diagnostics.php';

use Pustak\Modx\Actuator;
use Pustak\Modx\Diagnostics;

$pass = 0; $fail = 0;
function check(bool $ok, string $label, string $detail = ''): void {
    global $pass, $fail;
    if ($ok) { $pass++; echo "  ok    $label\n"; }
    else { $fail++; echo "  FAIL  $label\n"; if ($detail !== '') echo "        $detail\n"; }
}

$SNIPPET  = __DIR__ . '/../common/snippets/actuatorInfo.php';
$DOCUMENT = __DIR__ . '/../docs/actuator.openapi.json';
$source = (string) file_get_contents($SNIPPET);

// ── the block, extracted and run alone ────────────────────────────────────────────────────────
$begin = strpos($source, '// --- BEGIN actuator contract');
$end   = strpos($source, '// --- END actuator contract');
if ($begin === false || $end === false || $end < $begin) {
    echo "  FAIL  the snippet carries no marked contract block\n";
    exit(1);
}
$CONTRACT = null; $admits = null;
eval(substr($source, $begin, $end - $begin));
if (!is_array($CONTRACT) || !is_callable($admits)) {
    echo "  FAIL  the contract block does not define \$CONTRACT and \$admits\n";
    exit(1);
}

/** Why a schema admits any answer somewhere inside it, or null. The three ways P14 names. */
function untyped(array $schema, string $at): ?string {
    if ($schema === [] || !isset($schema['type'])) { return "$at has no schema"; }
    $types = (array) $schema['type'];
    if (in_array('object', $types, true)) {
        if (($schema['additionalProperties'] ?? null) !== false) { return "$at is an object that admits every key"; }
        if (empty($schema['properties'])) { return "$at is an object with no properties"; }
        foreach ($schema['properties'] as $k => $sub) {
            $why = untyped((array) $sub, "$at.$k");
            if ($why !== null) { return $why; }
        }
    }
    if (in_array('array', $types, true)) {
        if (!isset($schema['items'])) { return "$at is an array of anything"; }
        return untyped((array) $schema['items'], "{$at}[]");
    }
    return null;
}

/** The OpenAPI document, rendered from the contract and from the snippet's own send calls. */
function document(array $contract, array $sends): array {
    $ops = [];
    foreach ($sends as [$status, $shape]) { $ops[$shape][$status] = true; }
    $path = function (string $report) use ($contract, $ops): array {
        $responses = ['200' => ['description' => "the $report report",
            'content' => ['application/json' => ['schema' => ['$ref' => "#/components/schemas/$report"]]]]];
        foreach (array_keys($ops['error'] ?? []) as $status) {
            $responses[(string) $status] = ['description' => 'a refusal',
                'content' => ['application/json' => ['schema' => ['$ref' => '#/components/schemas/error']]]];
        }
        ksort($responses);
        return ['get' => ['summary' => "/actuator/info, the $report report", 'responses' => $responses]];
    };
    $paths = [];
    foreach (array_keys($contract) as $shape) {
        if ($shape === 'error') { continue; }
        $paths[$shape === 'info' ? '/actuator/info' : "/actuator/info?report=$shape"] = $path($shape);
    }
    return ['openapi' => '3.1.0',
            'info' => ['title' => 'modx /actuator/info', 'version' => '1',
                       'description' => 'Rendered from $CONTRACT in common/snippets/actuatorInfo.php by '
                                      . 'tests/actuator-typed.php --write-contract. Never edited by hand.'],
            'paths' => $paths,
            'components' => ['schemas' => $contract]];
}

// Every `$send(<status>, '<shape>', …)` in the snippet, read from the source — the ground truth.
preg_match_all('/\$send\(\s*(\d+)\s*,\s*([^,]+?)\s*,/', $source, $m, PREG_SET_ORDER);
$sends = [];
foreach ($m as $call) { $sends[] = [(int) $call[1], trim($call[2], " '\"")]; }

/** One whole run of the gate over a contract and a source; returns the faults it names. */
function gate(array $contract, array $sends, string $source): array {
    $faults = [];
    foreach ($contract as $shape => $schema) {
        $why = untyped((array) $schema, $shape);
        if ($why !== null) { $faults[] = "untyped: $why"; }
    }
    foreach ($sends as [$status, $shape]) {
        if (!isset($contract[$shape])) { $faults[] = "a send names the shape `$shape`, which the contract does not hold"; }
        elseif (($status >= 200 && $status < 300) === ($shape === 'error')) {
            $faults[] = "status $status is sent as `$shape`";
        }
    }
    foreach (array_keys($contract) as $shape) {
        if (!in_array($shape, array_column($sends, 1), true)) { $faults[] = "the contract holds `$shape` and nothing sends it"; }
    }
    if (substr_count($source, 'json_encode(') !== 1) { $faults[] = 'an answer is encoded outside $send'; }
    if (!preg_match('/\$send = static function \(int \$status, string \$shape, array \$body\)/', $source)) {
        $faults[] = '$send no longer takes a shape';
    }
    if (strpos($source, "header('Content-Type: application/json; charset=utf-8');") === false) {
        $faults[] = 'the media type the contract declares is not the one $send answers with';
    }
    return $faults;
}

if (in_array('--write-contract', $argv, true)) {
    file_put_contents($DOCUMENT, json_encode(document($CONTRACT, $sends), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
    echo "wrote docs/actuator.openapi.json\n";
    exit(0);
}

if (in_array('--control', $argv, true)) {
    // THE CONTROL. Each fault is induced on a copy; the gate must name every one.
    echo "control — three induced faults, each must go red:\n";
    $open = $CONTRACT; unset($open['info']['additionalProperties']);
    $empty = $CONTRACT; $empty['log'] = [];
    $stray = str_replace("\$send(200, 'info', \$out);", "\$send(200, 'verdicts', \$out);", $source);
    preg_match_all('/\$send\(\s*(\d+)\s*,\s*([^,]+?)\s*,/', $stray, $sm, PREG_SET_ORDER);
    $straySends = array_map(static fn($c) => [(int) $c[1], trim($c[2], " '\"")], $sm);
    $red = 0;
    foreach ([['an object that admits every key', gate($open, $sends, $source)],
              ['a report with no schema', gate($empty, $sends, $source)],
              ['an answer sent under a shape nobody declared', gate($CONTRACT, $straySends, $stray)]] as [$what, $faults]) {
        if ($faults !== []) { $red++; echo "  red   $what -> {$faults[0]}\n"; }
        else { echo "  GREEN $what — THE GATE CANNOT FAIL ON IT\n"; }
    }
    echo $red === 3 ? "control: 3 of 3 went red, as they must (exit 1)\n" : "control: only $red of 3 went red\n";
    exit(1);   // a control that exits 0 has proved nothing; $red is what to read
}

// ── the gate ──────────────────────────────────────────────────────────────────────────────────
echo "the gate:\n";
$faults = gate($CONTRACT, $sends, $source);
check($faults === [], 'every report and the refusal are typed, and every send names its shape', implode("\n        ", $faults));
check(count($sends) === 8, 'eight send calls were read from the snippet', 'read ' . count($sends));

echo "the document:\n";
$rendered = json_encode(document($CONTRACT, $sends), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
check(is_file($DOCUMENT) && file_get_contents($DOCUMENT) === $rendered,
      'docs/actuator.openapi.json is what the contract renders today',
      'run: php tests/actuator-typed.php --write-contract');

// ── real answers pass, built by the code that builds them ─────────────────────────────────────
echo "real answers:\n";
$handed = ['atom' => 'modx', 'requires' => [
    ['canonical' => 'vault:infra/modx_oidc_client_id', 'key' => 'sso.oidc_client_id',
     'kind' => 'secret', 'required' => true, 'validate' => 'presence'],
    ['key' => 'endpoint:google/oidc', 'keys' => ['sso.issuer', 'sso.auth_endpoint'],
     'kind' => 'endpoint', 'mode' => 'all_of', 'required' => true, 'validate' => 'presence'],
]];
$read = static fn(string $k): ?string => ['sso.oidc_client_id' => 'x', 'sso.issuer' => 'y'][$k] ?? null;
$info = Actuator::verdicts($handed, $read);
$info['environment'] = 'development'; $info['role'] = 'web'; $info['commit'] = null;
$info['modx_version'] = Diagnostics::version(static fn(string $k): ?string => null, null);
check($admits($CONTRACT['info'], $info) === null, 'the info report, from Actuator::verdicts and Diagnostics::version',
      (string) $admits($CONTRACT['info'], $info));
$info['modx_version'] = null; $info['commit'] = 'abc1234';
check($admits($CONTRACT['info'], $info) === null, 'the info report with no library version and a stamped commit');
check($admits($CONTRACT['info'], ['application' => 'modx', 'ready' => true, 'requirements' => [],
      'environment' => 'development', 'role' => 'web', 'commit' => null, 'modx_version' => null]) === null,
      'an info report with no requirement rows');

$fb = strpos($source, '$inlineOwnLines =');
$fe = strpos($source, '// --- END inline diagnostics fallback');
$inlineOwnLines = null;
eval(substr($source, $fb, $fe - $fb));
$tmp = tempnam(sys_get_temp_dir(), 'mx');
file_put_contents($tmp, "[2026-10-06] (ERROR) [SSO-callback] a line of ours\nsomebody else's line\n");
foreach ([['a log with a line of ours', $tmp], ['no log file at all', $tmp . '.absent']] as [$label, $path]) {
    $r = $inlineOwnLines($path, ['[SSO-'], 200);
    $r['caller'] = 'skunkworks'; $r['markers'] = ['[SSO-']; $r['environment'] = null;
    check($admits($CONTRACT['log'], $r) === null, "the log report — $label", (string) $admits($CONTRACT['log'], $r));
}
unlink($tmp);
check($admits($CONTRACT['elements'], ['environment' => 'development', 'caller' => 'skunkworks', 'elements' => [
      ['kind' => 'plugin', 'name' => 'edgeAddress', 'bytes' => 2048, 'sha1' => str_repeat('a', 40)],
      ['kind' => 'chunk', 'name' => 'empty', 'bytes' => 0, 'sha1' => null]]]) === null, 'the elements report');
check($admits($CONTRACT['settings'], ['environment' => null, 'caller' => 'skunkworks', 'note' => 'n', 'settings' => [
      'storage.base_url' => 'u', 'storage.environment' => null, 'sso.provider' => 'google',
      'log_target' => null, 'log_level' => '1']]) === null, 'the settings report');
check($admits($CONTRACT['error'], ['error' => 'Application badge required']) === null, 'the refusal');

// ── and an answer outside its shape does not leave ────────────────────────────────────────────
echo "answers outside the contract:\n";
$bad = $info; $bad['database_password'] = 'x';
check($admits($CONTRACT['info'], $bad) !== null, 'a key nobody declared is refused', 'it was admitted');
$bad = $info; unset($bad['ready']);
check($admits($CONTRACT['info'], $bad) !== null, 'a missing required key is refused', 'it was admitted');
$bad = $info; $bad['ready'] = 'yes';
check($admits($CONTRACT['info'], $bad) !== null, 'a string where a boolean is declared is refused', 'it was admitted');
$bad = $info; $bad['requirements'] = [['key' => 'k', 'ok' => true, 'detail' => 'ok', 'value' => 'the secret']];
check($admits($CONTRACT['info'], $bad) !== null, 'a requirement row carrying a value is refused', 'it was admitted');

// ── the whole door, driven: what leaves, and that an answer outside its shape does not ────────
echo "the door, driven end to end:\n";
$core = sys_get_temp_dir() . '/mx-actuator-' . getmypid();
mkdir("$core/components/pustak/lib", 0700, true);
mkdir("$core/config", 0700, true);
mkdir("$core/cache/logs", 0700, true);
foreach (glob(__DIR__ . '/../common/lib/*.php') as $f) { copy($f, "$core/components/pustak/lib/" . basename($f)); }
file_put_contents("$core/config/application.php",
    "<?php return ['client_identity_trusted' => '1', 'environment' => 'development', 'commit' => 'abc1234'];\n");
file_put_contents("$core/config/required-set.json", json_encode($handed));
file_put_contents("$core/cache/logs/error.log", "[2026-10-06] (ERROR) [SSO-callback] a line of ours\nnot ours\n");

/** One request: [status, decoded body, raw output]. */
$drive = static function (string $report, string $cn, string $mutation = '') use ($core): array {
    @unlink("$core/status");
    $cmd = escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg(__FILE__) . ' --drive ' . escapeshellarg($core)
         . ' ' . escapeshellarg($report) . ' ' . escapeshellarg($cn) . ' ' . escapeshellarg($mutation) . ' 2>&1';
    $raw = (string) shell_exec($cmd);
    return [(int) @file_get_contents("$core/status"), json_decode($raw, true), $raw];
};
foreach ([['info', 'monitoring@development'], ['elements', 'skunkworks@development'],
          ['settings', 'skunkworks@development'], ['log', 'skunkworks@development']] as [$report, $cn]) {
    [$status, $body, $raw] = $drive($report, $cn);
    check($status === 200 && is_array($body) && $admits($CONTRACT[$report], $body) === null,
          "the $report report leaves as 200, in its shape",
          "status $status; " . (is_array($body) ? (string) $admits($CONTRACT[$report], $body) : substr($raw, 0, 300)));
}
[$status, $body, $raw] = $drive('info', 'monitoring@development');
check(is_array($body) && $body['requirements'] !== [] && $body['commit'] === 'abc1234'
      && $body['modx_version'] === ['settings_version' => '3.2.4-pl', 'file_version' => '3.2.4-pl', 'agree' => true],
      'the info report carries the rows, the commit and the version it was given', substr($raw, 0, 300));
[$status, $body, $raw] = $drive('info', '-');
check($status === 401 && $body === ['error' => 'Application badge required'],
      'no identity is refused 401, in the refusal\'s shape', "status $status; " . substr($raw, 0, 200));
[$status, $body, $raw] = $drive('info', 'skunkworks@development');
check($status === 401, 'a caller admitted at another report is refused here', "status $status");
[$status, $body, $raw] = $drive('info', 'monitoring@development', 'extra-key');
check($status === 500 && is_array($body) && ($body['error'] ?? '') === 'answer outside its contract'
      && strpos((string) ($body['detail'] ?? ''), '`debug`') !== false && strpos($raw, 'leak') === false,
      'THE CONTROL: an info report grown a key is not sent — 500, naming the key, the value withheld',
      "status $status; " . substr($raw, 0, 300));
foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($core, FilesystemIterator::SKIP_DOTS),
         RecursiveIteratorIterator::CHILD_FIRST) as $f) { $f->isDir() ? rmdir((string) $f) : unlink((string) $f); }
rmdir($core);

echo "\n$pass passed, $fail failed\n";
exit($fail === 0 ? 0 : 1);
