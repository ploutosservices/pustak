# The MODx enhancement: every idea, and how they fit together

This document collects every idea in our enhancement of MODx in one place. For each idea it gives
the problem that caused it, how it works, how it connects to the other ideas, and where it lives in
the repository. It is written for a competent reader who has never seen this installation, and it is
the starting point for the README we will need if the enhancement is published as open source.

It points at files and does not copy them. Versions, counts, setting values and lists of names
belong to the code and the manifests, and those are what to read for them. Where this document and
a file disagree, the file is right and this document has a defect.

Other documents in `docs/` cover single subjects in depth: `HOW-IT-WORKS.md` (the traps),
`workflow.md` (the working loop and permissions), `installation.md`, `production-install.md`,
`upgrades.md`, `modx-sso-design.md`, `modx-storage-gate.md`, `tableRenderer.md`,
`apply-environment.md` and `content-vocabulary.md`. This document gives the overview and sends you
to them for detail.

---

## Contents

1. Terms used here
2. Three layers that stand on their own
3. The software carries no estate
4. Multi-tenant: the edge chooses the context
5. Multi-environment: one file per installation says what differs
6. Elements and documents are files in git, and git is the master
7. The content vocabulary
8. Sign-in: OpenID Connect per context, one gate
9. Access control: protected by default, declared once
10. Protected files from a storage service
11. Tables as data: tableRenderer and feedView
12. Sensitive values are never at rest in MODx (estate-specific)
13. Our maintenance code is an addition to the MODx package
14. Deploy by branch, behind a gate that touches nothing
15. Upgrading MODx
16. Installing from nothing
17. Restoring production data onto staging and a dev bench
18. Tests and the status report
19. Smaller ideas
20. How the ideas work together
21. What would be published and how
22. Open

---

## 1. Terms used here

| Term | Meaning in this document |
|---|---|
| **MODx** | MODX Revolution 3.x, the PHP content-management framework, as distributed by its maintainers. Called "stock" when unmodified. |
| **Context** | MODx's own partition of one installation: separate settings, resource tree and access grants. We use one context per tenant. |
| **Tenant** | One audience with its own site, for example a family site or a corporate site. |
| **Element** | A MODx chunk (HTML fragment), snippet (PHP called from a page), template or plugin (PHP bound to an event). MODx stores each one as a database column. |
| **Document** | A MODx page (a `modDocument` resource), also stored as a database row. |
| **Static resource** | A MODx resource that delivers a file instead of a page. |
| **Installation** | One MODx docroot together with its own database. |
| **Environment** | The role an installation plays: production, staging, or a development bench. |
| **Bench** | A disposable development installation on a developer's machine. |
| **Edge** | The web server in front of MODx (nginx, on every installation). |
| **Estate** | One owner's content and declarations: their contexts, people, groups, domains and documents. |
| **Estate file** | `estate.json` in the content repository, named to every script by the `MODX_ESTATE` variable. |
| **Seat** | The document tree in git (`seat/documents/`) and the scripts that move it to and from a database. |
| **Addition** | Our code that reads or writes MODx's tables directly (section 13). |
| **Install medium** | The docroot archive and database seed that bring up an installation (section 16). |
| **Deploy verb** | A job, run by the estate's operations tooling, that carries a committed ref to an installation. |

---

## 2. Three layers that stand on their own

**Problem.** A MODx site normally mixes three things: the framework, the site builder's code, and
the author's content. They are mixed in one docroot and one database. You cannot upgrade one, publish
one or restore one without touching the others.

**Idea.** Keep three layers, each with its own owner and its own repository or source:

| Layer | What it is | Where it lives | Who changes it |
|---|---|---|---|
| Stock MODx | The framework, with the pdoTools and SimpleSearch Extras | the MODx distribution; versions are pinned in `service.json` `ships` | upgraded only by MODx's own installer (section 15) |
| Our enhancement | Elements, the library, setup and maintenance scripts, tests | this repository (`modx`) | the developer |
| The content | The author's documents, the estate file and the install medium | the estate repository (`modx-estate`) | the author edits documents; the developer maintains the rest |

**How it works.** Stock MODx is not modified. The docroot `index.php` is byte-identical to the one
in the distribution. Stock `index.php` already reads a context key from an optional
`config.context.php`, and the only file of ours in the docroot is that one-line file (section 4).
Our PHP classes ship under `core/components/pustak/lib/`, which is a location MODx sets aside for
add-ons. An upgrade check confirms that the installed `core/` differs from the distribution only by
additions (`docs/upgrades.md`, Phase 1 step 4).

The author writes HTML plus the words listed in `docs/content-vocabulary.md` (section 7). The
author does not touch structure, access or templates as machinery. `docs/workflow.md`, "Three
contributors to the installation", records this split. The multi-context machinery is the
developer's and stays out of the author's view.

**Connections.** The layer boundary is what makes the other ideas possible: upgrades (15), the
addition review (13), publishing (21), and the rule that the software carries no estate (3).

**Where.** `service.json` (`ships`, `$not_shipped`), `../modx-estate/README.md`,
`docs/workflow.md`.

---

## 3. The software carries no estate

*(An idea the requested list did not name. It is the reason the enhancement can be published at
all.)*

**Problem.** The installer scripts used to hold one family's contexts and people written inline,
with resource ids that existed only in their database and an assumed admin account name. Software
written that way installs one estate and no other, and you cannot license it to anyone else.

**Idea.** The software holds the logic and the estate file holds the facts. Each script loads the
estate through one loader. Without an estate file the scripts install a generic empty estate, and a
malformed one makes them refuse instead of guessing.

**How it works.** `MODX_ESTATE` names the estate *file*, and the content checkout is taken to be the
directory that file sits in. `setup/estate.py` is the loader and holds no estate itself.
`setup/domains.py` turns the estate's `domains` into each context's host settings. The format is
`setup/estate.example.json`. A context that has a domain but is not declared, a declared user who is
missing from the database, or an unset variable each causes a refusal before anything is written.
`tests/estate-clean.sh` fails if an estate value (a real person, a real address or a credential)
reappears anywhere in the software, and it checks the loader's refusals in both directions.

