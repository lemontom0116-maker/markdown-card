import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { JSDOM } from "jsdom";
import { installMarkdownCard } from "../src/app.js";
import {
  codeBlockDisplayTitle,
  insertSmartLinkFromPaste,
  normalizeCodeLanguage,
  protectUnsafeMarkdown,
  smartLinkProviderForURL,
  smartLinkTitleForURL
} from "../src/markdown.js";
import {
  normalizeTagCommandName,
  parseYouTubeURL,
  rendererPluginRegistry,
  youtubeMarkdown
} from "../src/plugins.js";

function installDOMGlobals(window) {
  globalThis.window = window;
  globalThis.document = window.document;
  globalThis.Node = window.Node;
  globalThis.HTMLElement = window.HTMLElement;
  globalThis.HTMLAnchorElement = window.HTMLAnchorElement;
  globalThis.Element = window.Element;
  globalThis.DocumentFragment = window.DocumentFragment;
  globalThis.MutationObserver = window.MutationObserver;
  globalThis.DOMParser = window.DOMParser;
  globalThis.getSelection = window.getSelection.bind(window);
  globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
  globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
  if (!window.document.elementFromPoint) {
    window.document.elementFromPoint = () => (
      window.document.querySelector(".ProseMirror") ?? window.document.body
    );
  }
  if (!window.Range.prototype.getClientRects) {
    window.Range.prototype.getClientRects = () => [];
  }
  if (!window.Range.prototype.getBoundingClientRect) {
    window.Range.prototype.getBoundingClientRect = () => ({
      x: 0, y: 0, top: 0, left: 0, bottom: 0, right: 0, width: 0, height: 0
    });
  }
}

function makeDOM() {
  const dom = new JSDOM(
    '<!doctype html><html data-theme="dark"><body><main id="renderer"></main></body></html>',
    { url: "https://markdown-card.invalid/", pretendToBeVisual: true }
  );
  dom.window.matchMedia = () => ({
    matches: false,
    addEventListener() {},
    removeEventListener() {}
  });
  installDOMGlobals(dom.window);
  return dom;
}

function setup(payload = {}, options = {}) {
  const dom = makeDOM();
  const messages = [];
  if (options.nativeSlashCommandPanel) {
    dom.window.__markdownCardNativeCapabilities = { slashCommandPanel: true };
  }
  dom.window.webkit = {
    messageHandlers: {
      markdownCard: { postMessage: (message) => messages.push(message) }
    }
  };
  const api = installMarkdownCard(dom.window, dom.window.document);
  api.render({ cardID: "card-one", markdown: "", revision: 0, ...payload });
  return { dom, api, editor: api.getEditor(), messages };
}

function typeText(editor, text) {
  for (const character of text) {
    const { from, to } = editor.state.selection;
    let handled = false;
    editor.view.someProp("handleTextInput", (handler) => {
      if (handled) return true;
      handled = handler(editor.view, from, to, character) === true;
      return handled;
    });
    if (!handled) editor.view.dispatch(editor.state.tr.insertText(character));
  }
}

function pressKey(editor, key, options = {}) {
  const KeyboardEvent = editor.view.dom.ownerDocument.defaultView.KeyboardEvent;
  const event = new KeyboardEvent("keydown", {
    key,
    bubbles: true,
    cancelable: true,
    ...options
  });
  let handled = false;
  editor.view.someProp("handleKeyDown", (handler) => {
    if (handled) return true;
    handled = handler(editor.view, event) === true;
    return handled;
  });
  return handled;
}

function pasteText(editor, text) {
  const EventType = editor.view.dom.ownerDocument.defaultView.Event;
  const event = new EventType("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: { getData: (type) => type === "text/plain" ? text : "" }
  });
  const dispatched = editor.view.dom.dispatchEvent(event);
  return { handled: !dispatched, prevented: event.defaultPrevented };
}

function pasteImage(editor, name = "Screenshot.png", type = "image/png") {
  const Window = editor.view.dom.ownerDocument.defaultView;
  const file = new Window.File([new Uint8Array([137, 80, 78, 71])], name, { type });
  const event = new Window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: {
      items: [{ kind: "file", type, getAsFile: () => file }],
      getData: () => ""
    }
  });
  const dispatched = editor.view.dom.dispatchEvent(event);
  return { handled: !dispatched, prevented: event.defaultPrevented };
}

test("uses one Rich ProseMirror canvas and one hidden Source textarea", () => {
  const { dom, api } = setup({
    markdown: "# Heading\n\nBody\n\n- one\n- two",
    revision: 1
  });

  assert.equal(api.protocolVersion, 3);
  assert.equal(dom.window.document.querySelectorAll(".ProseMirror").length, 1);
  const sourceEditor = dom.window.document.querySelector("textarea.source-editor");
  assert.ok(sourceEditor);
  assert.equal(sourceEditor.hidden, true);
  assert.equal(dom.window.document.querySelectorAll(".editor-block").length, 0);
  assert.match(dom.window.document.querySelector(".ProseMirror").innerHTML, /<h1>Heading<\/h1>/);
  assert.match(dom.window.document.querySelector(".ProseMirror").innerHTML, /<ul>/);
});

test("reports validated intrinsic content height through the native bridge", () => {
  const { api, messages } = setup({ markdown: "# Height\n\nBody" });
  const height = api.measureContentHeight();
  const report = messages.find((message) => message.type === "contentHeightChanged");

  assert.ok(Number.isFinite(height));
  assert.ok(height >= 1);
  assert.equal(report.cardID, "card-one");
  assert.equal(report.height, height);
});

test("reports managed attachment metadata without matching source text", () => {
  const attachmentID = "34d1880c-35d5-4c7e-9620-40c3140b003c";
  const { messages } = setup({
    markdown: [
      `![Screenshot](attachments/${attachmentID}.png)`,
      "```text",
      "attachments/83e3fad5-cc28-41e2-9407-7a8236c5bfa9.png",
      "```"
    ].join("\n\n")
  });
  const metadata = messages.find((message) => message.type === "managedAttachmentsChanged");
  assert.deepEqual(metadata, {
    type: "managedAttachmentsChanged",
    cardID: "card-one",
    attachmentIDs: [attachmentID]
  });
});

