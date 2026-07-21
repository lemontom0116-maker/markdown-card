<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="Markdown Card app icon for macOS">
</p>

<h1 align="center">Markdown Card — Native Floating Markdown Notes for macOS</h1>

<p align="center">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-black.svg"></a>
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-black.svg">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-black.svg">
</p>

Markdown Card is an open-source native macOS app for floating Markdown notes
and desktop cards. It combines a continuous WYSIWYG editor with global
shortcuts, LaTeX, managed attachments, and CLI automation, while remaining a
quiet offline-first agent without a Dock, App Switcher, or menu-bar icon. Use
the global shortcuts to summon the Command Center, Library, or Settings without
turning the background agent into a regular macOS app.

> Version 0.2.0 requires macOS 14 or later and Apple Silicon. The downloadable
> app is ad-hoc signed, but is not yet notarized with an Apple Developer ID.

## Features

- **Native macOS agent** — AppKit panels, SwiftData persistence, global
  shortcuts, and System/Light/Dark appearance in an `LSUIElement` app.
- **Continuous WYSIWYG editing** — a Raycast Notes-style Tiptap/ProseMirror
  canvas; Markdown remains the stored, copied, and exported format.
- **Rich Markdown** — headings, emphasis, links, quotes, GFM tables, nested
  lists, tasks, fenced code with multi-color syntax highlighting, and KaTeX.
- **Long-form writing tools** — switch between Rich and Markdown Source, search
  or replace in either mode, navigate an H1–H6 Outline, render bundled Mermaid
  diagrams and footnotes, and edit table structure or image metadata.
- **Always-available desktop cards** — Mini, Sticky Note, Middle Note, and
  Custom cards float across apps and Spaces and can be dragged between displays
  using native macOS window behavior.
- **Adaptive layouts** — Mini, Sticky Note, Middle Note, and Custom, with
  content-aware height and configurable per-layout placement presets.
- **Command Center** — press `⌥Space` to search recent cards and run commands.
- **Card Library** — search and edit every card from a native split view.
- **Sleep mode** — fold every visible card into one draggable stack without
  changing card visibility or layout, then restore the original windows in place.
- **Card series** — add app-owned tags with `/tag`, filter the Library by tag,
  set an explicit chapter order, validate local links, and export the ordered
  cards as one Markdown tutorial without moving the window.
- **Markdown export** — save any card as `.md`; cards with pasted images also
  export a portable sibling `attachments/` folder for VS Code and repositories.
- **Linked Markdown files** — open a UTF-8 `.md` or `.markdown` file, save edits
  back atomically, keep the binding across launches, migrate safe relative
  resources during Save As, compare disk conflicts before overwriting, and
  restore earlier card versions.
- **YouTube covers** — paste a standalone YouTube URL or use `/youtube` to add
  a clickable 16:9 thumbnail.
- **CLI automation** — `mdcard` communicates with the single running agent over
  a user-only Unix domain socket.

## Install

### Download v0.2.0

