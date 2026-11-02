# apply-environment — one file says which environment, one program writes it

Design for the build filed on the backlog (ticket named in the commit that adds this file).
The owner, 2026-10-07: *"each restore and new install will requires - apply_environment.php run"*,
then *"you have to accept/implement or reject on your own"*. Accepted by skunkworks.

## The problem, measured 2026-10-07

MODx reads its configuration from database rows. A restore loads production's rows whole, so
every value that differs between production, staging and a development bench has to be written
again after it. Today that is done by about six jobs, each from a different source:

- environment variables set inside `config/scripts/ops.sh` verbs (`MODX_ESTATE_ENV`,
  `ESTATE_ENV_COLOR`, `MODX_ROOT`, `MODX_SSO_IDP`, `MODX_SSO_OIDC*`) read by `setup/02`, `setup/12`;
- literal SQL in `ops.sh` (`MODX_STAGING_OWNED_SETTINGS`, `_modx_dev_rebind_links`, the staging
  restore's `http_host`/`site_url`/`server_protocol` UPDATE);
- ansible variables passed to `setup/12`, `setup/13` under tags that run only by hand (`never`);
- (retired) `estate.json` `domains` host maps, once read by MODx's own binders; the names are infra's now.

Defects the survey found, each a consequence of that spread: the dev bench keeps production's
`storage.environment=production` and `modxsearch.ask_url` (no job writes them there); `ops.sh`
still UPDATEs `corp.base_url` after `setup/02` deleted the row; the staging restore hard-codes
`https://<ctx>.modx.<internal zone>/` instead of reading the estate's scheme (since retired).

## The design

1. **One file per installation says everything that differs:** `core/config/application.php`,
   which infra already renders per environment and which no restore touches (it is outside the
   database and excluded from the docroot tar). It gains one key:

       'settings' => [
           'system'   => ['estate_env' => 'staging', 'storage.environment' => 'staging', ...],
           'contexts' => ['worldview' => ['http_host' => 'worldview.modx.internal.test', ...], ...],
       ],

   A key that is absent is not managed by the program. Values are strings.

2. **One program writes it:** `setup/apply-environment.php`. It starts MODx the way
   `setup/07-regenerate-uris.php` does, reads `settings` from `application.php`, writes each
   system and context setting through MODx's own objects (creating a row that is missing),
   refreshes the cache, and prints one line per value changed. `--check` writes nothing, prints
   each difference and exits 1 if there is one. It refuses, by name, an `application.php` with no
   `environment` or no `settings`. The comparison is a pure function in `setup/lib/` so a
   `--before-apply` suite tests it with no database.

3. **What it manages** — the values the survey found differing by environment:
   - system: `estate_env`, `estate_env_color`, `error_log_filepath`, `kuber.base_url`,
     `kuber.reader_url`, `modxsearch.ask_url`, `munshi.backlog_url`, `sso.issuer`, `sso.auth_endpoint`,
     `sso.token_endpoint`, `sso.google_client_id`, `sso.google_client_secret`,
     `storage.base_url`, `storage.modx_token`, `storage.environment`,
     `new_folder_permissions`, `new_file_permissions`;
   - per context: `http_host`, `site_url`, `base_url`, `server_protocol`, `session_name`,
     `sso.provider`, `sso.oidc_issuer`, `sso.oidc_auth_endpoint`, `sso.oidc_token_endpoint`,
     `sso.oidc_userinfo_endpoint`, `sso.oidc_jwks_uri`, `sso.oidc_client_id`,
     `sso.oidc_client_secret`.

   **Not managed:** access rows, users and groups (they follow the estate's branch, not the
   environment — `setup/04`), and rows whose value is another row's id (`login_page`,
   `storage.protected_source`) — `setup/12` and `setup/20` derive those from the database.

4. **Who renders the file:** infra's `modx-web` role, from the values its verbs and variables
   hold today, for the installations it runs. For a development bench, which has no writer,
   the bench's own renderer (skunkworks) renders it from `estate.json` and the bench's
   facts.

5. **Who runs the program:** every job that loads a database or sets an installation up ends
   with it — the restores, the settings verbs, the domain binding — and the literal writes and
   environment variables those jobs carry today are removed. Those jobs are infra's.

## Parts it leans on

| Part | Owner | State |
|---|---|---|
| `setup/apply-environment.php`, `setup/lib/`, the bench's renderer, tests | skunkworks | built by this ticket |
| `roles/modx-web/templates/application.php.j2` gains `settings` | infra | asked on the ticket |
| `scripts/ops.sh` restore, settings and binding verbs run the program, drop their literal writes | infra | asked on the ticket |
| MODx `modSystemSetting` / `modContextSetting` objects | vendor | stock 3.2.4-pl |

## What the README may then claim

(a) a context is chosen by a header nginx sets, not by a URL setting in MODx — true today
(`common/lib/EdgeContext.php`); (b) on a restore or a new install the environment is set by
running one PHP program — true once infra's two asks land.
