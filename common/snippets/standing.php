/**
 * standing — a statement's standing, in words: agreed, proposed or rejected, its date and whose word.
 *
 *   [[!standing? &state=`agreed` &date=`2026-11-01` &who=`the board`]]
 *   -> <span class="badge bg-success text-white estate-standing" data-standing="agreed">agreed · 2026-11-01 · the board</span>
 *
 * The colour repeats the word and never replaces it: a card's colour alone said "agreed" to a reader who
 * could not name it (docs/design-standing-and-term.md). A mistake is drawn on the page, naming the
 * parameter, never guessed past. No `[` or `]` leaves here: MODx parses a snippet's output again.
 */
$colours = ['agreed' => 'bg-success text-white', 'proposed' => 'bg-warning text-dark', 'rejected' => 'bg-danger text-white'];
$out = static function (string $classes, string $state, string $text): string {
    return strtr('<span class="badge ' . $classes . ' estate-standing" data-standing="' . $state . '">'
        . htmlspecialchars($text, ENT_QUOTES, 'UTF-8') . '</span>', ['[' => '&#91;', ']' => '&#93;']);
};
$state = strtolower(trim((string) ($scriptProperties['state'] ?? '')));
$date = trim((string) ($scriptProperties['date'] ?? ''));
$who = trim((string) ($scriptProperties['who'] ?? ''));
if (!isset($colours[$state])) {
    return $out('bg-dark text-white', 'invalid', 'standing: &state must be agreed, proposed or rejected');
}
if (!preg_match('/^(\d{4})-(\d{2})-(\d{2})$/', $date, $m) || !checkdate((int) $m[2], (int) $m[3], (int) $m[1])) {
    return $out('bg-dark text-white', 'invalid', 'standing: &date must be a real date written YYYY-MM-DD');
}
if ($who === '') {
    return $out('bg-dark text-white', 'invalid', 'standing: &who must name whose word it is');
}
return $out($colours[$state], $state, "$state · $date · $who");