**Connections.** Sections 2 and 21. The content-vocabulary test (7) checks the estate's pages
against the software's word list across this boundary.

**Where.** `setup/estate.py`, `setup/estate.example.json`, `setup/domains.py`,
`setup/estate-repo.sh`, `tests/estate-clean.sh`, `docs/installation.md` ("What YOU edit").

---

## 4. Multi-tenant: the edge chooses the context

**Problem.** One MODx installation serves several tenants, one context each. MODx has to know which
context a request is for. The usual approaches are a host-to-context map kept inside MODx, or URL
settings that MODx compares against the request's `Host`. Both put a fact owned by the network (which
name reaches which tenant) into the application. Both also break when a tenant answers on more than
one name, or on a port during development.

**Idea.** The edge decides and MODx obeys. The web server that matched the name sets an `X-Tenant`
header, overwriting any value the client sent, and MODx reads only that header. MODx never reads the
host.

**How it works.** Stock `index.php` requires `config.context.php` if it exists and uses its return
value as the context key. Our `config.context.php` is one line that requires
`common/lib/EdgeContext.php` (installed at `core/components/pustak/lib/`). `EdgeContext` reads the
header. It serves the context only if the database holds that context and it is not one of MODx's
own (`mgr` or `web`). Any other request, whether it has no header, an unknown key or a malformed
one, gets a fixed 404 page that ships beside the class, and MODx is never started for it. The
database is asked because MODx, when given a context it does not have, starts with no context and
fails later somewhere less clear. A bench is served the same way, by a web server that sets the header.

Two companions keep links right when a context answers on several names. The `edgeAddress` plugin
(event `OnMODXInit`) rewrites `site_url` and `http_host` for the current request only, and only when
the edge vouched for the context and the name is one of that context's own non-production names. It
writes nothing to the database. The `contextBase` snippet returns another context's address from
that context's own `site_url`, so no second copy of a context's address is kept as a setting.

**Connections.** Sign-in is configured per context (8) and access is granted per context (9).
Domain binding is part of every restore (17). This is one of the two upstream requests (21).

**Where.** `common/lib/EdgeContext.php`, `common/lib/no-one-here-20261012.html`,
`setup/config-context.py` (writes and checks the one line),
`common/plugins/edgeAddress`, `common/snippets/contextBase.php`, `setup/11-add-context.py`,
`tests/edge-context.php`.

---

## 5. Multi-environment: one file per installation says what differs

**Problem.** Production, staging and each dev bench are separate installations with separate
databases. They run the same elements, but a small set of values must differ: which environment this
is, the storage scope, the sign-in provider, each context's host, the addresses of neighbouring
services. MODx keeps all of these as rows in the database. A restore loads production's rows whole,
so every bench inherits production's identity until something rewrites it. This has really happened:
production's signing key reached a dev bench this way. The rewriting was spread over about six jobs,
each using its own source of values, and the survey of those jobs found defects caused by that
spread.

**Idea.** One file per installation, outside the database, says what differs. One program writes
it into the database.

**How it works.**

1. `core/config/application.php` is rendered per installation. On real installations infra's
   provisioning role renders it. On a bench, the bench's own renderer renders it from the
   estate file. Because it is not in the database, no restore copies it. It is also kept out of the
   docroot archive, and no MODx upgrade rewrites it (the upgrader does rewrite `config.inc.php`,
   which is why that file was rejected). It is under `core/`, which the web server denies.
2. The file holds `environment`, `settings` (system settings and per-context settings, as strings),
   and other per-installation facts such as where the installation's client certificate lives and
   the badge it presents. `common/lib/Application.php` reads it. A value that is not a string
   reads as unset, so a PHP boolean is a mistake.
3. `setup/apply-environment.php` starts MODx, reads `settings`, and writes each value through
   MODx's own setting objects, creating rows that are missing. It prints one line per change.
   `--check` writes nothing and exits 1 on any difference. The comparison is a pure function in
   `setup/lib/ApplyEnvironment.php`, so it is tested without a database. A key absent from the file
   is not managed. Rows whose value is another row's id are not managed either; the setup scripts
   derive those from the database.

**Status.** The program, its library, the bench renderer and the test are built. Two pieces are
infra's and pending (section 22): the production and staging renders do not yet carry `settings`,
and the restore and settings jobs do not yet run the program or drop their own literal writes.

The application PHP that MODx runs reads no environment variables. This is why settings must be rows
and per-installation identity must be a file, and never an environment variable on the web process.
Only the shell tooling reads `MODX_*` variables.

**Connections.** Restore (17) is the reason this exists. The status report (18) reports the
environment from this file and refuses rather than infer it from a hostname. Storage identity (10)
reads its certificate location from here. This is the other upstream request (21).

**Where.** `docs/apply-environment.md`, `setup/apply-environment.php`,
`setup/lib/ApplyEnvironment.php`, `common/lib/Application.php`,
`tests/apply-environment.php`, `tests/application-badge.php`, `service.json` `identity.$roles`.

---

## 6. Elements and documents are files in git, and git is the master

**Problem.** Every element and every page is a database column. Edits made in the manager leave no
history, cannot be reviewed, and are lost on the next restore. Two places that are both allowed to
change the same fact will drift apart.

**Idea.** Git is the master copy. The database is something the deploy produces. Edits are made in
exactly one place between syncs.

**How it works.**

- **Elements** live as files in `common/chunks`, `common/snippets`, `common/templates` and
  `common/plugins`. A plugin's events are declared in a `<name>.events` file beside it, and a plugin
  without one is refused. `import.py` loads elements into a database and `export.py` writes them
  back to files. The deploy verb **upserts by name**: it matches each file to a row by name and
  inserts a row when no name matches. **Renaming an element therefore deploys it as a new row and
  leaves every page, template and event binding pointing at the old one.** The verb prints
  `inserted` for a name it did not find, and on a name that should already exist that word is the
  warning.
- **The library** (`common/lib/*.php`) consists of plain classes, installed under
  `core/components/pustak/lib/` by a separate mechanism from the elements. Elements and library
  can therefore be at different versions on an installation. Each element carries the code it
  runs, and the class is the unit that gets tested. We do not build runtime negotiation between the
  two.