test("imports and serializes GFM tables, tasks, nested lists, code, links, and images", () => {
  const markdown = [
    "# Semantics",
    "",
    "- [x] shipped",
    "  - nested",
    "",
    "| A | B |",
    "| - | - |",
    "| 1 | 2 |",
    "",
    "```javascript",
    "const answer = 42;",
    "```",
    "",
    "[site](https://example.com) ![diagram](https://example.com/a.png)"
  ].join("\n");
  const { dom, editor } = setup({ markdown });
  const html = dom.window.document.querySelector(".ProseMirror").innerHTML;
  const roundTrip = editor.getMarkdown();

  assert.match(html, /data-type="taskList"/);
  assert.match(html, /<table/);
  assert.match(html, /class="language-javascript"/);
  assert.match(html, /class="hljs-keyword"/);
  assert.match(html, /class="image-blocked"/);
  assert.match(roundTrip, /- \[x\] shipped/);
  assert.match(roundTrip, /\| A\s+\| B\s+\|/);
  assert.match(roundTrip, /```javascript/);
  assert.match(roundTrip, /\[site\]\(https:\/\/example\.com\)/);
  assert.match(roundTrip, /!\[diagram\]\(https:\/\/example\.com\/a\.png\)/);
});

test("Markdown syntax showcase covers supported nodes and safe degradation", async () => {
  const markdown = await readFile(
    new URL("../../Examples/MarkdownSyntaxShowcase.md", import.meta.url),
    "utf8"
  );
  const { dom, editor } = setup({ markdown });
  const canvas = dom.window.document.querySelector(".ProseMirror");
  const roundTrip = editor.getMarkdown();

  assert.equal(canvas.querySelectorAll("h1, h2, h3, h4, h5, h6").length >= 6, true);
  assert.ok(canvas.querySelector("strong"));
  assert.ok(canvas.querySelector("em"));
  assert.ok(canvas.querySelector("del, s"));
  assert.ok(canvas.querySelector("blockquote"));
  assert.ok(canvas.querySelector("ol"));
  assert.ok(canvas.querySelector('ul[data-type="taskList"]'));
  assert.ok(canvas.querySelector("table"));
  assert.equal(canvas.querySelectorAll("pre code").length, 2);
  assert.ok(canvas.querySelector(".math-node-inline"));
  assert.ok(canvas.querySelector(".math-node-block"));
  assert.ok(canvas.querySelector(".youtube-card"));
  assert.equal(canvas.querySelectorAll(".image-blocked").length >= 2, true);
  assert.equal(canvas.querySelectorAll("script, iframe, object, embed").length, 0);
  const images = [...canvas.querySelectorAll("img")];
  assert.equal(images.length, 1);
  assert.equal(images[0].classList.contains("youtube-card-image"), true);
  assert.match(images[0].getAttribute("src"), /^mdcard-asset:\/\/youtube\//);
  assert.match(canvas.textContent, /This must never execute/);
  assert.match(roundTrip, /# Markdown Syntax Showcase/);
  assert.match(roundTrip, /- \[x\] Completed task/);
  assert.match(roundTrip, /```python/);
  assert.match(roundTrip, /```swift/);
  assert.match(roundTrip, /\\operatorname\{Attention\}/);
  assert.match(roundTrip, /mdcard-asset|i\.ytimg\.com|YouTube video/);
  assert.match(roundTrip, /file:\/\/\/tmp\/private-image\.png/);
});

test("renders inline and block math and edits valid LaTeX in place", () => {
  const { dom, editor } = setup({
    markdown: "Inline $x^2$ here.\n\n$$\n\\frac{QK^T}{\\sqrt{d_k}}\n$$"
  });

  assert.equal(dom.window.document.querySelectorAll(".math-node-inline").length, 1);
  assert.equal(dom.window.document.querySelectorAll(".math-node-block").length, 1);
  editor.commands.setTextSelection({ from: 1, to: 3 });
  const selectionBefore = { from: editor.state.selection.from, to: editor.state.selection.to };
  const inline = dom.window.document.querySelector(".math-node-inline");
  const mouseDown = new dom.window.MouseEvent("mousedown", {
    bubbles: true, cancelable: true, button: 0
  });
  inline.dispatchEvent(mouseDown);
  const source = inline.querySelector("input.math-source");
  assert.ok(source);
  assert.equal(mouseDown.defaultPrevented, true);
  assert.deepEqual(
    { from: editor.state.selection.from, to: editor.state.selection.to },
    selectionBefore
  );
  assert.equal(source.selectionStart, source.value.length);
  assert.equal(source.selectionEnd, source.value.length);
  source.value = "y^2";
  source.dispatchEvent(new dom.window.FocusEvent("blur", { bubbles: true }));
  assert.match(editor.getMarkdown(), /\$y\^2\$/);
  assert.equal(dom.window.document.querySelectorAll(".math-node-inline").length, 1);
  assert.equal(inline.querySelector(".math-source"), null);
  assert.ok(inline.querySelector(".katex"));
});

test("formula Escape cancels source editing and block Command-Enter restores rendering", () => {
  const { dom, editor } = setup({ markdown: "Inline $x$\n\n$$\ny^2\n$$" });
  const inline = dom.window.document.querySelector(".math-node-inline");
  inline.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
  const inlineSource = inline.querySelector("input.math-source");
  inlineSource.value = "changed";
  inlineSource.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
    key: "Escape", bubbles: true, cancelable: true
  }));
  assert.match(editor.getMarkdown(), /\$x\$/);
  assert.equal(inline.querySelector(".math-source"), null);
  assert.ok(inline.querySelector(".katex"));

  const block = dom.window.document.querySelector(".math-node-block");
  block.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
  const blockSource = block.querySelector("textarea.math-source");
  blockSource.value = "z^3";
  blockSource.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
    key: "Enter", metaKey: true, bubbles: true, cancelable: true
  }));
  assert.match(editor.getMarkdown(), /\$\$\nz\^3\n\$\$/);
  assert.equal(block.querySelector(".math-source"), null);
  assert.ok(block.querySelector(".katex"));
});

test("block formula starts from line-leading double dollars plus Space or Enter", async () => {
  for (const trigger of ["Space", "Enter"]) {
    const { dom, editor } = setup();
    typeText(editor, "$$");
    if (trigger === "Space") typeText(editor, " ");
    else assert.equal(pressKey(editor, "Enter"), true);
    await new Promise((resolve) => dom.window.requestAnimationFrame(resolve));

    assert.equal(editor.state.doc.firstChild.type.name, "blockMath", trigger);
    const source = dom.window.document.querySelector("textarea.math-source");
    assert.ok(source, `${trigger} should focus a block formula source editor`);
    assert.equal(dom.window.document.activeElement, source);
    source.value = "\\frac{a+b}{c}";
    source.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
      key: "Enter", metaKey: true, bubbles: true, cancelable: true
    }));
    assert.equal(dom.window.document.querySelector("textarea.math-source"), null);
    assert.ok(dom.window.document.querySelector(".math-node-block .katex"));
    assert.match(editor.getMarkdown(), /\$\$\n\\frac\{a\+b\}\{c\}\n\$\$/);
  }
});

test("empty or invalid newly-created block formulas remain recoverable source", async () => {
  const empty = setup();
  typeText(empty.editor, "$$ ");
  await new Promise((resolve) => empty.dom.window.requestAnimationFrame(resolve));
  const emptySource = empty.dom.window.document.querySelector("textarea.math-source");
  emptySource.dispatchEvent(new empty.dom.window.FocusEvent("blur", { bubbles: true }));
  assert.equal(empty.editor.state.doc.firstChild.type.name, "paragraph");
  assert.equal(empty.editor.state.doc.firstChild.textContent, "$$");

  const invalid = setup();
  typeText(invalid.editor, "$$");
  assert.equal(pressKey(invalid.editor, "Enter"), true);
  await new Promise((resolve) => invalid.dom.window.requestAnimationFrame(resolve));
  const invalidSource = invalid.dom.window.document.querySelector("textarea.math-source");
  invalidSource.value = "\\frac{";
  invalidSource.dispatchEvent(new invalid.dom.window.FocusEvent("blur", { bubbles: true }));
  const invalidNode = invalid.dom.window.document.querySelector(".math-node-block.has-error");
  assert.ok(invalidNode);
  assert.match(invalidNode.textContent, /\\frac\{/);
  invalidNode.dispatchEvent(new invalid.dom.window.MouseEvent("mousedown", {
    bubbles: true, cancelable: true, button: 0
  }));
  assert.equal(
    invalid.dom.window.document.querySelector("textarea.math-source")?.value,
    "\\frac{"
  );
});

test("invalid formula edits become visible source instead of broken DOM", () => {
  const { dom, editor } = setup({ markdown: "Before $x$ after" });
  const inline = dom.window.document.querySelector(".math-node-inline");
  inline.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
  const source = inline.querySelector("input.math-source");
  source.value = "\\frac{";
  source.dispatchEvent(new dom.window.FocusEvent("blur", { bubbles: true }));

  assert.equal(dom.window.document.querySelectorAll(".math-node-inline").length, 0);
  assert.match(editor.getText(), /\$\\frac\{\$/);
  assert.doesNotMatch(dom.window.document.querySelector(".ProseMirror").innerHTML, /katex-error/);
});

test("Markdown typing rules produce rich text without source blocks", () => {
  const { editor, dom } = setup();
  typeText(editor, "## ");
  typeText(editor, "Raycast style");
  assert.equal(editor.state.doc.firstChild.type.name, "heading");
  assert.equal(editor.state.doc.firstChild.attrs.level, 2);

  editor.commands.setContent("", { contentType: "markdown", emitUpdate: false });
  typeText(editor, "**bold**");
  assert.match(dom.window.document.querySelector(".ProseMirror").innerHTML, /<strong>bold<\/strong>/);

  editor.commands.setContent("", { contentType: "markdown", emitUpdate: false });
  typeText(editor, "[Raycast](https://raycast.com)");
  const raycastLink = dom.window.document.querySelector("a[href='https://raycast.com']");
  assert.equal(raycastLink?.textContent, "Raycast");
  assert.equal(raycastLink?.dataset.smartLinkProvider, "web");
});

test("task input requires list context and normalizes shorthand to GFM", () => {
  for (const source of ["[] ", "[ ] ", "[x] "]) {
    const bare = setup();
    typeText(bare.editor, source);
    assert.equal(bare.editor.state.doc.firstChild.type.name, "paragraph");
    assert.equal(bare.editor.getText(), source);
  }

  for (const [source, checked] of [
    ["- [] ", false], ["- [ ] ", false], ["- [x] ", true], ["- [X] ", true]
  ]) {
    const { editor, dom } = setup();
    typeText(editor, source);
    const item = editor.state.doc.firstChild.firstChild;
    assert.equal(editor.state.doc.firstChild.type.name, "taskList", source);
    assert.equal(item.type.name, "taskItem", source);
    assert.equal(item.attrs.checked, checked, source);
    assert.equal(editor.state.doc.childCount, 1, `${source} must not leave a trailing paragraph`);
    assert.match(editor.getMarkdown(), checked ? /- \[x\] / : /- \[ \] /);
    assert.ok(dom.window.document.querySelector('ul[data-type="taskList"]'));
  }

  const inherited = setup({ markdown: "- first\n- second" });
  const paragraphs = [];
  inherited.editor.state.doc.descendants((node, position) => {
    if (node.type.name === "paragraph") paragraphs.push({ position: position + 1, size: node.content.size });
  });
  inherited.editor.commands.setTextSelection({
    from: paragraphs[1].position,
    to: paragraphs[1].position + paragraphs[1].size
  });
  inherited.editor.commands.deleteSelection();
  typeText(inherited.editor, "[] ");
  assert.deepEqual(
    inherited.editor.state.doc.content.content.slice(0, 2).map((node) => node.type.name),
    ["bulletList", "taskList"]
  );
  assert.match(inherited.editor.getMarkdown(), /- first[\s\S]*- \[ \] /);

  const preservesText = setup({ markdown: "- adada" });
  let paragraphStart = null;
  preservesText.editor.state.doc.descendants((node, position) => {
    if (paragraphStart == null && node.type.name === "paragraph") {
      paragraphStart = position + 1;
    }
  });
  assert.notEqual(paragraphStart, null);
  preservesText.editor.commands.setTextSelection(paragraphStart);
  typeText(preservesText.editor, "[] ");
  assert.equal(preservesText.editor.state.doc.firstChild.type.name, "taskList");
  assert.equal(preservesText.editor.state.doc.childCount, 1);
  assert.equal(
    preservesText.editor.state.doc.firstChild.firstChild.firstChild.textContent,
    "adada"
  );
  assert.equal(preservesText.editor.state.selection.$from.parentOffset, 0);
  assert.equal(preservesText.editor.getMarkdown(), "- [ ] adada");
});

test("task Enter and Backspace do not leave an undeletable empty row", () => {
  const { editor } = setup();
  typeText(editor, "- [] first");
  assert.equal(editor.state.doc.childCount, 1);
  assert.equal(editor.state.doc.firstChild.childCount, 1);

  assert.equal(pressKey(editor, "Enter"), true);
  assert.equal(editor.state.doc.firstChild.type.name, "taskList");
  assert.equal(editor.state.doc.firstChild.childCount, 2);
  assert.match(editor.getMarkdown(), /- \[ \] first\n- \[ \] $/);

  assert.equal(pressKey(editor, "Enter"), true);
  assert.equal(editor.state.doc.firstChild.type.name, "taskList");
  assert.equal(editor.state.doc.firstChild.childCount, 1);
  assert.equal(editor.state.doc.lastChild.type.name, "paragraph");

  assert.equal(pressKey(editor, "Backspace"), true);
  assert.equal(editor.state.doc.childCount, 1);
  assert.equal(editor.state.doc.firstChild.type.name, "taskList");
  assert.equal(editor.getMarkdown(), "- [ ] first");
});

test("typing a bullet marker at the start of a task row converts only that row", () => {
  const { editor } = setup({
    markdown: "- [ ] first\n- [x] second\n- [ ] third"
  });
  const taskParagraphs = [];
  editor.state.doc.descendants((node, position) => {
    if (node.type.name === "paragraph") taskParagraphs.push(position + 1);
  });
  editor.commands.setTextSelection(taskParagraphs[1]);
  typeText(editor, "- ");

  assert.deepEqual(
    editor.state.doc.content.content.map((node) => node.type.name),
    ["taskList", "bulletList", "taskList"]
  );
  assert.equal(editor.state.doc.child(1).firstChild.type.name, "listItem");
  assert.equal(editor.state.doc.child(1).textContent, "second");
  assert.equal(editor.getMarkdown(), "- [ ] first\n\n- second\n\n- [ ] third");

  const emptyRow = setup({ markdown: "- [ ] first" });
  emptyRow.editor.commands.focus("end");
  assert.equal(pressKey(emptyRow.editor, "Enter"), true);
  typeText(emptyRow.editor, "- ");
  assert.deepEqual(
    emptyRow.editor.state.doc.content.content.map((node) => node.type.name),
    ["taskList", "bulletList"]
  );
  assert.equal(emptyRow.editor.state.doc.lastChild.textContent, "");
});

test("bullet markers convert a nested task in place without detaching its checked parent", () => {
  for (const marker of ["- ", "+ ", "* "]) {
    const { editor } = setup({ markdown: "- [x] parent" });
    editor.commands.focus("end");
    assert.equal(pressKey(editor, "Enter"), true);
    assert.equal(pressKey(editor, "Tab"), true);

    let parent = editor.state.doc.firstChild.firstChild;
    assert.equal(parent.attrs.checked, true);
    assert.equal(parent.child(1).type.name, "taskList");

    typeText(editor, marker);
    parent = editor.state.doc.firstChild.firstChild;
    assert.equal(editor.state.doc.childCount, 1, marker);
    assert.equal(editor.state.doc.firstChild.type.name, "taskList", marker);
    assert.equal(editor.state.doc.firstChild.childCount, 1, marker);
    assert.equal(parent.type.name, "taskItem", marker);
    assert.equal(parent.attrs.checked, true, marker);
    assert.equal(parent.child(1).type.name, "bulletList", marker);
    assert.equal(parent.child(1).firstChild.type.name, "listItem", marker);

    typeText(editor, "child note");
    assert.equal(editor.getMarkdown(), "- [x] parent\n  - child note", marker);
  }

  const history = setup({ markdown: "- [x] parent\n  - [ ] " }).editor;
  history.commands.focus("end");
  typeText(history, "- ");
  assert.equal(history.getMarkdown(), "- [x] parent\n  - ");
  assert.equal(history.commands.undo(), true);
  assert.equal(history.getMarkdown(), "- [x] parent\n  - [ ] ");
  assert.equal(history.state.doc.firstChild.firstChild.attrs.checked, true);
  assert.equal(history.commands.redo(), true);
  assert.equal(history.getMarkdown(), "- [x] parent\n  - ");
});

test("Backspace removes a new child checkbox in place before deleting the empty bullet", () => {
  const { editor } = setup({ markdown: "- [x] parent" });
  editor.commands.focus("end");
  assert.equal(pressKey(editor, "Enter"), true);
  assert.equal(pressKey(editor, "Tab"), true);
  const nestedMarkdown = editor.getMarkdown();
  assert.equal(nestedMarkdown, "- [x] parent\n  - [ ] ");

  assert.equal(pressKey(editor, "Backspace"), true);
  assert.equal(editor.getMarkdown(), "- [x] parent\n  - ");
  assert.equal(editor.state.doc.firstChild.firstChild.attrs.checked, true);
  assert.equal(editor.state.doc.firstChild.firstChild.child(1).type.name, "bulletList");

  assert.equal(pressKey(editor, "Backspace"), true);
  assert.equal(editor.getMarkdown(), "- [x] parent");
  assert.equal(editor.state.doc.firstChild.firstChild.attrs.checked, true);
  assert.equal(editor.state.doc.firstChild.firstChild.childCount, 1);

  const history = setup({ markdown: nestedMarkdown }).editor;
  history.commands.focus("end");
  assert.equal(pressKey(history, "Backspace"), true);
  assert.equal(history.getMarkdown(), "- [x] parent\n  - ");
  assert.equal(history.commands.undo(), true);
  assert.equal(history.getMarkdown(), nestedMarkdown);
  assert.equal(history.state.doc.firstChild.firstChild.attrs.checked, true);
  assert.equal(history.commands.redo(), true);
  assert.equal(history.getMarkdown(), "- [x] parent\n  - ");
});

test("Backspace deletes only the empty nested bullet and preserves the parent checkbox state", () => {
  const cases = [
    { checked: false, children: ["only"], target: 0 },
    { checked: true, children: ["first", "second", "third"], target: 0 },
    { checked: true, children: ["first", "second", "third"], target: 1 }
  ];

  for (const { checked, children, target } of cases) {
    const markdown = [
      `- [${checked ? "x" : " "}] parent`,
      ...children.map((child) => `  - ${child}`)
    ].join("\n");
    const { editor } = setup({ markdown });
    const paragraphs = [];
    editor.state.doc.descendants((node, position) => {
      if (node.type.name === "paragraph") {
        paragraphs.push({ position: position + 1, size: node.content.size });
      }
    });
    const child = paragraphs[target + 1];
    editor.commands.setTextSelection({
      from: child.position,
      to: child.position + child.size
    });
    editor.commands.deleteSelection();

    assert.equal(pressKey(editor, "Backspace"), true);
    let parent = editor.state.doc.firstChild.firstChild;
    assert.equal(editor.state.doc.firstChild.type.name, "taskList");
    assert.equal(parent.type.name, "taskItem");
    assert.equal(parent.attrs.checked, checked);
    const remaining = children.filter((_value, index) => index !== target);
    if (remaining.length === 0) {
      assert.equal(parent.childCount, 1);
    } else {
      assert.equal(parent.child(1).type.name, "bulletList");
      assert.deepEqual(
        Array.from(parent.child(1).content.content, (item) => item.textContent),
        remaining
      );
    }

    assert.equal(editor.commands.undo(), true);
    parent = editor.state.doc.firstChild.firstChild;
    assert.equal(parent.attrs.checked, checked);
    assert.equal(parent.child(1).type.name, "bulletList");
    assert.equal(parent.child(1).childCount, children.length);
    assert.equal(editor.commands.redo(), true);
    parent = editor.state.doc.firstChild.firstChild;
    assert.equal(parent.attrs.checked, checked);
    assert.equal(parent.childCount, remaining.length === 0 ? 1 : 2);
  }
});

test("task items preserve nested bullet lists through GFM import and serialization", () => {
  const markdown = "- [ ] parent task\n  - child note\n  - another note\n- [x] next task";
  const { editor } = setup({ markdown });
  const taskList = editor.state.doc.firstChild;
  const parentTask = taskList.firstChild;

  assert.equal(taskList.type.name, "taskList");
  assert.equal(parentTask.type.name, "taskItem");
  assert.equal(parentTask.child(1).type.name, "bulletList");
  assert.equal(parentTask.child(1).childCount, 2);
  assert.equal(editor.getMarkdown(), markdown);
});

test("Tab moves an adjacent bullet under the previous task with one-step undo", () => {
  const original = "- [ ] parent task\n\n- child note\n- another note";
  const nested = "- [ ] parent task\n  - child note\n\n- another note";
  const { editor } = setup({ markdown: original });
  const paragraphs = [];
  editor.state.doc.descendants((node, position) => {
    if (node.type.name === "paragraph") paragraphs.push(position + 1);
  });
  editor.commands.setTextSelection(paragraphs[1]);

  assert.equal(pressKey(editor, "Tab"), true);
  const parentTask = editor.state.doc.firstChild.firstChild;
  assert.equal(parentTask.type.name, "taskItem");
  assert.equal(parentTask.child(1).type.name, "bulletList");
  assert.equal(parentTask.child(1).firstChild.type.name, "listItem");
  assert.equal(parentTask.child(1).textContent, "child note");
  assert.equal(editor.getMarkdown(), nested);

  assert.equal(editor.commands.undo(), true);
  assert.equal(editor.getMarkdown(), original);
  assert.equal(editor.commands.redo(), true);
  assert.equal(editor.getMarkdown(), nested);

  assert.equal(pressKey(editor, "Tab", { shiftKey: true }), true);
  assert.equal(editor.getMarkdown(), original);
});

test("task Enter, bullet typing, and Tab build a portable nested note", () => {
  const { editor } = setup();
  typeText(editor, "- [] parent task");
  assert.equal(pressKey(editor, "Enter"), true);
  typeText(editor, "- ");
  assert.deepEqual(
    editor.state.doc.content.content.map((node) => node.type.name),
    ["taskList", "bulletList"]
  );

  assert.equal(pressKey(editor, "Tab"), true);
  typeText(editor, "child note");
  assert.equal(editor.getMarkdown(), "- [ ] parent task\n  - child note");
});

test("Tab appends the first adjacent bullet to the last task's existing notes", () => {
  const original = [
    "- [ ] first task",
    "- [x] second task",
    "  - existing note",
    "",
    "- moved note",
    "- stays outside"
  ].join("\n");
  const nested = [
    "- [ ] first task",
    "- [x] second task",
    "  - existing note",
    "  - moved note",
    "",
    "- stays outside"
  ].join("\n");
  const { editor } = setup({ markdown: original });
  const paragraphs = [];
  editor.state.doc.descendants((node, position) => {
    if (node.type.name === "paragraph") paragraphs.push(position + 1);
  });
  editor.commands.setTextSelection(paragraphs[3]);

  assert.equal(pressKey(editor, "Tab"), true);
  const lastTask = editor.state.doc.firstChild.lastChild;
  assert.equal(lastTask.lastChild.type.name, "bulletList");
  assert.equal(lastTask.lastChild.childCount, 2);
  assert.equal(editor.getMarkdown(), nested);

  assert.equal(pressKey(editor, "Tab", { shiftKey: true }), true);
  assert.equal(editor.getMarkdown(), original);
});

test("task and bullet keyboard shortcuts convert in both directions", () => {
  const { editor } = setup({ markdown: "- [ ] keep me" });
  editor.commands.focus("end");

  assert.equal(pressKey(editor, "8", { metaKey: true, shiftKey: true }), true);
  assert.equal(editor.state.doc.firstChild.type.name, "bulletList");
  assert.equal(editor.state.doc.firstChild.firstChild.type.name, "listItem");
  assert.equal(editor.getMarkdown(), "- keep me");

  assert.equal(pressKey(editor, "9", { metaKey: true, shiftKey: true }), true);
  assert.equal(editor.state.doc.firstChild.type.name, "taskList");
  assert.equal(editor.state.doc.firstChild.firstChild.type.name, "taskItem");
  assert.equal(editor.getMarkdown(), "- [ ] keep me");
});

test("content height measurement never mutates task content or selection", () => {
  const { api, editor, messages } = setup({ markdown: "- [ ] one\n- [x] two" });
  editor.commands.setTextSelection(5);
  const markdownBefore = editor.getMarkdown();
  const jsonBefore = editor.getJSON();
  const selectionBefore = {
    from: editor.state.selection.from,
    to: editor.state.selection.to
  };

  api.measureContentHeight();
  api.measureContentHeight();

  assert.equal(editor.getMarkdown(), markdownBefore);
  assert.deepEqual(editor.getJSON(), jsonBefore);
  assert.deepEqual(
    { from: editor.state.selection.from, to: editor.state.selection.to },
    selectionBefore
  );
  assert.equal(messages.filter((message) => message.type === "contentHeightChanged").length, 1);
});

test("Tab indents code and lists without trapping ordinary paragraphs", () => {
  const code = setup({ markdown: "```python\none\ntwo\n```" });
  code.editor.commands.setTextSelection({ from: 1, to: 8 });
  assert.equal(pressKey(code.editor, "Tab"), true);
  assert.equal(code.editor.state.doc.firstChild.textContent, "    one\n    two");
  assert.equal(pressKey(code.editor, "Tab", { shiftKey: true }), true);
  assert.equal(code.editor.state.doc.firstChild.textContent, "one\ntwo");
  code.editor.commands.setTextSelection(4);
  assert.equal(pressKey(code.editor, "Tab"), true);
  assert.match(code.editor.state.doc.firstChild.textContent, /^one {4}/);

  for (const markdown of ["- one\n- two", "- [ ] one\n- [ ] two"]) {
    const list = setup({ markdown });
    const paragraphs = [];
    list.editor.state.doc.descendants((node, position) => {
      if (node.type.name === "paragraph") paragraphs.push(position + 1);
    });
    list.editor.commands.setTextSelection(paragraphs[1]);
    assert.equal(pressKey(list.editor, "Tab"), true);
    assert.match(list.editor.getMarkdown(), /\n  - (?:\[ \] )?two/);
    assert.equal(pressKey(list.editor, "Tab", { shiftKey: true }), true);
    assert.doesNotMatch(list.editor.getMarkdown(), /\n  - (?:\[ \] )?two/);
  }

  const paragraph = setup({ markdown: "Body" });
  paragraph.editor.commands.setTextSelection(3);
  assert.equal(pressKey(paragraph.editor, "Tab"), false);
  assert.equal(paragraph.editor.getMarkdown(), "Body");
});

test("language fences normalize aliases for highlighting while preserving source info strings", () => {
  assert.equal(normalizeCodeLanguage("python3"), "python");
  assert.equal(normalizeCodeLanguage("C++"), "cpp");
  assert.equal(normalizeCodeLanguage("zsh"), "bash");
  assert.equal(codeBlockDisplayTitle('python3 title="attention.py"'), "attention.py");
  assert.equal(codeBlockDisplayTitle("python title='attention graph.py'"), "attention graph.py");
  const { dom, editor } = setup({
    markdown: [
      '```python3 title="attention.py"', "def answer():", "    return 42", "```", "",
      "```c++", "int main() { return 0; }", "```", "",
      "```mystery", "opaque token", "```"
    ].join("\n")
  });
  const python = dom.window.document.querySelector("code.language-python");
  const cpp = dom.window.document.querySelector("code.language-cpp");
  const unknown = dom.window.document.querySelector("code.language-mystery");
  const titled = python.closest("pre");
  assert.ok(python.querySelector(".hljs-keyword"));
  assert.ok(cpp.querySelector(".hljs-type, .hljs-keyword"));
  assert.equal(unknown.querySelector("span"), null);
  assert.equal(titled.dataset.codeTitle, "attention.py");
  assert.match(titled.getAttribute("aria-label"), /^attention\.py, python code block\./u);
  assert.match(editor.getMarkdown(), /```python3 title="attention\.py"\n/);
  assert.match(editor.getMarkdown(), /```c\+\+\n/);
  assert.match(editor.getMarkdown(), /```mystery\n/);

  editor.commands.setContent("", { contentType: "markdown", emitUpdate: false });
  typeText(editor, "```python ");
  assert.equal(editor.state.doc.firstChild.type.name, "codeBlock");
  assert.equal(editor.state.doc.firstChild.attrs.language, "python");
});

