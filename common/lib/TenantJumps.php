<?php
/**
 * TenantJumps.php — the estate title bar's jump slot: the tenant's OTHER applications, one click away.
 *
 * claude/shared/design/estate-title-bar.md §The jump slot (the slot, dev's) and
 * design/modx-jump-icons-skunkworks.md (Library's drawing of it). The list is infra's, one file per
 * host: {<tenant key>: [{app, name, url, icon}]}. This draws the entries under the page's tenant key,
 * in the array's order, minus the entry whose `app` is Library's own atom — and nothing else: no
 * entry added, none dropped but its own, no address, name or icon of its own. Fields are drawn as
 * handed.
 *
 * Not drawn at all (never an empty <nav>): a list that does not parse or is not an object; no entry
 * under the key; nothing left once Library's own entry is gone. The snippet adds the signed-out case
 * and the unreadable file.
 *
 * Pure: no MODx, no request. The snippet estateJumps calls it; tests/tenant-jumps.php calls it directly.
 */

namespace Pustak\Modx;

final class TenantJumps
{
    /** Library's own atom: service.json `name`. tests/tenant-jumps.php holds the two equal. */
    public const SELF = 'modx';

    public static function render(string $json, string $tenant, string $self = self::SELF): string
    {
        // Decoded WITHOUT assoc so a JSON object stays an object: `[]` and `{}` are told apart, and a
        // list is not mistaken for a map of tenants.
        $list = json_decode($json);
        if (!$list instanceof \stdClass || !isset($list->{$tenant}) || !is_array($list->{$tenant})) {
            return '';
        }
        $links = '';
        foreach ($list->{$tenant} as $entry) {
            if (!$entry instanceof \stdClass || (string) ($entry->app ?? '') === $self) {
                continue;
            }
            $name = self::attr($entry->name ?? '');
            $links .= '<a href="' . self::attr($entry->url ?? '') . '" data-estate-tip="Open ' . $name . '">'
                . '<img src="' . self::attr($entry->icon ?? '') . '" alt="' . $name . '"></a>';
        }
        if ($links === '') {
            return '';
        }
        return '<nav class="estate-bar-jump" aria-label="This tenant&#039;s other applications">' . $links . '</nav>';
    }

    private static function attr($v): string
    {
        return htmlspecialchars(is_scalar($v) ? (string) $v : '', ENT_QUOTES | ENT_HTML5, 'UTF-8');
    }
}
