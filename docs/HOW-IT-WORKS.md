# How this MODx works

Written 2026-08-18, after a week in which one blank PDF cost five sessions. Every
sentence below that describes a trap describes something that actually happened, with the reason it
was invisible.

**This is the door.** It explains the model and the traps; it does not restate procedures that other
documents own:

| For | Read |
|---|---|
| the working model, who owns what, the edit loop | `workflow.md` |
| building an estate from nothing (stock MODX + our scripts) | `installation.md` |
| restoring the estate onto a ground | `production-install.md` |
| upgrading MODX itself | `upgrades.md` |
| the storage-backed file gate | `modx-storage-gate.md` |
| sign-in | `modx-sso-design.md`, and the sign-in section below for the door's realms per ground |
| the words a page may use (`[[$cardStart]]`, `[[!tableRenderer]]` …) | `content-vocabulary.md` |

`seat/` and `install/` are **not in this repository** — they are the estate repository (`modx-estate`), resolved from
`MODX_ESTATE`, which names the estate FILE and not the checkout.

---

## 1. Code and state are in different places, and that is the whole shape

**An element is a DATABASE COLUMN.** A snippet's body lives in `modx_site_snippets.snippet`, a
plugin's in `modx_site_plugins.plugincode`, a chunk's in `modx_site_htmlsnippets.snippet`, a template's in
`modx_site_templates.content`. This repository holds them as FILES, and the files are the master.

Three consequences that explain most of what feels strange here:

- **A deploy is an UPSERT, not a copy.** `apply-modx-elements.sh` matches by NAME and inserts what it
  cannot find. So **renaming an element deploys it as a NEW row** and leaves every resource, event
  binding and template call pointing at the old one — a total break behind a green deploy.
  The verb prints `updated <dir>/<name> (id N)` when it matched and `inserted` when it did not:
  **`inserted` on a name you expected to exist is that break announcing itself.**
- **The file and the row can differ by one byte, legitimately.** The verb stores the body after
  `perl -0777 -ne 's/\n\z//'` — exactly one trailing newline removed. Any check that compares a file
  to a column must do the same, or it reports drift on every correct deploy. One did, for as long as
  it existed, and the false positive was the first line a reader saw while a real finding sat under
  it (fixed 2026-08-18).
- **`common/lib/*.php` is NOT deployed by that verb.** Those are plain classes, shipped under
  `core/components/pustak/lib/` by infra's `modx-web` ansible role (tag `modx_lib`). So the library
  half and the element half ship by DIFFERENT mechanisms and either can be the older one on any
  ground at any moment. Do not build runtime negotiation between them — that was tried on
  2026-08-18 and failed in both directions inside one afternoon (absent: a 503 that made the owner's
  diagnosis wait on someone else's converge; present-but-older: an answer in yesterday's shape
  labelled current). **An element carries the code it runs; the class is the tested unit.**

**A document is a database ROW too**, rendered to files under `seat/documents/<context>/<alias>-<id>`
by `seat/pull.py` and pushed back by `seat/push.py`. Documents are the owner's editing surface; elements
are not.

**Estate facts are neither.** Which contexts exist, the bench zone — all of that lives in
`estate.json` in the estate repository (`modx-estate`). Which NAME reaches which context is the edge's: nginx sets
`X-Tenant` from the name's tenant, and
`config.context.php` is one line requiring `EdgeContext.php`, which reads that header and never the
host. It used to be a host map, first inside the docroot tar, then generated.

---

## 2. The environments, and which facts are per-ground

Three grounds: **production**, **staging**, and a **dev bench** on a dev box. They run the same
elements. What differs is a small set of facts, and every one of them has been wrong on a live
ground at least once.

### `core/config/application.php` — rendered by infra, per ground

| Key | What it decides | What happens when it is wrong |
|---|---|---|
| `environment` | which ground this instance believes it is | the actuator refuses rather than guessing; nothing infers it from a hostname |
| `estate_identity_dir` | where this ground's client certificate lives | absent → `StorageIdentity` returns NONE, **no HTTP request is made at all**, and a storage-backed page renders EMPTY |
| `client_identity_trusted` | whether `X-Client-Identity` may be believed | true where nginx does not overwrite the header turns a certificate door into an open one. **A header is an identity only where something the caller cannot reach wrote it.** |
| `commit` | which code infra stamped | null rather than a guess; a wrong commit in a report that exists to answer "what is deployed" is worse than no answer |

