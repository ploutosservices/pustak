/**
 * tableRenderer — render a table from JSON data held in the page, not from hand-written markup.
 *
 * WHY THIS EXISTS. A table typed as <td> is text forever: nothing can tell which column is an
 * email and which is a phone number. That is not theoretical — asked "who are my contacts at
 * the bank", the estate search returned the man's NAME and silently dropped his mobile and email
 * from the line below, because the page separated fields with a capital "I" on one line and a "|"
 * on the next. Same class of problem as two tables labelling what may be the same number "SSN" on
 * one and "EIN" on the other, where nothing can say which is right. Naming the fields removes the
 * ambiguity at the source instead of asking every reader to guess.
 *
 * WHERE THE DATA LIVES. In the page itself, in a block the browser ignores:
 *
 *   <script type="application/ld+json" id="contacts">
 *   [
 *     {"@type":"Person","name":"Alice Example","jobTitle":"Relationship Manager",
 *      "email":"someone@example.org","telephone":"+44 20 7946 0000"}
 *   ]
 *   </script>
 *
 *   [[!tableRenderer? &from=`contacts`]]
 *
 * Chosen over a TV, a chunk, or a separate resource because data and page stay in ONE seat file —
 * versioned, diffable, VSCode-editable, nothing hidden in the manager. `type="application/ld+json"`
 * is not JavaScript, so a browser neither renders nor executes it: if this snippet fails, the page
 * shows a missing table, never a wall of raw JSON. A CHUNK is still the right home for a list
 * shared across pages — pass it via &json instead.
 *
 * SCHEMA.ORG. The data is plain JSON, so anything works, but schema.org's vocabulary (name, email,
 * telephone, jobTitle, worksFor) is preferred where it fits: the names are already agreed, so they
 * do not get argued about later. Your own terms belong under your own namespace prefix
 * (e.g. "est:relationshipSince"). This snippet is deliberately TOLERANT — bare array, single
 * object, with or without @context/@type, or a JSON-LD @graph — so the data can grow richer
 * without this code changing.
 *
 * PROPERTIES
 *   &from     id of a <script type="application/(ld+)json"> block in THIS resource's content
 *   &json     the data directly — inline, or a chunk, e.g. &json=`[[$sharedContacts]]`
 *   &url      fetch the JSON from a URL at render time. For data that is REFRESHED BY SOMEONE
 *             ELSE on its own schedule — the backup status feed is regenerated every six
 *             hours by infra, and a copy pasted into the page would be as old as the last
 *             deploy. On a page whose whole subject is staleness, that is the one unacceptable
 *             failure. MUST be called uncached (`[[!tableRenderer`); a cached call is REFUSED,
 *             not quietly served, because MODx would freeze one fetch into the page cache and
 *             the table would then lie for as long as the cache lived.
 *             &urlTimeout seconds, default 3.
 *   &auth     name the AUDIENCE this call authenticates to, e.g. &auth=`kuber`. The fetch then
 *             carries `Authorization: Bearer <jwt>` asserting WHO IS READING THE PAGE, and the
 *             audience answers with that person's own data.
 *
 *             WHY THIS EXISTS. The owner, on ~460 rows of account numbers, card numbers and
 *             SSNs typed into the estate's pages: *"request skunkworks/kuber to get sensitive
 *             information from kuber ... if not logged in, display blank."* He rejected the premise
 *             that the value belongs in the page in ANY form — not as prose, not as JSON-in-content.
 *             The page carries the id (`<span class="bird" kuberid="67012">` has for years); the
 *             audience carries the value; and *"each person has different access"*, so the value is
 *             fetched as the reader, never as the site.
 *
 *             WHAT IS SENT: the reader's door access token EXCHANGED at the door for the &auth name
 *             (claude/shared/design/chowkidar-step4-skunkworks-apps.md §1) — aud the
 *             &auth name, azp this context's client, signed by the door. MODx mints nothing: the
 *             hand-made RS256 assertion (iss modx, `<audience>.jwt_private_key`) is retired. No
 *             exchange, no fetch — never the reader's own token instead. The token is fetched
 *             server-side, sent server-side, and NEVER reaches the browser.
 *
 *             THERE IS DELIBERATELY NO SNIPPET THAT RETURNS A TOKEN. An element that returns one
 *             can be written into a page — `[[!kuberAssertion]]` — and then the credential IS the page.
 *
 *             WHO THE READER IS, established from two independent facts that must agree:
 *             MODx must hold an authenticated web session for this context, AND the session must
 *             carry the address the door verified (`$_SESSION['sso.verified_email']`, stamped by
 *             GoogleSSOCallback at the moment of sign-in), AND that address must be the one on the
 *             signed-in account. A manager-created local login has no verified address and is
 *             therefore nobody here, and only the door's sign-in can support it. Anything less than all three ->
 *             no request is made at all. Not an unauthenticated fetch, not an empty table: silence,
 *             which is what "display blank" means when there is nobody to ask on behalf of.
 *
 *             A CREDENTIAL IS NEVER SENT IN CLEAR. https, or a host on loopback or the internal
 *             zone. The zone suffix is the owner's own rule — a zone suffix is a property of the
 *             network, an FQDN is only a name — and it is reused here rather than re-decided.
 *             Anything else is refused before the socket opens.
 *   &rows     dot-path to the array of rows inside the document, e.g. `jobs` or `data.items`.
 *             Real feeds wrap their rows in an envelope carrying metadata — the backup feed is
 *             {"generated": "...", "jobs": [...]} — and without this the envelope itself is the
 *             single row, which renders one line of empty cells and looks like a styling bug
 *             rather than a pointing error. Omitted => the document IS the rows.
 *   &columns  which keys, in what order, and their labels: `name=Name,email=Email`
 *             Omitted => every key of the first row, in order, @-keys excluded.
 *             A key NOT listed is ignored, so rows may carry ids or notes that are not displayed.
 *   &class    classes ADDED to `estate-table` (the estate table standard), e.g. `estate-fit`
 *             or `estate-sort estate-filter` (`smart-table` still accepted); a call cannot take the standard off.
 *   &caption  optional title, drawn as the estate table's title band. May carry {placeholders} filled from the TOP-LEVEL document,
 *             before &rows is walked — e.g. &caption=`As at {generated} UTC` against a feed whose
 *             envelope is {"generated": "...", "jobs": [...]}. This exists so a table of
 *             freshness can say when IT was fetched: a staleness report with no timestamp is the
 *             thing it is warning about. A placeholder with no matching key renders empty.
 *   &badge    columns whose value is wrapped in a <span> carrying a class, so distinct values are
 *             distinguishable at a glance: `status`. Several columns comma-separated.
 *             Written `status:state`, the COLOUR is looked up from a different field — `status`
 *             is still what the reader sees, `state` is what decides its class. Use that form
 *             whenever the displayed text is free prose: keying colour off the prose means
 *             re-wording a status silently drops its colour, and a value containing a comma
 *             cannot be a &badgeMap key at all. It also leaves `state` in the data as a short
 *             token a search can filter on, which the display text is not.
 *   &badgeMap value=class pairs for those columns, e.g.
 *             `ok=text-bg-success,stale=text-bg-warning,failed=text-bg-danger`.
 *             The value matched is the key field's when &badge names one, else the cell's own.
 *             A value not in the map gets &badgeClass alone — so an enum that GROWS renders as a
 *             neutral badge rather than silently borrowing the colour of whatever it sits near.
 *   &badgeClass  base class on every badge; defaults to `badge`. Bootstrap's own classes, from
 *             the stylesheet the site already loads — this snippet still emits no styling of its
 *             own, only class hooks.
 *   &tip      attach a rich tooltip to one column, built from OTHER fields of the same row, as
 *             `column:key=Label,key=Label` — e.g. `job:max_age_hours=Budget,detail=Detail`.
 *             For the detail that belongs to a row but does not deserve a column of its own: a
 *             seventh column costs every reader width on every row to serve the occasional
 *             question. The fields need not appear in &columns (a key not listed is ignored as
 *             a column), so this is how a value stays reachable without being on screen.
 *             A pair whose value is empty is omitted rather than rendered as a blank line.
 *   &localTime  columns holding an ISO-8601 UTC timestamp, comma-separated. The cell is emitted
 *             as <time datetime="{the original}">, and the DECORATOR rewrites it to the reader's
 *             own clock. The conversion happens in the browser because that is the only place
 *             that knows what "local" means — the server would have to guess a timezone, and a
 *             guessed timezone is worse than UTC because it looks right. The original stays in
 *             the datetime attribute and in the cell's data-sort, so the column still sorts
 *             chronologically after rewriting, and with JavaScript off the honest UTC string is
 *             what remains.
 *   &rowClass put a class on the <tr> according to one column's value, as
 *             `column:value=class,value=class` — e.g. `status:ok=tbl-quiet`. The table stays
 *             COMPLETE: every row is rendered and nothing is filtered away here. Marking a row
 *             is not the same as dropping it, and the difference matters — a reader who cannot
 *             get to the whole table has no way to know what was decided for them. What the
 *             class then does is the decorator's business (tbl-quiet is hidden behind a toggle
 *             by `quiet-first`), and with JavaScript off every row is simply there.
 *   &group    key to group rows by, e.g. &group=`section`. Emits a full-width heading row
 *             (<tr class="estate-row-section"><td colspan=N>) whenever the value
 *             CHANGES — the existing folderContent pattern. The grouping key is dropped from
 *             the columns automatically, since it is shown in the heading, not repeated per row.
 *   &groupClass  extra classes for that heading row's cell; none by default.
 *   &link     make a column a link, as `textKey:hrefKey`, e.g. &link=`name:url` renders the
 *             name cell as <a href="{url}">{name}</a>. Several pairs separated by commas.
 *             Explicit on purpose: nothing is auto-linked by guessing that a value looks like
 *             a URL or an email. The href field is not itself shown as a column unless listed
 *             in &columns. A MODx tag such as [[~992]] works as the href value.
 *   (none)    a document that declares its own `columns` (and `groups` or `rows`, `legend`,
 *             `notes`, `title`, `generated`) is rendered from that declaration alone — see
 *             "SELF-DESCRIBING" in the code. `[[!tableRenderer? &url=`…`]]` is the whole call.
 *   &linkClass  classes applied to those links, e.g. `btn btn-success btn-sm w-100`. Empty
 *             by default, so a link is a plain link unless asked otherwise.
 *
 * CONTRACT
 *   - A missing key renders an EMPTY CELL, never an error: rows legitimately differ (a support
 *     desk has no personal name).
 *   - Rows are NEVER re-ordered. Grouping emits a heading when the value changes, so data stays in
 *     the order the author wrote it; interleaved groups produce repeated headings rather than a
 *     silent re-sort of someone's records.
 *   - Malformed JSON renders NOTHING plus an HTML comment naming the fault. A bad table must never
 *     take the page down with it — this is what contains the one real risk of rendering at runtime:
 *     it fails per table, not per site. A URL that times out, refuses, or answers with something
 *     that is not JSON is the same class of event and is handled the same way: the table is
 *     missing, the page is fine, and the reason is in the source for whoever looks.
 *   - &url makes ONE outbound request, with a timeout, and never follows a redirect to a
 *     different host. What it may fetch is controlled by the fact that page content reaches
 *     production only through git and the content deploy — a URL in a page is authored,
 *     reviewed and diffable. That is the control; there is no separate allow-list to drift.
 *   - Markup only. Classes are emitted; the CSS is the owner's. No inline styles.
 *   - Values are HTML-escaped. Auto-linking emails and URLs is deliberately NOT done; use &link.
 *   - A newline inside a value becomes <br>, so multi-line values (a postal address) survive
 *     without the author embedding markup in their data.
 *
 * Derives purely from the resource + properties, so it may be called cached or uncached.
 */

