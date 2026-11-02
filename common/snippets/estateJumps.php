/**
 * estateJumps — the estate title bar's jump slot for this page: the tenant's other applications.
 *
 * Placed uncached in topNavBar, between the spacer and the actions (estate-title-bar.md rule 6). The
 * drawing is common/lib/TenantJumps.php; this decides only whether there is anything to draw:
 *
 *   - signed out: nothing. The slot is for a person already inside, and the greeting uses the same
 *     test (a user id above 0).
 *   - estate.tenant_apps_file empty, or the file unreadable: nothing. The path is the ground's,
 *     written into application.php by whoever renders it; this names no path of its own.
 *   - otherwise the entries under this context's key, which is the tenant key the edge hands as
 *     X-Tenant (EdgeContext), minus Library's own.
 */
$user = $modx->user;
if (!$user || (int) $user->get('id') <= 0) {
    return '';
}
$path = trim((string) $modx->getOption('estate.tenant_apps_file', null, ''));
if ($path === '' || !is_file($path) || !is_readable($path)) {
    return '';
}
$json = @file_get_contents($path);
if ($json === false) {
    return '';
}
require_once rtrim(MODX_CORE_PATH, '/') . '/components/pustak/lib/TenantJumps.php';
return \Pustak\Modx\TenantJumps::render($json, (string) $modx->context->get('key'));
