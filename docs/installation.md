# Installing from nothing

Stock MODX 3.2.4-pl from modx.com, then this repository's scripts and elements, and nothing else.
The one file you write is the **estate file** — who your sites serve and on which names. Everything
under `setup/`, `common/` and `tools/` is the software and is not edited.

This sequence was followed end to end on a clean database and docroot, with only an estate file
copied from `setup/estate.example.json`; the answers it gave are the table at the end.

## What is ours, and what is MODX's

    stock MODX distribution        index.php, manager/, connectors/, core/  — untouched, byte-identical
    config.context.php             1 line, requires EdgeContext.php               <- the only docroot file of ours
    core/components/pustak/lib/    common/lib — EdgeContext, SsoConfig, the storage gate, …
    the elements                   common/{chunks,snippets,plugins,templates}
    setup/*.py                     the sequence below

`index.php` is **not** modified. Stock MODX already reads `config.context.php` for a context key if
it is present. That file requires `core/components/pustak/lib/EdgeContext.php`, which takes the key
from the `X-Tenant` request header — set by your web server — and answers a fixed 404 page for anything else.

## Before you start

- **The right zip.** `https://modx.com/download/direct/modx-3.2.4-pl.zip` installs: it has
  `index.php`, `manager/`, `connectors/`. The `-advanced` zip is for upgrades only and cannot install.
- **What MODX 3.2.4 itself needs** (PHP with pdo_mysql, MariaDB or MySQL), plus Python 3 with
  `pymysql`, and `envsubst`.
- **An empty database** (utf8mb4) and an account that can create tables in it.
- **The estate file.** Copy `setup/estate.example.json` somewhere outside this repository and edit
  it (see *What you edit* below). Every script finds it through `MODX_ESTATE`.

Set these once, in the shell you run everything from:

    export MODX_ROOT=/path/to/docroot          # where the zip is unpacked
    export MODX_ESTATE=/path/to/estate.json    # your estate file
    export MODX_DB_NAME=modx                   # the empty database
    # the database account — EITHER a password login:
    export MODX_DB_USER=… MODX_DB_PASS=…
    # OR, if the account authenticates by unix_socket (no password), name the socket instead
    # and leave MODX_DB_USER / MODX_DB_PASS unset:
    export MODX_DB_SOCKET=/run/mysqld/mysqld.sock
    export MODX_ESTATE_ENV=development         # or staging / production: the colour of the title bar

## The sequence

**1. Unpack and install MODX.** The installer reads `setup/config.xml` inside the docroot; this
repository's `setup/config.xml` is a template whose values come from the environment:

    unzip modx-3.2.4-pl.zip && mv modx-3.2.4-pl "$MODX_ROOT"
    sudo chgrp -R www-data "$MODX_ROOT" && chmod -R g+w "$MODX_ROOT"   # if the web server is another user
    export MODX_HTTP_HOST=localhost MODX_ADMIN_USER=… MODX_ADMIN_PASS=… MODX_ADMIN_EMAIL=…
    envsubst < setup/config.xml > "$MODX_ROOT/setup/config.xml"
    php "$MODX_ROOT/setup/cli-install.php" < /dev/null

`MODX_ADMIN_USER` must equal `admin_username` in your estate file. The installer leaves the admin
password in `$MODX_ROOT/setup/config.xml`; step 4 deletes that directory.

**2. The Extras and the pustak package**, before anything that makes pages — the pages are made
on pustak's templates:

    php setup/install-extras.php                       # pdoTools and SimpleSearch, from modx.com

Then install **pustak**: the chunks, snippets, plugins and page templates of `common/`, the template
variables `common/tvs.json` declares (bound to their templates), and `common/lib` at
`core/components/pustak/lib/`. Download `pustak-<version>.transport.zip` from the repository's
releases, or build it with `php tools/build-transport.php --source . --version <version> --out <dir>`;
then in the manager: *Extras → Installer → Upload a package*, choose the zip, *Install*.
`php tools/verify-transport.php --source .` (with `MODX_ROOT` set) checks that what MODX holds is
byte for byte what the package was built from.

**3. Contexts, pages, access, sign-in** — in this order:

    python3 setup/01-contexts-users.py     # contexts, context settings, users
    python3 setup/03-resources-skeleton.py # support / content / files per context, auth pages
    python3 setup/04-access-control.py     # groups, grants, page + file protection
    python3 setup/12-sso.py                # sso-login / sso-logout / sso-callback per context

03 finds the templates by name and refuses if the package is not installed.

**4. Bind each context to its names, then the system settings.** The names are not this
software's: the installation's `core/config/application.php` carries them (infra renders it on a
ground; on a dev box the bench's own renderer renders it from infra's derivation), and
`setup/apply-environment.php` writes them. It runs AFTER 03, which creates each context's settings:

    php setup/apply-environment.php

    python3 setup/02-system-settings.py

**5. Last.**

    php setup/07-regenerate-uris.php                   # LAST — see below
    python3 setup/config-context.py --write "$MODX_ROOT"
    php clear-cache.php "$MODX_ROOT"

**6. Serve it.** Behind a web server, send each context's names to the docroot with the header
`X-Tenant: <context key>` set (and overwritten) by the server, and rewrite friendly URLs to
`index.php?q=$1`. A bench is served the same way as every other installation.

Signing in needs an identity provider configured per context — see `docs/modx-sso-design.md`. Until
it is, `sso-login` answers 200 with a page quoting `SSO-00`, and nobody can sign in.

### Three things in that list that look like decoration and are not

**`chgrp -R www-data` first**, when PHP runs as a different user from the one who unpacked the zip.
Otherwise `core/cache` belongs to the wrong user and MODX runs **with no cache and no log, and cannot
tell you so** — the log it would write the complaint to is the thing it cannot write. The symptom is
an empty start page and not one error message anywhere.

**`< /dev/null` on the installer.** `cli-install.php` falls back to interactive prompts for anything
it thinks is missing, and on a non-tty stdin it blocks **silently and forever**. With stdin closed
it finishes in about a second.

**`07-regenerate-uris.php` must run last.** `02` turns `friendly_urls` on, but `uri` is a stored
column, not a derived one — skip 07 and every friendly URL 404s.

### What a correct install answers

For a **protected** context (`"protected": true` in the estate file), with nobody signed in:

    /                    302 -> /sso-login                     its home needs a signed-in member
    /sso-login           200                                   the support subtree is anonymous
    /<any real page>     302 -> /sso-login?returnUrl=/<page>   every page is protected
    /manager/            200
    /<no such page>      404

For an **open** context, `/home` (and every page under it) answers 200 to anyone.

## What you edit

**One file: the estate file that `MODX_ESTATE` names.** Its format is `setup/estate.example.json`.

    contexts, users, groups,    WHO this estate serves: its contexts and how they present
    admin_username              themselves, the people, their groups, and the name of the MODX
                                manager account the installer created. A protected context names
                                its `home` (setup/03 creates a page called `home` in every context).
    domains                     WHICH name each context answers on, per profile (prod / bench).

`setup/estate.py` loads that file and `setup/domains.py` reads its `domains`; neither is edited.

### The refusals, and why they are refusals

Each exits **before anything is committed**, so a refusal leaves the database as it was.

| If | Then |
|----|------|
| the estate file gives a context a domain and does not declare it under `contexts` | `estate.py` refuses at import — a context with a domain and no declaration would get no access model and serve its content to anyone |
| a protected context's `home` names no published page | `04` refuses, naming the context and the alias |
| `admin_username` (or any declared user) is not in the database | `04` refuses, and names the estate file's `admin_username` and `setup/config.xml` `cmsadmin` |
| no context has a host yet | `02` refuses — it cannot tell which environment it is writing for |

## Also true of stock MODX 3.2.4, not of us

`photo_profile_source` fails to install on a strict-mode MariaDB — the transport declares it with
`value: null` against a `NOT NULL` column — while `cli-install.php` prints *"Thank you for installing
MODX!"* and exits 0. **Read `core/cache/logs/install.config.*.log`; do not trust the exit code.**
Nothing here uses that setting.