$from    = trim((string) $modx->getOption('from', $scriptProperties, ''));
$rawJson = (string) $modx->getOption('json', $scriptProperties, '');
$url        = trim((string) $modx->getOption('url', $scriptProperties, ''));
$urlTimeout = (int) $modx->getOption('urlTimeout', $scriptProperties, 3);
$auth       = strtolower(trim((string) $modx->getOption('auth', $scriptProperties, '')));
$rowsPath   = trim((string) $modx->getOption('rows', $scriptProperties, ''));
$badgeSpec  = trim((string) $modx->getOption('badge', $scriptProperties, ''));
$badgeMap   = trim((string) $modx->getOption('badgeMap', $scriptProperties, ''));
// The Feeds page's own address, handed in by feedView, so a `feed` column can link to another feed
// by NAME. Absent (a plain page call), a `feed` cell is just its text.
$feedBase   = trim((string) $modx->getOption('feedBase', $scriptProperties, ''));
// &noTitle=`1` — the page header already names this document (the Feeds page), so the title band keeps
// only its "generated" time and the copy button (the owner, 2026-10-04).
$noTitle    = (bool) $modx->getOption('noTitle', $scriptProperties, false);
$badgeClass = trim((string) $modx->getOption('badgeClass', $scriptProperties, 'badge'));

// column name => the field whose value picks the class (itself, unless written `column:keyField`)
$badges = [];
foreach (explode(',', $badgeSpec) as $col) {
    $col = trim($col);
    if ($col === '') {
        continue;
    }
    if (strpos($col, ':') !== false) {
        [$shown, $keyField] = array_map('trim', explode(':', $col, 2));
        if ($shown !== '') {
            $badges[$shown] = $keyField !== '' ? $keyField : $shown;
        }
        continue;
    }
    $badges[$col] = $col;
}
// &tip — "column:key=Label,key=Label"
// Bootstrap's default tooltip is a dark, centred pill — right for a three-word hint, wrong for a
// record. tipClass is passed through as data-bs-custom-class so the CSS (the estate stylesheet, not
// this file) can give it a light card and a left-aligned two-column layout.
$tipClass  = trim((string) $modx->getOption('tipClass', $scriptProperties, 'tbl-tip'));
$tipCol    = '';
$tipFields = [];
$tipRaw    = trim((string) $modx->getOption('tip', $scriptProperties, ''));
if ($tipRaw !== '' && strpos($tipRaw, ':') !== false) {
    [$tipCol, $tipPairs] = array_map('trim', explode(':', $tipRaw, 2));
    foreach (explode(',', $tipPairs) as $pair) {
        $pair = trim($pair);
        if ($pair === '') {
            continue;
        }
        $bits  = explode('=', $pair, 2);
        $key   = trim($bits[0]);
        if ($key !== '') {
            $tipFields[$key] = isset($bits[1]) && trim($bits[1]) !== '' ? trim($bits[1]) : $key;
        }
    }
}