- **Documents** are written to files as `seat/documents/<context>/<alias>-<id>.html` in the content
  repository by `seat/pull.py`, and written back by `seat/push.py`, which works on a bench only.
  `seat/seat-map.json` is the shared map of which table and column each file holds. Deleted pages
  are not written out, so deleting a page shows up in the diff. Static resources and element copies
  under `seat/` are reference-only and ignored by git. `pull.py` refuses to run over uncommitted
  edits.
- **Canonical forms.** MODx stores a body with no trailing newline, and editors write one.
  `canon.py` defines the disk form and the database form as inverses, so database to file to
  database is a fixed point. Every writer imports it, and the shell deploy verb follows the same
  rule. Without this, every correct deploy would report drift.
- **Where a new page is born.** A new page is created in the manager on production and then pulled
  into git, where it is edited from then on. The page id is production's fact and appears in the
  file name, so building a create path from git would give that id two masters. Document deploys
  edit existing pages only.
- **The pull-direction guard.** A pull from production can silently revert work that git holds
  and production does not have yet. `setup/pull-direction.py` sorts every difference after a pull.
  A file whose new content matches an earlier version of that same file means git is ahead, and the
  script exits 1 and names the commits that would be reverted.
- **Deploy from a ref.** `setup/deploy-local.sh` deploys a bench from a fetched git ref, the same
  way the production verbs do. Preview (from the working tree) and deploy (from a ref) are separate
  acts.

**Connections.** The vocabulary (7) guards the names that pages call. Deploy by branch (14) carries
these files. The status report's `?report=elements` (18) is how you check that a deploy landed.

**Where.** `common/`, `import.py`, `export.py`, `canon.py`, `setup/pull-direction.py`,
`setup/deploy-local.sh`, `../modx-estate/seat/pull.py`, `../modx-estate/seat/push.py`,
`../modx-estate/seat/seat-map.json`, `docs/workflow.md`, `docs/HOW-IT-WORKS.md` section 1,
`tests/element-body-db-form.py`, `tests/element-names-bind.sh`, `tests/pull-direction.sh`.

---

## 7. The content vocabulary

**Problem.** A page calls elements by name (`[[$cardStart]]`, `[[!tableRenderer]]`). When the
developer renames or removes one, the author's page breaks, and nothing says so until a reader sees
it. The author also has no single list of what they may write.

**Idea.** Publish the words a page may use as a contract. We may change the code behind a word, but
the word and its parameters keep working.

**How it works.** `docs/content-vocabulary.md` is a table with one row per word: its kind (chunk,
snippet, field, setting, link or placeholder), whose it is (ours, MODx's, or an Extra's), its
parameters, and what it renders. The test reads that table. `tests/content-vocabulary.py` checks two
things: every word marked as ours has its element in `common/`, and every tag in the estate's pages
is a word in the list. The first check needs only this checkout and runs in the deploy gate (14).
The second needs the estate file.

**Connections.** This is the boundary between layers 2 and 3. The upsert-by-name hazard (6) is
what it protects against. tableRenderer (11) is the largest single word.

**Where.** `docs/content-vocabulary.md`, `tests/content-vocabulary.py`.

---

## 8. Sign-in: OpenID Connect per context, one gate

**Problem.** MODx's form login (the Login Extra) keeps its own passwords, separate from the identity
readers already have elsewhere. One MODx
serves several contexts, and some are on public names and some on private ones. A public identity
provider will not redirect back to a name it cannot resolve, so one provider cannot serve every
context. Benches must never sign anyone in against the real provider.

**Idea.** Replace form login with OpenID Connect, authorization-code flow, chosen per context. Sign-in
only establishes who the reader is. Whether they may see a page is still decided by MODx's own
access control, and a valid sign-in is never a grant in itself. This is "one gate": the person must
already be a MODx user whose profile email is the verified address. Unknown addresses are refused by
default, and access is managed in the manager with no second list.

**How it works.** Each context has four pages, created under its anonymous `support` subtree by
`setup/12-sso.py`:

| Page | Element | Job |
|---|---|---|
| login entry | `GoogleSSOStart` | a branded sign-in card; its button stores state, nonce and the return path in the session, then redirects to the provider |
| callback | `GoogleSSOCallback` | checks state, exchanges the code over TLS, validates the token claims, requires a verified email, maps it to a MODx user, opens the session in this context, returns to the stored same-site path or the `userHome` router |
| logout | `GoogleSSOLogout` | ends this context's session only, not the reader's provider account |
| refusal | `unauthorizedNotice` | explains why a page was refused (section 9) |

`common/lib/SsoConfig.php` decides the provider for each context. MODx's `getOption` already
resolves a context setting over a system setting, so per-context settings are the whole mechanism.
Every context signs in at the estate sign-in door: production at production's door, a bench or
staging at the non-production door's realm for that ground, and the suites refuse to drive any
other. Both halves of a sign-in read the same class, so the
start and the callback cannot disagree about the provider, the client or the redirect address. Token
verification is a pinned, vendored copy of the bookkeeping system's verifier
(`common/lib/GoogleToken.php`, recorded in `ships`), not a second implementation. The `ssoRenew`
plugin (event `OnWebPageInit`) renews the reader's token on the server shortly before it expires. If
the renewal is refused, the session ends. If the provider cannot be reached, the page continues with
the token it has. `loginWidget` is the sign-in and sign-out control in the navigation bar.

The Login Extra is not installed and must not be reinstated.

**Connections.** Access control (9) decides what a signed-in reader sees. Protected files (10) use
the same access control. Render-time fetches as the reader (11, 12) forward the verified token.
Restore (17) loads production's rows, so the bench's sign-in setup must re-point a bench at the dev realm.

**Where.** `docs/modx-sso-design.md`, `common/snippets/GoogleSSO*.php`,
`common/snippets/loginWidget.php`,
`common/lib/SsoConfig.php`, `common/lib/GoogleToken.php`, `common/plugins/ssoRenew`,
`setup/12-sso.py`, `tests/sso-*.{sh,php}`, `tests/auth-end-to-end.sh`,
`tests/signing-out-really-signs-out.php`.

---

## 9. Access control: protected by default, declared once

*(The requested list mentions "protected contexts". The sources show more than that, so it has its
own section.)*

