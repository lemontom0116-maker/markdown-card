# Markdown Card Renderer

Offline `WKWebView` renderer for Markdown Card. It exports the same API under
both `window.MarkdownCard` and `window.markdownCard`:

```js
window.MarkdownCard.render({
  cardID: "card-id",
  title: "Card title",
  markdown: "# Markdown",
  resolvedAppearance: "dark", // "light" is also supported
  documentImagesAvailable: true, // native registered this card's document root
  revision: 1
});

window.MarkdownCard.focusEditor();
window.MarkdownCard.setAppearance("light");
window.MarkdownCard.setEditorMode("source"); // or "rich"
window.MarkdownCard.setDocumentImagesAvailable("card-id", true);
```

The native host should inject the resolved appearance at document start and
then pass the same value with the first render payload. Appearance changes only
swap CSS tokens; they do not reload the document or reset scroll position.

External links never navigate inside the web view. The renderer posts
`{ type: "openExternalLink", url }` to
`window.webkit.messageHandlers.markdownCard`. Remote images and arbitrary local
file URLs are replaced with a blocked-image label. A pasted or dropped image is sent to
the native host, normalized into the managed attachment directory, and inserted
as standard relative Markdown (`attachments/<uuid>.png`). A card linked to a
Markdown file may also request a source-preserving relative document image. The
renderer only classifies and encodes that relative path; native code resolves it
inside the registered document root, rejects traversal and symlink escapes, and
validates the bytes before returning them. The only image source allowed by the
production Content Security Policy is `mdcard-asset:`, which the native host
uses for validated attachment, document-image, and YouTube thumbnail bytes;
scripts, frames, and WebView network connections remain disabled.

User edits are emitted as
`{ type: "markdownChanged", cardID, markdown, revision }`. Revisions prevent a
stale native payload from overwriting a newer local edit. Renderer protocol v3
uses a single Tiptap/ProseMirror canvas: Markdown imports become rich text and
every document transaction serializes back to Markdown. Ordinary paragraphs,
headings, and lists never become separate textareas or editor cards. Rich edit
bursts are coalesced for 90 ms so one burst performs one Markdown serialization
and one managed-attachment scan before posting the latest revision.

`setEditorMode("source")` swaps the canvas for one plain Markdown textarea.
Toggling Source and Rich without editing preserves the original native Markdown
payload, including unknown syntax and original CRLF bytes. Once the textarea is
edited, its browser-normalized LF content becomes authoritative and is flushed
before copy, export, card replacement, mode switch, or renderer destruction.

`getMarkdownForCopy(attachmentBaseURL)` returns the authoritative Markdown for
the native Copy button. An untouched document without managed attachments keeps
its original bytes; when managed attachments need expansion, a cloned editor
document rewrites only `attachments/<uuid>.png` image nodes to percent-encoded
absolute `file://` URLs. Neither path mutates the live document, selection,
revision, or undo history.

`getMarkdownExportBundle()` returns `{ markdown, attachmentIDs }` from that same
authoritative Markdown, so untouched CRLF, spacing, aliases, and fence choices
remain byte-exact. The attachment list is deduplicated and includes only actual
managed image nodes, never matching text inside code blocks, remote images,
arbitrary local paths, or YouTube covers.
The renderer also posts `managedAttachmentsChanged` metadata when this set
changes so native Card and Library toolbars can describe attachment-aware
export without parsing Markdown strings. Export remains available for plain
Markdown; an empty attachment list writes only the `.md` file.

Tiptap packages and their transitive packages are locked to `3.22.3`. The
canvas includes GFM tables and contextual task input, VS Code Dark+/Light+
syntax highlighting, offline
KaTeX nodes, Markdown input rules, native undo/redo and IME composition. Formula
nodes render normally and expose only their inline LaTeX source while being
edited; entering source editing uses a collapsed caret and does not change the
ProseMirror selection. Invalid formulas fall back to visible source text. Raw HTML remains
visible text, unmanaged images remain source-preserving blocked nodes, and only
`⌘`-click on `http`, `https`, or `mailto` links is routed to the native host.