1. Download [`Markdown-Card-0.2.0-macos.zip`](https://github.com/lemontom0116-maker/markdown-card/releases/download/v0.2.0/Markdown-Card-0.2.0-macos.zip).
2. Unzip it and move **Markdown Card.app** to `/Applications`.
3. On first launch, Control-click the app and choose **Open**. If macOS still
   retains the quarantine flag, run:

```bash
xattr -dr com.apple.quarantine "/Applications/Markdown Card.app"
open "/Applications/Markdown Card.app"
```

### Upgrade from 0.1.x

First quit the installed agent from Command Center or run `mdcard quit`. Replace
the existing `Markdown Card.app` using the steps above. If upgrading from Easy
Card 0.1.0, remove `/Applications/Easy Card.app` first. Do not keep both apps
installed because they intentionally share the same bundle identifier for
compatibility.

Cards, settings, shortcuts, and attachments are preserved because the bundle
identifier, Application Support directory, UserDefaults, and database location
have not changed. Reinstall the bundled CLI after upgrading so it uses IPC v5.

### Build from source

Requirements: Xcode 16 or later, Swift 6, Node.js 20+, and macOS 14+.

```bash
git clone https://github.com/lemontom0116-maker/markdown-card.git
cd markdown-card
npm --prefix Renderer ci
./Scripts/build_and_run.sh build
open "dist/Markdown Card.app"
```

The build script bundles the offline renderer, builds the native app and CLI,
compiles the App Icon asset catalog, and ad-hoc signs the app.

## Use Markdown Card

### Keyboard actions

| Action | Default shortcut |
| --- | --- |
| Open Command Center | `⌥Space` |
| Create a new card | `⌥⌘N` |
| Open Card Library | `⇧⌘L` |
| Fold all cards while a card is active | Not set |
| Move the active card to its preset position | `⌘J` |
| Hide the active card | `Esc` or `⌘W` |
| Save the active linked Markdown file | `⌘S` |
| Save As and link the active card to the new file | `⌥⌘S` |

Command Center can open cards, create a card, open Card Library or Settings,
and quit the background agent. Customize shortcuts under
**Settings → Shortcuts**.

On upgrade, Markdown Card audits every managed shortcut. A saved binding that
conflicts with Markdown formatting, fixed File commands, or layout commands is
moved to a conflict-free replacement when one is available; otherwise it is
disabled. Settings shows the migration result, and the recorder explains the
exact reservation plus a recommended replacement. The old default `⌘L` for Card
Library migrates to `⇧⌘L`.

Markdown Card folds visible cards automatically when the Mac locks, the display
sleeps, or the system sleeps. Unlocking or waking leaves them folded: click the
48-point card-stack indicator to restore the original positions and front-to-back
order. Disable this behavior under **Settings → General → Fold cards when Mac
locks**. Folding is temporary and reversible; `mdcard hide --all` still marks
cards permanently hidden.

### Layouts

| Shortcut | Layout |
| --- | --- |
| `⌃1` | Mini |
| `⌃2` | Sticky Note |
| `⌃3` | Middle Note |
| `⌃5` | Custom Size |

The single Control modifier keeps every layout action to two physical keys.
While the Markdown editor has focus, `⌘1…6` still belong to heading levels
instead of changing the card window. Layout shortcuts work anywhere in the
active card window.

Markdown Card remains an accessory agent in every layout and Command Center
route, so it never appears in the Dock or App Switcher. Reopen it with the
global Command Center, Library, or Settings shortcut after switching apps.

Drag the 48-point header or title to move a card, including between displays.
Mini keeps the close control, title, and a persistent Layout button. Its tooltip
and accessibility help explain how to restore the editor; Full Keyboard Access
users can activate it without a mouse, or press `⌃2` for Sticky Note directly.

With a card active, press `⌘J` to move it once to the preset position on its
current display. Mini and Sticky Note default to the top-right corner, while
Middle Note defaults to the center. Choose a different nine-point anchor for
Mini, Sticky Note, and Middle Note under **Settings → Card Placement**. Custom
Size follows the Middle Note anchor. Visible cards on the same display are kept
apart with a small gap instead of being stacked on top of one another.

### Markdown input

Markdown syntax becomes formatted content while you type:

````markdown
# Heading
- List item
- [ ] Task
**bold** and *italic*
```swift
print("Hello, Markdown Card")
```
````

An empty card shows a lightweight `/` command hint that never becomes part of
the Markdown. Type `/table` to insert a 3 × 3 GFM table with a header row; wide
tables scroll horizontally inside narrow cards. In a link selection or at a
link caret, press `⌘K` to add, edit, or remove its label and destination. Press
`⌘Return` at the end of a fenced code block to continue in a normal paragraph.
On wider windows, the canvas stays centered at a readable line length.

Use the following shortcuts while the Rich editor has focus:

| Markdown action | Shortcut |
| --- | --- |
| Paragraph | `⌘0` |
| Heading 1–6 | `⌘1`–`⌘6` |
| Bold / Italic / Inline code | `⌘B` / `⌘I` / `⌘E` |
| Add or edit link | `⌘K` |
| Strikethrough | `⇧⌘S` |
| Ordered / bullet / task list | `⇧⌘7` / `⇧⌘8` / `⇧⌘9` |
| Exit a code block or toggle the current task | `⌘Return` |
| Focus table row/column handles from a table cell | `⌃Return` |

These writing tools work in both Rich and Source while their card WebView has
focus:

| Writing tool | Shortcut |
| --- | --- |
| Find | `⌘F` |
| Find and Replace | `⌥⌘F` |
| Switch Rich / Markdown Source | `⇧⌘M` |
| Toggle H1–H6 Outline | `⇧⌘O` |

Markdown shortcuts are deliberately focus-scoped: they run only when the card's
WebView/editor or one of its writing panels has keyboard focus. They do not
format text when the title, header controls, another native window, or another
app is focused. Standard macOS editing shortcuts such as Undo, Redo, Cut, Copy,
Paste, and Select All continue to route to the focused editor.

Rich and Source composition state is also bridged to the native card window.
While an IME candidate session is active, layout, Fold, and Move shortcuts are
consumed without changing the window; the same shortcuts resume after the
composition ends or the editor reloads.

`Esc` follows a two-level rule. With a Markdown popover or writing panel open,
it closes that surface and returns focus to the editor; with no editor surface
open, it hides the card. When the WebView is not focused, the card window handles
`Esc` directly and hides the card.

For a block formula, type `$$` at the beginning of a line, then Space or Enter.
Use `⌘Enter` or leave the formula to render it:

```markdown
$$
\frac{a+b}{c}
$$
```

Task shorthand is contextual: type `- [] ` or `- [ ] ` to create a task. When
converting an existing bullet, place the caret before its text and type `[] `;
the existing text is preserved. To put an ordinary bullet under a task, create
the bullet directly after the task list, place the caret in its first item, and
press `Tab`. This crosses the task/bullet boundary and writes standard nested
GFM (`  - child`); `Shift+Tab` moves it back to the top level.

### Long-form and CS tutorial writing

Press `⇧⌘M` to inspect or edit raw Markdown. Merely entering Source and
returning to Rich preserves the original Markdown payload; once Source text is
edited, browser textarea newlines are saved as LF. Press `⇧⌘O` for a
keyboard-navigable H1–H6 Outline. `⌘F` searches and `⌥⌘F` exposes Replace;
in Rich mode, replacements stay within individual text nodes and Replace All is
one undo step. Fragment links use Unicode-aware heading slugs and distinguish
duplicate headings, so a tutorial table of contents can jump to the intended
section. Rich serialization also grows an outer code fence beyond the longest
backtick run in its content, preserving examples that contain nested fences.
An optional fenced-code `title="attention.py"` value is shown beside the
normalized language in Rich mode while the original info string still
round-trips through Markdown.

When the caret is inside a table, Markdown Card places controls directly on the
real top and left table edges: the active column gets a drag handle and `+`, and
the active row gets a drag handle and `+`. No blank control row or column is
added inside the table border, and there is no ellipsis button or table-actions
popover. If an edge has no safe surrounding space, its controls hide instead of
covering table content. Drag a handle to
move that row or column; focus it and press Delete to remove it. `⌥←` / `⌥→`
moves a focused column, and `⌥↑` / `⌥↓` moves a focused row. Press `⌃Return`
from a table cell to focus the column handle, then Tab through the row handle
and the two add controls; Escape returns to the cell. Normal `Tab` / `Shift+Tab`
inside the table still navigates cells. Three-column tables fill the card width,
while wide tables keep readable minimum cell widths and scroll horizontally in
Sticky. Header and GFM delimiter alignment remain editable in Source without a
Rich-mode options menu. Pasting TSV still expands a table in one undoable action.
Double-click an image,
or select it and press
Return, to edit its source, alt text, optional Markdown title, caption, width,
and alignment. Editor controls never enter the Markdown. Caption, width, and
alignment use Markdown Card's reversible extension, for example:

```markdown
![Flow](./assets/flow.png "Tooltip"){caption="Attention flow" width="75%" align="center"}
```

The extension round-trips in Markdown Card but is not standard GFM; other
renderers may show only the underlying image and ignore the trailing attributes.

Mermaid fences render from the bundled offline dependency while keeping their
editable source visible; invalid syntax produces an error without discarding the
fence. GFM-style footnote references and definitions support forward navigation
and backlinks. Source mode supports `⌘B`, `⌘I`, `⌘E`, `⌘K`, `⌘0`–`⌘6`, and
`⇧⌘S`; each syntax transformation is one undo step. Inline-code wrapping grows
its delimiter when the selection itself contains backticks.

In Rich mode, renaming exactly one otherwise-unchanged heading also repairs its
internal fragment links in the same undo step, including Unicode, encoded
fragments, and duplicate-heading suffixes. Ambiguous structural or multi-heading
edits leave links unchanged and announce that manual review is needed; Source
mode never guesses heading identity.

This makes ordinary CS tutorial work—headings, formulas, fenced code, GFM tables,
relative raster or SVG diagrams, footnotes, search, navigation, and source
inspection—practical in one card. A demanding tutorial still has known limits:

- A Rich edit serializes canonical Markdown semantics rather than promising a
  byte-minimal Git diff. Use Source for whitespace-sensitive or unknown syntax;
  compare the saved file before committing a tutorial repository change.
- Images can be pasted or file-dropped and edited, but there is not yet a
  keyboard-reachable Choose File button. Caption/width/alignment attributes are
  app-specific.
- Linked files are checked for external changes when saving rather than watched
  in real time. Conflict comparison is a read-only line comparison, not a live
  two-pane merge editor.
- Series export carries safe chapter images in a namespaced sibling asset tree,
  but ordinary relative file/source links are not bundled and produce portability
  warnings instead of being silently treated as portable.

Use
[`Examples/CSTutorialAuthoringFixture.md`](Examples/CSTutorialAuthoringFixture.md)
with the
[`M2/M3 acceptance plan`](Examples/MarkdownWritingM2M3TestPlan.md) to exercise
these implemented paths and record the remaining gaps separately.

### Tags and card series

Type `/tag`, enter one tag name, and press Return. Tags are compact outlined
chips attached below the card title and remain inactive until you select one.
The active tag keeps the same geometry and adds a short inset underline; click
it again to return to the unfiltered card.
Use the bare `‹‹` and `››` controls to move through that series without changing
the card's position or layout. A new series defaults to newest-first creation
order. Use **Series → Move Chapter Earlier** (`⌃⌥⌘↑`) and **Move Chapter Later**
(`⌃⌥⌘↓`) to persist an explicit per-tag order. Mini hides series UI.

Right-click a tag and choose **Remove Tag** to remove it. Tags are
Markdown Card metadata: they are intentionally excluded from copied and
exported Markdown. Card Library keeps **All** and a `+N` catalog control visible,
uses pinned and recently selected tags as responsive shortcuts, and provides a
searchable complete list. Choose **Manage Tags…** to pin, rename, merge, or
globally remove a tag; global removal never deletes cards or Markdown. Library
series navigation remains inside the active tag and text-search result set.

**Series → Validate Series Links…** checks in-card heading fragments, safe local
files under each linked document root, and cross-card fragments when both cards
are file-bound. **Export Series…** writes the explicit order as one UTF-8 `.md`
file with a generated title, contents, chapter headings, and stable chapter
markers. Safe relative and managed images are copied beside it under
`<filename>-assets/chapter-N-ID/`, with each chapter's Markdown references
rewritten to that namespace so same-named diagrams do not overwrite one another.
Unresolved images and ordinary relative file/source links produce portability
warnings but do not block export. The combined Markdown has the same 4 MiB limit.

### Images, Copy, and Export

- Paste a clipboard image with `⌘V`; Markdown Card validates and stores a PNG
  using standard syntax such as `![Image](attachments/id.png)`.
- **Copy** immediately writes the latest Markdown. Managed attachments become
  absolute `file://` URLs for local tools such as Obsidian.
- **Export** is available on every non-Mini card and in Card Library. Plain
  cards write one UTF-8 `.md` file. Cards with managed images also write a
  sibling `attachments/` folder with portable relative links for VS Code, Git
  repositories, and static Markdown tooling.

### Linked Markdown files

Choose **File → Open Markdown…** (`⌘O`) to create a card bound to an existing
UTF-8 `.md` or `.markdown` file. The header shows the filename, adding
`Edited` while the card contains changes not yet written to that file. `⌘S`
saves the live editor snapshot back to the current binding; `⌥⌘S` writes a
new file and makes it the binding.

Linked documents may render relative PNG, JPEG, GIF, WebP, or safe SVG images at
most 16 MiB, no larger than 8192 pixels on either axis, and within a 40-million
pixel single-frame budget. Animated images are limited to 120 frames and 100
million decoded pixels in total. SVG must be UTF-8, declare dimensions or a
`viewBox`, and pass a conservative element/attribute allowlist; styles, scripts,
active embeds, event handlers, external references, entities, imports, and
non-fragment URLs are rejected.
Resolution is restricted to the linked file's directory: absolute paths, `..`
traversal, symlink escapes, remote images, unsupported bytes, and oversized files
remain blocked without exposing arbitrary filesystem access.

Save As copies managed attachments and validated document-local images into the
new document root, rewriting paths when a destination collision needs a stable
`-2` suffix. Identical existing bytes are reused and existing files are never
overwritten. Unsafe, missing, or unsupported resources fail safely; an unbound
card with unresolved relative images still saves its Markdown and lists the
paths it could not copy.

If the card changes while Save As is copying resources, the completed file stays
as a point-in-time copy, but Markdown Card does not apply its rewritten paths or
new binding back onto the newer editor state. It shows **Copy Saved; Card Kept
Editing**, preserves the new text and original binding, and lets the author run
Save As again when ready.

Clicking a relative source link such as `./src/attention.py#L12-L18` is also
native-validated and root-confined. A small UTF-8 file with a supported line or
heading fragment opens in a read-only, line-numbered viewer with the destination
selected; a valid file without a resolvable preview is handed to macOS. Missing
files, traversal, symlink escapes, and unsupported schemes remain blocked. The
failure is shown in a non-modal banner instead of only sounding an alert. For an
unbound card, the banner offers **Save As…** so its document folder can become
the root for relative links.

If the Rich renderer fails to load or answer within four seconds, or its WebKit
content process exits, the card keeps its Markdown and shows **Retry**, **Open
Source**, and **Copy**. Open Source is a native editable fallback: changes keep
using the card's normal autosave path, so a renderer fault does not turn the
note into read-only content.

Before Save, Markdown Card compares the file's SHA-256 digest with the version
that was opened or last saved. A disk change is never overwritten silently; the
alert offers **Reload File**, **Compare…**, **Save As…**, or **Keep Mine…**.
Compare shows a read-only line comparison and returns to the chooser. Keep Mine
requires a second **Overwrite with Card** confirmation, stores the disk text in
recoverable history first, and writes only if the file has not changed again.
Reload similarly refuses to discard edits made after the conflict prompt. Save
uses an atomic replacement and preserves existing POSIX permissions. The current
file limit is 4 MiB, and external changes are checked when saving rather than
watched live.

Choose **File → Version History…** to compare up to 50 distinct snapshots for the
active card and restore one. Restoring snapshots the current card first, so the
operation remains recoverable. At launch, a newer autosaved version that differs
from the persisted card is recovered automatically; there is no separate crash
recovery dialog.

## CLI

Install the bundled helper from **Settings → CLI**, or from a source checkout:

```bash
./Scripts/build_and_run.sh install-cli
```

Ensure `~/.local/bin` is in `PATH`, then use:

```bash
CARD_ID="$(mdcard create note.md --title "Project note" \
  --tag Research --tag "CS 336")"
mdcard tag "$CARD_ID" "Reading queue"
mdcard show "$CARD_ID"
mdcard fold                 # temporary, reversible global presentation state
mdcard unfold
printf '# Updated\n\nBody.' | mdcard update "$CARD_ID" -
mdcard list
mdcard list --json          # includes a tags string array for each card
mdcard theme system        # system | light | dark
mdcard hide "$CARD_ID"
mdcard hide --all
mdcard delete "$CARD_ID"
mdcard quit
```

Repeat `--tag` to add multiple tags while creating a card. `mdcard tag` adds one
tag to an existing card. Quote names that contain spaces; names are normalized
and equivalent tags are deduplicated while preserving the first display
spelling. Tags remain Markdown Card metadata and never change copied or
exported Markdown.

The CLI never writes the database directly. It launches Markdown Card when
needed and sends versioned requests to the agent. This release uses IPC v5;
after upgrading Markdown Card, reinstall the bundled CLI from **Settings →
CLI** so the app and helper stay on the same protocol version.

## Development

```bash
npm --prefix Renderer test
swift test
./Scripts/integration_test.sh
```

Useful build commands:

```bash
./Scripts/build_and_run.sh run
./Scripts/build_and_run.sh verify
./Scripts/build_and_run.sh logs
```

The renderer is built only during development and then runs offline in
`WKWebView`. Dependencies are locked in `Package.resolved` and
`Renderer/package-lock.json`.

## License

Markdown Card is available under the [MIT License](LICENSE).