**Problem.** MODx protection is opt-in for each resource. A resource in no resource group is
public. Pages created in the manager were public until a job next ran. Protecting the wrong page,
such as the sign-in page itself, locks everyone out in a redirect loop. An access model written down
in two places has already been found false.

**Idea.** Every page and every file is protected unless it is in the context's anonymous `support`
subtree or is a declared machine door. The model is declared once and enforced at save time.

**How it works.**

- `setup/access_model.py` is the one declaration: user groups and the contexts each may enter, the
  resource groups for pages and files, and the machine doors. `setup/04-access-control.py` writes
  it into a database (context grants, resource-group grants, memberships) and also renders it into
  a system setting that the plugin reads.
  `setup/verify-file-protection.py` checks, read-only, that a database still matches the
  declaration, and it is the basis of a regular monitor.
- The `protectOnSave` plugin (on save, undelete and duplicate) applies the same rule to one
  resource at the moment it is saved, so a new page is never public in between. It identifies the
  `support` subtree mechanically and does nothing if it cannot resolve the declaration. It never
  blocks a save.
- `userHome` is each context's start page. It is a router: it sends a signed-in reader to their own
  home in this context (set in the manager), and otherwise to the context default. It tries
  candidates in order and logs loudly if none resolves, because blank output had hidden this failure
  before.
- `unauthorizedNotice` handles a signed-in reader who is refused. Without it, that reader loops
  between sign-in and the start page. With it, they are told the account is not a member of this
  area and offered sign-out. Nothing about the estate's shape is revealed.
- Menus (`pdoMenu` with permission checks) list only pages the reader may list, so navigation
  follows access with no separate logic.
- `setup/16-modxsite.py` creates a context that is never served and holds the system-wide fallback
  pages, so system defaults do not borrow a served context's pages.

**Connections.** Sign-in (8) supplies the identity. Files (10) are protected by the same model. The
status report's door (18) is a declared machine door.

**Where.** `docs/modx-login-design.md` (the underlying MODx access model), `setup/access_model.py`,
`setup/04-access-control.py`, `setup/verify-file-protection.py`, `common/plugins/protectOnSave`,
`common/snippets/userHome.php`, `common/snippets/unauthorizedNotice.php`, `setup/16-modxsite.py`,
`tests/protect-on-save.sh`, `tests/context-protection.sh`, `tests/verify-protection-wrong-class.sh`,
`tests/unauthorized-names-itself.php`.

---

## 10. Protected files from a storage service

**Problem.** A static resource backed by a file under the web root is served by the web server
before MODx runs, so access control is skipped. An unguessable file name only hides the file: a
leaked URL works forever.

**Idea.** The bytes live in a separate storage service, outside the web root. Every fetch goes
through MODx and its access control, and MODx streams the bytes on the server's side.

**How it works.**

- **Model.** A protected file is a native MODx static resource. Its native `content_type` field
  holds the real type, and its `content` field holds the sha1 of the bytes. That one value is both
  the pointer and the marker that the file is stored remotely, because a real path can never be a
  bare 40-character hex string. Files on disk and files in storage coexist.
- **Download.** The `deliverStorageFile` plugin (event `OnWebPagePrerender`) ignores anything that
  is not a static resource whose content is a sha1. For one that is, it checks view permission again
  and streams the bytes from the storage service by sha1. MODx core has already enforced access in
  the request phase, so an anonymous request gets no bytes. The browser never sees a storage
  address.
- **Upload.** An editor uploads into a `Protected` media source rooted in `core/protected/`, which
  the web server denies, and saves a static resource that points at the file. The
  `storeProtectedFile` plugin then pushes the bytes to storage, checks storage's sha1 against its
  own, sets `content` to the sha1, sets the real type, and deletes the disk copy last. A failure
  never blocks the save, and the file stays protected. `store-file.py` does the same for a single
  file from a shell.
- **Identity.** MODx proves who it is to storage with the installation's client certificate, not a
  bearer token, because a token in a settings row would be copied by every restore.
  `common/lib/StorageIdentity.php` makes that decision and is testable without MODx. The
  certificate location comes from `application.php` (5). The files are re-read on every call
  because the certificate is renewed in place.
