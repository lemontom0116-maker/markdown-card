# Changelog

All notable changes to Markdown Card are documented here.

## Unreleased

## 0.2.0 — 2026-07-21

- Added long-form Markdown writing tools: lossless-until-edited Rich/Source
  switching (`⇧⌘M`), Find and Replace in both modes (`⌘F` / `⌥⌘F`), an
  H1–H6 Outline (`⇧⌘O`), bundled offline Mermaid rendering, GFM footnotes,
  contextual table header/alignment/TSV actions, and image source/alt/title/
  caption/width/alignment editing. Unicode-aware duplicate heading fragments now
  jump to the intended section; safe single-heading renames repair internal links
  in the same undo step, while ambiguous edits remain unchanged with an
  accessible warning. Rich serialization expands outer code fences around nested
  backtick runs and preserves untouched fence style and language spelling.
- Split Mermaid into a 0.94 MiB startup renderer and a local 3.29 MiB vendor that
  loads only for cards containing Mermaid, while retaining offline CSP-safe
  rendering and source-preserving errors.
- Added Source-mode Markdown transformations for `⌘B`, `⌘I`, `⌘E`, `⌘K`,
  `⌘0`–`⌘6`, and `⇧⌘S`; every transformation is composition-safe and forms one
  undo step. Document-wide IME guards now cover Rich, Source, formula, link,
  image, find, slash/tag, and protected-media interactions. Composition state is
  bridged through WKWebView so native layout, Fold, and Move commands cannot
  steal a candidate keystroke, and resets on blur, reload, failure, or teardown.
- Preserved the original Markdown bytes for untouched Rich copy and export;
  Rich transactions still intentionally serialize the current semantic document.
- Added linked `.md` / `.markdown` documents with Open, atomic Save, portable
  Save As, persistent card bindings, a compact clean/edited filename indicator,
  a 4 MiB UTF-8 boundary, and digest-based Reload File / Compare / Save As /
  Keep Mine conflict handling. Compare is read-only; Keep Mine snapshots the
  disk version and requires a second overwrite confirmation.
- Save As now copies managed attachments and safe document-local images, reuses
  identical destination bytes, rewrites deterministic collision names, never
  overwrites existing resources, and rolls back copied resources when the
  Markdown write fails.
- Save As now guards its editor revision and original binding: edits made while
  resources are copying keep their newer text and old binding, while the written
  point-in-time copy is reported instead of being applied back over the card.
- Library File actions revalidate the selected card after each asynchronous
  renderer snapshot, preventing a mid-operation row change from saving content
  into the previous card.
- Added up to 50 distinct recoverable versions per card, a File → Version
  History comparison and restore flow, automatic recovery of a newer autosaved
  startup snapshot, and disk-version capture before conflict overwrite.
- Added native-validated relative document images for linked Markdown files.
  PNG, JPEG, GIF, WebP, and restricted passive SVG stay inside the document root
  and retain the renderer's offline CSP; traversal, symlink escapes, active SVG,
  invalid bytes, files over 16 MiB, images over 8192 px or 40 million pixels,
  and animations over 120 frames or 100 million decoded pixels remain blocked.
- Added root-confined relative source links with `#Lx`, `#Lx-Ly`, and heading
  fragments. Small UTF-8 targets open in a native read-only line viewer;
  traversal, symlink escapes, missing files, and unsupported schemes are rejected.
- Gave focused-card Markdown shortcuts priority over window commands: `⌘0` and
  `⌘1…6` now select paragraph/headings, `⇧⌘S` remains strikethrough, card
  layouts moved from `⌘1…5` to `⌃1…3` and `⌃5`, and Save As moved from `⇧⌘S` to
  `⌥⌘S`. Markdown commands run only while that card's WebView has keyboard
  focus, and `Esc` dismisses its active writing surface before hiding the card.
- Unified Home, Card Library, and Settings inside one Raycast-inspired Command
  Center workspace with route-specific search, a directly editable Library,
  card information, stable deep-route sizing, and keyboard-first navigation.
- Fixed a hidden Library or Settings workspace reappearing when a floating card
  reactivated the accessory app. Deep routes now hide explicitly on app
  deactivation while preserving their route and only return through an explicit
  Command Center, Library, or Settings action.
- Removed the Full Screen card layout and migrated existing Full Screen cards to
  centered Middle Notes without changing their Markdown or metadata. Markdown
  Card now remains an accessory agent in Home, Library, Settings, and every
  card layout, so it never appears in the Dock or App Switcher.
- Added startup migration for every persisted managed shortcut that conflicts
  with Markdown, fixed File commands, or layout commands. Settings now reports
  the migration, rejects reserved recordings with an exact reason, recommends a
  conflict-free replacement, and exposes the feedback to accessibility clients.
- Added a keyboard-first `⌘K` link editor for creating, updating, and removing
  labels and safe external destinations; Card Library now defaults to `⇧⌘L`,
  including a one-time migration from the old default.