// column name => true
$localTime = [];
foreach (explode(',', (string) $modx->getOption('localTime', $scriptProperties, '')) as $col) {
    $col = trim($col);
    if ($col !== '') {
        $localTime[$col] = true;
    }
}

// &rowClass — "column:value=class,value=class"
$rowClassCol = '';
$rowClasses  = [];
$rowClassRaw = trim((string) $modx->getOption('rowClass', $scriptProperties, ''));
if ($rowClassRaw !== '' && strpos($rowClassRaw, ':') !== false) {
    [$rowClassCol, $rowClassPairs] = array_map('trim', explode(':', $rowClassRaw, 2));
    foreach (explode(',', $rowClassPairs) as $pair) {
        $pair = trim($pair);
        if ($pair === '' || strpos($pair, '=') === false) {
            continue;
        }
        [$val, $cls] = array_map('trim', explode('=', $pair, 2));
        if ($val !== '' && $cls !== '') {
            $rowClasses[$val] = $cls;
        }
    }
}

// value => extra class
$badgeClasses = [];
foreach (explode(',', $badgeMap) as $pair) {
    $pair = trim($pair);
    if ($pair === '' || strpos($pair, '=') === false) {
        continue;
    }
    [$val, $cls] = array_map('trim', explode('=', $pair, 2));
    if ($val !== '') {
        $badgeClasses[$val] = $cls;
    }
}
$columns = trim((string) $modx->getOption('columns', $scriptProperties, ''));
// The estate table: every table this draws wears claude/shared design/estate-table.css,
// linked from Bootstrap.5.Head. &class ADDS to `estate-table` (estate-fit, a decorator opt-in such
// as smart-table); it no longer replaces it, so no call can opt a table out of the standard.
$class   = trim('estate-table ' . trim((string) $modx->getOption('class', $scriptProperties, '')));
// THE ESTATE TABLE'S BEHAVIOUR IS THE SHARED SCRIPT NOW: <CDN>/estate/table/estate-table.js,
// linked from Bootstrap.5.Javascript, opts in by estate-sort / estate-filter / estate-copy. Library's
// own names are translated here so a call written with them keeps working — smart-table was sort AND
// filter — and Library's rule that a table with a title gets a copy button is kept by $tableClass.
$class = trim(preg_replace(['/\bsmart-table\b/', '/\bsortable\b/', '/\bfilterable\b/'],
                           ['estate-sort estate-filter', 'estate-sort', 'estate-filter'], $class));
$tableClass = function ($band) use ($class) {
    $tokens = explode(' ', $class);
    $copy = $band !== '' && !in_array('no-copy', $tokens, true) && !in_array('estate-copy', $tokens, true);
    return trim(implode(' ', array_diff($tokens, ['no-copy'])) . ($copy ? ' estate-copy' : ''));
};
$caption = trim((string) $modx->getOption('caption', $scriptProperties, ''));
$group      = trim((string) $modx->getOption('group', $scriptProperties, ''));
$groupClass = trim((string) $modx->getOption('groupClass', $scriptProperties, ''));
$linkSpec   = trim((string) $modx->getOption('link', $scriptProperties, ''));
$linkClass  = trim((string) $modx->getOption('linkClass', $scriptProperties, ''));

// textKey => hrefKey
$links = [];
foreach (explode(',', $linkSpec) as $pair) {
    $pair = trim($pair);
    if ($pair === '' || strpos($pair, ':') === false) {
        continue;
    }
    [$textKey, $hrefKey] = array_map('trim', explode(':', $pair, 2));
    if ($textKey !== '' && $hrefKey !== '') {
        $links[$textKey] = $hrefKey;
    }
}

/** The estate table's box around a <table>: an optional title band (the caption's job here),
 *  then the scroller. $title is markup already escaped by the caller. */
$boxOpen = function ($title, $fit) {
    return '<div class="estate-table-box' . ($fit ? ' estate-fit' : '') . '">'
         . ($title !== '' ? '<div class="estate-table-title">' . $title . '</div>' : '')
         . '<div class="estate-table-scroll">';
};
$boxClose = '</div></div>';

/** Columns whose every filled value is a number, so they right-align (estate-num). */
$numCols = function ($keys, $rows) {
    $num = [];
    foreach ($keys as $k) {
        $seen = false; $all = true;
        foreach ($rows as $r) {
            if (!is_array($r) || !array_key_exists($k, $r) || !is_scalar($r[$k]) || trim((string) $r[$k]) === '') {
                continue;
            }
            $seen = true;
            if (!preg_match('/^[(\-+]?\s*[$£€₹]?\s*[(\-]?\d[\d,]*(\.\d+)?\s*%?\)?$/u', trim((string) $r[$k]))) {
                $all = false; break;
            }
        }
        if ($seen && $all) {
            $num[$k] = true;
        }
    }
    return $num;
};

/** Fail visibly to an author reading the source, invisibly to a visitor. */
$fail = function ($why) {
    return '<!-- tableRenderer: ' . htmlspecialchars($why, ENT_QUOTES, 'UTF-8') . ' -->';
};

// &auth names an audience and nothing else: it becomes half a system-setting key below, so it is
// clamped to a shape that cannot reach sideways into another setting.
if ($auth !== '' && !preg_match('/^[a-z0-9_]+$/', $auth)) {
    return $fail('&auth must name an audience using [a-z0-9_], e.g. &auth=`kuber`');
}
if ($auth !== '' && $url === '') {
    // Refused rather than ignored. A page that asks for an authenticated read and silently gets an
    // unauthenticated one is the worst outcome available here.
    return $fail('&auth is only meaningful with &url — there is nothing to authenticate to');
}