**Why a file and not system settings**, and this is not a style preference: `restore_modx_dev` loads
production's dump WHOLE. A settings row would copy production's identity onto every bench — which is
how production's `kuber.jwt_private_key` once reached a dev bench. `config.inc.php` is out
because MODX's own upgrader rewrites it.

**`Application::config()` returns null for any value that is not a string.** The obvious render of a
flag — a PHP boolean `true` — reads as UNSET at the consumer. That cost an hour on
`client_identity_trusted` while everything else was correct.

### System settings that decide whether the install works at all

Readable without a shell: `GET /actuator/info?report=settings` (see §4).

| Setting | Correct | The failure it caused |
|---|---|---|
| `storage.base_url` | **`https://…`** | `http://` blanked **every PDF in the estate**. A client certificate does not exist without TLS: nginx verifies nothing, sets no identity, and the storage door refuses the call as a bearer — 401. `13-storage-gate.py` had the http value as its DEFAULT. |
| `storage.environment` | the ground's own | it filters the storage HOLD, not the file. Every modx blob is held only in `production`, so any ground naming its own environment on a READ got `{"detail":"Not found"}` for a file that was right there. Reads no longer send it. |
| `sso.provider` (per context) | the estate OIDC provider on the internal zone | Google cannot issue a callback to a private name, so an internal-zone context on `google` cannot sign anyone in — `SSO-00` |
| `log_target` / `log_level` | `FILE` / `1` | both read correct while `core/cache/logs` was unwritable, so every error was discarded rather than recorded. See §5. |

### Sign-in differs by design, and it is a step of the restore

Every ground signs in at the **estate sign-in door** (design/estate-sign-in.md): production at
production's door, dev and staging at the non-production door's `dev` and `staging` realms, which
hold test users only. The mock provider is retired. The guard is the internal **zone
suffix**, not a hostname — a zone is a property of the network, a name is something somebody
maintains.

**`setup/12-sso.py` has two switches and they are not the same switch:**

    MODX_SSO_IDP=<issuer>          the per-INSTALL endpoints (sso.auth_endpoint/token_endpoint/issuer)
    MODX_SSO_OIDC=<issuer>         the per-CONTEXT provider — plus MODX_SSO_OIDC_CONTEXTS and a
    MODX_SSO_OIDC_SECRET_<CTX>     client id and secret per context

One MODx serves four contexts and `getOption()` resolves a context setting over the system value, so
**the per-context path is the one that decides.** Passing only `MODX_SSO_IDP` writes the endpoints and
leaves `sso.provider` on `google`, which is a half-configured state that reports success — the fault
the owner hit on staging on 2026-08-18. On an internal-zone ground the contexts are derived from the bench zone,
so `MODX_SSO_OIDC_CONTEXTS` is not needed there; the secret is each context's door client secret,
handed in the environment by the bench's sign-in setup from the dev OpenBao.

---

## 3. The programs, and what each one will silently NOT do

The last column is the point of this table.

