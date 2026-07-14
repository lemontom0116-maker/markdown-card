import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { JSDOM } from "jsdom";
import { installMarkdownCard } from "../src/app.js";
import { normalizeCodeLanguage, protectUnsafeMarkdown } from "../src/markdown.js";
import {
  parseYouTubeURL,
  rendererPluginRegistry,
  youtubeMarkdown
} from "../src/plugins.js";

function installDOMGlobals(window) {
  globalThis.window = window;
  globalThis.document = window.document;
  globalThis.Node = window.Node;
  globalThis.HTMLElement = window.HTMLElement;
  globalThis.Element = window.Element;
  globalThis.DocumentFragment = window.DocumentFragment;
  globalThis.MutationObserver = window.MutationObserver;
  globalThis.DOMParser = window.DOMParser;
  globalThis.getSelection = window.getSelection.bind(window);
  globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
  globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
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

function setup(payload = {}) {
  const dom = makeDOM();
  const messages = [];
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

test("uses one continuous ProseMirror canvas with no block textareas", () => {
  const { dom, api } = setup({
    markdown: "# Heading\n\nBody\n\n- one\n- two",
    revision: 1
  });

  assert.equal(api.protocolVersion, 3);
  assert.equal(dom.window.document.querySelectorAll(".ProseMirror").length, 1);
  assert.equal(dom.window.document.querySelectorAll("textarea.source-editor").length, 0);
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
  assert.match(dom.window.document.querySelector(".ProseMirror").innerHTML, /<a[^>]+href="https:\/\/raycast\.com"[^>]*>Raycast<\/a>/);
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

test("language fences normalize aliases, highlight known languages, and preserve unknown languages", () => {
  assert.equal(normalizeCodeLanguage("python3"), "python");
  assert.equal(normalizeCodeLanguage("C++"), "cpp");
  assert.equal(normalizeCodeLanguage("zsh"), "bash");
  const { dom, editor } = setup({
    markdown: [
      "```python3", "def answer():", "    return 42", "```", "",
      "```c++", "int main() { return 0; }", "```", "",
      "```mystery", "opaque token", "```"
    ].join("\n")
  });
  const python = dom.window.document.querySelector("code.language-python");
  const cpp = dom.window.document.querySelector("code.language-cpp");
  const unknown = dom.window.document.querySelector("code.language-mystery");
  assert.ok(python.querySelector(".hljs-keyword"));
  assert.ok(cpp.querySelector(".hljs-type, .hljs-keyword"));
  assert.equal(unknown.querySelector("span"), null);
  assert.match(editor.getMarkdown(), /```python\n/);
  assert.match(editor.getMarkdown(), /```cpp\n/);
  assert.match(editor.getMarkdown(), /```mystery\n/);

  editor.commands.setContent("", { contentType: "markdown", emitUpdate: false });
  typeText(editor, "```python ");
  assert.equal(editor.state.doc.firstChild.type.name, "codeBlock");
  assert.equal(editor.state.doc.firstChild.attrs.language, "python");
});

test("empty cards have a caret surface without placeholder copy", () => {
  const { dom } = setup();
  const canvas = dom.window.document.querySelector(".ProseMirror");
  assert.equal(canvas.textContent, "");
  assert.equal(canvas.querySelector("[data-placeholder]"), null);
  assert.doesNotMatch(canvas.innerHTML, /Write Markdown/i);
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

test("links open only on Command-click through the native bridge", () => {
  const { dom, messages } = setup({ markdown: "[Open](https://example.com/path)" });
  const link = dom.window.document.querySelector("a");
  link.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.notEqual(messages.at(-1)?.type, "openExternalLink");

  link.dispatchEvent(new dom.window.MouseEvent("click", {
    bubbles: true,
    cancelable: true,
    metaKey: true
  }));
  assert.deepEqual(messages.at(-1), {
    type: "openExternalLink",
    url: "https://example.com/path"
  });
});

test("slash plugin menu inserts YouTube and converts supported URLs", () => {
  assert.deepEqual(rendererPluginRegistry.map((plugin) => plugin.id), ["youtube"]);
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
  assert.match(css, /--body-line-height:\s*1\.58/);
  assert.match(css, /p,[\s\S]*?line-height:\s*var\(--body-line-height\)/);
  assert.match(paragraphRule, /margin:\s*0/);
  assert.doesNotMatch(css, /p\s*\+\s*p(?![\w.-])[\s\S]*?margin/);
  assert.match(css, /p\s*\+\s*ul,[\s\S]*?margin-top:\s*15px/);
});

test("nested list rows do not inherit top-level block gaps", async () => {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  const nestedListRule = css.match(/li\s*>\s*ul,[\s\S]*?li\s*>\s*ol\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  const adjacentItemRule = css.match(/li\s*\+\s*li\s*\{([\s\S]*?)\}/)?.[1] ?? "";

  assert.match(css, /\.markdown-canvas\s*>\s*ul,[\s\S]*?margin-bottom:\s*15px/);
  assert.match(nestedListRule, /margin:\s*0/);
  assert.match(adjacentItemRule, /margin-top:\s*0/);
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
  assert.doesNotMatch(css, /\.editor-block|\.source-editor|\.source-fallback/);
  assert.doesNotMatch(css, /Write Markdown|data-placeholder/);
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

test("production shell permits only native-scheme images and forbids web network and frames", async () => {
  const html = await readFile(new URL("../templates/index.html", import.meta.url), "utf8");
  assert.match(html, /default-src 'none'/);
  assert.match(html, /connect-src 'none'/);
  assert.match(html, /img-src mdcard-asset:/);
  assert.match(html, /frame-src 'none'/);
  assert.doesNotMatch(html, /https?:\/\//);
});