// ---- locate the data -------------------------------------------------------
// &url wins when given: it is the only source that is not already in the page.
if ($rawJson === '' && $url !== '') {
    // Refuse a cached call rather than serve a frozen fetch. MODx would store this snippet's
    // output in the page cache, so one fetch would be replayed until the cache was cleared —
    // and a staleness table that is itself stale is the exact failure this property exists to
    // avoid. isProcessingUncacheable() is true only inside a [[! ]] call.
    $parser = $modx->getParser();
    if (!$parser || !$parser->isProcessingUncacheable()) {
        return $fail('&url requires an uncached call — write [[!tableRenderer instead of [[tableRenderer');
    }
    if (!preg_match('#^https?://#i', $url)) {
        return $fail('&url must be an http(s) URL');
    }

    // ---- who is reading, and the assertion that says so --------------------
    $authHeader = '';
    if ($auth !== '') {
        $host    = strtolower((string) parse_url($url, PHP_URL_HOST));
        // The estate's internal zone (estate.internal_zone, written by setup/02) is the one other
        // place plain http may carry a bearer: it is the private network. No zone, no exception.
        $zone    = strtolower(trim((string) $modx->getOption('estate.internal_zone')));
        if ($zone !== '' && $zone[0] !== '.') $zone = '.' . $zone;
        $onWire  = !preg_match('#^https://#i', $url)
                && $host !== '127.0.0.1' && $host !== '::1' && $host !== 'localhost'
                && !($zone !== '' && substr($host, -strlen($zone)) === $zone);
        if ($onWire) {
            return $fail("&auth will not present a bearer credential in clear text: $url must be "
                       . 'https (plain http is accepted only on loopback or in the internal zone'
                       . ($zone !== '' ? " $zone" : ', and estate.internal_zone is not set') . ')');
        }

        // Three facts that must agree. Any disagreement is nobody, and nobody asks nothing.
        $reader  = '';
        $ctxKey  = $modx->context ? (string) $modx->context->get('key') : '';
        if ($modx->user && $ctxKey !== '' && $modx->user->isAuthenticated($ctxKey)) {
            $verified = strtolower(trim((string) ($_SESSION['sso.verified_email'] ?? '')));
            $profile  = $modx->user->getOne('Profile');
            $onFile   = $profile ? strtolower(trim((string) $profile->get('email'))) : '';
            if ($verified !== '' && $verified === $onFile) {
                $reader = $verified;
            }
        }
        if ($reader === '') {
            // The owner's rule, and the reason this is a return rather than a fetch: "if not logged in,
            // display blank". The alternative — asking the audience as the site — would hand a page
            // one person's data to whoever opened it.
            return $fail("no signed-in, door-verified reader: nothing was requested from '$auth'");
        }

        // The reader's door token exchanged for the &auth name. No exchange, no fetch.
        require_once rtrim(MODX_CORE_PATH, '/') . '/components/pustak/lib/SsoConfig.php';
        $exchanged = SsoConfig::forContext($modx)->exchangeFor((string) ($_SESSION['sso.access_token'] ?? ''), $auth);
        if ($exchanged === '') {
            return $fail("the door gave no token for '$auth' (no access token in the session, or the "
                       . "exchange was refused) — nothing was requested from $url");
        }
        $authHeader = "Bearer $exchanged";
    }

    $timeout = $urlTimeout > 0 ? $urlTimeout : 3;
    $body    = false;

    if (function_exists('curl_init')) {
        $ch   = curl_init($url);
        $opts = [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => $timeout,
            CURLOPT_TIMEOUT        => $timeout,
            // No redirect following: a 302 to another host would turn an authored, reviewable
            // URL into whatever that host decides to point at today. With &auth in play it would
            // also hand the credential to that host, which is the stronger reason to keep it off.
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_USERAGENT      => 'tableRenderer/1.0 (+modx)',
        ];
        if ($authHeader !== '') {
            $opts[CURLOPT_HTTPHEADER] = ['Authorization: ' . $authHeader];
        }
        curl_setopt_array($ch, $opts);
        $body   = curl_exec($ch);
        $status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        $err    = curl_error($ch);
        curl_close($ch);
        if ($body === false) {
            return $fail("could not fetch $url — " . ($err !== '' ? $err : 'request failed'));
        }
        if ($status < 200 || $status >= 300) {
            return $fail("$url returned HTTP $status");
        }
    } else {
        $headers = "User-Agent: tableRenderer/1.0 (+modx)\r\n";
        if ($authHeader !== '') {
            $headers .= 'Authorization: ' . $authHeader . "\r\n";
        }
        $ctx  = stream_context_create(['http' => [
            'timeout'       => $timeout,
            'follow_location' => 0,
            'ignore_errors' => true,
            'header'        => $headers,
        ]]);
        $body = @file_get_contents($url, false, $ctx);
        if ($body === false) {
            return $fail("could not fetch $url — request failed or timed out after {$timeout}s");
        }
        // $http_response_header is set by the stream wrapper in this scope.
        if (isset($http_response_header[0]) && !preg_match('# (2\d\d) #', ' ' . $http_response_header[0] . ' ')) {
            return $fail("$url returned: " . $http_response_header[0]);
        }
    }
    $rawJson = (string) $body;
}

if ($rawJson === '' && $from !== '') {
    $content = $modx->resource ? (string) $modx->resource->get('content') : '';
    if ($content === '') {
        return $fail("no resource content to read '$from' from");
    }
    // Match <script ... id="from" ... type="application/json|ld+json" ...> in either attribute
    // order, and tolerate single quotes.
    $idPat   = preg_quote($from, '#');
    $pattern = '#<script\b(?=[^>]*\btype=["\']application/(?:ld\+)?json["\'])'
             . '(?=[^>]*\bid=["\']' . $idPat . '["\'])[^>]*>(.*?)</script>#is';
    if (!preg_match($pattern, $content, $m)) {
        return $fail("no <script type=\"application/ld+json\" id=\"$from\"> block found in this page");
    }
    $rawJson = $m[1];
}

if (trim($rawJson) === '') {
    return $fail('no data: pass &url (fetched at render time), &from (a block id in this page), or &json (the data)');
}

// ---- parse -----------------------------------------------------------------
$data = json_decode(trim($rawJson), true);
if ($data === null && json_last_error() !== JSON_ERROR_NONE) {
    return $fail('invalid JSON — ' . json_last_error_msg());
}

