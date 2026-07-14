# Markdown Card Renderer

Offline `WKWebView` renderer for Markdown Card. It exports the same API under
both `window.MarkdownCard` and `window.markdownCard`:

```js
window.MarkdownCard.render({
  cardID: "card-id",
  title: "Card title",
  markdown: "# Markdown",
  resolvedAppearance: "dark", // "light" is also supported
  revision: 1
});

window.MarkdownCard.focusEditor();
window.MarkdownCard.setAppearance("light");
```

The native host should inject the resolved appearance at document start and
then pass the same value with the first render payload. Appearance changes only
swap CSS tokens; they do not reload the document or reset scroll position.

External links never navigate inside the web view. The renderer posts
`{ type: "openExternalLink", url }` to
`window.webkit.messageHandlers.markdownCard`. Remote images and arbitrary local
file URLs are replaced with a blocked-image label. A clipboard image is sent to
the native host, normalized into the managed attachment directory, and inserted
as standard relative Markdown (`attachments/<uuid>.png`). The only image source
allowed by the production Content Security Policy is `mdcard-asset:`, which the
native host uses for validated attachment and YouTube thumbnail bytes; scripts,
frames, and WebView network connections remain disabled.

User edits are emitted as
`{ type: "markdownChanged", cardID, markdown, revision }`. Revisions prevent a
stale native payload from overwriting a newer local edit. Renderer protocol v3
uses a single Tiptap/ProseMirror canvas: Markdown imports become rich text and
every document transaction serializes back to Markdown. Ordinary paragraphs,
headings, and lists never become separate textareas or editor cards.

`getMarkdownForCopy(attachmentBaseURL)` serializes a cloned editor document for
the native Copy button. It expands only managed `attachments/<uuid>.png` image
nodes to percent-encoded absolute `file://` URLs and never mutates the live
document, selection, revision, or undo history.

`getMarkdownExportBundle()` serializes another clone without expanding image
paths and returns `{ markdown, attachmentIDs }`. The attachment list is
deduplicated and includes only actual managed image nodes, never matching text
inside code blocks, remote images, arbitrary local paths, or YouTube covers.
The renderer also posts `managedAttachmentsChanged` metadata when this set
changes so native Card and Library toolbars can reveal Export without parsing
Markdown strings.

Tiptap packages and their transitive packages are locked to `3.22.3`. The
canvas includes GFM tables and contextual task input, VS Code Dark+/Light+
syntax highlighting, offline
KaTeX nodes, Markdown input rules, native undo/redo and IME composition. Formula
nodes render normally and expose only their inline LaTeX source while being
edited; entering source editing uses a collapsed caret and does not change the
ProseMirror selection. Invalid formulas fall back to visible source text. Raw HTML remains
visible text, unmanaged images remain source-preserving blocked nodes, and only
`⌘`-click on `http`, `https`, or `mailto` links is routed to the native host.

Empty documents intentionally have no placeholder copy. H2 headings use the
same open document flow as other headings without a default underline. Fenced
code normalizes common aliases (`python3` to `python`, `c++` to `cpp`, and so
on), highlights only registered languages, preserves unknown language names,
and never guesses an unknown language.

Task input converts only inside a list: `- [] `, `- [ ] `, `- [x] `, and
`- [X] ` normalize to GFM task Markdown, while bare checkbox text remains a
paragraph. Tab and Shift-Tab use four-space code indentation or list nesting;
ordinary paragraphs retain the system focus-navigation behavior.

The internal renderer plugin registry currently contains YouTube. Typing `/`
at the beginning of a paragraph opens the keyboard-navigable plugin menu;
`/youtube URL` accepts watch, short, embed, and youtu.be links and converts to a
selectable 16:9 cover node. Pasting a valid URL immediately after choosing
`/youtube` calls the same paragraph-replacement transaction as standalone URL
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
