/**
 * term — a defined term, its meaning and an example, at an address a later page can point at.
 *
 *   [[!term? &term=`roster` &meaning=`The people a school expects on a day.` &example=`Monday's roster has 31 names.`]]
 *   -> <dl class="estate-term" id="term-roster"><dt><dfn>roster</dfn></dt><dd>…</dd><dd class="text-muted"><em>Example:</em> …</dd></dl>
 *
 * A later page links [[~<this page>]]#term-roster. &id overrides the address; a term with no a–z or 0–9 in
 * it needs one. &meaning and &example are the author's HTML, as a page's body is; &term is escaped. It draws
 * a block: on its own line, never inside a <p>. A mistake is drawn on the page, naming the parameter. No `[`
 * or `]` leaves here: MODx parses a snippet's output again (docs/design-standing-and-term.md).
 */
$safe = static function (string $html): string { return strtr($html, ['[' => '&#91;', ']' => '&#93;']); };
$refuse = static function (string $why) use ($safe): string {
    return $safe('<dl class="estate-term" data-term="invalid"><dt>' . htmlspecialchars("term: $why", ENT_QUOTES, 'UTF-8') . '</dt></dl>');
};
$term = trim((string) ($scriptProperties['term'] ?? ''));
$meaning = trim((string) ($scriptProperties['meaning'] ?? ''));
$example = trim((string) ($scriptProperties['example'] ?? ''));
$id = trim((string) ($scriptProperties['id'] ?? ''));
if ($term === '') {
    return $refuse('&term must name the term');
}
if ($meaning === '') {
    return $refuse('&meaning must say what the term means');
}
if ($id === '') {
    $slug = trim((string) preg_replace('/[^a-z0-9]+/', '-', strtolower($term)), '-');
    if ($slug === '') {
        return $refuse('this term has no a-z or 0-9 to make its address from; give &id');
    }
    $id = "term-$slug";
} elseif (!preg_match('/^[A-Za-z][A-Za-z0-9_-]*$/', $id)) {
    return $refuse('&id must start with a letter and hold only letters, digits, - and _');
}
$html = '<dl class="estate-term" id="' . $id . '">'
    . '<dt><dfn>' . htmlspecialchars($term, ENT_QUOTES, 'UTF-8') . '</dfn></dt>'
    . '<dd>' . $meaning . '</dd>'
    . ($example !== '' ? '<dd class="text-muted"><em>Example:</em> ' . $example . '</dd>' : '')
    . '</dl>';
return $safe($html);
