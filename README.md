# Folio

A Markdown reader for macOS, built for reading long documents rather than editing short ones.

Folio is native AppKit — no web view. A document becomes a list of components, each with its own
view and its own text selection, and the reading pane lays them out as however many pages of a
spread the width will hold.

## What it does

**Reading**

- One column on a narrow window, and another page each time the width arrives for one — as many
  as fit at the reading measure, with no ceiling, scrolling vertically whatever the count. Pin a
  count from View › Columns if you would rather cross a narrower page.
- A section stays whole where it can: a heading is not left stranded at the foot of a column.
- Long tables paginate by row with the header repeated. Anything too big to break spans the spread.
- A dashed accent rule marks each page boundary, with a marker where a section carries on overleaf.
- Serif, sans, or monospaced; three line widths; three densities. Text size up to twice the default.

**Getting around**

- A window with nothing open is a welcome screen of its own — the recents list and nothing else.
  Clicking a file navigates to the reading screen, and the outline and document controls arrive
  without changing the unified titlebar around them. A back button in the toolbar — View › Back
  to Welcome, ⌘[ — returns, leaving the window as free for the next document as a new one.
- An outline sidebar that tracks what is on the page — one block over every section on screen, not
  a single highlighted row.
- Clicking a heading scrolls there and glows the component it landed on.
- The reading position is the reader's own: resizing the window, toggling the sidebar, or crossing
  from one column count to another puts them back exactly where they were.
- Wiki-style and relative links resolve against the document's folder, so a vault stays navigable.
- A coding agent's plan file — Claude Code's `~/.claude/plans`, Cursor's `~/.cursor/plans`,
  Codex's `~/.codex/plans` — roots at the workspace of the session that wrote it, so its links
  and run commands resolve against the project it describes rather than the plans folder. Links
  with a line suffix (`src/voucher.py:1043`) open the file they name.

**Blocks**

- Tables with rules, numeric alignment, and spanning rows.
- Fenced code with syntax highlighting and a copy button.
- YAML frontmatter as a card.
- Images, with alt text.
- Mermaid `flowchart`/`graph` and `stateDiagram-v2` drawn natively on a diagram card — no web
  view, no image export. The header names the kind that was actually drawn, and says so when a
  wide diagram had to be re-laid-out to fit the column.
- Every other Mermaid kind, math, and raw HTML stay labelled source cards with a copy button.
  Their label keeps the `mermaid ·` prefix, so a diagram Folio cannot draw never looks as though
  it had been. A drawn diagram's text is not in the document's text stream — the copy button
  returns the Mermaid source.

Dark appearance only. Contrast is checked in the test suite rather than eyeballed.

## Download and install

1. Open the [latest GitHub release](https://github.com/huylg/folio/releases/latest).
2. Under **Assets**, download the `Folio-<version>.dmg` file.
3. Open the disk image and drag **Folio** to the **Applications** folder.
4. The app is signed ad hoc and is not notarized, so on first launch Control-click Folio in Finder,
   choose **Open**, then confirm that you want to open it. After that, it opens normally.

Folio requires macOS 13 or later. Each release also includes a `.sha256` file for verifying the
download before installation.

## Updating

Folio checks its own GitHub releases and, when there is a newer one, says so with a small pill in
the titlebar. Clicking it downloads the release; clicking it again swaps the bundle and relaunches.
The disk image is mounted, the app copied off it, and the volume unmounted, so an update taken this
way needs none of the drag-across that installing by hand does. Releases up to v1.3.0 were zips and
are still accepted, so a reader on an old build is not stranded.
A right-click on the pill offers the release notes, skipping the version, and cancelling a download
in progress.

The check is a preference rather than a default. Folio otherwise never reaches the network without
being asked — remote images are off for the same reason — so it puts the question once, on first
launch, and honours the answer. `Folio › Check for Updates…` works either way, and Settings ›
Advanced has the switch, the version the app is running, and a Check Now button.

Two limits worth stating plainly:

- The bundle is signed ad hoc and is not notarized, so there is no publisher signature to check a
  download against. The trust anchor is HTTPS to GitHub plus the SHA-256 the release workflow
  publishes beside the disk image, which catches a corrupt or substituted asset but not a
  compromised GitHub account. Before anything is installed the unpacked bundle also has to identify itself as
  `io.huylg.folio`, carry a runnable executable, and report a version — a download that fails any
  of those is discarded with the installed copy untouched.
- Folio will not ask for an administrator. A copy in `/Applications` under a standard account
  cannot be replaced in place, so the updater reveals the new bundle in the Finder and leaves the
  move to you.

## Building

Swift 5.9 and macOS 13 or later.

```bash
make app
```

That writes `build/Folio.app`. `make run` opens it, `make test` runs the suite, `make build` just
compiles, and `make dmg` wraps the bundle into `build/Folio.dmg` the way a release does.

The app icon is drawn rather than checked in: `Tools/MakeAppIcon.swift` renders it in CoreGraphics
and `make icon` pipes the result through `iconutil`, so a change to the icon is a readable diff and
no binary lives in the tree. `make app` builds it for you. It is three drawings rather than one
scaled down — the rule count that reads as text at 512 is a grey wash at 32, and at 16 a page is
three pixels across, so only the heading bar survives.

## The command line

The binary doubles as a renderer, which is how the layout is checked without launching anything.

```bash
.build/debug/Folio --render-txt "path/to/doc.md"
```

A deterministic structural dump: the primary regression check, and cheaper than diffing pixels.
`make dump` runs it over every file in `sample-vault/`.

```bash
.build/debug/Folio --render-png "path/to/doc.md" out.png --width 1300
```

A PNG of the reading pane. `make snapshot` does the whole sample vault at 900pt wide.

## Layout

```
Sources/FolioKit/
  Model/        document loading, frontmatter, settings
  Rendering/    Markdown → components: attributes, metrics, theme, block views
  Update/       the release check, the download and its verification, the bundle swap
  UI/           the window, the welcome screen, the reading pane, the component stack, the outline
Sources/Folio/  the executable
Tools/          the app icon, drawn in CoreGraphics
Tests/          230-odd tests, mostly against real windows
sample-vault/   documents to read while working on it
```

The reading pane's two halves are `NativeDocumentView`, which owns the viewport, scrolling, and
navigation, and `DocumentStackView`, which measures every component and decides which page and
column each one lands on.

## Tests

```bash
make test
```

They run against real `NSWindow`s and assert on real geometry — where a component landed, how wide a
column came out, what the outline reported, what a colour measures against its background. Several
exist because a specific thing looked wrong once and the comment above them says what it was.

## Continuous integration

Two GitHub Actions workflows, both on `macos-26`:

- `ci.yml` builds and runs the suite on every push to `main` and every pull request, then attaches
  the debug `Folio.app` to the run as an artifact.
- `release.yml` fires on a `v*` tag: it runs the tests, builds `make dmg CONFIG=release VERSION=…`
  with the tag stamped into the bundle, and publishes `Folio-<tag>.dmg` and its `.sha256` on a
  GitHub release with generated notes. The image opens on a window holding the app next to a
  symlink to `/Applications`, so installing is the usual drag across. The stamp is checked before
  the image is built — a bundle that still claimed the template's version would leave the updater
  unable to tell one release from the next.

An update installed from inside the app clears the quarantine flag itself, so the first-launch step
under **Download and install** is only needed for the first copy.
