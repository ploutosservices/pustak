/**
 * loginWidget — navbar login/logout control (SSO-only; replaces the [[!Login]] widget role).
 * Call uncached: [[!loginWidget]] — it must reflect the live session on every request.
 *
 * &variant=`printWho` -> the signed-in reader's full name as the bar's ` data-estate-print-who="…"` attribute
 *               (claude/shared/design/estate-print.md §3), and nothing for a reader not signed in.
 * &variant=`estate` -> the estate title bar's own classes. Anything else, including the
 *               default, renders as it always has: this snippet is called TWICE on a page, once in
 *               the bar and once in the footer, and the bar's classes are styled for a dark bar.
 *
 * Logged in  -> the user's name + a logout link (logout_page runs GoogleSSOLogout).
 * Logged out -> a sign-in link to login_page (GoogleSSOStart), carrying returnUrl so the user
 *               returns to where they were after the door.
 */

$estate = ($modx->getOption('variant', $scriptProperties, '') === 'estate');
$whoClass  = $estate ? 'estate-bar-who' : 'navbar-text me-2';
$exitClass = $estate ? 'estate-bar-exit' : '';
// IN THE BAR, THE ESTATE'S ICONS AND ITS HOVER (estate-title-bar.md rule 8): the CDN's
// estate/icons/<meaning>.svg drawn by .estate-bar-icon (Bootstrap.5.CSS), its sentence in
// data-estate-tip, which titlebar.css draws. ?v= is the first 12 of the file's sha256. The footer
// keeps its Bootstrap glyphs and title: it is not the bar.
$cdn = rtrim((string) $modx->getOption('estate_cdn_url'), '/');
$icon = function ($bi, $meaning, $v, $tip) use ($estate, $cdn) {
    $label = ' aria-label="' . $tip . '"';
    if (!$estate) {
        return [' title="' . $tip . '"' . $label, '<i class="bi ' . $bi . '"></i>'];
    }
    $url = htmlspecialchars($cdn . '/estate/icons/' . $meaning . '.svg?v=' . $v, ENT_QUOTES);
    return [' data-estate-tip="' . $tip . '"' . $label,
            '<span class="estate-bar-icon" style="--estate-icon: url(&quot;' . $url . '&quot;)" aria-hidden="true"></span>'];
};

$user = $modx->user;
if ($user && (int) $user->get('id') > 0) {
    $profile = $user->getOne('Profile');
    $name = $profile ? trim((string) $profile->get('fullname')) : '';
    if ($name === '') {
        $name = (string) $user->get('username');
    }
    if ($modx->getOption('variant', $scriptProperties, '') === 'printWho') {
        return ' data-estate-print-who="' . htmlspecialchars($name, ENT_QUOTES) . '"';
    }
    $logout = $modx->makeUrl((int) $modx->getOption('logout_page'), '', '', 'full');
    // THE ESTATE'S OWN CLASSES: the greeting, then sign out, in that order — rule 6 of
    // claude/shared/design/estate-title-bar.md. The bar's stylesheet on the CDN styles both; this
    // snippet contributes no styling of its own.
    // Hover the name for the address this session is signed in as (the owner, 2026-10-04: two accounts
    // share his name, and only one of them is entitled to kuber's values). The Google-verified address
    // the sign-in stamped, else the account's own email; a Bootstrap tooltip, not the title box.
    $email = trim((string) ($_SESSION['sso.verified_email'] ?? ''));
    if ($email === '' && $profile) {
        $email = trim((string) $profile->get('email'));
    }
    $tip = $email !== '' ? ' data-bs-toggle="tooltip" data-bs-placement="bottom" title="' . htmlspecialchars($email, ENT_QUOTES) . '"' : '';
    // WHERE AM I SIGNED IN: the door's account page for this context's realm, where a
    // person sees and ends their sessions. From the issuer the context signs in at; none, no link.
    require_once rtrim(MODX_CORE_PATH, '/') . '/components/pustak/lib/SsoConfig.php';
    $sso = SsoConfig::forContext($modx);
    $account = $sso->issuers ? rtrim($sso->issuers[0], '/') . '/account' : '';
    [$whereAttr, $whereIcon] = $icon('bi-person-badge', 'sessions', 'a7bf0962a222', 'Where am I signed in');
    $where = $account !== ''
        ? '<a class="' . $exitClass . '" href="' . htmlspecialchars($account, ENT_QUOTES) . '"' . $whereAttr . '>' . $whereIcon . '</a>'
        : '';
    [$outAttr, $outIcon] = $icon('bi-box-arrow-right', 'sign-out', '073fb12777a6', 'Sign out');
    if ($estate) {
        // THE GREETING (estate-title-bar.md §2.3): the first name, which titlebar.js turns into "Good
        // morning, <first name>" by the reader's clock, and an estate-hover card with the picture, the full
        // name and the email. The picture is the `picture` claim of the door's token this session holds
        // (validated at sign-in); with none, the name's first letter on a disc. No links in the card.
        $first = preg_split('/\s+/', $name)[0];
        $picture = '';
        $parts = explode('.', (string) ($_SESSION['sso.id_token'] ?? ''));
        if (count($parts) === 3) {
            $claims = json_decode((string) base64_decode(strtr($parts[1], '-_', '+/')), true);
            $pic = is_array($claims) ? ($claims['picture'] ?? '') : '';
            if (is_string($pic) && strncmp($pic, 'https://', 8) === 0) {
                $picture = $pic;
            }
        }
        $letter = mb_strtoupper(mb_substr($name !== '' ? $name : $email, 0, 1));
        $face = $picture !== ''
            ? '<img class="modx-avatar" src="' . htmlspecialchars($picture, ENT_QUOTES) . '" alt="" referrerpolicy="no-referrer">'
            : '<span class="modx-avatar" aria-hidden="true">' . htmlspecialchars($letter, ENT_QUOTES) . '</span>';
        $h = function ($s) { return htmlspecialchars($s, ENT_QUOTES); };
        return '<span class="estate-bar-who estate-hover" tabindex="0" data-estate-first-name="' . $h($first) . '">'
             . '<span class="estate-bar-who-text">' . $h($first) . '</span>'
             . '<span class="estate-hover-card">' . $face . '<span><b>' . $h($name) . '</b> ' . $h($email) . '</span></span></span>'
             . $where
             . '<a class="' . $exitClass . '" href="' . $logout . '"' . $outAttr . '>' . $outIcon . '</a>';
    }
    return '<span class="' . $whoClass . '"' . $tip . '>' . htmlspecialchars($name, ENT_QUOTES) . '</span>'
         . $where
         . '<a class="' . $exitClass . '" href="' . $logout . '"' . $outAttr . '>' . $outIcon . '</a>';
}

// Same-site return path only (GoogleSSOStart re-validates it server-side before use).
if ($modx->getOption('variant', $scriptProperties, '') === 'printWho') {
    return '';
}
$return = '/' . ltrim((string) ($_SERVER['REQUEST_URI'] ?? ''), '/');
$login = $modx->makeUrl((int) $modx->getOption('login_page'), '', ['returnUrl' => $return], 'full');
[$inAttr, $inIcon] = $icon('bi-box-arrow-in-right', 'sign-in', 'd2658abeed49', 'Sign in');
return '<a class="' . $exitClass . '" href="' . $login . '"' . $inAttr . '>' . $inIcon . '</a>';