// ---- a SELF-DESCRIBING document: the layout travels with the data ---------------------------
// When the page passes no &columns and the document declares its own `columns`, the document is
// the whole view: a view change is a JSON change and never a page edit. Shape (infra's
// quickbooks-status.json is the first publisher):
//   title, generated            caption: the title, then "generated <time>" in the reader's clock
//   columns[{key,label,type}]   type `time` = a local-time cell ("format": "date" = the date alone,
//                                        the clock in its tooltip), `status` = a badge,
//                               `list` = the cell is an array, drawn as an <ol>, one item per line;
//                                        `item` names the field shown when the items are objects, or
//                                        is a template of fields: "{environment}: {entrypoint}";
//                                        `max` items show (default 5, 0 = all), the rest behind a
//                                        "+N more" that opens in place
//                               `link` = the cell's value opens the address in the row's `href` field;
//                                        a value that is only the address itself, or "text": false,
//                                        draws the link mark with the address as its tooltip
//                               `actions` = several marks in one cell: `items` lists column
//                                        specs of the icon types (gitea, link, feed), each drawn when its
//                                        field has a value; the column does not sort. Any column may
//                                        carry `icon` (gitea|feed|link or a bi-… name): the header is
//                                        that icon, the label its tooltip
//                               `feed`  = the value is another feed's NAME in the index; on the Feeds
//                                        page the feed mark before it opens that feed (?feed=<name>),
//                                        `href` names a field shown as the mark's tooltip; elsewhere text
//                               `gitea` = the same, for a document on Gitea: the value stays TEXT and
//                                        the Gitea icon before it is the only click (gitea-link);
//                                        `"text": false` draws the icon alone, for a column whose words
//                                        add nothing (every manifest is service.json)
//                                        (the feeds page)
//                               `backlog-record` = the value is a backlog record's NUMBER; the
//                                        whole cell (estate-link) opens that record in Munshi's backlog
//                                        viewer, at system setting `munshi.backlog_url` + "/<n>". The
//                                        feed names the type, never the address (the owner's ruling); an
//                                        empty setting leaves the number as plain text
//   legend[{status,label,colour}]  the badge colour for each status (Bootstrap text-bg-<colour>),
//                               rendered under the table as the key to the colours
//   notes[]                     one line each, under the legend
//   groups[{heading, rows[]}]   a full-width heading row per group; or a flat `rows[]`
// Page properties that only describe layout (&rows, &badge, &badgeMap, &localTime, &group,
// &caption) are ignored in this mode — the document wins, so the two cannot disagree.
if ($columns === '' && is_array($data) && isset($data['columns']) && is_array($data['columns'])
    && $data['columns'] !== [] && is_array(reset($data['columns']))) {
    $doc   = $data;
    // Where a backlog-record opens: the environment's own setting, http(s) only, no trailing slash.
    // No default — an environment nobody addressed shows the number and nothing that could mislead.
    $backlogUrl = rtrim(trim((string) $modx->getOption('munshi.backlog_url', null, '')), '/');
    if (!preg_match('#^https?://#i', $backlogUrl)) {
        $backlogUrl = '';
    }
    $h     = function ($v) { return htmlspecialchars(is_scalar($v) ? (string) $v : '', ENT_QUOTES, 'UTF-8'); };
    $cols  = [];
    // One column spec, normalised. `icon` (any column): the header is drawn as that icon —
    // one of the estate's marks (gitea, feed, link) or a Bootstrap icon name (bi-…) — with the label
    // as its tooltip and accessible name. `items` (type actions): ordinary specs of the
    // icon-drawing types, drawn side by side in one cell.
    $parseCol = function ($c) use (&$parseCol) {
        $spec = ['label' => $c['label'] ?? $c['key'], 'type' => (string) ($c['type'] ?? ''),
                 'key'   => (string) $c['key'],
                 'item'  => (string) ($c['item'] ?? ''), 'href' => (string) ($c['href'] ?? ''),
                 'max'   => isset($c['max']) && is_numeric($c['max']) ? max(0, (int) $c['max']) : 5,
                 'text'  => !(array_key_exists('text', $c) && $c['text'] === false),
                 'format'=> ($c['format'] ?? '') === 'date' ? 'date' : '',
                 'icon'  => is_scalar($c['icon'] ?? null) ? preg_replace('/[^a-z0-9-]/', '', strtolower((string) $c['icon'])) : '',
                 'items' => []];
        foreach ((is_array($c['items'] ?? null) ? $c['items'] : []) as $it) {
            if (is_array($it) && isset($it['key']) && is_scalar($it['key']) && (string) $it['key'] !== '') {
                $spec['items'][] = $parseCol($it);
            }
        }
        return $spec;
    };
    foreach ($doc['columns'] as $c) {
        if (is_array($c) && isset($c['key']) && is_scalar($c['key']) && (string) $c['key'] !== '') {
            $cols[(string) $c['key']] = $parseCol($c);
        }
    }
    if ($cols === []) {
        return $fail('the document declares `columns` but none has a key');
    }
    $colour = [];
    $legend = (isset($doc['legend']) && is_array($doc['legend'])) ? $doc['legend'] : [];
    foreach ($legend as $l) {
        if (is_array($l) && isset($l['status']) && is_scalar($l['status']) && !empty($l['colour'])) {
            $colour[(string) $l['status']] = 'text-bg-' . preg_replace('/[^a-z-]/', '', strtolower((string) $l['colour']));
        }
    }
    $timeCell = function ($v) use ($h) {
        return '<time datetime="' . $h($v) . '" class="tbl-localtime">' . $h($v) . '</time>';
    };
    $badge = function ($v) use ($h, $colour, $badgeClass) {
        $cls = trim($badgeClass . ' ' . ($colour[is_scalar($v) ? (string) $v : ''] ?? ''));
        return '<span class="' . $h($cls) . '">' . $h($v) . '</span>';
    };
    // ONE MARK for an item of an actions column — the same drawing as a gitea, link or feed cell with
    // "text": false, or nothing when the item's field is empty or not an http(s) address.
    $markFor = function (array $c, array $row) use ($h, $feedBase) {
        $hrefVal = $c['href'] !== '' && is_scalar($row[$c['href']] ?? null) ? trim((string) $row[$c['href']]) : '';
        $val     = is_scalar($row[$c['key']] ?? null) ? trim((string) $row[$c['key']]) : '';
        if ($c['type'] === 'gitea' && preg_match('#^https?://#i', $hrefVal)) {
            return '<a class="gitea-link" href="' . $h($hrefVal) . '" target="git" data-bs-toggle="tooltip" title="' . $h($hrefVal) . '"></a>';
        }
        if ($c['type'] === 'link' && preg_match('#^https?://#i', $hrefVal)) {
            $hrefHost = strtolower((string) parse_url($hrefVal, PHP_URL_HOST));
            $here     = strtolower((string) preg_replace('/:\d+$/', '', (string) ($_SERVER['HTTP_HOST'] ?? '')));
            $target   = ($hrefHost !== '' && $hrefHost !== $here) ? ' target="external"' : '';
            return '<a class="web-link" href="' . $h($hrefVal) . '"' . $target . ' data-bs-toggle="tooltip" title="' . $h($hrefVal) . '"></a>';
        }
        if ($c['type'] === 'feed' && $val !== '' && $feedBase !== '') {
            $sep = strpos($feedBase, '?') === false ? '?' : '&';
            $tip = $hrefVal !== '' ? $hrefVal : 'Open the feed ' . $val;
            return '<a class="feed-link" href="' . $h($feedBase . $sep . 'feed=' . rawurlencode($val)) . '" data-bs-toggle="tooltip" title="' . $h($tip) . '"></a>';
        }
        return '';
    };
    $sections = [];
    if (isset($doc['groups']) && is_array($doc['groups'])) {
        foreach ($doc['groups'] as $g) {
            if (is_array($g)) {
                $sections[] = [(string) ($g['heading'] ?? ''), (is_array($g['rows'] ?? null) ? $g['rows'] : []), true];
            }
        }
    } elseif (isset($doc['rows']) && is_array($doc['rows'])) {
        $sections[] = ['', $doc['rows'], false];
    }
    if ($sections === []) {
        return $fail('the document declares `columns` but carries neither `groups` nor `rows`');
    }

    $title = $noTitle ? '' : trim((string) ($doc['title'] ?? ''));
    $gen   = trim((string) ($doc['generated'] ?? ''));
    $band  = ($title !== '' || $gen !== '')
        ? $h($title) . ($title !== '' && $gen !== '' ? ' — ' : '') . ($gen !== '' ? 'generated ' . $timeCell($gen) : '')
        : '';
    $allRows = [];
    foreach ($sections as [, $srows]) {
        $allRows = array_merge($allRows, $srows);
    }
    $num = $numCols(array_keys($cols), $allRows);
    $nc  = function ($key) use ($num) { return isset($num[$key]) ? ' class="estate-num"' : ''; };
    $out = $boxOpen($band, false) . '<table class="' . $h($tableClass($band)) . '">';
    $out .= '<thead><tr>';
    $marks = ['gitea' => 'gitea-link', 'feed' => 'feed-link', 'link' => 'web-link'];
    foreach ($cols as $key => $c) {
        $cls = trim(($nc($key) !== '' ? 'estate-num' : '') . ($c['type'] === 'actions' ? ' estate-no-sort' : ''));
        $attr = $cls !== '' ? ' class="' . $cls . '"' : '';
        if ($c['icon'] !== '') {
            // A HEADER ICON: the icon is what is seen, the label is the tooltip and the name a screen
            // reader speaks.
            $glyph = isset($marks[$c['icon']]) ? '<span class="' . $marks[$c['icon']] . '" aria-hidden="true"></span>'
                   : (strpos($c['icon'], 'bi-') === 0 ? '<i class="bi ' . $h($c['icon']) . '" aria-hidden="true"></i>' : '');
            $out .= '<th scope="col"' . $attr . ' data-bs-toggle="tooltip" title="' . $h($c['label']) . '">'
                  . $glyph . '<span class="visually-hidden">' . $h($c['label']) . '</span></th>';
        } else {
            $out .= '<th scope="col"' . $attr . '>' . $h($c['label']) . '</th>';
        }
    }
    $out .= '</tr></thead><tbody>';
    $span = count($cols);
    foreach ($sections as [$heading, $srows, $isGroup]) {
        if ($isGroup) {
            $out .= '<tr class="estate-row-section"><td colspan="' . $span . '"'
                  . ($groupClass !== '' ? ' class="' . $h($groupClass) . '"' : '') . '>' . $h($heading) . '</td></tr>';
        }
        foreach ($srows as $row) {
            if (!is_array($row)) {
                continue;
            }
            $out .= '<tr>';
            foreach ($cols as $key => $c) {
                $v = $row[$key] ?? '';
                if ($c['type'] === 'actions') {
                    // AN ACTIONS COLUMN: each item drawn as its mark when its field has a value,
                    // left to right; an empty item draws nothing.
                    $marksHtml = '';
                    foreach ($c['items'] as $it) {
                        $marksHtml .= $markFor($it, $row);
                    }
                    $out .= '<td class="text-nowrap">' . $marksHtml . '</td>';
                    continue;
                }
                if ($c['type'] === 'list' && is_array($v)) {
                    // One <li> per item, in his page style (an <ol> inside the cell). An object item
                    // shows its `item` field; one without it, or a nested array, shows nothing rather
                    // than raw JSON — the column's declaration is what was wrong, and it is the
                    // publisher's to fix.
                    $items = [];
                    foreach ($v as $it) {
                        if (is_array($it) && strpos($c['item'], '{') !== false) {
                            // A template: each {field} replaced by that field of the item; a missing or
                            // non-scalar field becomes nothing.
                            $t = preg_replace_callback('/\{([A-Za-z0-9_.-]+)\}/', function ($m) use ($it) {
                                return is_scalar($it[$m[1]] ?? null) ? (string) $it[$m[1]] : '';
                            }, $c['item']);
                        } else {
                            $t = is_array($it) ? ($c['item'] !== '' ? ($it[$c['item']] ?? '') : '') : $it;
                        }
                        if (is_scalar($t) && trim((string) $t) !== '') {
                            $items[] = '<li>' . $h($t) . '</li>';
                        }
                    }
                    // A long list shows its first `max` items; the rest sit in a <details> that opens in
                    // place (the owner, 2026-10-04: rakhwala's 81 dependencies made one row 1,645px tall). The
                    // hidden items stay in the cell, so the filter still finds them and the copy carries
                    // them. <details> needs no script and no style of ours.
                    $cell = '';
                    if ($items) {
                        $max = $c['max'];
                        if ($max === 0 || count($items) <= $max + 1) {
                            $cell = '<ol>' . implode('', $items) . '</ol>';
                        } else {
                            $cell = '<ol>' . implode('', array_slice($items, 0, $max)) . '</ol>'
                                  . '<details><summary>+' . (count($items) - $max) . ' more</summary>'
                                  . '<ol start="' . ($max + 1) . '">' . implode('', array_slice($items, $max)) . '</ol></details>';
                        }
                    }
                    $out .= '<td>' . $cell . '</td>';
                    continue;
                }
                if (!is_scalar($v) || (string) $v === '') {
                    $out .= '<td></td>';
                } elseif ($c['type'] === 'time') {
                    // "format": "date" — the cell shows the date alone, on one line; the clock is in
                    // the tooltip the page script already gives every time (the owner, 2026-10-04).
                    $tc = $timeCell($v);
                    if ($c['format'] === 'date') {
                        $tc = str_replace('class="tbl-localtime"', 'class="tbl-localtime" data-format="date"', $tc);
                    }
                    $out .= '<td class="estate-nowrap" data-sort="' . $h($v) . '">' . $tc . '</td>';
                } elseif ($c['type'] === 'status') {
                    $out .= '<td>' . $badge($v) . '</td>';
                } elseif ($c['type'] === 'feed' && $feedBase !== '') {
                    // A NAME, never an address: feedView looks it up in the index and refuses one it
                    // does not carry, so a feed cannot send the reader anywhere the index does not name.
                    // Drawn like a Gitea link (the owner, 2026-10-04): the feed mark before the name is the
                    // only click; `href`, when the column names one, is a field shown as its tooltip.
                    $sep   = strpos($feedBase, '?') === false ? '?' : '&';
                    $tip   = ($c['href'] !== '' && is_scalar($row[$c['href']] ?? null)) ? (string) $row[$c['href']] : 'Open the feed ' . (string) $v;
                    $out  .= '<td><a class="feed-link" href="' . $h($feedBase . $sep . 'feed=' . rawurlencode((string) $v))
                           . '" data-bs-toggle="tooltip" title="' . $h($tip) . '"></a>' . ($c['text'] ? $h($v) : '') . '</td>';
                } elseif ($c['type'] === 'gitea' && $c['href'] !== '' && is_scalar($row[$c['href']] ?? null)
                          && preg_match('#^https?://#i', (string) $row[$c['href']])) {
                    // The name is text; the mark opens it, in the shared "git" tab (the owner, 2026-10-04).
                    // With "text": false the mark stands alone, titled with the value it replaces.
                    // The tooltip is the document's address, like the feed mark's (the owner, 2026-10-04),
                    // and a Bootstrap tooltip rather than the browser's plain title box.
                    $out .= '<td><a class="gitea-link" href="' . $h($row[$c['href']])
                          . '" target="git" data-bs-toggle="tooltip" title="' . $h($row[$c['href']]) . '"></a>'
                          . ($c['text'] ? $h($v) : '') . '</td>';
                } elseif ($c['type'] === 'backlog-record' && ctype_digit(trim((string) $v)) && $backlogUrl !== '') {
                    // The estate's clickable cell (the owner's ruling): the WHOLE <td> opens the record and
                    // carries estate-link's pointer and hover; the number is text, never a hyperlink or an
                    // icon. Bootstrap.5.Javascript's data-content-url handler opens it.
                    $n    = trim((string) $v);
                    $out .= '<td class="estate-link' . ($nc($key) !== '' ? ' estate-num' : '') . '" data-sort="' . $h($n)
                          . '" data-content-url="' . $h($backlogUrl . '/' . $n) . '" tabindex="0">' . $h($n) . '</td>';
                } elseif ($c['type'] === 'link' && $c['href'] !== '' && is_scalar($row[$c['href']] ?? null)
                          && preg_match('#^https?://#i', (string) $row[$c['href']])) {
                    // http(s) only: a feed must not be able to put a javascript: address on the page.
                    // Outside this site it opens in the external tab (his rule for links out); inside,
                    // in place.
                    $addr     = (string) $row[$c['href']];
                    $hrefHost = strtolower((string) parse_url($addr, PHP_URL_HOST));
                    $here     = strtolower((string) preg_replace('/:\d+$/', '', (string) ($_SERVER['HTTP_HOST'] ?? '')));
                    $target   = ($hrefHost !== '' && $hrefHost !== $here) ? ' target="external"' : '';
                    if (!$c['text'] || trim((string) $v) === $addr) {
                        // Words that would only repeat the address (or "text": false): the link mark,
                        // with the address as its Bootstrap tooltip (the owner, 2026-10-04).
                        $out .= '<td><a class="web-link" href="' . $h($addr) . '"' . $target
                              . ' data-bs-toggle="tooltip" title="' . $h($addr) . '"></a></td>';
                    } else {
                        $out .= '<td><a href="' . $h($addr) . '"' . $target . '>' . $h($v) . '</a></td>';
                    }
                } else {
                    $out .= '<td' . $nc($key) . '>' . nl2br($h($v), false) . '</td>';
                }
            }
            $out .= '</tr>';
        }
    }
    $out .= '</tbody></table>' . $boxClose;
    if ($legend !== []) {
        $out .= $boxOpen('', true) . '<table class="estate-table estate-fit"><tbody>';
        foreach ($legend as $l) {
            if (is_array($l) && isset($l['status'])) {
                $out .= '<tr><td>' . $badge($l['status']) . '</td><td>' . $h($l['label'] ?? '') . '</td></tr>';
            }
        }
        $out .= '</tbody></table>' . $boxClose;
    }
    foreach ((isset($doc['notes']) && is_array($doc['notes'])) ? $doc['notes'] : [] as $n) {
        if (is_scalar($n) && trim((string) $n) !== '') {
            $out .= '<p class="text-body-secondary mb-1">' . $h($n) . '</p>';   // no `small`: the owner cannot read smaller type
        }
    }
    return $out;
}