Empty documents show a CSS-only writing and `/` command hint; it is never
serialized into Markdown. H2 headings use the same open document flow as other
headings without a default underline. Fenced code normalizes common aliases
internally for highlighting (`python3` to `python`, `c++` to `cpp`, and so on),
but retains an untouched block's original info string and backtick/tilde fence
when a Rich edit happens elsewhere. It highlights only registered languages,
preserves unknown language names, never guesses an unknown language, and exits
into a paragraph with `⌘Return` when the caret is at the end. During Rich
serialization, a fence grows only when its own content requires a longer run,
so nested Markdown examples remain one valid code block.

Task input converts only inside a list: `- [] `, `- [ ] `, `- [x] `, and
`- [X] ` normalize to GFM task Markdown, while bare checkbox text remains a
paragraph. Tab and Shift-Tab use four-space code indentation or list nesting;
ordinary paragraphs retain the system focus-navigation behavior.

## Writing tools and shortcut ownership

The document-level writing tools work in Rich and Source:

| Command | Shortcut | Behavior |
| --- | --- | --- |
| Find | `⌘F` | Finds the next textual match in the active mode |
| Find and Replace | `⌥⌘F` | Adds Replace and Replace All controls |
| Rich / Source | `⇧⌘M` | Flushes the active mode before switching |
| Outline | `⇧⌘O` | Lists H1–H6 and moves the active-mode selection |

Rich mode also owns the usual Markdown formatting commands:

| Command | Shortcut |
| --- | --- |
| Paragraph / Heading 1–6 | `⌘0` / `⌘1`–`⌘6` |
| Bold / Italic / Inline code / Link | `⌘B` / `⌘I` / `⌘E` / `⌘K` |
| Strikethrough | `⇧⌘S` |
| Ordered / bullet / task list | `⇧⌘7` / `⇧⌘8` / `⇧⌘9` |
| Exit code block or toggle task | `⌘Return` |
| Focus table row/column handles from a table cell | `⌃Return` |

These commands are intentionally card-focus-scoped. Native forwards the
Markdown contract only while the first responder belongs to that card's
`WKWebView`; it does not invoke Markdown formatting from a card header, native
window, or another app. To remove collisions, native card layouts use the
two-key combinations `⌃1…5`, and **File → Save As** uses `⌥⌘S`. `⇧⌘S` therefore always
means strikethrough in the focused Rich editor.

Source remains a raw textarea, but the Markdown formatting contract is shared
with Rich: `⌘B`, `⌘I`, `⌘E`, `⌘K`, `⌘0…6`, and `⇧⌘S` wrap the selection or
transform its current line. Each transform records one Source-mode undo step;
`⌘Z` / `⇧⌘Z` restores that exact value and selection. Find, Replace, Outline,
mode switching, and ordinary textarea editing continue to work normally.

`Esc` is consumed by the open link, Find, Outline, or image editor first. With
no renderer surface left to dismiss, the renderer posts `hideRequested` for the
card. This prevents a first Escape from closing the whole card while a writing
surface is active.

Find in Rich mode deliberately matches within one ProseMirror text node and
never crosses a mark, table boundary, or atom node. Replace All dispatches one
transaction, so it is one undo step. Outline reads H1–H6 from the active rich
document or Source text and ignores fence contents, including nested fences.
Fragment clicks resolve Unicode-aware heading slugs, append stable suffixes for
duplicate headings, and scroll the matching rich heading into view. A Rich-mode
rename repairs same-document fragment links only when one heading changed and
the edit is confined to that heading. Duplicate suffix moves are repaired by
outline identity in the same undo event. Ambiguous renames leave links untouched
and show a visible warning.

