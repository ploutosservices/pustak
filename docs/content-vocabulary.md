# Content vocabulary — the words you may write in a page

A page is HTML. These are the extra words our MODx gives you to write inside it. Each one
is a promise: we may change the code behind a word, but the word and its parameters keep working,
so your page never has to change because ours did. `tests/content-vocabulary.py` holds us to it — it
goes red when a word below loses its element, and when a page uses a word that is not below.

How a word is written: `[[$name? &param=`value`]]` for a chunk, `[[!name? &param=`value`]]` for a
snippet (the `!` means "run it fresh on every view"), `[[*field]]`, `[[++setting]]`, `[[~id]]`.

The table is read by the test, so keep its shape: one row per word; `whose` is `ours`, `modx`, `estate`
(a chunk that is the estate's own content, held in modx-estate `seat/estate-elements/chunks/`) or an
extra's name; `kind` is `chunk`, `snippet`, `field`, `setting`, `link` or `placeholder`.

| word | kind | whose | parameters | renders |
|---|---|---|---|---|
| cardStart | chunk | ours | `&title` (heading), `&colour` (Bootstrap colour of the heading, default `primary`), `&text` (heading text colour class, default `text-white`), `&extra`, `&bodyExtra` (more classes), `&id`, `&headId` | opens a card: a coloured heading and its body. Close it with `cardEnd` |
| cardEnd | chunk | ours | none | closes the card `cardStart` opened |
| sectionHead | chunk | ours | `&title`, `&id`, `&colour` (default `info`), `&size` (`fs-1`…`fs-6`, default `fs-5`), `&text`, `&extra`, `&anchor`, `&nav` (its name in the page's jump list, default the title) | a centred section heading, always open, the jump list can reach. Prefer `sectionStart` |
| sectionStart | chunk | ours | `&title`, `&id` (required), `&colour` (default `info`), `&text`, `&nav` | the section to use: a heading at the left that shows and hides the section below it. Close it with `sectionEnd` |
| sectionEnd | chunk | ours | none | closes the section `sectionStart` opened |
| folderContent | chunk | ours | none | a folder page: the side bar, the title and a table of the pages inside this one |
| Bootstrap.5.Head | chunk | ours | none | the page's `<head>`: styles, title, the bird icon |
| tableRenderer | snippet | ours | `&from` (id of a `<script type="application/ld+json">` block in this page), `&url` (fetch the data each view — write `[[!tableRenderer`), `&columns`, `&auth`; the full list is `docs/tableRenderer.md` | a table drawn from data, so each column knows what it holds |
| feedView | snippet | ours | none (the feed is picked by the page address) | any of the estate's feeds, laid out by the feed's own description |
| standing | snippet | ours | `&state` (`agreed`, `proposed` or `rejected`), `&date` (YYYY-MM-DD), `&who` (whose word) | a mark naming a statement's standing in words: agreed, proposed or rejected, its date and whose word |
| term | snippet | ours | `&term`, `&meaning`, `&example` (optional), `&id` (default `term-` and the term) | a defined term with its meaning and an example; a later page links to it at `#term-…`. On its own line |
| userHome | snippet | ours | none | sends a signed-in reader to their home in this site |
| unauthorizedNotice | snippet | ours | none | what a reader sees when a page refuses them |
| GoogleSSOStart | snippet | ours | none | the sign-in button and the start of sign-in |
| GoogleSSOCallback | snippet | ours | none | the end of sign-in, on the page the sign-in returns to |
| GoogleSSOLogout | snippet | ours | none | signs the reader out |
| actuatorInfo | snippet | ours | none | the installation's own status report, for the estate's monitoring |
| ssoBackchannelLogout | snippet | ours | none | ends this site's sessions when the reader signs out at the door |
| fsalookup | chunk | estate | none | a firm-reference lookup form from the old site (your content, held with your pages) |
| estate-will | chunk | estate | none | a trust table (your content, held with your pages) |
| estate-revocable | chunk | estate | none | a trust table (your content, held with your pages) |
| estate-nevada-1 | chunk | estate | none | a trust table (your content, held with your pages) |
| estate-nevada-2 | chunk | estate | none | a trust table (your content, held with your pages) |
| trust-toc | chunk | estate | none | the trusts' table of contents (your content, held with your pages) |
| id | field | modx | none | this page's number |
| introtext | field | modx | none | this page's summary |
| parent | field | modx | none | the number of the page this one sits under |
| longtitle | field | modx | none | this page's long title |
| menutitle | field | modx | none | this page's title in menus |
| assets_url | setting | modx | none | where this site's files are served from |
| site_start | setting | modx | none | the number of this site's home page |
| site_name | setting | modx | none | this site's name |
| ~ | link | modx | the page number, `[[~123]]` | the address of page 123 |
| link | placeholder | modx | none | inside a menu template: the item's address |
| link_attributes | placeholder | modx | none | inside a menu template: the item's link attributes |
| menutitle | placeholder | modx | none | inside a menu template: the item's title |
| attributes | placeholder | modx | none | inside a menu template: the item's attributes |
| wrapper | placeholder | modx | none | inside a menu template: the items it wraps |
| SimpleSearch | snippet | SimpleSearch | see the extra's documentation | search results |
| SimpleSearchForm | snippet | SimpleSearch | see the extra's documentation | the search box |
| pdoMenu | snippet | pdoTools | see the extra's documentation | a menu of pages |

## Not settled yet

The five trust-table chunks (`estate-will`, `estate-revocable`, `estate-nevada-1`,
`estate-nevada-2`, `trust-toc`) are your content and live with your pages in modx-estate
(`seat/estate-elements/chunks/`), deployed by name onto the rows that already exist — never as new
ones. The firm-reference lookup chunk is a script from the old site.