// Caption placeholders read the ENVELOPE, so they must be resolved before the walk below
// discards it. Substituted RAW here on purpose: the caption is escaped once, where it is
// rendered, so a feed cannot inject markup and a value containing & or < is not escaped twice.
// A placeholder whose key is also in &localTime becomes a <time> in the reader's clock, so
// "Generated {generated}" no longer prints raw UTC — escaped piece by piece here, and
// $captionHtml is then emitted as-is.
$captionHtml = null;
if ($caption !== '' && strpos($caption, '{') !== false && is_array($data)) {
    $envelope    = $data;
    $parts       = preg_split('/(\{[A-Za-z0-9_.-]+\})/', $caption, -1, PREG_SPLIT_DELIM_CAPTURE);
    $captionHtml = '';
    foreach ($parts as $part) {
        if (preg_match('/^\{([A-Za-z0-9_.-]+)\}$/', $part, $m)) {
            $v = $envelope[$m[1]] ?? '';
            $v = is_scalar($v) ? (string) $v : '';
            $e = htmlspecialchars($v, ENT_QUOTES, 'UTF-8');
            $captionHtml .= ($v !== '' && isset($localTime[$m[1]]))
                ? '<time datetime="' . $e . '" class="tbl-localtime">' . $e . '</time>' : $e;
        } else {
            $captionHtml .= htmlspecialchars($part, ENT_QUOTES, 'UTF-8');
        }
    }
}

