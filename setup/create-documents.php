<?php
/**
 * create-documents.php — Library's new pages are born from git.
 *
 * Design: claude-shared design/modx-page-births-skunkworks.md, sections 2 and 3. A page declared under
 * modx-estate's seat/births/ is created on this ground by MODx's own Resource/Create processor, found by
 * (context, URI) — never by id, never by alias alone.
 *
 * Fed to the PHP that can bootstrap MODx ON STDIN, the way the suites reach a containerised MODx:
 *
 *     php -- <MODX_ROOT> <payload.json> < setup/create-documents.php
 *
 * Arguments, not environment: `docker exec` carries none of the caller's environment (tests/lib.sh).
 * The payload is births.json with each entry's body inlined as "body":
 *
 *     [{"context": "worldview", "alias": "example-page", "parent": "worldview/notes" | 0,
 *       "pagetitle": "Example page", "template": "BaseTemplate", "published": 1, "hidemenu": 0,
 *       "body": "<p>…</p>"}]
 *
 * Output, one line per entry, for the deploy verb's log:
 *     exists <ctx>/<uri> (id N)[ DELETED]      nothing written
 *     created <ctx>/<uri> (id N)               born by Resource/Create, read back
 *     waiting <ctx>/<alias>: no context …      this ground has no such context yet; nothing written
 * Exit 0 when every entry exists or was created; 1 on a refusal (named on stderr); 2 on bad input.
 *
 * It creates and nothing else: no update, no delete, no id of our choosing, no cache clear (the verb's
 * apply clears it). Every check runs before the first write, so a refusal writes nothing.
 */
define('MODX_API_MODE', true);

[, $root, $payloadPath] = $argv + [null, '', ''];
if (!$root || !is_file($root . '/index.php')) {
    fwrite(STDERR, "REFUSING: MODX_ROOT is " . var_export($root, true) . " and has no index.php\n");
    exit(2);
}
if (!$payloadPath || !is_readable($payloadPath)) {
    fwrite(STDERR, "REFUSING: the payload " . var_export($payloadPath, true) . " is not a readable file\n");
    exit(2);
}
$entries = json_decode((string) file_get_contents($payloadPath), true);
if (!is_array($entries) || ($entries && array_keys($entries) !== range(0, count($entries) - 1))) {
    fwrite(STDERR, "REFUSING: the payload is not a JSON list of entries\n");
    exit(2);
}

require_once $root . '/index.php';
$modx->initialize('mgr');
// The install's administrator: Resource/Create checks new_document, add_children, new_document_in_root
// and publish_document against the acting user, and a command line has none.
$modx->user = $modx->getObject(MODX\Revolution\modUser::class, ['sudo' => 1]);
if (!$modx->user) {
    fwrite(STDERR, "REFUSING: this install has no sudo user to create as\n");
    exit(1);
}

use MODX\Revolution\modResource;
use MODX\Revolution\modTemplate;
use MODX\Revolution\modDocument;

/** The URI MODx would give this entry, from MODx's own getAliasPath (friendly_urls, suffixes, lowercasing). */
function uri_for($modx, array $fields): string
{
    $probe = $modx->newObject(modDocument::class);
    $probe->fromArray($fields);
    return (string) $probe->getAliasPath($fields['alias'], $fields);
}