| Program | Owns | Will silently not do |
|---|---|---|
| `apply-modx-elements.sh` (infra's, skunkworks runs it) | upsert elements into a ground by name; snapshot first; clear the element caches | it does not deploy `common/lib`. It clears only `{scripts,includes}/elements` and the `resource` cache. `--target local` resolves to `${MODX_ROOT:-/srv/local/modx}` and applies to **nothing** if no bench is there. A plugin without a `<name>.events` sidecar is refused — before that it deployed code wired to no event and reported success. |
| `setup/make-current.sh` | build a bench: unpack the docroot tar, write machine config, place `common/lib` and the one-line `config.context.php`, render the bench's `application.php`, load the seed | it does not create the database, and it refuses on an uncommitted repo or a populated schema unless `FORCE=1`. Until 2026-08-18 it did not write `config.context.php` at all, so a bench with 1,545 resources answered MODX's own 404 on every host and explained nothing. |
| `setup/load-seed.sh` | load + bind + verify, as ONE act (the bind is `setup/apply-environment.php`) | the pairing is deliberate: a seed loaded without its bind is the failure this prevents, on the ground that is supposed to be safe. |
| the bench's renderer | render a bench's `application.php` from infra's `modx-environment.py --env dev --machine <box>` | MODx types no host name; without it the bench answers for production's public names. |
| `setup/config-context.py` | write `config.context.php`: the one-line `EdgeContext.php` require, the same on every profile | it decides nothing — the context is the edge's `X-Tenant` header, read by `EdgeContext.php`. |
| `setup/12-sso.py` | the SSO wiring: settings, the four pages per context, repointing login/logout/unauthorized | see §2 — the wrong variable leaves `sso.provider` on Google and says nothing. It refuses to point a context outside the internal zone at the mock. |
| `setup/13-storage-gate.py` | the `storage.*` settings and the delivery plumbing | it REWRITES `storage.base_url` and `storage.environment` from its defaults unless `MODX_STORAGE_BASEURL` / `MODX_STORAGE_ENV` name them (the token only when given). Running it to update one plugin can repoint the storage door and reset the scope. Its own default was `http://` until 2026-08-18. |
| `clear-cache.php` | refresh MODx's whole cache (`cacheManager->refresh()`), carrying `core/cache/logs` aside and back | a bare `refresh()` deletes the error log, which is how two earlier defects both hid — so it refuses to refresh if it cannot move the log aside. It also cannot delete files owned by another user: if the php-fpm pool and the tree's owner are different accounts, it reports success having removed nothing. |
| `ops.sh local restore_modx_dev` | pull production's dump through night-desk with the agent's OWN token, load it, rebind, regenerate the working tree (then the bench's sign-in setup points SSO at the dev realm), then apply git master to the bench (`setup/deploy-local.sh`; `--production-only` skips it) | it REGENERATES `common/` and `seat/` from the database and leaves them uncommitted — so it can overwrite committed code NEWER than the dump, and a session-close `git add -A` would push the regression. Check `git status` after every run. |
| `ops.sh staging modx` | dispatch a staging refresh from production, through the door, audited by caller | production is only ever READ. |
| `ops.sh seat modx` | fetch the seat commits a ground made, as a git bundle, and push them with YOUR Gitea identity | no ground pushes to Gitea. It stops rather than overwrite uncommitted seat edits in your clone. |
| `seat/pull.py` / `seat/push.py` | documents between the database and files | `push.py` is BENCH ONLY. |
| `actuatorInfo` (element) | the read path — see §4 | it must be called uncached (`[[!actuatorInfo]]`); a cached call is refused, because a cached diagnostic is a lie with a timestamp. |
| `tests/run-all.sh` | every suite in its `suites=(…)` list | suites REFUSE rather than pass when their ground is missing, and the runner reports refusals separately from failures. A refusal is not a pass. |

---

## 4. How to see a ground without logging in to it

This did not exist until 2026-08-18, and its absence is why the blank PDF survived five sessions.

The actuator is a MODx resource (`actuator/info` in the `platform` context) calling `[[!actuatorInfo]]`.
It is reached with a **client certificate** — nginx sets `X-Client-Identity` from a verified chain and
overwrites it on every request. Two caller lists, deliberately separate: `monitoring` polls the info
report, `skunkworks` reads the diagnostics.

**AND IT IS EXEMPT FROM PAGE PROTECTION, which is the half that was missing until 2026-09-05.** Every
`modDocument` outside `support` joins `allContextProtected` (§ setup/04), and that answers an
anonymous caller 302 to the sign-in page — one layer ABOVE the element, so a caller presenting a
verified certificate got the same sign-in redirect as one presenting nothing, and the code that
decides who may read this never ran. `service.json`'s `identity.routes` is the declaration of which
paths are machine doors; `04` exempts exactly those and names each one it exempts in its output.
Read `setup/access_model.py` MACHINE_DOORS before adding a route row: a row there un-protects that
page, and what keeps that honest is the element's own refusal, not the access model.

    GET /actuator/info                    requirement verdicts, environment, commit, MODx version
    GET /actuator/info?report=settings    the five settings of §2, by explicit allow-list
    GET /actuator/info?report=elements    name, byte length and sha1 of every element the ground HOLDS
    GET /actuator/info?report=log         this estate's OWN lines out of the MODX error log

Four properties worth knowing before you extend it:

- **`?report=log` returns only lines OUR elements wrote** — matched against a marker list. Not a
  redaction: a mask fails open and looks identical when it does. The MODX error log carries failed SQL
  with its parameters, on a host that answers the public internet, so the bound is that nothing we did
  not author can appear at all.
- **`?report=elements` is how you check a deploy.** The verb's own `updated` reports the upsert, not
  the row. Hash the file the way the verb stores it and compare.
- **`?report=settings` is an allow-list, never a prefix.** `storage.modx_token` shares a namespace
  with `storage.base_url`.
- **MODX owns `q`.** Friendly URLs are `index.php?q=<uri>`, so a diagnostic query named `q` is
  consumed as a resource path and answers MODX's own 404 before your code runs. Use another name.

**The version is reported from two witnesses** — `settings_version` and `getVersionData()` — because
they can disagree: the 3.2.2 → 3.2.3 upgrade exited 0 while logging a failure. `agree: null` means one could
not be read, which is not the same finding as "they differ".

---

## 5. The failures that look like success

Read this section before trusting any green in this estate.

1. **A verb that reports the action, not the result.** `apply-modx-elements.sh --only <name>` printed
   `done — 0 element(s) applied`, exit 0, after taking a real snapshot and clearing the cache, when
   the name matched nothing. Every signal a deployer reads said success while the database kept the
   old code.
2. **A cache clear that deletes nothing.** `rm -rf` and `cacheManager->refresh()` both report success
   when the files belong to another user. Symptom: a deployed element change that does not take
   effect, with a clean deploy log.
3. **An error log with nowhere to go.** `core/cache/logs` was present and NOT WRITABLE on production
   and staging while `log_target=FILE` and `log_level=1`. Every error was discarded. "No such file"
   cannot tell "nothing has been logged" from "nothing CAN be" — the actuator now reports the
   directory separately for exactly that reason.
4. **A failure with no wire trace.** `StorageIdentity` returning NONE makes **no HTTP request**. There
   is no 404, no 401, nothing for a monitor to see — the page is simply empty. Fail-closed is right,
   and it means the log line is the ONLY witness.
5. **A drift check that fires on a trailing newline.** It cried wolf on every correct deploy, and the
   false positive was masking a real finding underneath it.
6. **A check that names the wrong subject.** A suite asked whether the certificate key was readable by
   `www-data` on a ground where the web process runs as somebody else, and reported a defect that did
   not exist.
7. **A green you can forge.** `client_identity_trusted='1'` on a bench whose nginx sets nothing lets
   you type your own identity header. That tests your code and says nothing about the door.
8. **A stale half answering in the old shape.** Two deploy mechanisms, one library, and a response
   that said `library` while returning last week's fields.

**The order that works: make the ground readable, read it, then fix.** Every session that reversed
those produced a confident wrong answer.

---

## 6. Doing a piece of work, end to end

    1  bench            MODX_ROOT=/srv/local/modx MODX_DB_PASS=… MODX_ESTATE=…/estate.json \
                        bash setup/make-current.sh          (or ops.sh local restore_modx_dev to
                                                             refresh it from production)
    2  check            git -C . status                      restore_modx_dev regenerates the tree
    3  change           edit common/<kind>/<name>            the file is the master
    4  prove locally    php tests/<suite>.php  /  bash tests/run-all.sh
                        for anything with a decision in it, drive the CLASS under php — no MODX
                        needed, which is how the storage path was proven without a bench at all
    5  apply to bench   apply-modx-elements.sh --only <name> --target local
                        php clear-cache.php /srv/local/modx
    6  staging          commit and push master, then  git push origin master:staging
                        (staging access converge + staging elements, workflow.md)
                        read it back:  ?report=elements  and compare the sha1
    7  production       git push origin staging:production
                        read it back the same way, then ?report=log

**Never skip 6.** And read the sha1 back rather than trusting the word `updated` — that is the one
habit this whole document exists to install.

---

## 7. What is still open

- **Staging reads `storage.environment = production`.** Reads ignore it, so nothing is broken today;
  a WRITE from staging would pin its hold to production's scope.
- **Static elements are not used.** MODX supports `static=1` + `static_file`, which would make an
  element a file the ground checks out instead of a database column — and would remove most of §1 and
  §5 with it. The owner raised it on 2026-08-17. Nobody has costed it and it has no owner.