// Walk to the rows when they are wrapped in an envelope. Named explicitly rather than guessed:
// a feed may carry several arrays, and picking "the first one that looks like rows" would
// silently render a different table the day the publisher adds a field.
if ($rowsPath !== '') {
    foreach (explode('.', $rowsPath) as $step) {
        $step = trim($step);
        if ($step === '') {
            continue;
        }
        if (!is_array($data) || !array_key_exists($step, $data)) {
            return $fail("&rows path '$rowsPath' does not exist in the data (no '$step')");
        }
        $data = $data[$step];
    }
}

// Tolerate the shapes JSON-LD actually arrives in.
if (isset($data['@graph']) && is_array($data['@graph'])) {
    $data = $data['@graph'];
}
// A list of rows, or a single object? array_is_list() is PHP 8.1+, so check it the portable way.
$isList = is_array($data) && ($data === [] || array_keys($data) === range(0, count($data) - 1));
if (is_array($data) && !$isList) {
    $data = [$data];                       // a single object is a one-row table
}
if (!is_array($data) || $data === []) {
    return $fail('no rows to render');
}

$rows = [];
foreach ($data as $row) {
    if (is_array($row)) {
        $rows[] = $row;
    }
}
if ($rows === []) {
    return $fail('no object rows to render');
}

// ---- decide the columns ----------------------------------------------------
$headers = [];                              // key => label
if ($columns !== '') {
    foreach (explode(',', $columns) as $spec) {
        $spec = trim($spec);
        if ($spec === '') {
            continue;
        }
        $parts = explode('=', $spec, 2);
        $key   = trim($parts[0]);
        if ($key !== '') {
            // TWO DIFFERENT THINGS, and conflating them cost two conversions:
            //   `key`   — no label offered, so the key is the best available heading
            //   `key=`  — a label WAS offered and it is deliberately empty
            // The old test was `trim($parts[1]) !== ''`, which treated an explicitly empty label as
            // if none had been given and printed the key. A table whose first heading cell is blank
            // (a row-label column, very common) came back with "col0" written across the top, and
            // convert-doc rightly refused to write a page it could see had changed.
            $headers[$key] = array_key_exists(1, $parts) ? trim($parts[1]) : $key;
        }
    }
} else {
    // Every key of the first row, in author order. @context/@type/@id are JSON-LD machinery and
    // are never columns; a nested value has no sensible cell, so it is skipped rather than
    // rendered as "Array".
    foreach ($rows[0] as $key => $value) {
        if (is_string($key) && $key !== '' && $key[0] !== '@' && !is_array($value)) {
            $headers[$key] = $key;
        }
    }
}
// The grouping key is shown in its own heading row, so it is never also a column.
if ($group !== '') {
    unset($headers[$group]);
}
if ($headers === []) {
    return $fail('no columns: the first row has no simple fields, so pass &columns');
}