- **Why a plugin.** We rejected a custom resource class because MODx 3 custom resource classes are
  unreliable (upstream issue modxcms/revolution#14759). We rejected a core edit because the next
  upgrade would silently remove it. The plugin header holds the decision and a compatibility watch
  list for each upgrade.

**Connections.** Access control (9) protects files as it protects pages, with one set of rules. The
environment file (5) supplies the certificate location. The status report (18) reads the storage
settings without exposing their values.

**Where.** `docs/modx-storage-gate.md`, `common/plugins/deliverStorageFile`,
`common/plugins/storeProtectedFile`, `common/lib/StorageIdentity.php`, `store-file.py`,
`setup/13-storage-gate.py`, `setup/20-protected-files.py`, `setup/14-storage-upload.py` and
`setup/15-storage-apply.py` (the one-time migration), `tests/protected-absorb.sh`,
`tests/storage-identity.php`.

---

## 11. Tables as data: tableRenderer and feedView

**Problem.** A table typed as `<td>` cells stays text forever. Nothing can tell which column is an
email address and which is a phone number. Search then returns a name without the means to reach
the person, and two tables can label the same number differently with nothing able to say which is
right.

**Idea.** Write the data and name the fields, and let a snippet draw the table. What is shown and
what is known become separate decisions: a field left off the screen is still in the data for
search and other readers.

**How it works.** The data sits in the page inside `<script type="application/ld+json" id="...">`.
A browser neither displays nor runs that block, so if the snippet fails the reader sees a missing
table and never raw JSON. The data can also come from a chunk (`&json`) or from a URL fetched at
render time (`&url`). Schema.org field names are preferred where they fit. Parameters choose and
label columns and add links, badges, tooltips, local-time conversion, row classes and grouping. Two
table classes add client-side sort and filter, and "exceptions first". A call that fetches data
must be uncached (`[[!tableRenderer`), and a cached call is refused, because a cached fetch would
serve stale data indefinitely. The snippet never breaks a page: on failure it renders nothing and
leaves an HTML comment that names the reason. It adds no styling, no reordering and no guessing.

`&auth` fetches **as the reader**. A signed-in reader's identity travels with the request, the other
system decides what that person may see, and with nobody signed in nothing is requested at all.

`feedView` is one page that shows any feed, chosen by name from an index whose address is a system
setting. Each feed describes itself (title, columns, rows or groups), so a new feed needs no new
page. The reader supplies a name and never an address, so the server cannot be made to fetch
arbitrary URLs.

**Connections.** It is part of the content vocabulary (7). `&auth` depends on sign-in (8). The
pattern of fetching as the reader is what section 12 relies on.

**Where.** `docs/tableRenderer.md`, `common/snippets/tableRenderer.php`,
`common/snippets/feedView.php`, `common/templates/page.feeds.html`,
`docs/table-decorator.css.proposed`, `tests/tableRenderer-auth.php`.

---

## 12. Sensitive values are never at rest in MODx (estate-specific)

*This is a principle of this estate. The mechanism depends on the estate's bookkeeping system, so it
is not part of what would be published (21).*

**Problem.** Pages written over years held bank account numbers as plain text. Any tool that reads
MODx (AI search, a backup, a database dump, a cached page) can surface them. Deleting the strings
once protects only against the tools that exist on that day.

**Idea.** The page stores an identifier and never the value. The value is fetched at render time
from the bookkeeping system, as the reader, so it is never at rest in MODx. An absent value also
protects against tools that do not exist yet.

**How it works.** A page carries an empty element with a bookkeeping id
(`<span class="bird" kuberid="...">`). The bookkeeping-names plugin (event `OnWebPagePrerender`) collects
every empty element that carries an id. It makes one request with the reader's own verified token
and fills in the names. With no signed-in, verified reader, no request is made and the cells stay
blank. A token that fails verification ends the MODx session. The minting happens in a plugin and
not in a snippet because content can call a snippet, and then anyone able to edit a page could mint
a credential. The folder search snippet uses the same as-the-reader pattern to ask the estate's search service
about a folder's own context.

**Where.** `service.json` `$why_the_numbers_are_not_here`, the bookkeeping-names plugin and its
setup script, the folder search snippet, `tests/kuber-google-token.php`, `tests/auth-end-to-end.sh`.

---

## 13. Our maintenance code is an addition to the MODx package

**Problem.** MODx has no API for a migration, a seed edit, a check, a repair, a backup or a
restore. Code that does these must reach MODx's tables directly. If that code is scattered and
unnamed, nobody can say what touches the schema, and nobody checks it against a new MODx release.

**Idea.** The owner ruled on 2026-10-07 that this code is an addition to the MODx package, not a
second route into it. The addition is named by path. It is the only code allowed to reach MODx's
tables by SQL. It is reviewed against every new MODx version.

**How it works.**

1. `service.json` `identity.layer` lists the addition's paths (the setup scripts, `changes/`, the
   tests, `export.py`, `import.py`, `doors.py`). `identity.store_clients` lists the database clients
   and `identity.store_key` lists the credential's variable. The content repository declares its
   seat scripts in the same way in its own manifest.
2. `p12-import.py` walks every file git tracks. Outside the layer it refuses any import or call of
   a declared client and any read of the key. It reads the manifest and keeps no list of its own,
   and it prints the layer so that widening the layer to turn the gate green is visible. The same
   bytes ship in every repository that carries the gate.
3. `service.json` `addition.reviewed_against` names the MODx version the addition was last reviewed
   against. `tests/addition-reviewed.py` fails while that differs from the shipped version in
   `ships`. Because it is in the deploy gate (14), a MODx version the addition has not been reviewed
   against does not deploy.
4. The review is `docs/upgrades.md` Phase 1 step 14: read the release's schema and processor changes
   against the tables the addition uses, run the suites, then move `ships` and `reviewed_against`
   together in one commit.

**Connections.** Upgrades (15) are when the review happens. The deploy gate (14) enforces it. The
three layers (2) are what make "addition" a meaningful word.

**Where.** `service.json` (`identity.layer`, `$layer_why`, `addition`, `$addition`),
`p12-import.py`, `p12-import.py.source`, `tests/addition-reviewed.py`, `docs/upgrades.md`,
`changes/`, `setup/migrations/`.

---

## 14. Deploy by branch, behind a gate that touches nothing

**Problem.** Pushing to `master` once deployed production, and the routing table that decided this
lived in a different repository, so nothing in the working tree warned anyone. A deploy runs on the
installation it deploys to, and on production that installation holds production's data, so a test
suite run there could write to production.

**Idea.** Both repositories have three branches. Work lands on `master`, which deploys nothing. A
merge to `staging` deploys staging, and a merge to `production` deploys production. Before applying
any element, the element deploy runs a fixed set of suites that can reach nothing but the checkout,
and it refuses to apply if any of them is red.

**How it works.**

- Promotion is `git push origin master:staging`, then `git push origin staging:production`. Each
  must fast-forward. In this repository a merge carries element bodies and the access-control
  converge. In the content repository it carries page bodies. The verbs are listed in
  `service.json` `deploys`, and `tests/deploys-declared.sh` checks that list against the estate's
  job list and routes in both directions. Each deploy applies everything committed at the ref,
  including other people's committed work.