test("empty cards show command discovery without serializing placeholder copy", () => {
  const { dom, api, editor } = setup();
  const canvas = dom.window.document.querySelector(".ProseMirror");
  const placeholder = canvas.querySelector("[data-placeholder]");
  assert.equal(canvas.textContent, "");
  assert.equal(placeholder?.dataset.placeholder, "Start writing… Type / for commands");
  assert.equal(api.getState().markdown, "");
  assert.equal(editor.getMarkdown(), "");
});

test("revisioned transactions serialize Markdown and undo/redo without rebuilding the canvas", () => {
  const { dom, api, editor, messages } = setup({ markdown: "Body", revision: 3 });
  const canvas = dom.window.document.querySelector(".ProseMirror");
  editor.commands.setTextSelection(editor.state.doc.content.size);
  editor.commands.insertContent(" updated");

  assert.equal(dom.window.document.querySelector(".ProseMirror"), canvas);
  assert.equal(api.getState().revision, 4);
  assert.equal(api.getState().markdown, "Body updated");
  assert.deepEqual(messages.at(-1), {
    type: "markdownChanged",
    cardID: "card-one",
    markdown: "Body updated",
    revision: 4
  });

  editor.commands.undo();
  assert.equal(api.getState().markdown, "Body");
  editor.commands.redo();
  assert.equal(api.getState().markdown, "Body updated");
});

