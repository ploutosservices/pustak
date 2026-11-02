<?php
/**
 * standing-and-term — the two content words of docs/design-standing-and-term.md draw what it says, refuse
 * aloud what it refuses, and let no `[[` out. Runs each snippet's own body, the way tests/context-base.php
 * does; each guard has a control that breaks the snippet and must be seen red (P11).
 *
 *   php tests/standing-and-term.php
 */
declare(strict_types=1);

$pass = 0; $fail = 0;
function check(bool $ok, string $label, string $detail = ''): void {
    global $pass, $fail;
    if ($ok) { $pass++; echo "  ok    $label\n"; }
    else { $fail++; echo "  FAIL  $label\n"; if ($detail !== '') echo "        $detail\n"; }
}
function ask(string $code, array $scriptProperties): string {
    $modx = null;
    return (string) (function () use ($modx, $code, $scriptProperties) { return eval($code); })();
}
function swap(string $code, string $from, string $to): string {
    $n = 0; $out = str_replace($from, $to, $code, $n);
    if ($n !== 1) { echo "  FAIL  control could not be built: '$from' found $n times\n"; exit(1); }
    return $out;
}

$S = (string) file_get_contents(dirname(__DIR__) . '/common/snippets/standing.php');
$T = (string) file_get_contents(dirname(__DIR__) . '/common/snippets/term.php');

echo "standing — a statement's standing, in words\n";
$ok = ask($S, ['state' => 'agreed', 'date' => '2026-11-01', 'who' => 'the board']);
check($ok === '<span class="badge bg-success text-white estate-standing" data-standing="agreed">agreed · 2026-11-01 · the board</span>',
      'agreed: the word, the date and whose word, on success', $ok);
check(strpos(ask($S, ['state' => ' Proposed ', 'date' => '2026-11-01', 'who' => 'dev']), 'bg-warning text-dark estate-standing" data-standing="proposed">proposed · ') !== false,
      'proposed, written with capitals and spaces: matched, on warning');
check(strpos(ask($S, ['state' => 'rejected', 'date' => '2026-11-01', 'who' => 'dev']), 'bg-danger text-white estate-standing" data-standing="rejected">rejected · ') !== false,
      'rejected: on danger');
$bad = ['an unknown state' => ['state' => 'maybe', 'date' => '2026-11-01', 'who' => 'x'],
        'no state' => ['date' => '2026-11-01', 'who' => 'x'],
        'a date of the wrong shape' => ['state' => 'agreed', 'date' => '1 Nov 2026', 'who' => 'x'],
        'a date that is no day' => ['state' => 'agreed', 'date' => '2026-13-45', 'who' => 'x'],
        'no who' => ['state' => 'agreed', 'date' => '2026-11-01', 'who' => ' ']];
foreach ($bad as $label => $p) {
    $r = ask($S, $p);
    check(strpos($r, 'data-standing="invalid">standing: &amp;') !== false, "refused aloud: $label", $r);
}
$r = ask($S, ['state' => 'agreed', 'date' => '2026-11-01', 'who' => '<b>[[~1]]</b>']);
check(strpos($r, '[') === false && strpos($r, '<b>') === false && strpos($r, '&#91;&#91;~1&#93;&#93;') !== false,
      'who is escaped, and no [ leaves', $r);
$r = ask($S, ['state' => 'agreed', 'date' => '2026-11-01', 'who' => '']);
check(strpos($r, '2026-11-01') === false, 'a refusal does not echo what was written', $r);

echo "term — a defined term at an address\n";
$r = ask($T, ['term' => 'Roster day', 'meaning' => 'The people <a href="/x">expected</a>.', 'example' => 'Monday.']);
check($r === '<dl class="estate-term" id="term-roster-day"><dt><dfn>Roster day</dfn></dt><dd>The people <a href="/x">expected</a>.</dd><dd class="text-muted"><em>Example:</em> Monday.</dd></dl>',
      'term, meaning (the author\'s HTML kept), example; address term-roster-day', $r);
$r = ask($T, ['term' => 'roster', 'meaning' => 'm']);
check(strpos($r, 'Example') === false && strpos($r, 'id="term-roster"') !== false, 'no example: no example line');
check(strpos(ask($T, ['term' => 'x', 'meaning' => 'm', 'id' => 'roster-def']), 'id="roster-def"') !== false, '&id gives the address');
$bad = ['no term' => ['meaning' => 'm'], 'no meaning' => ['term' => 'x'],
        'a term with no a-z or 0-9, and no id' => ['term' => 'ताम्रपत्र', 'meaning' => 'm'],
        'an id that is no id' => ['term' => 'x', 'meaning' => 'm', 'id' => '1 "x"']];
foreach ($bad as $label => $p) {
    $r = ask($T, $p);
    check(strpos($r, 'data-term="invalid"><dt>term: ') !== false && strpos($r, '"x"') === false, "refused aloud: $label", $r);
}
check(strpos(ask($T, ['term' => 'ताम्रपत्र', 'meaning' => 'm', 'id' => 'tamrapatra']), '<dfn>ताम्रपत्र</dfn>') !== false,
      'that term with an &id is drawn');
$r = ask($T, ['term' => '<i>[[$x]]</i>', 'meaning' => 'see [[~5]]', 'example' => 'a [b]']);
check(strpos($r, '[') === false && strpos($r, ']') === false && strpos($r, '<i>') === false, 'term escaped, and no [ or ] leaves', $r);

echo "controls — each guard, broken, is seen\n";
$c = swap($S, "!checkdate((int) \$m[2], (int) \$m[3], (int) \$m[1])", 'false');
check(strpos(ask($c, ['state' => 'agreed', 'date' => '2026-13-45', 'who' => 'x']), 'invalid') === false,
      'control: a standing that checks only the date\'s shape lets 2026-13-45 through');
$c = swap($S, "['[' => '&#91;', ']' => '&#93;']", '[]');
check(strpos(ask($c, ['state' => 'agreed', 'date' => '2026-11-01', 'who' => '[[~1]]']), '[[') !== false,
      'control: a standing without the bracket rewrite lets [[ out');
$c = swap($T, "if (\$slug === '') {", 'if (false) {');
check(strpos(ask($c, ['term' => 'ताम्रपत्र', 'meaning' => 'm']), 'id="term-"') !== false,
      'control: a term without the empty-address refusal draws id="term-"');
$c = swap($T, "htmlspecialchars(\$term, ENT_QUOTES, 'UTF-8')", '$term');
check(strpos(ask($c, ['term' => '<i>x</i>', 'meaning' => 'm']), '<i>') !== false,
      'control: a term that does not escape &term lets markup through');

printf("\n%d passed, %d failed\n", $pass, $fail);
exit($fail === 0 ? 0 : 1);