Selecting a table cell places controls directly on the real top edge for the
active column and the real left edge for the active row. Each edge contains one
Lucide drag handle and one spatial `+`; no blank control row or column is added
inside the table border, and there is no ellipsis trigger, text button strip, or
actions popover. If the surrounding space is unsafe, those controls hide. Drag a
handle to reorder, or focus it and use `⌥←` / `⌥→` for a column and `⌥↑` / `⌥↓`
for a row. Delete removes the focused row or column. While the caret is in a
table, `⌃Return` focuses the column handle without changing ordinary `Tab` /
`Shift+Tab` cell navigation; Tab advances through both handles and both add
controls, and Escape returns to the editor. Three-column tables fill the
available canvas; wider tables preserve a minimum cell width and remain
horizontally scrollable in Sticky. Tab-separated clipboard data overlays from
the active cell and expands the table in one undo step. The header row cannot be
moved out of first position, and column movement is disabled for merged cells so
serialization remains portable. Header and alignment delimiters remain
round-trippable through Source. Column width controls are intentionally omitted:
GFM Markdown has no reversible column-width syntax, so a width UI would either
lose data or introduce renderer-specific HTML.

Selecting an image and pressing Return, or double-clicking it, opens source,
alt-text, title, caption, width, and alignment editing. Pasted and dropped image
files become managed attachments; safe document-relative sources remain
source-preserving and replaceable. Caption/width/alignment use a compact optional
attribute suffix (`{caption="…" width="75%" align="center"}`) that round-trips
through Rich and Source.

Fenced code can include an optional title such as
````markdown
```python3 title="attention.py"
```
````
Rich mode shows `attention.py · python` in the code-block header while preserving
the complete original info string for Markdown serialization.

Fenced `mermaid` blocks render to sanitized, accessible SVG entirely from a
self-hosted dependency while their source stays editable below the preview;
parse errors are visible beside the preserved source. The Mermaid vendor is a
separate classic script and is loaded only when a card actually contains a
Mermaid fence; ordinary cards never parse or execute it. This remains fully
offline and compatible with the renderer's `script-src 'self'` CSP and bundled
WKWebView `file:` URL. GFM-style `[^label]` references
and `[^label]: definition` blocks render numbered endnotes and backlinks and
serialize back to the same Markdown form. Safe `./` document-relative links post
an `openDocumentLink` request to native rather than granting the WebView
filesystem access. Parent traversal (`../`) is rejected at authoring time because
native resolves links inside the bound document folder.

Current deliberate limits are: no citation bibliography engine, no merged-cell
column reorder, and no table column-width control because GFM has no lossless,
portable representation for those widths. Untouched copy/export remains
byte-exact until the first Rich document edit; after that edit, preservation is
node-scoped (including untouched fenced-code aliases/fences), not a promise of
whole-document byte-minimal diffs.

The internal renderer plugin registry contains YouTube, Table, and the native
Tag metadata command. Typing `/` at the beginning of a paragraph opens the
keyboard-navigable plugin menu. `/table` inserts a 3 × 3 GFM table with a header
row; a wrapper keeps wide tables horizontally reachable in narrow cards.
`/youtube URL` accepts watch, short, embed, and youtu.be links and converts to a
selectable 16:9 cover node. Pasting a valid URL immediately after choosing the
command calls the same paragraph-replacement transaction as standalone URL
paste, so both paths produce identical cover nodes. Its stable Markdown
representation is:

```markdown
[![YouTube video](https://i.ytimg.com/vi/VIDEO_ID/hqdefault.jpg)](https://www.youtube.com/watch?v=VIDEO_ID)
```

Importing that exact structure restores the rich node. Incomplete or invalid
commands remain ordinary editable text, and Command-click routes the canonical
video URL to the native host.

## Commands

```sh
npm install
npm test
npm run build
npm run dev -- --port 4173
```

Use `?preview=1` for the dark reference content and
`?preview=1&theme=light` for its light companion. Production assets are written
to `../Resources/Renderer/`.