- `tests/run-all.sh --before-apply` runs its `before_apply` list. Each suite runs in an empty
  environment (only `PATH` and a temporary `HOME`), so no database, socket or `MODX_*` variable can
  reach it. A refusal counts as red. A suite is added to the list only after it has passed with no
  network, with the socket hidden and with no variables, and only if it names no database, socket,
  container, docroot or URL in its own text. `tests/before-apply-touches-nothing.sh` proves the
  first condition on every bench run. The element deploy verb (infra's) checks that the mode exists
  in the tree before running it, refuses on red, and applies nothing in that case.
- What is not a deploy: a MODx upgrade, a schema change, a SQL migration, or installing an Extra.
  Infra does these on the installation, following the runbooks (`docs/workflow.md`, "Nobody may").

**Connections.** Files in git (6) are what gets deployed. The vocabulary (7) and the addition review
(13) are suites in the gate. The status report (18) is how you read the result.

**Where.** `docs/workflow.md` ("Deploying is MERGING", "Nobody may"), `service.json` `deploys`,
`tests/run-all.sh`, `tests/before-apply-touches-nothing.sh`, `tests/deploys-declared.sh`.

---

## 15. Upgrading MODx

**Problem.** MODx's installer can exit 0 and print "Installation finished" while its log records a
failed insert, which leaves a new setting missing. It also rewrites `config.inc.php` and every
`config.core.php` it finds. Without a recorded before-state, "it still works" is only an opinion.

**Idea.** Rehearse the upgrade on a bench restored from production. Capture a baseline and compare
afterwards. Treat the install log, not the exit code, as the evidence. Write every surprise back into
the runbook. Infra applies the upgrade to staging, then to production, after a mandatory backup.

**How it works.** `docs/upgrades.md` is the runbook. In short:

- Phase 0: find the target from upstream's tags. Upstream publishes tags, not releases. Diff the old
  and new distributions to see what actually changes.
- Phase 1, on the bench: restore, then capture a baseline with `setup/upgrade-baseline.py capture`.
  It records the version from two sources, the tables, row counts and the objects we write. Save
  signed-in copies of sample pages (`setup/upgrade-sample-pages.sh`) and the standing checks. Copy
  the new `core/` and `setup/` over the old, without deleting, after confirming the tree is stock
  plus additions. Hash the files that must survive. Run the installer. Read every log file newer
  than the run (no new log file means no error). Restore `config.inc.php` byte for byte except the
  install time. Delete `setup/`. Clear the cache. Compare with `setup/upgrade-baseline.py compare`,
  which reports every difference and judges none, so each one must be explained. Check sign-in.
  Finish with the addition review (13).
- A failure found in rehearsal becomes a migration in `setup/migrations/`. Extras are upgraded in
  the same window as the core.
- Phase 2: infra applies the same steps to staging and then production. Phase 3: regenerate the
  install medium as a matched pair (16).

**Connections.** The addition review (13), the install medium (16), restore (17), and the test
suite, which serves as the regression test (18).

**Where.** `docs/upgrades.md`, `setup/upgrade-baseline.py`, `setup/upgrade-sample-pages.sh`,
`setup/migrations/`, `setup/patches/`, `setup/modx-snapshot.sh`.

---

## 16. Installing from nothing

**Problem.** The estate was migrated from older sites and had never been installed from scratch, so
nobody knew whether the software could install anyone else's site. The first attempt found a
lockout: the sign-in page was protected, so nobody could sign in.

**Idea.** There are two paths, and both are scripted. **From nothing:** install stock MODx and run
our scripts in order. This is what an outsider would do. **From the install medium:** load a matched
docroot archive and database seed. This is how a known estate is rebuilt.

**How it works.**

- **From nothing** (`docs/installation.md`). Use the full MODx distribution, which contains
  `index.php`, `manager/` and `connectors/`. The "advanced" distribution contains only `core/` and
  `setup/`, and our current install guide uses it for upgrades only. Fix group ownership first,
  otherwise MODx runs with no cache and no log and cannot report it. Run the CLI installer with
  standard input closed, otherwise it can hang silently. Install pdoTools, SimpleSearch and the
  pustak package (it carries the templates, which the setup scripts find by name), then run
  `setup/01`, `03`, `04`, `12`, bind the domains, `02`, and `setup/07-regenerate-uris.php` last,
  because URIs are a stored column. Write `config.context.php`. The guide lists the responses a correct
  install gives. The only file an installer edits is the estate file (3).
- **From the install medium** (`docs/production-install.md`). The content repository holds
  `install/modx-docroot.tar.gz` and `install/modx-seed.sql.gz`. The archive is third-party software
  at a version (MODx plus the two Extras, extracted), with machine config, cache, the installer, our
  library, `application.php` and `config.context.php` all excluded. It is not an archive of record:
  if it is lost, rebuild it. The seed is a full dump with secret settings excluded. The two are a
  matched pair, regenerated together from one bench (`setup/regenerate-docroot.sh`,
  `setup/regenerate-seed.sh`). `setup/load-seed.sh` loads the seed, binds the profile's domains and
  verifies them as one act, because a load that skipped the binding once left production answering
  on bench names. `setup/make-current.sh` builds a bench from both artefacts and refuses if the
  repository has uncommitted changes or the database already holds data.

**Connections.** The estate file (3), the edge file (4), the environment file (5, applied last), and
upgrades (15), which regenerate the pair.

**Where.** `docs/installation.md`, `docs/production-install.md`, `setup/RUNBOOK.md` (the original
migration replay), `setup/config.xml`, `setup/install-extras.php`, `setup/0*.py`–`setup/2*.py`,
`setup/load-seed.sh`, `setup/make-current.sh`, `setup/regenerate-*.sh`,
`setup/apply-environment.php`.

---

## 17. Restoring production data onto staging and a dev bench

**Problem.** Staging and benches need production's content to be realistic. A restore copies
everything, including production's identity, hosts, sign-in provider and storage scope. A restore
also regenerates the files in the working tree from the database, which can overwrite committed work
that is newer than the dump.

**Idea.** Production is only ever read. After every restore, each per-environment fact is reapplied
by a named step, and the working tree is checked before anything is committed.

**How it works.** The estate's operations verbs do the restore (the bench restore and the staging
refresh, both outside this repository). Production is read through a dump door with the caller's own
credential. After loading, the following must be reapplied:

| What | By | Why |
|---|---|---|
| Context hosts | `setup/apply-environment.php` from infra's derivation (the bench's own renderer on a bench); `apply-environment.php --check` checks | otherwise the copy links to, and answers for, production's names |
| Sign-in provider | the bench's sign-in setup (12-sso.py pointed at the door's dev realm) | a copy must not sign anyone in at production's door |
| Environment settings | today, settings passes and literal writes inside infra's verbs; once section 5 lands, `setup/apply-environment.php` alone | production's rows describe production |
| Elements at git's ref | `setup/deploy-local.sh` (bench) | the dump may be behind git |
| The working tree | `git status`, then `setup/pull-direction.py` | the regenerated tree may revert newer work |
| Secrets | from the environment or vault, never from the seed | the seed excludes them on purpose |

