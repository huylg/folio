# Folio

A Markdown reader for macOS, built for reading long documents rather than editing short ones.

Folio is native AppKit — no web view. A document becomes a list of components, each with its own
view, while selection and Find share one document-wide text index. The reading pane lays the
components out as however many pages of a spread the width will hold.

## What it does

**Reading**

- One column on a narrow window, and another page each time the width arrives for one — as many
  as fit at the reading measure, with no ceiling, scrolling vertically whatever the count. Pin a
  count from View › Columns if you would rather cross a narrower page.
- A section stays whole where it can: a heading is not left stranded at the foot of a column.
- Long tables paginate by row with the header repeated. Anything too big to break spans the spread.
- A dashed accent rule marks each page boundary, with a marker where a section carries on overleaf.
- Serif, sans, or monospaced; three line widths; three densities. Text size up to twice the default.

**Selecting and finding**

- Drag a continuous selection through prose, code, table cells, frontmatter, and source cards,
  including across columns and pages. Drag beyond the viewport to keep scrolling the selection.
- Double-click selects a word; triple-click selects a paragraph. Shift-click and Shift-arrow keys
  extend the selection. ⌘A selects the whole document, including text currently offscreen.
- ⌘C copies readable text: prose, unfenced code, tab-separated tables, and frontmatter fields.
  Images and rendered diagrams select as whole objects and copy their Markdown/source substitutes.
  Repeated table headers are copied once; buttons, reading statistics, and run output are excluded.
- ⌘F opens the native Find bar; ⌘G and ⇧⌘G move between matches; ⌘E searches the selected text.
  Find includes offscreen document text and displayed source cards, but excludes hidden image paths
  and rendered-diagram source. Displayed image captions remain searchable. The app is read-only.
- A preview stays nonactivating while hovered. Click its text to select and copy within the preview;
  it stays open while focused. Escape or an outside click dismisses it. Find targets the main document.
- Run consoles keep their own local selection and copying.

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

Folio uses [Sparkle 2](https://sparkle-project.org) to check, verify, download, and install updates.
With automatic checks enabled, it checks at launch and every hour while running. The preference
is opt-in; `Folio › Check for Updates…` and Settings › Advanced › Check Now work either way.
Existing automatic-check and skipped-version preferences are carried over from the previous updater.

The titlebar pill shows **Update Available**, **Downloading…**, **Preparing Update…**, and
**Restart to Update**. Click once to download and again when ready to restart. Right-click to
view release notes, skip a version, or cancel an active download. Sparkle may also finish an
already prepared installation when you quit normally. Dismissing an available update leaves
Sparkle free to remind you later; skipping suppresses that version until a manual check.

Releases include a signed Sparkle `appcast.xml` feed and an Ed25519 signature for the archive.
The bundled public key verifies the archive before extraction. The `.dmg` and `.sha256` sidecar
remain available so the old updater can install the first Sparkle-enabled release. That first
upgrade still uses the old updater's verification; Sparkle verifies subsequent upgrades.

The application remains ad-hoc signed and is not notarized. Sparkle's update signatures do not
replace Apple Developer ID signing or remove the first-install Gatekeeper restrictions.

### Release signing setup

The Folio public key is stored in `Support/Info.plist`, so local builds and CI builds
include it automatically. The matching private key is stored in this Mac's login Keychain
under account `io.huylg.folio` and in the GitHub repository secret `SPARKLE_PRIVATE_KEY`.
The release workflow also has the public key available as repository variable
`SPARKLE_PUBLIC_KEY`.

Build locally without setting any environment variables:

```bash
make app                          # Packaged app with updates enabled
make dmg CONFIG=release            # Release disk image
make appcast CONFIG=release        # DMG, checksum, and signed appcast in build/
```

`make appcast` signs with the existing Keychain item; macOS may request Keychain access.
For a specific release version, pass `VERSION=1.11.0` (for example). Nothing is uploaded by
these commands. A new Mac can build the app with the checked-in public key; signing releases
requires securely importing the existing private key into that Mac's Keychain:

```bash
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account io.huylg.folio -f <secure-backup-file>
```

Keep a secure backup of the private key. Do not generate a replacement for an existing release
identity: installed clients trust the matching public key. Keep `CFBundleVersion` increasing;
Sparkle uses it for version comparison.

GitHub Actions uses `SPARKLE_PRIVATE_KEY` via stdin to generate the signed appcast, and
publishes the `.dmg`, `.sha256`, and `appcast.xml` after validation. The feed URL is the latest
release's `appcast.xml` asset; no separate server is needed. CI refuses to sign if its secret
is missing, or to publish if the public/private keys do not match.

For isolated tests, `SPARKLE_PUBLIC_KEY` can override the bundled public key and
`SPARKLE_PRIVATE_KEY` can override Keychain signing. Run
`python3 Tools/test_sparkle_release.py` after `make app` to verify framework startup, packaging,
and archive signatures with a temporary test key; CI also runs this check.

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

## Tracing a scroll

When scrolling stutters, the question is what the main thread was doing in the frame that came
late. Launch the binary with `FOLIO_SCROLL_TRACE` set and it says:

```bash
FOLIO_SCROLL_TRACE=1 .build/debug/Folio
```

Every trackpad or wheel gesture ends with a summary on stderr: how many frames arrived, how many
came late and by how much, how many viewport events the scroll view sent per frame, and what each
phase of the scroll cost over the gesture — vending views, relaying out prose, probing for the
outline, drawing — costliest first. A single viewport event slow enough to have cost a frame on
its own gets a line of its own, with its breakdown, as it happens. The same phases go out as
`os_signpost` intervals under the `io.huylg.folio` subsystem, so Instruments' os_signpost track
shows them frame by frame, and the lines also reach the unified log:

```bash
log stream --predicate 'subsystem == "io.huylg.folio" AND category == "scroll"'
```

which is how to read them from a bundled copy, launched with `open --env FOLIO_SCROLL_TRACE=1
build/Folio.app`. With the variable unset none of this runs — the hooks are a flag check each.

Two phases deserve a word. `layoutText` is where the text is painted: under a layer-backed window,
which the reading pane is, TextKit 2 renders in `layout()` and `drawText` is a no-op — and every
prose view on screen re-runs that layout on every scroll event, so its row scales with the number
of views live rather than with the document. `populateVisible`, `visibleSections`, `captureAnchor`
and `headingProbe` look at a screenful of placements, found by search, however long the document
is; a row there that grows with the document is a regression.

Without a trackpad — on a CI runner, or in an agent's session — the same trace comes from scripted
gestures:

```bash
FOLIO_SCROLL_HARNESS=1 FOLIO_HARNESS_PARAGRAPHS=6000 \
    swift test -c release -Xswiftc -enable-testing --filter ScrollHarness 2>&1 | grep '^\['
```

## Layout

```
Sources/FolioKit/
  Model/        document loading, frontmatter, settings
  Rendering/    Markdown → components: attributes, metrics, theme, block views
  Update/       Sparkle integration and update presentation
  UI/           the window, the welcome screen, the reading pane, the component stack, the outline
Sources/Folio/  the executable
Tools/          app icon, Sparkle packaging and release feed generation
Tests/          layout and interaction tests, mostly against real windows
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
- `release.yml` fires on a `v*` tag: it builds `make dmg CONFIG=release VERSION=…`
  with the tag stamped into the bundle, embeds the update public key, and generates a signed
  Sparkle appcast. It publishes `Folio-<tag>.dmg`, its `.sha256`, and `appcast.xml` together on
  a GitHub release. Signing setup is described under **Release signing setup** above.