// ---- render ----------------------------------------------------------------
$esc = function ($v) {
    if (is_bool($v)) {
        return $v ? 'yes' : 'no';
    }
    if (is_array($v)) {
        // A nested object (e.g. worksFor) is shown by its name if it has one, else skipped.
        $v = $v['name'] ?? '';
    }
    // Escape first, THEN allow newlines through as <br> — so a multi-line address survives
    // without the author putting markup in their data, and markup in the data stays inert.
    return nl2br(htmlspecialchars((string) $v, ENT_QUOTES, 'UTF-8'), false);
};

/** Render one cell, as a link when &link named this column and the row has an href. */
$cell = function ($key, $row) use ($esc, $links, $linkClass, $badges, $badgeClasses, $badgeClass, $localTime) {
    if (!array_key_exists($key, $row)) {
        return '';
    }
    $text = $esc($row[$key]);
    if ($text !== '' && isset($localTime[$key])) {
        $raw = is_scalar($row[$key]) ? (string) $row[$key] : '';
        return '<time datetime="' . htmlspecialchars($raw, ENT_QUOTES, 'UTF-8')
             . '" class="tbl-localtime">' . $text . '</time>';
    }
    if ($text !== '' && isset($badges[$key])) {
        // An unmapped value keeps the base class only — a new enum member shows up as a plain
        // badge rather than inheriting a neighbour's colour and reading as a status it is not.
        // The class is chosen by the key field, which is this column itself unless &badge named
        // another; a missing key field is simply unmapped, never an error.
        $keyField = $badges[$key];
        $rawVal   = $row[$keyField] ?? '';
        $raw      = is_scalar($rawVal) ? (string) $rawVal : '';
        $extra    = $badgeClasses[$raw] ?? '';
        $cls   = trim($badgeClass . ' ' . $extra);
        return '<span class="' . htmlspecialchars($cls, ENT_QUOTES, 'UTF-8') . '">' . $text . '</span>';
    }
    if ($text === '' || !isset($links[$key])) {
        return $text;
    }
    $href = $row[$links[$key]] ?? '';
    if (!is_string($href) || trim($href) === '') {
        return $text;                       // no destination: plain text, never an empty link
    }
    $cls = $linkClass !== ''
        ? ' class="' . htmlspecialchars($linkClass, ENT_QUOTES, 'UTF-8') . '"'
        : '';
    return '<a href="' . htmlspecialchars(trim($href), ENT_QUOTES, 'UTF-8') . '"' . $cls . '>'
         . $text . '</a>';
};

$band = $captionHtml !== null ? $captionHtml
      : ($caption !== '' ? htmlspecialchars($caption, ENT_QUOTES, 'UTF-8') : '');
$num  = $numCols(array_keys($headers), $rows);
$out  = $boxOpen($band, in_array('estate-fit', explode(' ', $class), true))
      . '<table class="' . htmlspecialchars($tableClass($band), ENT_QUOTES, 'UTF-8') . '">';
$out .= '<thead><tr>';
foreach ($headers as $key => $label) {
    $out .= '<th scope="col"' . (isset($num[$key]) ? ' class="estate-num"' : '') . '>'
          . htmlspecialchars($label, ENT_QUOTES, 'UTF-8') . '</th>';
}
$out .= '</tr></thead><tbody>';
$span      = max(1, count($headers));
$lastGroup = null;
foreach ($rows as $row) {
    if ($group !== '') {
        $thisGroup = array_key_exists($group, $row) ? (string) $row[$group] : '';
        if ($thisGroup !== $lastGroup) {
            $out .= '<tr class="estate-row-section"><td colspan="' . $span . '"'
                 . ($groupClass !== '' ? ' class="' . htmlspecialchars($groupClass, ENT_QUOTES, 'UTF-8') . '"' : '') . '>'
                 . htmlspecialchars($thisGroup, ENT_QUOTES, 'UTF-8') . '</td></tr>';
            $lastGroup = $thisGroup;
        }
    }
    $trClass = '';
    if ($rowClassCol !== '' && array_key_exists($rowClassCol, $row) && is_scalar($row[$rowClassCol])) {
        $mapped = $rowClasses[(string) $row[$rowClassCol]] ?? '';
        if ($mapped !== '') {
            $trClass = ' class="' . htmlspecialchars($mapped, ENT_QUOTES, 'UTF-8') . '"';
        }
    }
    $out .= '<tr' . $trClass . '>';
    foreach ($headers as $key => $label) {
        // data-sort keeps the ORIGINAL value as the sort key, so a column the decorator rewrites
        // for display (a timestamp turned into the reader's clock) still sorts chronologically
        // rather than alphabetically by whatever the browser's locale printed.
        $tdAttr = '';
        if (isset($localTime[$key]) && array_key_exists($key, $row) && is_scalar($row[$key])) {
            $tdAttr = ' data-sort="' . htmlspecialchars((string) $row[$key], ENT_QUOTES, 'UTF-8') . '"';
        }
        if ($tipCol !== '' && $key === $tipCol && $tipFields) {
            $lines = [];
            foreach ($tipFields as $tk => $tlabel) {
                if (!array_key_exists($tk, $row) || !is_scalar($row[$tk])) {
                    continue;
                }
                $tv = trim((string) $row[$tk]);
                if ($tv === '') {
                    continue;               // an empty value is silence, not a blank line
                }
                $lines[] = '<dt>' . htmlspecialchars($tlabel, ENT_QUOTES, 'UTF-8') . '</dt>'
                         . '<dd>' . htmlspecialchars($tv, ENT_QUOTES, 'UTF-8') . '</dd>';
            }
            if ($lines) {
                // A DESCRIPTION LIST, not a <table>, and not by preference: Bootstrap's tooltip
                // sanitizer strips every tag outside its allowlist, and that list has NO table,
                // tbody, tr, th or td. A <table> here is removed silently and the tooltip renders
                // EMPTY — which is exactly what happened. dl/dt/dd are on the allowlist, are the
                // right semantics for label/value pairs, read sensibly with no CSS at all, and
                // the CSS turns them into the two columns the owner asked for.
                $tip = '<dl class="tip-table">' . implode('', $lines) . '</dl>';
                // The body is markup, escaped per value above and attribute-escaped once here —
                // a value from the feed can never become markup.
                $tdAttr .= ' data-bs-toggle="tooltip" data-bs-html="true" data-bs-placement="right"'
                        . ' data-bs-custom-class="' . htmlspecialchars($tipClass, ENT_QUOTES, 'UTF-8') . '"'
                        . ' data-bs-title="' . htmlspecialchars($tip, ENT_QUOTES, 'UTF-8') . '"'
                        . ' class="tbl-has-tip' . (isset($num[$key]) ? ' estate-num' : '') . '"';
            }
        }
        if (isset($num[$key]) && strpos($tdAttr, ' class="') === false) {
            $tdAttr .= ' class="estate-num"';
        }
        $out .= '<td' . $tdAttr . '>' . $cell($key, $row) . '</td>';
    }
    $out .= '</tr>';
}
$out .= '</tbody></table>' . $boxClose;

return $out;