- Added `/table`, horizontally scrollable wide tables, centered readable-width
  editing on wide windows, an empty-card command hint, visible code-language
  context, and `⌘Return` to exit a code block at its end.
- Fixed normal GFM tables collapsing into the left side of a full-width frame.
  Three-column tables now fill the canvas, wide tables retain horizontal scroll,
  and table editing now places row/column drag handles and spatial `+` controls
  directly on the real top/left table edges without adding a blank control row
  or column inside the border. The ellipsis trigger and table-actions popover
  were removed. `⌃Return` reaches the handles from a table cell; drag, Delete,
  Option-arrow movement, unsafe-edge/offscreen hiding, and one-step Undo remain
  contained.
- Made plain Markdown export available from every non-Mini card and selected
  Library document while preserving portable attachment-bundle export.
- Kept Mini visually quiet while making its Layout control keyboard focusable
  with a visible focus state.
- Added temporary Fold All sleep mode with lock/display/system-sleep triggers,
  an accessible draggable card-stack indicator, in-place window restoration,
  a configurable global shortcut, dynamic menu commands, and `mdcard fold` /
  `mdcard unfold`.
- Added a configurable `⌘J` action that moves the active Mini, Sticky, Middle,
  or Custom card to a nine-point preset on its current display while keeping
  visible cards from overlapping. Custom follows the Middle preset.
- Extended `mdcard` with repeatable `create --tag`, `mdcard tag <UUID> <NAME>`,
  and normalized tag-name arrays in `list --json`. Tags remain app metadata and
  do not change Markdown copy or export.
- Replaced Card Library's hidden horizontal tag overflow with an always-visible
  **All** / `+N` filter bar, searchable full catalog, pinned and recent
  shortcuts, card counts, and global rename, merge, and tag-only deletion.
  Tag lifecycle changes migrate explicit series order and roll back on
  persistence failure without changing Markdown or deleting cards.
- Upgraded app/CLI IPC to v5; reinstall the bundled CLI after upgrading the app
  so both components use the same protocol version.
- Added metadata tags through `/tag`, compact outlined chips with toggle-off
  selection, newest-first fallback series navigation, persistent explicit
  chapter order, local-link validation, and portable ordered series export.
  Export includes generated contents and stable chapter markers, copies safe
  chapter images into namespaced sibling directories, and warns when ordinary
  relative file links or unresolved images cannot be carried.
- Series export now computes one global heading slug sequence and rewrites each
  chapter's inline and reference fragments, so duplicate headings keep pointing
  to their original chapter after merge. Safe asset stems and decoded `%20`
  paths keep images reopenable for export names containing `~` or spaces.
- Tags now start inactive, and the title, tag rail, and first Markdown block use
  a tighter vertical rhythm.
- Slash commands now use a nonactivating native panel that can extend beyond a
  card's bounds while staying on screen.
- Added matching tag filtering and series navigation to Card Library while
  keeping tags out of Markdown copy and export.
- Prevented GFM footnote navigation metadata from feeding DOM mutations back
  into ProseMirror and starving the renderer event loop. Renderer load/render
  timeouts, WebContent termination, and navigation failures now offer Retry,
  editable native Source, and Copy Markdown recovery without losing the card.
- Relative source-link failures now stay visible in a non-modal banner with a
  Save As path for the exact card. Command Center no longer invents or repeats
  Recent items, and Mini keeps a permanently visible Layout recovery control.
- Fenced-code `title="…"` metadata is visible beside the language, and compact
  Source/code context labels now use a legible 12-point minimum.
- `Tab` can now move the first ordinary bullet immediately following a task
  list under that task, with `Shift+Tab`, undo/redo, import, and GFM Markdown
  serialization preserving the mixed nested-list structure.

## 0.1.1 — 2026-07-14

- Renamed the product and build artifact from Easy Card to Markdown Card while
  preserving the bundle ID, user data, settings, shortcuts, CLI, and IPC.
- Replaced manual header dragging with native AppKit window dragging so cards
  can move between displays and Spaces.
- Restored saved cards on their persisted display instead of the mouse display.
- Added MIT licensing and updated public project metadata and documentation.

## 0.1.0 — 2026-07-14

Initial public release as Easy Card.

- Native always-on-top Markdown cards for macOS 14 and later.
- Continuous WYSIWYG Markdown editing with GFM, KaTeX, syntax highlighting, and tasks.
- Mini, Sticky, Middle, Full Screen, and Custom layouts with content-aware sizing.
- Global Command Center, Card Library, appearance settings, and configurable shortcuts.
- Local image attachments, Markdown copy, and portable Markdown bundle export.
- YouTube cover plugin and standalone YouTube URL conversion.
- `mdcard` CLI for creating, updating, listing, showing, hiding, and deleting cards.
