<?php
/**
 * tenant-jumps — what the jump slot draws from infra's tenant-apps list (estate-title-bar.md §The jump slot).
 *
 * Calls common/lib/TenantJumps.php directly: the entries under the page's tenant, in order, minus
 * Library's own, every field drawn as handed and escaped; and nothing at all — never an empty <nav> —
 * when there is nothing to draw. Also holds TenantJumps::SELF equal to service.json's `name`, the one
 * place Library's atom is declared.
 */
$fail = 0; $ran = 0;
function t(string $name, bool $ok): void {
    global $fail, $ran; $ran++;
    if ($ok) { echo "  ok    $name\n"; } else { $fail++; echo "  FAIL  $name\n"; }
}
$repo = dirname(__DIR__);
$lib = $repo . '/common/lib/TenantJumps.php';
if (!is_file($lib)) { fwrite(STDERR, "REFUSING TO RUN: no $lib — run this from the repo.\n"); exit(2); }
require $lib;
use Pustak\Modx\TenantJumps as J;

$e = fn(string $app, string $name, string $url, string $icon) => compact('app', 'name', 'url', 'icon');
$list = json_encode([
    'platform'  => [$e('kuber', 'Kuber', 'https://k.example/', 'https://cdn.example/k.svg'),
                    $e('modx', 'Saraswati', 'https://l.example/', 'https://cdn.example/v.svg'),
                    $e('munshi', 'Munshi', 'https://m.example/', 'https://cdn.example/m.svg')],
    'worldview' => [$e('modx', 'Saraswati', 'https://w.example/', 'https://cdn.example/v.svg')],
    'other'     => [$e('munshi', 'Not yours', 'https://x.example/', 'https://cdn.example/x.svg')],
]);

echo "== drawn ==\n";
$out = J::render($list, 'platform');
t('one nav, the slot class and its label',
  substr_count($out, '<nav ') === 1 && str_starts_with($out, '<nav class="estate-bar-jump" aria-label="This tenant&#039;s other applications">'));
t('the other apps, in the array order',
  strpos($out, 'https://k.example/') !== false && strpos($out, 'https://k.example/') < strpos($out, 'https://m.example/'));
t('Library\'s own entry is not drawn', strpos($out, 'https://l.example/') === false && substr_count($out, '<a ') === 2);
t('each link: href, tip, img src and alt as handed',
  strpos($out, '<a href="https://k.example/" data-estate-tip="Open Kuber"><img src="https://cdn.example/k.svg" alt="Kuber"></a>') !== false);
t('another tenant\'s entries never appear', strpos($out, 'Not yours') === false);
t('no target and no rel', strpos($out, 'target=') === false && strpos($out, 'rel=') === false);

echo "== not drawn at all ==\n";
t('only Library\'s own entry -> nothing', J::render($list, 'worldview') === '');
t('no entry under the key -> nothing', J::render($list, 'unlisted') === '');
t('{} -> nothing', J::render('{}', 'platform') === '');
t('a JSON list, not a map -> nothing', J::render('[{"app":"kuber"}]', '0') === '');
t('not JSON -> nothing', J::render('not json', 'platform') === '');
t('empty string -> nothing', J::render('', 'platform') === '');
t('the key holds no list -> nothing', J::render('{"platform":{"app":"kuber"}}', 'platform') === '');

echo "== as handed, and escaped ==\n";
$odd = json_encode(['t' => [$e('munshi', 'A "B" <c>', 'https://m.example/?a=1&b="2"', '')]]);
$o = J::render($odd, 't');
t('quotes and angle brackets in the name are escaped', strpos($o, 'alt="A &quot;B&quot; &lt;c&gt;"') !== false && strpos($o, '<c>') === false);
t('the url is escaped, not altered', strpos($o, 'href="https://m.example/?a=1&amp;b=&quot;2&quot;"') !== false);
t('an empty icon is drawn as handed', strpos($o, '<img src="" alt=') !== false);

echo "== Library's atom is service.json's name ==\n";
$manifest = json_decode((string) @file_get_contents($repo . '/service.json'), true);
t('TenantJumps::SELF equals service.json name', is_array($manifest) && ($manifest['name'] ?? null) === J::SELF);

printf("\n%d passed, %d failed\n", $ran - $fail, $fail);
exit($fail ? 1 : 0);