test("IME composition keeps the same continuous editor instance", () => {
  const { dom, api, editor } = setup({ markdown: "中文" });
  const canvas = dom.window.document.querySelector(".ProseMirror");
  canvas.dispatchEvent(new dom.window.CompositionEvent("compositionstart", { bubbles: true, data: "输" }));
  canvas.dispatchEvent(new dom.window.CompositionEvent("compositionend", { bubbles: true, data: "输入" }));
  editor.commands.setContent("中文输入", { contentType: "markdown", emitUpdate: true });

  assert.equal(dom.window.document.querySelector(".ProseMirror"), canvas);
  assert.equal(api.getState().markdown, "中文输入");
});

test("stale native payloads do not overwrite newer local edits", () => {
  const { api, editor } = setup({ markdown: "Before", revision: 7 });
  editor.commands.focus("end");
  editor.commands.insertContent(" local");
  assert.equal(api.getState().revision, 8);

  api.render({ cardID: "card-one", markdown: "Before", revision: 7 });
  assert.equal(api.getState().markdown, "Before local");
  assert.equal(api.getState().revision, 8);
});

test("same-card external updates preserve scroll and selection; new cards reset scroll", () => {
  const { dom, api, editor } = setup({ markdown: "One paragraph", revision: 1 });
  const root = dom.window.document.getElementById("renderer");
  editor.commands.setTextSelection({ from: 2, to: 5 });
  root.scrollTop = 120;
  api.render({ cardID: "card-one", markdown: "Updated paragraph", revision: 2 });
  assert.equal(root.scrollTop, 120);
  assert.deepEqual(api.getState().selection, { from: 2, to: 5 });

  api.render({ cardID: "card-two", markdown: "Two", revision: 0 });
  assert.equal(root.scrollTop, 0);
});

test("switching cards resets undo history instead of restoring the previous card", () => {
  const { api, editor, messages } = setup({ markdown: "# Source", revision: 1 });
  editor.commands.focus("end");
  editor.commands.insertContent(" edited");

  api.render({ cardID: "card-two", markdown: "# Target", revision: 4 });
  const messageCount = messages.length;

  assert.equal(editor.commands.undo(), false);
  assert.equal(api.getState().markdown, "# Target");
  assert.equal(api.getState().revision, 4);
  assert.equal(messages.length, messageCount);
  assert.equal(messages.some((message) => (
    message.type === "markdownChanged"
      && message.cardID === "card-two"
      && message.markdown.includes("Source")
  )), false);
});

test("external links open once on primary click, Command-click, and keyboard activation", () => {
  const { dom, messages } = setup({
    markdown: "[Web](https://example.com/path) [Mail](mailto:hello@example.com)"
  });
  const web = dom.window.document.querySelector("a[href='https://example.com/path']");
  const mail = dom.window.document.querySelector("a[href='mailto:hello@example.com']");

  assert.equal(web.dispatchEvent(new dom.window.MouseEvent("click", {
    bubbles: true,
    cancelable: true,
    button: 0
  })), false);
  assert.deepEqual(messages.filter((message) => message.type === "openExternalLink"), [{
    type: "openExternalLink",
    url: "https://example.com/path"
  }]);

  web.dispatchEvent(new dom.window.MouseEvent("click", {
    bubbles: true,
    cancelable: true,
    button: 0,
    metaKey: true
  }));
  mail.dispatchEvent(new dom.window.MouseEvent("click", {
    bubbles: true,
    cancelable: true,
    button: 0,
    detail: 0
  }));
  assert.deepEqual(messages.filter((message) => message.type === "openExternalLink"), [
    { type: "openExternalLink", url: "https://example.com/path" },
    { type: "openExternalLink", url: "https://example.com/path" },
    { type: "openExternalLink", url: "mailto:hello@example.com" }
  ]);

  for (const options of [
    { button: 0, ctrlKey: true },
    { button: 0, shiftKey: true },
    { button: 1 },
    { button: 2 }
  ]) {
    assert.equal(web.dispatchEvent(new dom.window.MouseEvent("click", {
      bubbles: true,
      cancelable: true,
      ...options
    })), true);
  }
  assert.equal(messages.filter((message) => message.type === "openExternalLink").length, 3);
});

test("dragging a link does not accidentally open it", () => {
  const { dom, messages } = setup({ markdown: "[Drag me](https://example.com/path)" });
  const link = dom.window.document.querySelector("a");
  link.dispatchEvent(new dom.window.MouseEvent("mousedown", {
    bubbles: true,
    cancelable: true,
    button: 0,
    clientX: 4,
    clientY: 4
  }));
  link.dispatchEvent(new dom.window.MouseEvent("mousemove", {
    bubbles: true,
    cancelable: true,
    button: 0,
    clientX: 12,
    clientY: 4
  }));
  link.dispatchEvent(new dom.window.MouseEvent("mouseup", {
    bubbles: true,
    cancelable: true,
    button: 0,
    clientX: 12,
    clientY: 4
  }));
  link.dispatchEvent(new dom.window.MouseEvent("click", {
    bubbles: true,
    cancelable: true,
    button: 0,
    clientX: 12,
    clientY: 4
  }));
  assert.equal(messages.some((message) => message.type === "openExternalLink"), false);
});

test("hovering an external link for one second opens the existing editor without stealing focus", async () => {
  const url = "https://example.com/same";
  const markdown = `[First](${url}) and [Second](${url})`;
  const { dom, editor } = setup({ markdown, revision: 1 });
  const links = [...dom.window.document.querySelectorAll("a[href]")];
  const secondLink = links[1];
  const popover = dom.window.document.querySelector(".link-editor-popover");
  const textInput = popover.querySelector("input[name='text']");
  const urlInput = popover.querySelector("input[name='url']");
  const activeElement = dom.window.document.activeElement;

  secondLink.dispatchEvent(new dom.window.MouseEvent("mouseover", {
    bubbles: true,
    relatedTarget: dom.window.document.body
  }));
  await new Promise((resolve) => dom.window.setTimeout(resolve, 250));
  assert.equal(popover.hidden, true);
  await new Promise((resolve) => dom.window.setTimeout(resolve, 850));

  assert.equal(popover.hidden, false);
  assert.equal(popover.dataset.openedBy, "hover");
  assert.equal(textInput.value, "Second");
  assert.equal(urlInput.value, url);
  assert.equal(dom.window.document.activeElement, activeElement);

  textInput.value = "Updated";
  textInput.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  secondLink.dispatchEvent(new dom.window.MouseEvent("mouseout", {
    bubbles: true,
    relatedTarget: popover
  }));
  popover.dispatchEvent(new dom.window.MouseEvent("mouseleave", {
    relatedTarget: dom.window.document.body
  }));
  await new Promise((resolve) => dom.window.setTimeout(resolve, 220));
  assert.equal(popover.hidden, false);

  popover.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
  assert.equal(editor.getMarkdown(), `[First](${url}) and [Updated](${url})`);
  assert.equal(popover.hidden, true);
  assert.equal(editor.commands.undo(), true);
  assert.equal(editor.getMarkdown(), markdown);
});

test("smart links classify exact platform hosts and derive offline titles", () => {
  const providers = new Map([
    ["https://support.apple.com/en-us/HT213650", "apple"],
    ["https://github.com/example/project", "github"],
    ["https://gist.github.com/example/abc123", "github"],
    ["https://huggingface.co/Qwen/Qwen3-8B", "huggingface"],
    ["https://zhuanlan.zhihu.com/p/123456", "zhihu"],
    ["https://www.xiaohongshu.com/explore/abc123", "xiaohongshu"],
    ["https://x.com/example/status/123", "x"],
    ["https://mobile.twitter.com/example/status/123", "x"],
    ["https://www.figma.com/design/example/file", "figma"],
    ["https://linear.app/example/issue/MC-7", "linear"],
    ["https://example.notion.site/Notes-123", "notion"],
    ["https://workspace.slack.com/archives/C123", "slack"],
    ["https://mail.google.com/mail/u/0/", "gmail"],
    ["https://calendar.google.com/calendar/u/0/r", "googlecalendar"],
    ["https://drive.google.com/file/d/123/view", "googledrive"],
    ["https://docs.google.com/document/d/123/edit", "googledocs"],
    ["https://docs.google.com/spreadsheets/d/123/edit", "googlesheets"],
    ["https://docs.google.com/presentation/d/123/edit", "googleslides"],
    ["https://gitlab.com/example/project", "gitlab"],
    ["https://export.arxiv.org/abs/2401.01234", "arxiv"],
    ["https://openreview.net/forum?id=abc123", "openreview"],
    ["https://doi.org/10.1145/123", "doi"],
    ["https://paperswithcode.com/paper/example", "paperswithcode"],
    ["https://www.kaggle.com/competitions/example", "kaggle"],
    ["https://platform.openai.com/docs", "openai"],
    ["https://colab.research.google.com/drive/123", "googlecolab"],
    ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "youtube"],
    ["https://www.bilibili.com/video/BV1xx411c7mD", "bilibili"],
    ["https://example.com/guide", "web"],
    ["https://github.com.evil.test/example/project", "web"]
  ]);
  for (const [url, provider] of providers) {
    assert.equal(smartLinkProviderForURL(url)?.id, provider);
  }

  for (const rejected of [
    "https://github.com@evil.test/example/project",
    "javascript:https://github.com/example/project",
    "mailto:hello@github.com"
  ]) {
    assert.equal(smartLinkProviderForURL(rejected), null);
  }

  assert.equal(
    smartLinkTitleForURL("https://github.com/example/project/issues/42"),
    "example/project · Issue #42"
  );
  assert.equal(
    smartLinkTitleForURL("https://huggingface.co/datasets/example/corpus"),
    "example/corpus · Dataset"
  );
  assert.equal(
    smartLinkTitleForURL("https://x.com/example/status/123"),
    "@example · Post"
  );
  assert.equal(
    smartLinkTitleForURL("https://www.zhihu.com/question/123456"),
    "知乎问题 #123456"
  );
  assert.equal(
    smartLinkTitleForURL("https://arxiv.org/pdf/2401.01234.pdf"),
    "arXiv · 2401.01234"
  );
  assert.equal(
    smartLinkTitleForURL("https://openreview.net/forum?id=abc123"),
    "OpenReview · abc123"
  );
  assert.equal(smartLinkTitleForURL("https://www.example.com/guide"), "example.com");
  assert.equal(
    smartLinkTitleForURL("https://github.com/%0Aevil/%E2%80%AErepo"),
    "evil/repo"
  );
  const boundedTitle = smartLinkTitleForURL(`https://github.com/${"a".repeat(500)}/repo`);
  assert.ok([...boundedTitle].length <= 120);
  assert.doesNotMatch(boundedTitle, /[\u0000-\u001f\u007f-\u009f\u202a-\u202e]/u);
});

