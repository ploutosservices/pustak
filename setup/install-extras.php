<?php
/**
 * Headless extension install (Layer 2) — proven on faltu-1, MODx 3.2.1-pl 2026-07-12.
 * Installs the Extras our elements depend on (pdoTools -> [[pdoMenu]]/Fenom, SimpleSearch -> search)
 * from the modx.com provider, with NO manager UI. Login was RETIRED: auth is the sign-in door only
 * (GoogleSSOStart/Callback/Logout snippets); no [[!Login]] form, so the Login Extra is not installed.
 * Run as www-data:
 *   sudo -u www-data php setup/install-extras.php
 * Idempotent-ish: re-running re-installs the same signatures.
 *
 * ONLY THE PINNED VERSION (design claude/shared design/modx-one-version.md part 2). Each
 * add-on is installed at the version service.json `ships` pins, never the provider's latest(): from
 * core/packages/<signature>.transport.zip when the docroot holds it (the docroot tar carries both),
 * else the provider's release with that exact signature. Neither there: refused, nothing installed.
 */
// This was a HARDCODE, not even a default — the dev bench that stopped existing when the
// bench became staging (2026-08-14).
$root = getenv('MODX_ROOT') ?: ($argv[1] ?? '');
if (!$root || !is_file($root . '/config.core.php')) {
    fwrite(STDERR, "REFUSING: no config.core.php under '" . ($root ?: '(nothing)') . "'.\n"
                 . "          Set MODX_ROOT or pass the docroot. Nothing was installed.\n");
    exit(2);
}
require $root . '/config.core.php';
require MODX_CORE_PATH . 'vendor/autoload.php';

$modx = new \MODX\Revolution\modX();
$modx->initialize('mgr');
$modx->setLogLevel(\MODX\Revolution\modX::LOG_LEVEL_ERROR);
$modx->setLogTarget('ECHO');

$provider = $modx->getObject(\MODX\Revolution\Transport\modTransportProvider::class, 1); // modx.com
if (!$provider) { echo "NO PROVIDER id=1\n"; exit(2); }
echo "provider: " . $provider->get('name') . " " . $provider->get('service_url') . "\n";

$ships = json_decode((string) @file_get_contents(dirname(__DIR__) . '/service.json'), true)['ships'] ?? null;
if (!is_array($ships)) { fwrite(STDERR, "REFUSING: no ships list in service.json beside setup/. Nothing was installed.\n"); exit(2); }
$pins = [];
foreach (['pdoTools', 'SimpleSearch'] as $name) {
    $s = array_values(array_filter($ships, fn($x) => ($x['component'] ?? '') === $name));
    if (count($s) !== 1 || ($s[0]['pinned'] ?? false) !== true || empty($s[0]['version'])) {
        fwrite(STDERR, "REFUSING: service.json ships does not pin $name exactly once. Nothing was installed.\n"); exit(2);
    }
    $pins[$name] = strtolower($name) . '-' . $s[0]['version'];
}

$refused = 0;
foreach ($pins as $name => $sig) {
    echo "\n=== $name, pinned $sig ===\n";
    $package = $modx->getObject(\MODX\Revolution\Transport\modTransportPackage::class, ['signature' => $sig]);
    if ($package) {
        echo "registered already\n";
    } elseif (is_readable(MODX_CORE_PATH . "packages/$sig.transport.zip")) {
        // Registered as Package Management's ScanLocal registers a local zip (Processors/Workspace/Packages/ScanLocal.php).
        [$pname, $ver, $rel] = array_pad(explode('-', $sig, 3), 3, '');
        $v = explode('.', $ver);
        $r = preg_split('/(\d+)/', $rel, -1, PREG_SPLIT_DELIM_CAPTURE);
        $package = $modx->newObject(\MODX\Revolution\Transport\modTransportPackage::class);
        $package->fromArray(['signature' => $sig, 'state' => 1, 'created' => date('Y-m-d H:i:s'), 'workspace' => 1,
            'package_name' => $pname, 'version_major' => $v[0] ?? 0, 'version_minor' => $v[1] ?? 0, 'version_patch' => $v[2] ?? 0,
            'release' => $r[0] ?? $rel, 'release_index' => $r[1] ?? '0'], '', true);
        if (!$package->save()) { echo "could not register core/packages/$sig.transport.zip\n"; $refused++; continue; }
        echo "registered from core/packages/$sig.transport.zip\n";
    } else {
        $versions = $provider->latest($name);       // array of {version,signature,location,...}
        $node = null;
        foreach (is_array($versions) ? $versions : [] as $n) {
            if (($n['signature'] ?? '') === $sig) { $node = $n; break; }
        }
        if (!$node || empty($node['location'])) {
            echo "REFUSED: neither core/packages/$sig.transport.zip nor a provider release signed $sig — the provider's newest: "
               . implode(', ', array_slice(array_map(fn($n) => $n['signature'] ?? '?', is_array($versions) ? $versions : []), 0, 5)) . "\n";
            $refused++; continue;
        }
        $package = $provider->transfer($sig, null, ['location' => $node['location']]); // downloads + creates modTransportPackage
        if (!$package) { echo "transfer() FAILED (download/auth?)\n"; $refused++; continue; }
        echo "downloaded from the provider: " . $package->get('signature') . "\n";
    }
    if ($package->install()) { echo "INSTALLED OK\n"; } else { echo "install() returned false\n"; $refused++; } // model method: no manager-permission check
}
if ($refused) { echo "\n$refused add-on(s) not installed at their pin\n"; exit(1); }
echo "\ndone\n";