Then clear the cache (`clear-cache.php` keeps the error log while it clears). A staging page deploy
fails if production gained a page after staging's last refresh, so refresh staging before merging
such a page.

**Connections.** This is why section 5 exists. Pull-direction (6) is the guard. `make-current.sh`
(16) rebuilds from the medium instead of from production.

**Where.** `docs/workflow.md` (the prod-to-dev loop, the download guard), `docs/apply-environment.md`
(the survey of what differs), `setup/12-sso.py`,
`setup/bench-open-reading.py` (a bench reachable with no sign-in, reversible),
`setup/deploy-local.sh`, `setup/pull-direction.py`, `clear-cache.php`.

---

## 18. Tests and the status report

**Problem.** Several of these features fail silently by design. A page that cannot establish its
reader renders blank, and blank is also the correct output for nobody signed in. The developer has
no shell on production and no way to see an installation's state without one.

**Idea.** Tests that refuse rather than degrade, are themselves shown failing before they are
trusted, and report "could not check" separately from "passed". The installation also reports its
own state through one machine door.

**How it works.**

- **The suites.** `tests/run-all.sh` runs every suite in its list and gives one verdict, with
  refusals counted apart from passes and failures. `--requirements` asks the suites what an
  installation must provide. Bench suites pin the host they address, clean up after themselves,
  and refuse anything that looks like production. The one suite that breaks access control on
  purpose to prove the monitor sees it refuses any installation that is not a bench. `tests/lib.sh`
  holds the shared helpers. Its matching avoids `grep -q` in a pipe, which caused false failures.
  Its cache clear waits out the opcache revalidation window, during which a setting that is in the
  database can read as empty over HTTP.
- **The status report.** `/actuator/info` is a MODx page in the platform context that calls
  `[[!actuatorInfo]]`, uncached and refused if cached. It is reached with a client certificate:
  nginx verifies the chain and sets the caller's identity, and the snippet admits only the callers
  listed for each question. It is exempt from page protection as a declared machine door. Reports:
  requirement verdicts (verdicts, never values), environment, commit and MODx version, with the
  version taken from two sources so that a disagreement shows. `?report=settings` returns an
  allow-listed set. `?report=elements` gives the name, length and sha1 of every element, which is
  how a deploy is checked. `?report=log` returns only lines that our own elements wrote, matched by
  marker, so nothing we did not write can appear. The verdict logic is `common/lib/Actuator.php`
  and the log reader is `common/lib/Diagnostics.php`, both testable without MODx.
- **Doors declared.** `doors.py` generates, from each element's own source, the list of doors and
  who may call each. It counts a check only when the element also refuses on it. It found that MODx
  has exactly one door of its own; everything else is a page under MODx access control.
  `service.json` `identity.routes` declares that one row.
- **Failures name themselves.** A refusal shown to a person or written to the log carries its
  reason. `tests/failures-name-themselves.sh` checks this.

**Connections.** Every section has suites. The before-apply subset is the deploy gate (14). The
suite is the regression test for upgrades (15).

**Where.** `tests/README.md`, `tests/run-all.sh`, `tests/lib.sh`, `common/snippets/actuatorInfo.php`,
`common/lib/Actuator.php`, `common/lib/Diagnostics.php`, `docs/actuator.openapi.json`,
`tests/actuator-*.php`, `tests/diagnostics.php`, `doors.py`, `docs/HOW-IT-WORKS.md` sections 4 and 5.

---

## 19. Smaller ideas

Each of these is real, but none needs a full section.

| Idea | Problem it solves | Where |
|---|---|---|
| A guard on settings passes | a setup pass that empties a setting rolls back and exits 1 instead of committing | `setup/settings_guard.py`, `tests/settings-guard.py` |
| Renaming a context is a verb | a context key is copied by string into many tables with no foreign key; the verb derives the list of places | `setup/21-rename-context.py`, `setup/migrate-estate-keys.py` |
| The environment marker in the title bar | each installation shows its environment's word and colour; an unset value shows as development, not as production | `setup/02-system-settings.py`, `common/chunks/topNavBar.html` |
| A self-maintaining jump list | in-page navigation built from the page's own section headings | `common/snippets/jumpNav.php`, `common/chunks/sectionHead.html` |
| Strict HTML for documents | every document parsed as strict HTML5, and fixes applied only where they cannot change what a browser renders | `setup/html-strict-report.py`, `setup/html-strict-fix.py` |
| Every tag resolves | every `[[...]]` in pages and elements is checked against the database | `setup/tag-resolve.py` |
| Application badge | MODx identifies itself to other services from `application.php`; if absent, the header is omitted | `common/lib/Application.php`, the bookkeeping-names plugin |
| Seed without secrets | secret settings are excluded from the dump, and the script refuses a database that looks like production | `setup/regenerate-seed.sh` |
| Snapshots | a hashed file list plus a diff-friendly database dump, before and after any step | `setup/modx-snapshot.sh` |
| A local patch to an Extra | a defect in an Extra recorded as a patch file with its reason | `setup/patches/` |
| The application's own name and mark | the app is called Saraswati and wears a veena, chosen by the owner (a symbol, not a figure, so it suits every tenant's site); the estate's shared pages keep the estate's bird mark; a context with its own logo keeps it; the mark lives in a new dated CDN directory because the CDN is immutable for a year | `common/chunks/topNavBar.html`, `common/chunks/Bootstrap.5.Head.html`, `common/chunks/Bootstrap.5.googleLogin.html`, `common/snippets/unauthorizedNotice.php`, `common/snippets/GoogleSSOStart.php`; the files under the CDN's `brand/20261007-veena/` |

---

## 20. How the ideas work together

### A request, end to end

1. The edge matches the name, sets `X-Tenant`, and terminates TLS (4).
2. Stock `index.php` requires `config.context.php`. `EdgeContext` returns the context, or the 404
   page for an unknown tenant (4).
3. `edgeAddress` adjusts this request's links if the name is a bench or staging name (4).
   `ssoRenew` renews the reader's token if it is near expiry (8).
4. MODx access control decides whether the reader may load this page or file. If not, they get the
   sign-in entry or `unauthorizedNotice` (8, 9).
5. The page renders. Words from the vocabulary expand (7). tableRenderer draws tables from data,
   fetching as the reader where asked (11).
