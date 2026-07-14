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
quiet offline-first agent without a permanent Dock or menu-bar icon.

> Version 0.1.1 requires macOS 14 or later and Apple Silicon. The downloadable
> app is ad-hoc signed, but is not yet notarized with an Apple Developer ID.

## Features

- **Native macOS agent** — AppKit panels, SwiftData persistence, global
  shortcuts, and System/Light/Dark appearance in an `LSUIElement` app.
- **Continuous WYSIWYG editing** — a Raycast Notes-style Tiptap/ProseMirror
  canvas; Markdown remains the stored, copied, and exported format.
- **Rich Markdown** — headings, emphasis, links, quotes, GFM tables, nested
  lists, tasks, fenced code with multi-color syntax highlighting, and KaTeX.
- **Always-available desktop cards** — cards float across apps and Spaces and
  can be dragged between displays using native macOS window behavior.
- **Adaptive layouts** — Mini, Sticky Note, Middle Note, Full Screen, and
  Custom, with content-aware height outside Full Screen.
- **Command Center** — press `⌥Space` to search recent cards and run commands.
- **Card Library** — search and edit every card from a native split view.
- **Attachments and export** — paste images, copy Markdown for local apps, or
  export a portable `.md + attachments/` bundle for VS Code and repositories.
- **YouTube covers** — paste a standalone YouTube URL or use `/youtube` to add
  a clickable 16:9 thumbnail.
- **CLI automation** — `mdcard` communicates with the single running agent over
  a user-only Unix domain socket.

## Install

### Download v0.1.1

1. Download [`Markdown-Card-0.1.1-macos.zip`](https://github.com/lemontom0116-maker/markdown-card/releases/download/v0.1.1/Markdown-Card-0.1.1-macos.zip).
2. Unzip it and move **Markdown Card.app** to `/Applications`.
3. On first launch, Control-click the app and choose **Open**. If macOS still
   retains the quarantine flag, run:

```bash
xattr -dr com.apple.quarantine "/Applications/Markdown Card.app"
open "/Applications/Markdown Card.app"
```

### Upgrade from Easy Card 0.1.0

First quit the old agent from Command Center or run `mdcard quit`. Remove the
old `/Applications/Easy Card.app`, then install `Markdown Card.app` using the
steps above. Do not keep both apps installed because they intentionally share
the same bundle identifier for compatibility.

Cards, settings, shortcuts, attachments, and CLI state are preserved: the
bundle identifier, Application Support directory, UserDefaults, database, and
IPC protocol have not changed.

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

### Global actions

| Action | Default shortcut |
| --- | --- |
| Open Command Center | `⌥Space` |
| Create a new card | `⌥⌘N` |
| Hide the active card | `Esc` or `⌘W` |

Command Center can open cards, create a card, open Card Library or Settings,
and quit the background agent. Customize global shortcuts under
**Settings → Shortcuts**.

### Layouts

| Shortcut | Layout |
| --- | --- |
| `⌘1` | Mini |
| `⌘2` | Sticky Note |
| `⌘3` | Middle Note |
| `⌘4` | Full Screen |
| `⌘5` | Custom Size |

Drag the 48-point header or title to move a card, including between displays.
Mini keeps only the close control and title, revealing Layout on hover.

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

For a block formula, type `$$` at the beginning of a line, then Space or Enter.
Use `⌘Enter` or leave the formula to render it:

```markdown
$$
\frac{a+b}{c}
$$
```

Task shorthand is contextual: type `- [] ` or `- [ ] ` to create a task. When
converting an existing bullet, place the caret before its text and type `[] `;
the existing text is preserved.

### Images, Copy, and Export

- Paste a clipboard image with `⌘V`; Markdown Card validates and stores a PNG
  using standard syntax such as `![Image](attachments/id.png)`.
- **Copy** immediately writes the latest Markdown. Managed attachments become
  absolute `file://` URLs for local tools such as Obsidian.
- **Export** appears when a card contains attachments. It writes a `.md` file
  and sibling `attachments/` folder with portable relative links for VS Code,
  Git repositories, and static Markdown tooling.

## CLI

Install the bundled helper from **Settings → CLI**, or from a source checkout:

```bash
./Scripts/build_and_run.sh install-cli
```

Ensure `~/.local/bin` is in `PATH`, then use:

```bash
CARD_ID="$(mdcard create note.md --title "Project note")"
mdcard show "$CARD_ID"
printf '# Updated\n\nBody.' | mdcard update "$CARD_ID" -
mdcard list
mdcard list --json
mdcard theme system        # system | light | dark
mdcard hide "$CARD_ID"
mdcard hide --all
mdcard delete "$CARD_ID"
mdcard quit
```

The CLI never writes the database directly. It launches Markdown Card when
needed and sends versioned requests to the agent.

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
