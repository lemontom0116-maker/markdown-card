<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="Easy Card app icon">
</p>

<h1 align="center">Easy Card</h1>

<p align="center">
  Beautiful, always-available Markdown cards for macOS.
</p>

Easy Card is a native macOS agent app that turns Markdown into lightweight
desktop cards. Press a global shortcut, write in a continuous rich-text canvas,
and keep notes above your other windows without a menu-bar item or permanent
Dock icon.

> Easy Card 0.1.0 requires macOS 14 or later. The downloadable build is ad-hoc
> signed but not yet notarized with an Apple Developer ID.

## Features

- **Native macOS agent** — quiet `LSUIElement` app with AppKit panels, SwiftData
  persistence, global shortcuts, and System/Light/Dark appearance.
- **Continuous Markdown editing** — Raycast Notes-style WYSIWYG canvas powered
  by Tiptap/ProseMirror. Markdown remains the stored and copied format.
- **Rich syntax** — headings, emphasis, links, quotes, GFM tables, nested lists,
  tasks, fenced code with VS Code-style highlighting, inline code, and KaTeX.
- **Always-on-top cards** — every card floats across applications and Spaces.
- **Five layouts** — Mini, Sticky Note, Middle Note, Full Screen, and Custom;
  non-fullscreen layouts grow with their content inside safe limits.
- **Command Center** — press `⌥Space` to search cards and run commands without
  opening a conventional app window.
- **Card Library** — search and edit every card from a native split-view window.
- **Images and export** — paste clipboard images as managed attachments, copy
  Markdown for local apps, or export `Card.md + attachments/` for VS Code and
  repositories.
- **YouTube covers** — paste a standalone YouTube URL or use `/youtube` to add a
  clickable 16:9 video cover.
- **CLI automation** — `mdcard` talks to the single running agent over a
  user-only Unix domain socket.
- **Offline-first renderer** — the editor cannot make arbitrary web requests;
  only validated YouTube thumbnails use the native allowlisted loader.

## Install

### Download the release

1. Download `Easy-Card-0.1.0-macos.zip` from the
   [latest release](https://github.com/lemontom0116-maker/easy-card/releases/latest).
2. Unzip it and move **Easy Card.app** to `/Applications`.
3. On first launch, Control-click the app and choose **Open** because 0.1.0 is
   not notarized. If macOS still keeps the downloaded quarantine flag, run:

```bash
xattr -dr com.apple.quarantine "/Applications/Easy Card.app"
open "/Applications/Easy Card.app"
```

### Build from source

Requirements: Xcode 16 or later, Swift 6, Node.js 20+, and macOS 14+.

```bash
git clone https://github.com/lemontom0116-maker/easy-card.git
cd easy-card
npm --prefix Renderer ci
./Scripts/build_and_run.sh build
open "dist/Easy Card.app"
```

The build script bundles the offline renderer, compiles the native app and CLI,
builds the App Icon asset catalog, and ad-hoc signs `dist/Easy Card.app`.

## Use Easy Card

### Global actions

| Action | Default shortcut |
| --- | --- |
| Open Command Center | `⌥Space` |
| Create a new card | `⌥⌘N` |
| Hide the active card | `Esc` or `⌘W` |

Command Center can open cards, create a card, open Card Library or Settings,
and quit the background agent. Shortcuts can be changed under
**Settings → Shortcuts**.

### Layouts

| Shortcut | Layout |
| --- | --- |
| `⌘1` | Mini |
| `⌘2` | Sticky Note |
| `⌘3` | Middle Note |
| `⌘4` | Full Screen |
| `⌘5` | Custom Size |

Drag the 48-point header or title to move a card. Mini keeps only the close
control and title, revealing Layout on hover.

### Markdown input

Markdown syntax becomes formatted content as you type. Examples:

````markdown
# Heading
- List item
- [ ] Task
**bold** and *italic*
```swift
print("Hello, Easy Card")
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

- Paste a clipboard image with `⌘V`; Easy Card stores a validated PNG and keeps
  standard Markdown such as `![Image](attachments/id.png)`.
- **Copy** writes the latest Markdown immediately. Managed attachments become
  absolute `file://` URLs for local tools such as Obsidian.
- **Export** appears when a card has attachments. It writes a `.md` file and a
  sibling `attachments/` folder using portable relative links for VS Code and
  Git repositories.

## CLI

Install the bundled CLI from **Settings → CLI**, or from a source checkout:

```bash
./Scripts/build_and_run.sh install-cli
```

Make sure `~/.local/bin` is in `PATH`, then use:

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

The CLI never writes the database directly. It launches Easy Card when needed
and sends versioned requests to the agent.

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

The renderer is built only at development time and then runs fully offline in
`WKWebView`. Source dependencies are locked in `Package.resolved` and
`Renderer/package-lock.json`.