test("only standalone external links show local icons and preserve Markdown bytes", () => {
  const markdown = [
    "[Markdown Card](https://github.com/example/markdown-card)",
    "",
    "正文中的 [GitHub](https://github.com/) 应保持普通内联样式。",
    "",
    "[Qwen 模型](https://huggingface.co/Qwen/Qwen3-8B \"Model\")",
    "",
    "[伪装链接](https://github.com.evil.test/example)"
  ].join("\n");
  const { dom, api, editor, messages } = setup({ markdown, revision: 1 });
  const blocks = [...dom.window.document.querySelectorAll("p.smart-link-block")];

  assert.equal(blocks.length, 3);
  assert.deepEqual(
    blocks.map((block) => block.dataset.smartLinkProvider),
    ["github", "huggingface", "web"]
  );
  const githubLink = blocks[0].querySelector("a.smart-link");
  assert.equal(githubLink?.dataset.smartLinkProvider, "github");
  assert.equal(githubLink?.querySelector(".smart-link-icon")?.getAttribute("aria-hidden"), "true");
  assert.equal(githubLink?.querySelector(".smart-link-icon")?.getAttribute("draggable"), "false");
  assert.equal(githubLink?.querySelector(".smart-link-icon")?.dataset.markdownCopy, "exclude");
  assert.equal(githubLink?.querySelector(".smart-link-icon svg")?.getAttribute("focusable"), "false");
  assert.equal(githubLink?.querySelector(".smart-link-title")?.textContent, "Markdown Card");
  assert.equal(
    dom.window.document.querySelector("a[href='https://github.com/']")
      ?.closest("p")?.classList.contains("smart-link-block"),
    false
  );
  assert.equal(
    dom.window.document.querySelector("a[href='https://github.com.evil.test/example']")
      ?.classList.contains("smart-link"),
    true
  );
  assert.equal(
    dom.window.document.querySelector("a[href='https://github.com.evil.test/example']")
      ?.closest("p")?.dataset.smartLinkProvider,
    "web"
  );
  assert.equal(editor.getMarkdown(), markdown);
  assert.equal(api.getMarkdownForCopy(), markdown);
  assert.equal(api.getMarkdownExportBundle().markdown, markdown);
  assert.doesNotMatch(api.getMarkdownForCopy(), /smart-link|🤗|𝕏/u);

  editor.commands.setTextSelection(1);
  githubLink.querySelector(".smart-link-icon").dispatchEvent(new dom.window.MouseEvent("click", {
    bubbles: true,
    cancelable: true,
    button: 0
  }));
  assert.deepEqual(messages.filter((message) => message.type === "openExternalLink"), [{
    type: "openExternalLink",
    url: "https://github.com/example/markdown-card"
  }]);
});