6. Before output, the bookkeeping-names plugin fills identifiers with values fetched as the reader (12), and
   `deliverStorageFile` streams a protected file's bytes from storage (10).

### A change, end to end

1. Edit a file in `common/` or `seat/documents/` (6). Words must be in the vocabulary (7).
2. Run the suites on a bench (18). Preview with `import.py` or `seat/push.py`, or deploy the bench
   from a ref (6).
3. Commit to `master`, which deploys nothing (14).
4. Promote to `staging`. The gate runs and elements, access and pages deploy. Check with
   `?report=elements` (14, 18).
5. Promote to `production` in the same way.

### Which facts live where

| Fact | Its one home |
|---|---|
| which tenant a name reaches | the edge's configuration (outside these repositories) |
| which contexts, people, groups and domains an estate has | the estate file (3) |
| what differs between environments | `core/config/application.php` (5) |
| element bodies | `common/` (6) |
| page bodies | `seat/documents/` in the content repository (6) |
| page ids and new pages | production's database (6) |
| who may see what | `setup/access_model.py` (9) |
| the words a page may use | `docs/content-vocabulary.md` (7) |
| which code may reach MODx's tables | `service.json` `identity.layer` (13) |
| which MODx version the addition was reviewed against | `service.json` `addition` (13) |
| sensitive figures | the bookkeeping system, never MODx (12) |
| protected file bytes | the storage service, keyed by sha1 (10) |

---

## 21. What would be published and how

### What would be published

| Part | Form | Contents |
|---|---|---|
| **The management repository** | a fresh public git repository | `setup/` (install sequence, access model, verifiers, seed and docroot builders, restore helpers, `apply-environment.php` and its library, the upgrade tooling), `import.py`, `export.py`, `canon.py`, `p12-import.py`, `doors.py`, `clear-cache.php`, `tests/`, and the documents in `docs/` that describe software rather than this estate |
| **A MODx Extra (transport package)** | a package installable through MODx's Package Management | the in-MODx parts: the vocabulary chunks (cards, sections, folder pages, head), `tableRenderer` and `feedView`, the sign-in snippets with `SsoConfig`, `GoogleToken` and `ssoRenew`, `userHome`, `unauthorizedNotice`, `loginWidget`, `jumpNav`, `contextBase`, the storage gate plugins with `StorageIdentity`, `protectOnSave`, `edgeAddress`, `EdgeContext` and the 404 page, and `actuatorInfo` with `Actuator` and `Diagnostics`, and the page templates with the template variables they read (`pagecontent`, `initjs`) |
| **Upstream request: environment configuration** | a comment on modxcms/revolution issue #16766 | a per-installation file outside the database, applied by one program, so that a restore cannot carry one environment's identity into another (section 5) |
| **Upstream request: context by header** | a new issue on modxcms/revolution | stock `index.php` already reads `config.context.php`; propose that core can take the context from a header the edge sets and overwrites, refusing contexts the database lacks (section 4) |
| **The install guide** | the README and `docs/installation.md` | install from a stock distribution with the Extra and the scripts, with only an estate file to edit |

### What must be removed first

1. **The owner's name**, in prose, in docblocks, in quoted rulings and in context keys used as
   examples.
2. **Internal hostnames.** Names in the estate's private zone appear in code comments, tests and
   defaults (for example the storage service's default base URL), and so do the private and public
   domains of the estate's sites.
3. **Real email addresses and real people's details.** These include example data in docblocks and
   docs: the tableRenderer examples carry a real contact.
4. **History.** Publish from a fresh repository with no git history. An old database password is
   in this repository's history (`setup/RUNBOOK.md` still shows the bench credentials of the
   original replay), and history cannot be cleaned reliably.
5. **Ticket and record numbers** in comments, which mean nothing outside the estate. Replace them
   with the reason they stand for.

### What stays private

- The bookkeeping integration: the bookkeeping-names plugin and its setup script, the `&auth` minting
  configuration that names the bookkeeping system, and `GoogleToken.php` as vendored from it. The
  generic as-the-reader pattern can be described without it.
- The folder search snippet (it depends on the estate's search service).
- The estate's operations verbs and provisioning role (infra's), the migration-era scripts that
  name the source sites (`setup/05`, `06`, `08`, `09`, `17`, `18`, the boundary audit and
  link-repair scripts, the id map, the migration manifests), and the estate repository as a whole.
- The trust-table and other content chunks in `common/chunks` that are the author's content (22).

---

## 22. Open

1. **Infra's two asks for the environment file**, both pending: the
   provisioning role's `application.php` template gains `settings`, and the restore, settings and
   domain-binding verbs run `setup/apply-environment.php` and drop their literal writes and
   environment variables. Until both land, a restore is still put right by several jobs (section
   17).
2. **The README claim that waits on them.** `docs/apply-environment.md` names two claims. "A
   context is chosen by a header nginx sets, not by a URL setting in MODx" is true today. "On a
   restore or a new install the environment is set by running one PHP program" becomes true only
   once item 1 lands.
3. **Five trust-table chunks** (`estate-will`, `estate-revocable`, `estate-nevada-1`,
   `estate-nevada-2`, `trust-toc`) are the author's content held in `common/chunks`. They belong in
   `modx-estate`. Moving them is its own build, because a moved element deploys as a new row and
   leaves the old one bound (6). The same section of `docs/content-vocabulary.md` notes that
   the firm-reference lookup chunk is a script from the old site.
4. **Nothing automatic runs the modx-estate gate.** The content repository carries its own
   `p12-import.py` and declares its own layer, but no deploy or hook runs it, so a violation there
   would not be stopped.
5. Further items the sources list as open: the two Extras install unpinned (`latest()`), so a fresh
   install does not reproduce the versions in `ships` (`service.json` `$known_gaps`). The tooling
   role has no self-diagnosis. Staging and the dev bench still carry production's
   `storage.environment` (`docs/HOW-IT-WORKS.md` section 7, `docs/apply-environment.md`). Static
   elements (`static=1`), which would let MODx read an element from a file instead of a column,
   have not been costed. Some documents reference legacy asset trees that were never placed
   (`docs/production-install.md`).
