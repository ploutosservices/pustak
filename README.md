# MODx, managed as files

This repository is the software half of a multi-site MODx 3 installation: the elements (chunks,
snippets, plugins, templates) as files, the scripts that install and maintain a MODx database, and
the tests that check both. The content — documents and the estate's own declarations — lives in a
separate repository. `docs/modx-enhancement.md` describes every idea here and how they fit. This
is **pustak**, one of four parts; how MODx, pustak, the content (gyan) and the search (khojo) fit
together is in the estate repository's `README.md`.

Two decisions shape everything else.

## 1. The web server chooses the context, not MODx

A MODx installation serves several sites, each a MODx *context*. Stock MODx picks the context from
settings in its database (`http_host`, `site_url`) or from a hand-edited `config.context.php`. Here
it does neither: **nginx sets a request header naming the context, and MODx serves that context or
nothing.**

- `common/lib/EdgeContext.php` makes this true. The docroot's `config.context.php` is one line that
  requires it. It reads the `X-Tenant` header (`HTTP_X_TENANT`), which nginx sets and overwrites on
  every request, so a caller cannot choose it; it never reads the host name. A key the database has
  is served. No header, an unknown key, or MODx's own `mgr`/`web` gets a 404 with a fixed page, and
  MODx is not started.
- `tests/edge-context.php` holds that shut: a declared context is served; no header, an unknown or
  malformed key, `mgr` and `web` are not, and the host is never read. That the header cannot be
  forged is the web server's part — it overwrites whatever the caller sent.

So which name reaches which site is the web server's configuration, and adding a site to the
installation never needs a URL setting in MODx to be right first.

## 2. One program sets the environment

MODx keeps its configuration in database rows. A restore of production's database onto staging or
a development machine therefore brings production's identity with it — its host names, the
services it links to, how it signs people in. Here **one file per installation says what differs,
and one program writes it** after every restore and every new install.

- `core/config/application.php` in the installation (outside the database, so no restore touches
  it) carries a `settings` key: the system and per-context settings that differ by environment.
- `setup/apply-environment.php` makes this true. It reads those settings, writes each through MODx's
  own setting objects, refreshes the cache, and prints one line per value changed. `--check` writes
  nothing and exits 1 on any difference. It refuses a file with no `environment` or no `settings`.
- `setup/lib/ApplyEnvironment.php` is its pure half (read, compare, never print a secret), tested
  with no database by `tests/apply-environment.php`.
- A development bench renders the file with its own renderer; on other installations
  whoever provisions the server renders it. `docs/apply-environment.md` lists the keys it manages
  and why.

So after a restore or a new install the environment is set by running
`php setup/apply-environment.php`, and `--check` says whether it still holds.

## Install

On stock MODX 3.2.4-pl, with one file of your own to write — the estate file, copied from
`setup/estate.example.json`: **`docs/installation.md`** is the whole sequence, from the zip to the
answers a correct install gives. The in-MODX parts also come as one MODX Extra, **pustak**, built
by `tools/build-transport.php` and installed through Package Management.

## Tests

`bash tests/run-all.sh --before-apply` runs the suites that need no database, no web server and no
environment — what a deploy may run before it changes anything. `bash tests/run-all.sh` runs every
suite against a bench; `--requirements` asks each suite what an installation must provide for it.

## Licence

Apache License 2.0 — see `LICENSE`.