// --- 1. every check before any write -------------------------------------------------------------
$refusals = [];
$waiting = [];  // entries whose context this ground does not have yet
$plan = [];       // [label, fields, uri]
$seen = [];       // "<ctx>/<uri>" => label
foreach ($entries as $i => $e) {
    $label = '#' . ($i + 1) . ' ' . ($e['context'] ?? '?') . '/' . ($e['alias'] ?? '?');
    foreach (['context', 'alias', 'pagetitle', 'template', 'body'] as $k) {
        if (!isset($e[$k]) || !is_string($e[$k]) || ($k !== 'body' && $e[$k] === '')) {
            $refusals[] = "$label: field '$k' is missing or not a string";
            continue 2;
        }
    }
    // A context this ground does not have yet is not a bad entry: a context is created on each ground
    // in turn (setup/11-add-context.py), and its pages are declared once, in git. The page WAITS — named,
    // nothing written for it — and is born by the first run after its context exists.
    if (!$modx->getObject(MODX\Revolution\modContext::class, ['key' => $e['context']])) {
        $waiting[] = "waiting {$e['context']}/{$e['alias']}: no context '{$e['context']}' on this ground yet";
        continue;
    }
    // The parent: 0, or "<context>/<uri>" naming exactly one undeleted page of THAT context. A string
    // handed to Resource/Create as `parent` would be taken for a context key and the page would land at
    // the root (Create.php:321-329), so it is resolved here, to an id.
    $parentId = 0;
    $parent = $e['parent'] ?? 0;
    if ($parent !== 0 && $parent !== '0') {
        if (!is_string($parent) || strpos($parent, '/') === false) {
            $refusals[] = "$label: parent " . json_encode($parent) . " is neither 0 nor '<context>/<uri>'";
            continue;
        }
        [$pctx, $puri] = explode('/', $parent, 2);
        if ($pctx !== $e['context']) {
            $refusals[] = "$label: parent '$parent' is in another context";
            continue;
        }
        $hit = $modx->getCollection(modResource::class, ['context_key' => $pctx, 'uri' => $puri, 'deleted' => 0]);
        if (count($hit) === 0) {
            // An earlier entry of this payload may be the parent; it has no id until it is born.
            $pending = $seen["$pctx/$puri"] ?? null;
            if ($pending === null) {
                $refusals[] = "$label: parent '$parent' is not an undeleted page here, nor an earlier entry";
                continue;
            }
            $parentId = ['pending' => "$pctx/$puri"];
        } elseif (count($hit) > 1) {
            $refusals[] = "$label: parent '$parent' names " . count($hit) . " pages";
            continue;
        } else {
            $parentId = (int) reset($hit)->get('id');
        }
    }
    $tpl = $modx->getCollection(modTemplate::class, ['templatename' => $e['template']]);
    if (count($tpl) !== 1) {
        $refusals[] = "$label: template '{$e['template']}' matches " . count($tpl) . " templates, not exactly one";
        continue;
    }
    $fields = [
        'context_key' => $e['context'],
        'class_key'   => modDocument::class,
        'alias'       => $e['alias'],
        'pagetitle'   => $e['pagetitle'],
        'template'    => (int) reset($tpl)->get('id'),
        'published'   => (int) ($e['published'] ?? 1),
        'hidemenu'    => (int) ($e['hidemenu'] ?? 0),
        'content'     => $e['body'],
        'parent'      => $parentId,
    ];
    // A pending parent's URI is computed when it is born; for the plan, compute against the root of the
    // context, then again at write time with the real parent.
    $uri = uri_for($modx, array_merge($fields, ['parent' => is_int($parentId) ? $parentId : 0]));
    $key = $e['context'] . '/' . $uri;
    if (isset($seen[$key]) && is_int($parentId)) {
        $refusals[] = "$label: URI '$key' is also entry {$seen[$key]}";
        continue;
    }
    $seen[$key] = $label;
    $plan[] = [$label, $fields, $uri];
}
if ($refusals) {
    foreach ($refusals as $r) fwrite(STDERR, "REFUSED $r\n");
    fwrite(STDERR, count($refusals) . " entr" . (count($refusals) === 1 ? 'y' : 'ies') . " refused — nothing was written\n");
    exit(1);
}
foreach ($waiting as $w) echo "$w\n";

// --- 2 and 3. exists, or born --------------------------------------------------------------------
$born = [];   // "<ctx>/<uri>" => id, for a parent born earlier in this run
foreach ($plan as [$label, $fields, $uri]) {
    if (is_array($fields['parent'])) {
        $fields['parent'] = $born[$fields['parent']['pending']]
            ?? (int) $modx->getObject(modResource::class, ['context_key' => $fields['context_key'],
                   'uri' => substr($fields['parent']['pending'], strlen($fields['context_key']) + 1)])->get('id');
        $uri = uri_for($modx, $fields);
    }
    $ctx = $fields['context_key'];
    // Deleted rows included: a page in the recycle bin holds its URI, and an undelete would collide.
    $have = $modx->getObject(modResource::class, ['context_key' => $ctx, 'uri' => $uri]);
    if ($have) {
        $born["$ctx/$uri"] = (int) $have->get('id');
        echo "exists $ctx/$uri (id {$have->get('id')})" . ($have->get('deleted') ? ' DELETED' : '') . "\n";
        continue;
    }
    $r = $modx->runProcessor('resource/create', $fields);
    if ($r->isError()) {
        $why = $r->getMessage();
        foreach ((array) $r->getFieldErrors() as $fe) $why .= ' ' . $fe->field . ': ' . $fe->message;
        fwrite(STDERR, "REFUSED $label: Resource/Create said: " . trim($why) . "\n");
        exit(1);
    }
    $id = (int) ($r->getObject()['id'] ?? 0);
    $row = $id ? $modx->getObject(modResource::class, $id) : null;
    if (!$row || (int) $row->get('published') !== $fields['published'] || $row->get('uri') !== $uri) {
        fwrite(STDERR, "REFUSED $label: born as id $id but read back " . ($row
            ? "published=" . $row->get('published') . " uri='" . $row->get('uri') . "'" : 'no row')
            . ", wanted published={$fields['published']} uri='$uri'\n");
        exit(1);
    }
    $born["$ctx/$uri"] = $id;
    echo "created $ctx/$uri (id $id)\n";
}
exit(0);