test("smart-link icon styling stays compact, local, and non-circular", async () => {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  const linkRule = css.match(/\.smart-link-block \.smart-link\s*\{([\s\S]*?)\}/u)?.[1] ?? "";
  const titleRule = css.match(/\.smart-link-block \.smart-link-title\s*\{([\s\S]*?)\}/u)?.[1] ?? "";
  const iconRule = css.match(/\.smart-link-block \.smart-link-icon\s*\{([\s\S]*?)\}/u)?.[1] ?? "";
  const iconSource = await readFile(new URL("../src/smart-link-icons.js", import.meta.url), "utf8");

  assert.match(linkRule, /align-items:\s*flex-start/u);
  assert.match(linkRule, /line-height:\s*1\.35/u);
  assert.match(titleRule, /line-height:\s*inherit/u);
  assert.match(titleRule, /overflow-wrap:\s*anywhere/u);
  assert.doesNotMatch(titleRule, /padding-(?:block-)?top/u);
  assert.match(iconRule, /width:\s*16px/u);
  assert.match(iconRule, /height:\s*16px/u);
  assert.match(iconRule, /flex:\s*0\s+0\s+16px/u);
  assert.match(iconRule, /margin-block-start:\s*0\.175em/u);
  assert.match(iconRule, /padding:\s*var\(--smart-link-icon-inset,\s*2px\)/u);
  assert.match(
    iconRule,
    /background-color:\s*var\(--smart-link-brand-color,\s*#667085\)/u
  );
  assert.match(
    iconRule,
    /color:\s*var\(--smart-link-brand-foreground,\s*#ffffff\)/u
  );
  assert.match(
    iconRule,
    /box-shadow:\s*inset 0 0 0 1px var\(--smart-link-tile-outline,\s*transparent\)/u
  );
  assert.match(iconRule, /line-height:\s*0/u);
  assert.match(iconRule, /opacity:\s*1/u);
  assert.doesNotMatch(iconRule, /border-radius:\s*50%/u);
  assert.doesNotMatch(iconRule, /color-mix/u);
  assert.doesNotMatch(iconSource, /["']mark["']/u);
  assert.deepEqual(
    [...iconSource.matchAll(/https?:\/\/[^"']+/gu)].map((match) => match[0]),
    ["http://www.w3.org/2000/svg"]
  );
  assert.doesNotMatch(iconSource, /\bfetch\s*\(|XMLHttpRequest|createElement\(["']img["']/u);

  const xiaohongshu = setup({
    markdown: "[小红书笔记](https://www.xiaohongshu.com/explore/abc123)"
  });
  const icon = xiaohongshu.dom.window.document.querySelector(".smart-link-icon");
  assert.equal(icon?.dataset.iconPresentation, "tile");
  assert.equal(icon?.style.getPropertyValue("--smart-link-brand-color"), "#FF2442");
  assert.equal(icon?.style.getPropertyValue("--smart-link-brand-foreground"), "#FFFFFF");
  assert.equal(icon?.style.getPropertyValue("--smart-link-icon-inset"), "1px");
  assert.doesNotMatch(iconSource, /contrastingForeground|#171717/u);
});

test("every smart-link provider uses a solid icon tile with high-contrast geometry", () => {
  const examples = new Map([
    ["apple", "https://support.apple.com/en-us/HT213650"],
    ["github", "https://github.com/example/project"],
    ["huggingface", "https://huggingface.co/Qwen/Qwen3-8B"],
    ["zhihu", "https://www.zhihu.com/question/123456"],
    ["xiaohongshu", "https://www.xiaohongshu.com/explore/abc123"],
    ["x", "https://x.com/example/status/123"],
    ["figma", "https://www.figma.com/design/example/file"],
    ["linear", "https://linear.app/example/issue/MC-7"],
    ["notion", "https://example.notion.site/Notes-123"],
    ["slack", "https://workspace.slack.com/archives/C123"],
    ["gmail", "https://mail.google.com/mail/u/0/"],
    ["googlecalendar", "https://calendar.google.com/calendar/u/0/r"],
    ["googledrive", "https://drive.google.com/file/d/123/view"],
    ["googledocs", "https://docs.google.com/document/d/123/edit"],
    ["googlesheets", "https://docs.google.com/spreadsheets/d/123/edit"],
    ["googleslides", "https://docs.google.com/presentation/d/123/edit"],
    ["gitlab", "https://gitlab.com/example/project"],
    ["arxiv", "https://arxiv.org/abs/2401.01234"],
    ["openreview", "https://openreview.net/forum?id=abc123"],
    ["doi", "https://doi.org/10.1145/123"],
    ["paperswithcode", "https://paperswithcode.com/paper/example"],
    ["kaggle", "https://www.kaggle.com/competitions/example"],
    ["openai", "https://platform.openai.com/docs"],
    ["googlecolab", "https://colab.research.google.com/drive/123"],
    ["youtube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"],
    ["bilibili", "https://www.bilibili.com/video/BV1xx411c7mD"],
    ["web", "https://example.com/guide"]
  ]);
  const expectedPalette = new Map([
    ["apple", ["#147EFB", "#FFFFFF"]],
    ["github", ["#000000", "#FFFFFF"]],
    ["huggingface", ["#FFFFFF", "#3A3B45"]],
    ["zhihu", ["#0084FF", "#FFFFFF"]],
    ["xiaohongshu", ["#FF2442", "#FFFFFF"]],
    ["x", ["#5F6F7A", "#FFFFFF"]],
    ["figma", ["#D83B16", "#FFFFFF"]],
    ["linear", ["#5E6AD2", "#FFFFFF"]],
    ["notion", ["#F7F7F5", "#111111"]],
    ["slack", ["#4A154B", "#FFFFFF"]],
    ["gmail", ["#EA4335", "#FFFFFF"]],
    ["googlecalendar", ["#1967D2", "#FFFFFF"]],
    ["googledrive", ["#1769AA", "#FFFFFF"]],
    ["googledocs", ["#1967D2", "#FFFFFF"]],
    ["googlesheets", ["#137333", "#FFFFFF"]],
    ["googleslides", ["#9A5B00", "#FFFFFF"]],
    ["gitlab", ["#B63B0B", "#FFFFFF"]],
    ["arxiv", ["#B31B1B", "#FFFFFF"]],
    ["openreview", ["#176B87", "#FFFFFF"]],
    ["doi", ["#4A3500", "#FAB70C"]],
    ["paperswithcode", ["#087F8C", "#FFFFFF"]],
    ["kaggle", ["#0077A8", "#FFFFFF"]],
    ["openai", ["#0B7F62", "#FFFFFF"]],
    ["googlecolab", ["#B85C00", "#FFFFFF"]],
    ["youtube", ["#FF0000", "#FFFFFF"]],
    ["bilibili", ["#007AA3", "#FFFFFF"]],
    ["web", ["#667085", "#FFFFFF"]]
  ]);
  const luminance = (color) => {
    const channels = color.slice(1).match(/.{2}/gu).map(
      (channel) => Number.parseInt(channel, 16) / 255
    );
    return channels.reduce((sum, channel, index) => {
      const linear = channel <= 0.04045
        ? channel / 12.92
        : ((channel + 0.055) / 1.055) ** 2.4;
      return sum + linear * [0.2126, 0.7152, 0.0722][index];
    }, 0);
  };
  const contrastRatio = (first, second) => {
    const values = [luminance(first), luminance(second)].sort((left, right) => right - left);
    return (values[0] + 0.05) / (values[1] + 0.05);
  };

  for (const [provider, url] of examples) {
    const { dom } = setup({ markdown: `[Link](${url})` });
    const icon = dom.window.document.querySelector(".smart-link-icon");
    assert.ok(icon, `${provider} should render a local icon`);
    assert.equal(
      icon.dataset.iconPresentation,
      provider === "web" ? "generic" : "tile",
      `${provider} should not use a transparent mark presentation`
    );
    const background = icon.style.getPropertyValue("--smart-link-brand-color");
    const foreground = icon.style.getPropertyValue("--smart-link-brand-foreground");
    assert.deepEqual(
      [background, foreground],
      expectedPalette.get(provider),
      `${provider} should use its theme-independent palette`
    );
    assert.match(background, /^#[\dA-F]{6}$/iu, `${provider} needs a solid background`);
    assert.match(foreground, /^#[\dA-F]{6}$/iu, `${provider} needs a solid foreground`);
    if (provider !== "github") {
      assert.notEqual(background.toUpperCase(), "#000000", `${provider} must not use a black tile`);
    }
    assert.ok(
      contrastRatio(background, foreground) >= 3,
      `${provider} icon geometry should have at least 3:1 contrast`
    );
    if (provider === "huggingface") {
      assert.equal(background, "#FFFFFF");
      assert.equal(foreground, "#3A3B45");
      assert.equal(icon.style.getPropertyValue("--smart-link-icon-inset"), "1px");
      assert.equal(icon.querySelector("svg")?.getAttribute("viewBox"), "0 0 95 88");
      assert.deepEqual(
        [...icon.querySelectorAll("svg path")].map((path) => path.getAttribute("fill")),
        ["#FFD21E", "#FF9D0B", "#3A3B45", "#FF323D", "#3A3B45", "#FF9D0B", "#FFD21E", "#FF9D0B", "#FFD21E"]
      );
    }
    if (provider === "github") {
      assert.equal(background, "#000000");
      assert.equal(foreground, "#FFFFFF");
      assert.equal(icon.querySelector("svg")?.getAttribute("viewBox"), "0 0 24 24");
      assert.match(
        icon.querySelector("svg path")?.getAttribute("d") ?? "",
        /^M10\.226 17\.284/u
      );
    }
    if (provider === "notion") {
      assert.equal(icon.style.getPropertyValue("--smart-link-tile-outline"), "#D4D4D0");
    }
    assert.ok(icon.querySelector("svg path"), `${provider} should keep bundled vector geometry`);
    if (!["huggingface", "notion", "doi"].includes(provider)) {
      assert.equal(foreground, "#FFFFFF", `${provider} should use a white mark`);
    }
  }
});

test("pasting any safe bare HTTP URL into an empty Rich paragraph is one undo step", () => {
  const url = "https://github.com/example/project/pull/7";
  const { dom, editor } = setup();
  assert.deepEqual(pasteText(editor, url), { handled: true, prevented: true });
  assert.equal(editor.getMarkdown(), `[example/project · PR #7](${url})`);
  assert.equal(dom.window.document.querySelectorAll("p.smart-link-block").length, 1);
  assert.equal(editor.commands.undo(), true);
  assert.equal(editor.getMarkdown(), "");

  const inline = setup({ markdown: "Prefix ", revision: 1 });
  inline.editor.commands.setTextSelection(inline.editor.state.doc.content.size - 1);
  assert.equal(insertSmartLinkFromPaste(inline.editor.view, url), false);
  assert.equal(inline.editor.getMarkdown(), "Prefix ");

  const generic = setup();
  assert.equal(insertSmartLinkFromPaste(generic.editor.view, "https://example.com/path"), true);
  assert.equal(generic.editor.getMarkdown(), "[example.com](https://example.com/path)");
  assert.equal(generic.editor.commands.undo(), true);
  assert.equal(generic.editor.getMarkdown(), "");
});

test("every supported provider derives a local title while Source paste stays native", () => {
  const examples = new Map([
    ["https://support.apple.com/en-us/HT213650", "Apple 支持 · HT213650"],
    ["https://github.com/example/project", "example/project"],
    ["https://huggingface.co/Qwen/Qwen3-8B", "Qwen/Qwen3-8B"],
    ["https://www.zhihu.com/question/123456", "知乎问题 #123456"],
    ["https://www.xiaohongshu.com/explore/abc123", "小红书笔记"],
    ["https://x.com/example/status/123", "@example · Post"],
    ["https://arxiv.org/abs/2401.01234", "arXiv · 2401.01234"],
    ["https://openreview.net/forum?id=abc123", "OpenReview · abc123"],
    ["https://example.com/path", "example.com"]
  ]);
  for (const [url, expectedTitle] of examples) {
    const pasted = setup();
    assert.equal(insertSmartLinkFromPaste(pasted.editor.view, url), true);
    assert.equal(pasted.editor.state.doc.textContent, expectedTitle);
  }

  const source = setup();
  source.api.setEditorMode("source", { focus: false });
  const sourceEditor = source.dom.window.document.querySelector(".source-editor");
  const event = new source.dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: { getData: () => "https://github.com/example/project" }
  });
  assert.equal(sourceEditor.dispatchEvent(event), true);
  assert.equal(event.defaultPrevented, false);
  assert.equal(source.editor.getMarkdown(), "");
});

test("smart-link paste keeps hostile URL delimiters parseable across Markdown round trips", () => {
  for (const source of [
    "https://github.com/example/project?value=)",
    "https://github.com/example/project?value=(nested)",
    "https://github.com/example/project?value=<tag>",
    "https://github.com/example/project?value=\\path"
  ]) {
    const pasted = setup();
    assert.equal(insertSmartLinkFromPaste(pasted.editor.view, source), true);
    const markdown = pasted.editor.getMarkdown();
    const href = pasted.dom.window.document.querySelector("a")?.getAttribute("href");
    assert.ok(href);
    assert.doesNotMatch(href, /[()<>\\]/u);

    const reopened = setup({ markdown, revision: 1 });
    assert.equal(
      reopened.dom.window.document.querySelector("a")?.getAttribute("href"),
      href
    );
    assert.equal(reopened.editor.getMarkdown(), markdown);
  }
});

test("smart-link generated labels neutralize Markdown delimiters across reopen", () => {
  for (const source of [
    "https://github.com/%5Devil/repo",
    "https://github.com/%2Aevil%2A/repo",
    "https://github.com/%60evil%60/repo",
    "https://github.com/%5Cevil/repo",
    "https://github.com/%7E%7Eevil%7E%7E/repo",
    "https://github.com/%7Cevil/repo",
    "https://github.com/%5Eevil%5E/repo",
    "https://github.com/%24evil%24/repo"
  ]) {
    const pasted = setup();
    assert.equal(insertSmartLinkFromPaste(pasted.editor.view, source), true);
    const markdown = pasted.editor.getMarkdown();
    const title = pasted.editor.state.doc.textContent;
    assert.doesNotMatch(title, /[\\[\]*_`~|^$]/u);

    const reopened = setup({ markdown, revision: 1 });
    assert.equal(reopened.editor.state.doc.textContent, title);
    assert.equal(reopened.editor.getMarkdown(), markdown);
    assert.equal(reopened.dom.window.document.querySelectorAll("p.smart-link-block").length, 1);
  }
});

test("slash plugin menu inserts YouTube and converts supported URLs", () => {
  assert.deepEqual(rendererPluginRegistry.map((plugin) => plugin.id), ["youtube", "table", "tag"]);
  const expectedID = "dQw4w9WgXcQ";
  for (const source of [
    `https://www.youtube.com/watch?v=${expectedID}`,
    `https://youtu.be/${expectedID}`,
    `https://youtube.com/shorts/${expectedID}`,
    `https://youtube.com/embed/${expectedID}`
  ]) {
    assert.equal(parseYouTubeURL(source)?.videoID, expectedID);
  }
  assert.equal(parseYouTubeURL("https://example.com/watch?v=dQw4w9WgXcQ"), null);
  assert.equal(parseYouTubeURL("file:///tmp/video"), null);

  const { dom, editor } = setup();
  typeText(editor, "/");
  const menu = dom.window.document.querySelector(".slash-plugin-menu");
  assert.ok(menu);
  assert.equal(menu.hidden, false);
  assert.match(menu.textContent, /YouTube/);
  assert.equal(pressKey(editor, "ArrowDown"), true);
  assert.equal(pressKey(editor, "ArrowUp"), true);
  assert.equal(pressKey(editor, "Escape"), true);
  assert.equal(menu.hidden, true);
  typeText(editor, "y");
  assert.equal(menu.hidden, false);
  assert.equal(pressKey(editor, "Enter"), true);
  assert.equal(editor.getText(), "/youtube ");

  assert.deepEqual(
    pasteText(editor, `https://youtu.be/${expectedID}?si=slash-command`),
    { handled: true, prevented: true }
  );
  assert.equal(editor.state.doc.firstChild.type.name, "youtubeCard");
  assert.equal(editor.state.doc.firstChild.attrs.videoID, expectedID);
  assert.equal(dom.window.document.querySelectorAll(".youtube-card").length, 1);
  assert.equal(
    dom.window.document.querySelector(".youtube-card-image")?.getAttribute("src"),
    `mdcard-asset://youtube/${expectedID}`
  );
  assert.equal(editor.getMarkdown().trim(), youtubeMarkdown(expectedID));

  const invalid = setup();
  invalid.editor.commands.insertContent("/youtube https://example.com/nope");
  assert.equal(invalid.editor.state.doc.firstChild.type.name, "paragraph");
  assert.match(invalid.editor.getText(), /^\/youtube/);
});

test("native slash command panel mirrors selection and safely chooses a command", () => {
  const { dom, api, editor, messages } = setup({}, { nativeSlashCommandPanel: true });
  typeText(editor, "/");

  const menu = dom.window.document.querySelector(".slash-plugin-menu");
  const opened = messages.filter((message) => (
    message.type === "slashCommandMenuChanged" && message.visible === true
  )).at(-1);
  assert.ok(opened);
  assert.equal(menu.hidden, true);
  assert.equal(opened.cardID, "card-one");
  assert.deepEqual(opened.items.map((item) => item.id), ["youtube", "table", "tag"]);
  assert.equal(opened.selectedIndex, 0);
  assert.ok(Number.isFinite(opened.anchor.left));
  assert.ok(Number.isFinite(opened.anchor.top));
  assert.ok(Number.isFinite(opened.anchor.bottom));

  const originalCoordsAtPos = editor.view.coordsAtPos.bind(editor.view);
  editor.view.coordsAtPos = () => ({ left: 28, right: 28, top: -40, bottom: -20 });
  dom.window.document.querySelector("#renderer").dispatchEvent(new dom.window.Event("scroll"));
  const scrolledAbove = messages.filter((message) => (
    message.type === "slashCommandMenuChanged" && message.visible === true
  )).at(-1);
  assert.equal(scrolledAbove.anchor.top, -40);
  assert.equal(scrolledAbove.anchor.bottom, -20);
  editor.view.coordsAtPos = originalCoordsAtPos;
  dom.window.document.querySelector("#renderer").dispatchEvent(new dom.window.Event("scroll"));

  assert.equal(api.dismissSlashCommandMenu(), true);
  assert.equal(
    messages.filter((message) => message.type === "slashCommandMenuChanged").at(-1).visible,
    false
  );
  assert.equal(pressKey(editor, "ArrowDown"), false);
  assert.equal(api.focusEditor(), true);
  assert.equal(
    messages.filter((message) => message.type === "slashCommandMenuChanged").at(-1).visible,
    true
  );

  assert.equal(pressKey(editor, "ArrowDown"), true);
  const moved = messages.filter((message) => (
    message.type === "slashCommandMenuChanged" && message.visible === true
  )).at(-1);
  assert.equal(moved.selectedIndex, 1);
  assert.equal(api.chooseSlashCommand("tag"), true);
  assert.equal(editor.getText(), "/tag ");
  assert.equal(
    messages.filter((message) => message.type === "slashCommandMenuChanged").at(-1).visible,
    false
  );

  const escaped = setup({}, { nativeSlashCommandPanel: true });
  typeText(escaped.editor, "/");
  assert.equal(pressKey(escaped.editor, "Escape"), true);
  assert.equal(
    escaped.messages.filter(
      (message) => message.type === "slashCommandMenuChanged"
    ).at(-1).visible,
    false
  );
});

test("top-level tag commands submit one atomic metadata message and stay out of Markdown", () => {
  const { api, editor, messages } = setup({
    markdown: "Before\n\n/tag   Transformer   Reading\n\nAfter",
    revision: 8
  });
  let commandEnd = null;
  editor.state.doc.descendants((node, position) => {
    if (node.type.name === "paragraph" && node.textContent.startsWith("/tag")) {
      commandEnd = position + node.nodeSize - 1;
    }
  });
  assert.notEqual(commandEnd, null);
  editor.commands.setTextSelection(commandEnd);

  const messageCount = messages.length;
  assert.equal(pressKey(editor, "Enter"), true);
  const transactionMessages = messages.slice(messageCount).filter(
    (message) => ["markdownChanged", "tagCommandSubmitted"].includes(message.type)
  );

  assert.deepEqual(transactionMessages, [{
    type: "tagCommandSubmitted",
    cardID: "card-one",
    tagName: "Transformer Reading",
    markdown: "Before\n\nAfter",
    revision: 9
  }]);
  assert.equal(api.getState().markdown, "Before\n\nAfter");
  assert.equal(editor.state.selection.$from.parent.textContent, "After");
  assert.equal(api.getMarkdownExportBundle().markdown, "Before\n\nAfter");
  assert.equal(
    api.getMarkdownForCopy("file:///tmp/markdown-card-attachments/"),
    "Before\n\nAfter"
  );
});

test("tag slash entry is top-level only and Tag names are validated before submission", () => {
  assert.equal(normalizeTagCommandName("  阅读   笔记  "), "阅读 笔记");
  assert.equal(normalizeTagCommandName("x".repeat(65)), null);
  assert.equal(normalizeTagCommandName("bad\u0000tag"), null);

  const topLevel = setup();
  typeText(topLevel.editor, "/tag");
  const menu = topLevel.dom.window.document.querySelector(".slash-plugin-menu");
  assert.equal(menu.hidden, false);
  assert.match(menu.textContent, /Tag/);
  assert.equal(pressKey(topLevel.editor, "Enter"), true);
  assert.equal(topLevel.editor.getText(), "/tag ");

  const nested = setup({ markdown: "- /" });
  nested.editor.commands.focus("end");
  const nestedMenu = nested.dom.window.document.querySelector(".slash-plugin-menu");
  assert.doesNotMatch(nestedMenu.textContent, /Tag/);

  const command = setup({ markdown: "- /tag Nested", revision: 2 });
  command.editor.commands.focus("end");
  const before = command.messages.length;
  pressKey(command.editor, "Enter");
  assert.equal(
    command.messages.slice(before).some((message) => message.type === "tagCommandSubmitted"),
    false
  );
  assert.match(command.editor.getMarkdown(), /\/tag Nested/);

  const multiline = setup({ markdown: "/tag First  \nSecond", revision: 3 });
  multiline.editor.commands.focus("end");
  const multilineBefore = multiline.messages.length;
  pressKey(multiline.editor, "Enter");
  assert.equal(
    multiline.messages.slice(multilineBefore).some(
      (message) => message.type === "tagCommandSubmitted"
    ),
    false
  );
});

test("IME Enter never submits a tag command until composition has ended", () => {
  const composing = setup({ markdown: "/tag 中文系列", revision: 4 });
  composing.editor.commands.focus("end");
  const before = composing.messages.length;

  pressKey(composing.editor, "Enter", { isComposing: true });
  assert.equal(
    composing.messages.slice(before).some((message) => message.type === "tagCommandSubmitted"),
    false
  );

  const completed = setup({ markdown: "/tag 中文系列", revision: 4 });
  completed.editor.commands.focus("end");
  assert.equal(pressKey(completed.editor, "Enter"), true);
  assert.deepEqual(completed.messages.at(-1), {
    type: "tagCommandSubmitted",
    cardID: "card-one",
    tagName: "中文系列",
    markdown: "",
    revision: 5
  });
});

test("Undo never restores an already-submitted tag command into Markdown", () => {
  const { editor, api } = setup({ markdown: "Body", revision: 1 });
  editor.commands.focus("end");
  pressKey(editor, "Enter");
  typeText(editor, "/tag Research");
  assert.equal(pressKey(editor, "Enter"), true);
  assert.equal(api.getState().markdown, "Body");

  editor.commands.undo();
  assert.equal(api.getState().markdown, "Body");
  assert.doesNotMatch(editor.getMarkdown(), /\/tag Research/);
});

test("standalone YouTube URLs paste or finish on Enter as rich covers", () => {
  const videoID = "dQw4w9WgXcQ";
  for (const source of [
    `https://www.youtube.com/watch?v=${videoID}`,
    `https://youtu.be/${videoID}`,
    `https://youtube.com/shorts/${videoID}`,
    `https://youtube.com/embed/${videoID}`
  ]) {
    const pasted = setup();
    assert.deepEqual(pasteText(pasted.editor, source), { handled: true, prevented: true });
    assert.equal(pasted.editor.state.doc.firstChild.type.name, "youtubeCard");
    assert.equal(pasted.editor.getMarkdown().trim(), youtubeMarkdown(videoID));
  }

  const typed = setup();
  typed.editor.commands.insertContent(`https://youtu.be/${videoID}`);
  assert.equal(pressKey(typed.editor, "Enter"), true);
  assert.equal(typed.editor.state.doc.firstChild.type.name, "youtubeCard");

  const mixed = setup({ markdown: "Watch this: " });
  mixed.editor.commands.focus("end");
  pasteText(mixed.editor, `https://youtu.be/${videoID}`);
  assert.equal(mixed.editor.state.doc.firstChild.type.name, "paragraph");
  assert.equal(mixed.dom.window.document.querySelector(".youtube-card"), null);
});

test("YouTube Markdown round-trips as a rich cover and opens on ordinary click", () => {
  const videoID = "dQw4w9WgXcQ";
  const markdown = youtubeMarkdown(videoID);
  const { dom, editor, messages } = setup({ markdown });
  const card = dom.window.document.querySelector(".youtube-card");
  assert.ok(card);
  assert.equal(editor.state.doc.firstChild.type.name, "youtubeCard");
  assert.equal(editor.getMarkdown().trim(), markdown);

  card.dispatchEvent(new dom.window.MouseEvent("click", {
    bubbles: true, cancelable: true, button: 0
  }));
  assert.deepEqual(messages.at(-1), {
    type: "openExternalLink",
    url: `https://www.youtube.com/watch?v=${videoID}`
  });

  assert.equal(editor.commands.setNodeSelection(0), true);
  assert.equal(editor.commands.deleteSelection(), true);
  assert.equal(editor.state.doc.firstChild.type.name, "paragraph");
});

test("raw HTML is visible source, images never create img elements, and local URLs do not open", () => {
  const markdown = '<script>alert(1)</script>\n\n<img src="file:///secret" onerror="x">\n\n![remote](https://example.com/x.png)\n\n[local](file:///tmp/a)';
  const { dom } = setup({ markdown });
  const canvas = dom.window.document.querySelector(".ProseMirror");

  assert.equal(canvas.querySelectorAll("script, img, iframe, object, embed").length, 0);
  assert.match(canvas.textContent, /<script>alert\(1\)<\/script>/);
  assert.match(canvas.textContent, /<img src="file:\/\/\/secret" onerror="x">/);
  assert.equal(canvas.querySelectorAll(".image-blocked").length, 1);
  assert.equal(canvas.querySelector('a[href^="file:"]'), null);
  assert.match(protectUnsafeMarkdown("```html\n<img>\n```\n<img>"), /```html\n<img>\n```\n&lt;img>/);
});

test("exports both native aliases and resolves system, light, and dark appearances", () => {
  const { dom, api } = setup();
  assert.equal(dom.window.MarkdownCard, api);
  assert.equal(dom.window.markdownCard, api);
  assert.equal(api.setAppearance("light"), "light");
  assert.equal(dom.window.document.documentElement.dataset.theme, "light");
  assert.equal(api.setAppearance("system"), "light");
  assert.equal(api.setAppearance("dark"), "dark");
});

test("100KB serialization remains bounded and records transaction timing", () => {
  const body = Array.from({ length: 3200 }, (_, index) => `Paragraph ${index} with **bold** content.`).join("\n\n");
  assert.ok(Buffer.byteLength(body) > 100_000);
  const { api, editor } = setup({ markdown: body });
  editor.commands.focus("end");
  editor.commands.insertContent("x");
  assert.ok(Number.isFinite(api.getState().lastSerializationMs));
  assert.ok(api.getState().lastSerializationMs < 250, `serialization took ${api.getState().lastSerializationMs}ms`);
});

test("paragraph Enter and automatic wrapping share one body line height", async () => {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  const { dom } = setup({ markdown: "First paragraph\n\nSecond paragraph" });
  const paragraphs = dom.window.document.querySelectorAll(".ProseMirror > p");
  const paragraphRule = css.match(/(?:^|\n)p\s*\{([\s\S]*?)\}/)?.[1] ?? "";

  assert.equal(paragraphs.length, 2);
  assert.match(css, /--body-line-height:\s*1\.5/);
  assert.match(css, /--block-gap:\s*10px/);
  assert.match(css, /p,[\s\S]*?line-height:\s*var\(--body-line-height\)/);
  assert.match(paragraphRule, /margin:\s*0/);
  assert.doesNotMatch(css, /p\s*\+\s*p(?![\w.-])[\s\S]*?margin/);
  assert.match(css, /p\s*\+\s*ul,[\s\S]*?margin-top:\s*var\(--block-gap\)/);
});

test("Enter-created task rows and adjacent task-list blocks share one row gap", async () => {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  const entered = setup({ markdown: "- [ ] first" });
  entered.editor.commands.focus("end");
  assert.equal(pressKey(entered.editor, "Enter"), true);
  typeText(entered.editor, "second");
  assert.equal(entered.dom.window.document.querySelectorAll('ul[data-type="taskList"]').length, 1);
  assert.equal(entered.dom.window.document.querySelectorAll('ul[data-type="taskList"] > li').length, 2);

  const separate = setup({ markdown: "- [ ] first\n\n- [ ] second" });
  assert.equal(separate.dom.window.document.querySelectorAll('ul[data-type="taskList"]').length, 2);

  assert.match(css, /--task-row-gap:\s*0px/);
  assert.match(
    css,
    /ul\[data-type="taskList"\]\s*>\s*li\s*\+\s*li\s*\{[\s\S]*?margin-top:\s*var\(--task-row-gap\)/
  );
  assert.match(
    css,
    /ul\[data-type="taskList"\]:has\(\+\s*ul\[data-type="taskList"\]\)\s*\{[\s\S]*?margin-bottom:\s*var\(--task-row-gap\)/
  );
  assert.match(
    css,
    /ul\[data-type="taskList"\]\s*\+\s*ul\[data-type="taskList"\]\s*\{[\s\S]*?margin-top:\s*var\(--task-row-gap\)/
  );
});

test("nested list rows do not inherit top-level block gaps", async () => {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  const nestedListRule = css.match(/li\s*>\s*ul,[\s\S]*?li\s*>\s*ol\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  const adjacentItemRule = css.match(/li\s*\+\s*li\s*\{([\s\S]*?)\}/)?.[1] ?? "";

  assert.match(
    css,
    /\.markdown-canvas\s*>\s*ul,[\s\S]*?margin-bottom:\s*var\(--block-gap\)/
  );
  assert.match(nestedListRule, /margin:\s*0/);
  assert.match(adjacentItemRule, /margin-top:\s*0/);
});

test("headings, media, math, and code share a compact vertical rhythm", async () => {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  const headingRule = css.match(/h1,[\s\S]*?h6\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  const imageRule = css.match(/\.local-attachment\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  const youtubeRule = css.match(/\.youtube-card\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  const mathRules = [...css.matchAll(/\.math-node-block\s*\{([\s\S]*?)\}/g)];
  const mathRule = mathRules.at(-1)?.[1] ?? "";
  const preRule = css.match(/(?:^|\n)pre\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  const blockMarginRule = css.match(
    /blockquote,\s*table,\s*pre,\s*\.math-node-block\s*\{([\s\S]*?)\}/
  )?.[1] ?? "";

  assert.match(headingRule, /margin:\s*1\.1em 0 0\.4em/);
  assert.match(imageRule, /display:\s*inline-block/);
  assert.match(imageRule, /margin:\s*4px 0 var\(--block-gap\)/);
  assert.match(imageRule, /vertical-align:\s*top/);
  assert.match(youtubeRule, /margin:\s*4px 0 var\(--block-gap\)/);
  assert.match(mathRule, /padding:\s*2px 0 4px/);
  assert.match(preRule, /padding:\s*12px 16px/);
  assert.match(preRule, /line-height:\s*var\(--body-line-height\)/);
  assert.match(blockMarginRule, /margin:\s*0/);
  assert.match(css, /\.ProseMirror-selectednode\s*\{[\s\S]*?outline:\s*1px solid var\(--focus\)/);
});

test("clipboard images become managed local attachments and keep Markdown copy serializable", async () => {
  const { dom, api, editor, messages } = setup({ markdown: "" });
  assert.deepEqual(pasteImage(editor), { handled: true, prevented: true });
  await new Promise((resolve) => setTimeout(resolve, 20));
  const request = messages.find((message) => message.type === "localImagePasteRequested");
  assert.ok(request);
  assert.equal(request.cardID, "card-one");
  assert.equal(request.mimeType, "image/png");

  const attachmentID = "34d1880c-35d5-4c7e-9620-40c3140b003c";
  assert.equal(api.completeImagePaste({
    requestID: request.requestID,
    cardID: "card-one",
    source: `attachments/${attachmentID}.png`,
    alt: "Screenshot"
  }), true);

  const image = dom.window.document.querySelector("img.local-attachment");
  assert.ok(image);
  assert.equal(image.getAttribute("src"), `mdcard-asset://attachment/${attachmentID}.png`);
  assert.match(editor.getMarkdown(), /!\[Screenshot\]\(attachments\/34d1880c-35d5-4c7e-9620-40c3140b003c\.png\)/);
});

test("caret deletion selects adjacent media before an explicit keyboard deletion", () => {
  const attachmentID = "34d1880c-35d5-4c7e-9620-40c3140b003c";
  const source = `![Screenshot](attachments/${attachmentID}.png)`;
  const backward = setup({ markdown: source });
  let imagePosition = null;
  backward.editor.state.doc.descendants((node, position) => {
    if (node.type.name === "blockedImage") imagePosition = position;
  });
  assert.notEqual(imagePosition, null);
  backward.editor.commands.setTextSelection(imagePosition + 1);

  assert.equal(pressKey(backward.editor, "Backspace"), true);
  assert.equal(backward.editor.state.selection.constructor.name, "NodeSelection");
  assert.equal(pressKey(backward.editor, "Backspace", { repeat: true }), true);
  assert.equal(backward.editor.getMarkdown(), source);
  assert.ok(backward.dom.window.document.querySelector("img.local-attachment"));
  assert.equal(pressKey(backward.editor, "Backspace"), true);
  assert.equal(backward.editor.getMarkdown(), "");

  const forward = setup({ markdown: source });
  let forwardImagePosition = null;
  forward.editor.state.doc.descendants((node, position) => {
    if (node.type.name === "blockedImage") forwardImagePosition = position;
  });
  forward.editor.commands.setTextSelection(forwardImagePosition);
  assert.equal(pressKey(forward.editor, "Delete"), true);
  assert.equal(forward.editor.state.selection.constructor.name, "NodeSelection");
  assert.equal(pressKey(forward.editor, "Delete", { repeat: true }), true);
  assert.equal(forward.editor.getMarkdown(), source);

  assert.equal(pressKey(forward.editor, "Delete"), true);
  assert.equal(forward.dom.window.document.querySelector("img.local-attachment"), null);
  assert.equal(forward.editor.getMarkdown(), "");
  forward.api.flushMarkdownChanges();
  assert.deepEqual(
    forward.messages.filter((message) => message.type === "managedAttachmentsChanged").at(-1),
    { type: "managedAttachmentsChanged", cardID: "card-one", attachmentIDs: [] }
  );
});

test("Markdown copy expands only managed attachments to absolute file URLs without editing the card", () => {
  const firstID = "34d1880c-35d5-4c7e-9620-40c3140b003c";
  const secondID = "83e3fad5-cc28-41e2-9407-7a8236c5bfa9";
  const source = [
    `![First](attachments/${firstID}.png)`,
    `![Second](attachments/${secondID}.png)`,
    "```text",
    `attachments/${firstID}.png`,
    "```",
    "![Remote](https://example.com/remote.png)",
    youtubeMarkdown("dQw4w9WgXcQ")
  ].join("\n\n");
  const { api, editor } = setup({ markdown: source });
  editor.commands.setTextSelection(1);
  editor.commands.insertContent("Copy history marker ");

  const markdownBefore = editor.getMarkdown();
  const jsonBefore = editor.getJSON();
  const stateBefore = api.getState();
  const copied = api.getMarkdownForCopy(
    "file:///Users/test/Library/Application Support/Markdown Card/attachments"
  );
  const exported = api.getMarkdownExportBundle();

  assert.match(copied, new RegExp(`file:///Users/test/Library/Application%20Support/Markdown%20Card/attachments/${firstID}\\.png`));
  assert.match(copied, new RegExp(`file:///Users/test/Library/Application%20Support/Markdown%20Card/attachments/${secondID}\\.png`));
  assert.match(copied, new RegExp(`\\nattachments/${firstID}\\.png\\n`));
  assert.match(copied, /https:\/\/example\.com\/remote\.png/);
  assert.match(copied, /i\.ytimg\.com\/vi\/dQw4w9WgXcQ\/hqdefault\.jpg/);
  assert.equal(exported.markdown, markdownBefore);
  assert.deepEqual(exported.attachmentIDs, [firstID, secondID]);
  assert.equal(editor.getMarkdown(), markdownBefore);
  assert.deepEqual(editor.getJSON(), jsonBefore);
  assert.deepEqual(api.getState().selection, stateBefore.selection);
  assert.equal(api.getState().revision, stateBefore.revision);

  assert.equal(editor.commands.undo(), true);
  assert.notEqual(editor.getMarkdown(), markdownBefore);
  assert.equal(editor.commands.redo(), true);
  assert.equal(editor.getMarkdown(), markdownBefore);
  assert.throws(() => api.getMarkdownForCopy("https://example.com/attachments/"));
});

test("theme tokens keep the UI grayscale while code uses VS Code Light+ and Dark+ colors", async () => {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  const grayscaleTokens = [
    "canvas", "text-primary", "text-secondary", "text-muted", "line", "line-strong",
    "surface-muted", "selection", "scroll-thumb", "focus"
  ];
  const syntaxTokens = [
    "syntax-foreground", "syntax-keyword", "syntax-type", "syntax-string", "syntax-number",
    "syntax-comment", "syntax-function", "syntax-variable", "syntax-meta"
  ];
  for (const token of [...grayscaleTokens, ...syntaxTokens]) {
    assert.ok(css.match(new RegExp(`--${token}:`, "g")).length >= 2, `${token} needs light and dark values`);
  }
  const darkBlock = css.match(/:root\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  const lightBlock = css.match(/:root\[data-theme="light"\]\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  const tokenValue = (block, token) => block.match(new RegExp(`--${token}:\\s*(#[0-9a-f]{6})`, "i"))?.[1];
  assert.equal(tokenValue(darkBlock, "canvas"), "#1e1e1e");
  assert.equal(tokenValue(lightBlock, "canvas"), "#fbfbfb");
  for (const token of grayscaleTokens) {
    for (const block of [darkBlock, lightBlock]) {
      const color = tokenValue(block, token);
      assert.ok(color, `missing ${token}`);
      assert.equal(color.slice(1, 3), color.slice(3, 5), `${token} must remain grayscale`);
      assert.equal(color.slice(3, 5), color.slice(5, 7), `${token} must remain grayscale`);
    }
  }
  for (const block of [darkBlock, lightBlock]) {
    const colors = syntaxTokens.map((token) => tokenValue(block, token));
    assert.equal(colors.every(Boolean), true);
    assert.ok(new Set(colors).size >= 7, "syntax palette must contain distinct semantic colors");
    assert.ok(colors.some((color) => color.slice(1, 3) !== color.slice(3, 5)));
  }
  assert.match(css, /\.hljs-keyword[\s\S]*var\(--syntax-keyword\)/);
  assert.match(css, /\.hljs-string[\s\S]*var\(--syntax-string\)/);
  assert.match(css, /\.hljs-comment[\s\S]*var\(--syntax-comment\)/);
  assert.doesNotMatch(css, /gradient\s*\(/i);
  assert.doesNotMatch(css, /\.editor-block|\.source-fallback/);
  assert.match(css, /\.source-editor\s*\{[\s\S]*font-family:/);
  assert.doesNotMatch(css, /Write Markdown/i);
  const placeholder = css.match(
    /\.markdown-canvas\s+p\.is-editor-empty:first-child::before\s*\{([\s\S]*?)\}/
  )?.[1] ?? "";
  assert.match(placeholder, /content:\s*attr\(data-placeholder\)/);
  assert.match(placeholder, /pointer-events:\s*none/);
  const h2Block = css.match(/h2\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  assert.doesNotMatch(h2Block, /border-bottom|padding-bottom/);
  const blockMath = css.match(/\.math-node-block\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  assert.doesNotMatch(blockMath, /border-(?:top|bottom)/);
  const completedTask = css.match(/li\[data-checked="true"\][\s\S]*?\{([\s\S]*?)\}/)?.[1] ?? "";
  assert.match(completedTask, /color:\s*var\(--text-muted\)/);
});

test("body text keeps WCAG AA contrast in both appearances", async () => {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  const rootBlock = css.match(/:root\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  const lightBlock = css.match(/:root\[data-theme="light"\]\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  const token = (block, name) => {
    const value = block.match(new RegExp(`--${name}:\\s*(#[0-9a-f]{6})`, "i"))?.[1];
    assert.ok(value, `missing ${name}`);
    return value;
  };
  const luminance = (hex) => {
    const channel = Number.parseInt(hex.slice(1, 3), 16) / 255;
    return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
  };
  const contrast = (foreground, background) => {
    const bright = Math.max(luminance(foreground), luminance(background));
    const dark = Math.min(luminance(foreground), luminance(background));
    return (bright + 0.05) / (dark + 0.05);
  };
  for (const [name, block] of [["dark", rootBlock], ["light", lightBlock]]) {
    const background = token(block, "canvas");
    assert.ok(contrast(token(block, "text-primary"), background) >= 4.5, `${name} primary contrast`);
    assert.ok(contrast(token(block, "text-secondary"), background) >= 4.5, `${name} secondary contrast`);
  }
});

test("tagged cards keep a compact header-to-first-block rhythm", async () => {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  const rendererBlock = css.match(/#renderer\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  const compactBlock = css.match(
    /@media\s*\(max-width:\s*620px\)\s*\{[\s\S]*?#renderer\s*\{([\s\S]*?)\}/
  )?.[1] ?? "";
  assert.match(rendererBlock, /padding:\s*6px 40px 42px/);
  assert.match(compactBlock, /padding:\s*6px 28px 24px/);
});

test("production shell permits only native-scheme images and forbids web network and frames", async () => {
  const html = await readFile(new URL("../templates/index.html", import.meta.url), "utf8");
  assert.match(html, /default-src 'none'/);
  assert.match(html, /connect-src 'none'/);
  assert.match(html, /img-src mdcard-asset:/);
  assert.match(html, /frame-src 'none'/);
  assert.doesNotMatch(html, /https?:\/\//);
});
