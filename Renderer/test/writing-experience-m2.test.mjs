import test from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { installMarkdownCard } from "../src/app.js";
import {
  headingFragmentRepairPlan,
  headingForFragment,
  normalizeSafeLinkTarget,
  outlineWithFragments,
  sourceDocumentOutline
} from "../src/writing-tools.js";

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
      x: 0,
      y: 0,
      top: 0,
      left: 0,
      bottom: 0,
      right: 0,
      width: 0,
      height: 0
    });
  }
}

function makeDOM() {
  const dom = new JSDOM(
    '<!doctype html><html data-theme="dark"><head></head><body><main id="renderer"></main></body></html>',
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

function input(dom, element) {
  element.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
}

function documentKey(dom, key, options = {}) {
  const event = new dom.window.KeyboardEvent("keydown", {
    key,
    bubbles: true,
    cancelable: true,
    ...options
  });
  dom.window.document.dispatchEvent(event);
  return event;
}

function editorDOMKey(editor, key, options = {}) {
  const KeyboardEvent = editor.view.dom.ownerDocument.defaultView.KeyboardEvent;
  const event = new KeyboardEvent("keydown", {
    key,
    bubbles: true,
    cancelable: true,
    ...options
  });
  editor.view.dom.dispatchEvent(event);
  return event;
}

function editorKey(editor, key, options = {}) {
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

function submit(dom, form) {
  form.dispatchEvent(new dom.window.Event("submit", {
    bubbles: true,
    cancelable: true
  }));
}

function firstNodePosition(editor, names) {
  let match = null;
  const accepted = new Set(Array.isArray(names) ? names : [names]);
  editor.state.doc.descendants((node, position) => {
    if (match == null && accepted.has(node.type.name)) match = { node, position };
  });
  return match;
}

function tableDimensions(editor) {
  const context = firstNodePosition(editor, "table");
  if (!context) return null;
  return {
    rows: context.node.childCount,
    columns: context.node.firstChild?.childCount ?? 0
  };
}

test("Source mode is lossless until edited and flushes last characters on copy, export, switch, and destroy", () => {
  const raw = [
    "# CRLF title",
    "",
    "-  deliberate spacing  ",
    "",
    "````md",
    "```js",
    "const exact = true",
    "```",
    "````"
  ].join("\r\n");
  const { dom, api, messages } = setup({ markdown: raw, revision: 7 });
  const source = dom.window.document.querySelector("textarea.source-editor");

  const start = messages.length;
  const toSource = documentKey(dom, "m", { metaKey: true, shiftKey: true });
  assert.equal(toSource.defaultPrevented, true);
  assert.equal(api.peekState().editorMode, "source");
  assert.equal(source.hidden, false);
  assert.equal(source.value, raw.replaceAll("\r\n", "\n"), "textarea display follows browser newline rules");
  assert.equal(api.getMarkdownForCopy(), raw, "a mode toggle keeps the native payload byte-for-byte");
  assert.equal(api.getMarkdownExportBundle().markdown, raw);
  assert.equal(messages.slice(start).some((message) => message.type === "markdownChanged"), false);

  dom.window.document.querySelector("button.source-mode-chip").click();
  assert.equal(api.peekState().editorMode, "rich");
  assert.equal(api.peekState().markdown, raw);
  api.setEditorMode("source", { focus: false });

  source.value += "Z";
  input(dom, source);
  const edited = `${raw.replaceAll("\r\n", "\n")}Z`;
  assert.equal(api.getMarkdownForCopy(), edited);
  assert.deepEqual(api.getMarkdownExportBundle(), { markdown: edited, attachmentIDs: [] });
  assert.equal(
    messages.filter((message) => message.type === "markdownChanged").at(-1)?.markdown,
    edited
  );

  source.value += "!";
  input(dom, source);
  api.render({ cardID: "card-two", markdown: "Second", revision: 0 });
  assert.equal(
    messages.filter((message) => message.type === "markdownChanged" && message.cardID === "card-one").at(-1)?.markdown,
    `${edited}!`
  );

  const secondSource = dom.window.document.querySelector("textarea.source-editor");
  secondSource.value += "?";
  input(dom, secondSource);
  api.destroy();
  assert.equal(
    messages.filter((message) => message.type === "markdownChanged" && message.cardID === "card-two").at(-1)?.markdown,
    "Second?"
  );
});

test("Rich serialization grows an outer code fence around nested Markdown fences", () => {
  const nested = [
    "````markdown",
    "```python",
    "print(\"nested fence\")",
    "```",
    "````",
    "",
    "After"
  ].join("\n");
  const { api, editor } = setup({ markdown: nested });
  editor.commands.focus("end", { scrollIntoView: false });
  editor.commands.insertContent(" edited");

  const serialized = api.getState().markdown;
  assert.match(serialized, /^````markdown\n```python\nprint\("nested fence"\)\n```\n````/u);
  const reparsed = setup({ markdown: serialized }).editor;
  assert.equal(reparsed.state.doc.firstChild.type.name, "codeBlock");
  assert.match(reparsed.state.doc.firstChild.textContent, /```python[\s\S]*```/u);
  assert.equal(reparsed.state.doc.childCount, 2);
});

test("untouched Rich copy and export preserve the original Markdown bytes", () => {
  const raw = [
    "# Exact title  ",
    "",
    "````markdown",
    "```python3",
    "print(\"nested\")",
    "```",
    "````"
  ].join("\r\n");
  const { api } = setup({ markdown: raw });

  assert.equal(api.getMarkdownForCopy(), raw);
  assert.deepEqual(api.getMarkdownExportBundle(), { markdown: raw, attachmentIDs: [] });
});

test("an unrelated Rich edit preserves untouched fenced-code aliases and fence style", () => {
  const raw = [
    "~~~~python3",
    "print('alias stays')",
    "~~~~",
    "",
    "Paragraph",
    "",
    "```js",
    "const answer = 42",
    "```"
  ].join("\n");
  const { api, editor } = setup({ markdown: raw });
  const codeBlocks = [];
  editor.state.doc.descendants((node) => {
    if (node.type.name === "codeBlock") codeBlocks.push(node);
  });
  assert.equal(codeBlocks[0].attrs.language, "python");
  assert.equal(codeBlocks[0].attrs.sourceInfo, "python3");
  assert.equal(codeBlocks[0].attrs.sourceFence, "~~~~");

  let paragraphEnd = null;
  editor.state.doc.descendants((node, position) => {
    if (node.type.name === "paragraph" && node.textContent === "Paragraph") {
      paragraphEnd = position + 1 + node.content.size;
    }
  });
  assert.notEqual(paragraphEnd, null);
  editor.view.dispatch(editor.state.tr.insertText(" edited", paragraphEnd));
  const serialized = editor.getMarkdown();
  assert.match(serialized, /^~~~~python3\nprint\('alias stays'\)\n~~~~/u);
  assert.match(serialized, /```js\nconst answer = 42\n```/u);
  api.destroy();
});

test("a Rich edit burst performs one Markdown serialization and one attachment metadata scan", () => {
  const { api, editor, messages } = setup({ markdown: "Start" });
  editor.commands.focus("end", { scrollIntoView: false });
  const baseline = api.peekState();
  const messageStart = messages.length;

  editor.commands.insertContent(" one");
  editor.commands.insertContent(" two");
  editor.commands.insertContent(" three");

  const pending = api.peekState();
  assert.equal(pending.pendingMarkdownPost, true);
  assert.equal(pending.serializationCount, baseline.serializationCount);
  assert.equal(pending.attachmentScanCount, baseline.attachmentScanCount);
  assert.equal(
    messages.slice(messageStart).some((message) => message.type === "markdownChanged"),
    false
  );

  assert.equal(api.flushMarkdownChanges(), "Start one two three");
  const flushed = api.peekState();
  assert.equal(flushed.pendingMarkdownPost, false);
  assert.equal(flushed.serializationCount, baseline.serializationCount + 1);
  assert.equal(flushed.attachmentScanCount, baseline.attachmentScanCount + 1);
  const changes = messages.slice(messageStart).filter((message) => message.type === "markdownChanged");
  assert.equal(changes.length, 1);
  assert.equal(changes[0].markdown, "Start one two three");
});

test("Find works in Rich and Source, stays inside text nodes, and Replace All is one undo step", () => {
  const { dom, api, editor } = setup({ markdown: "**foo**foo foo" });
  const document = dom.window.document;
  const panel = document.querySelector(".find-panel[role='search']");
  const find = panel.querySelector("input[name='find']");
  const replacement = panel.querySelector("input[name='replace']");
  const count = panel.querySelector(".find-count");

  const shortcut = documentKey(dom, "f", { metaKey: true, altKey: true });
  assert.equal(shortcut.defaultPrevented, true);
  assert.equal(panel.hidden, false);
  assert.equal(panel.querySelector(".replace-row").hidden, false);

  find.value = "foofoo";
  input(dom, find);
  assert.equal(count.textContent, "No matches", "a match cannot cross a mark/text-node boundary");

  const before = editor.getMarkdown();
  find.value = "foo";
  input(dom, find);
  assert.equal(count.textContent, "1 of 3");
  replacement.value = "bar";
  assert.equal(api.replaceAllMatches(), true);
  assert.equal(editor.state.doc.textContent, "barbar bar");
  assert.equal(editor.commands.undo(), true);
  assert.equal(editor.getMarkdown(), before, "all replacements share one ProseMirror transaction");

  api.closeFind({ restoreFocus: false });
  api.setEditorMode("source", { focus: false });
  const source = document.querySelector("textarea.source-editor");
  source.value = "alpha beta alpha";
  input(dom, source);
  api.openFind({ showReplace: true });
  find.value = "alpha";
  input(dom, find);
  replacement.value = "gamma";
  assert.equal(api.replaceCurrentMatch(), true);
  assert.equal(api.replaceAllMatches(), true);
  assert.equal(source.value, "gamma beta gamma");
  assert.equal(api.flushMarkdownChanges(), "gamma beta gamma");
});

test("Outline lists H1-H6 in both modes and ignores shorter nested fence markers", () => {
  const markdown = [
    "# Top",
    "",
    "````markdown",
    "# Hidden",
    "```",
    "## Still hidden",
    "````",
    "",
    "###### Deep",
    "",
    "Setext section",
    "---"
  ].join("\n");
  assert.deepEqual(
    sourceDocumentOutline(markdown).map(({ level, text }) => ({ level, text })),
    [
      { level: 1, text: "Top" },
      { level: 6, text: "Deep" },
      { level: 2, text: "Setext section" }
    ]
  );

  const { dom, api } = setup({ markdown });
  assert.deepEqual(
    api.getOutline().map(({ level, text }) => ({ level, text })),
    [
      { level: 1, text: "Top" },
      { level: 6, text: "Deep" },
      { level: 2, text: "Setext section" }
    ]
  );

  api.setEditorMode("source", { focus: false });
  const shortcut = documentKey(dom, "o", { metaKey: true, shiftKey: true });
  assert.equal(shortcut.defaultPrevented, true);
  const panel = dom.window.document.querySelector(".outline-panel[role='dialog']");
  const buttons = [...panel.querySelectorAll("button.outline-item")];
  assert.equal(panel.hidden, false);
  assert.deepEqual(buttons.map((button) => button.dataset.level), ["1", "6", "2"]);
  assert.equal(dom.window.document.activeElement, buttons[0]);
  panel.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
    key: "ArrowDown",
    bubbles: true,
    cancelable: true
  }));
  assert.equal(dom.window.document.activeElement, buttons[1]);
  const deepPosition = Number(buttons[1].dataset.position);
  buttons[1].click();
  assert.equal(panel.hidden, true);
  assert.equal(dom.window.document.querySelector("textarea.source-editor").selectionStart, deepPosition);
});

test("table edge handles avoid popovers, follow the active row and column, and keep structural undo atomic", () => {
  const { dom, editor } = setup({
    markdown: "| A | B |\n| --- | --- |\n| one | two |"
  });
  const firstCell = firstNodePosition(editor, ["tableHeader", "tableCell"]);
  assert.ok(firstCell);
  assert.equal(editor.commands.setTextSelection(firstCell.position + 2), true);

  const controls = dom.window.document.querySelector(".table-edge-controls[role='group']");
  const button = (command) => controls.querySelector(`button[data-command='${command}']`);
  const addRow = button("addRowAfter");
  const addColumn = button("addColumnAfter");
  const rowHandle = button("rowHandle");
  const columnHandle = button("columnHandle");
  assert.equal(dom.window.document.querySelector(".table-context-toolbar"), null);
  assert.equal(dom.window.document.querySelector(".table-actions-menu"), null);
  assert.equal(button("openTableMenu"), null);
  assert.equal(controls.classList.contains("markdown-card-overlay"), false);
  assert.equal(controls.hidden, false);
  assert.equal(addRow.getAttribute("aria-label"), "Insert row after current row");
  assert.equal(addColumn.getAttribute("aria-label"), "Insert column after current column");
  assert.match(rowHandle.getAttribute("aria-label"), /Drag up or down to move/u);
  assert.match(columnHandle.getAttribute("aria-label"), /Drag left or right to move/u);
  assert.equal([...controls.children].filter((element) => element.tagName === "BUTTON").length, 4);
  assert.deepEqual(tableDimensions(editor), { rows: 2, columns: 2 });

  const wrapper = dom.window.document.querySelector(".tableWrapper");
  const selectedCell = wrapper.querySelector("th");
  const selectedRow = selectedCell.closest("tr");
  let wrapperBounds = { left: 100, top: 200, right: 500, bottom: 320, width: 400, height: 120 };
  let cellBounds = { left: 100, top: 200, right: 320, bottom: 250, width: 220, height: 50 };
  let rowBounds = { left: 100, top: 200, right: 500, bottom: 250, width: 400, height: 50 };
  wrapper.getBoundingClientRect = () => wrapperBounds;
  selectedCell.getBoundingClientRect = () => cellBounds;
  selectedRow.getBoundingClientRect = () => rowBounds;
  wrapper.dispatchEvent(new dom.window.Event("scroll", { bubbles: false }));
  assert.equal(addColumn.style.left, "298px", "column add control follows the selected column edge");
  assert.equal(addRow.style.top, "228px", "row add control follows the selected row edge");
  assert.equal(columnHandle.style.left, "188px", "column handle stays centered on the active column");
  assert.equal(rowHandle.style.top, "203px", "row handle stays centered on the active row");

  editor.commands.focus(undefined, { scrollIntoView: false });
  const tableShortcut = editorDOMKey(editor, "Enter", { ctrlKey: true });
  assert.equal(tableShortcut.defaultPrevented, true);
  assert.equal(dom.window.document.activeElement, columnHandle);
  assert.match(columnHandle.getAttribute("aria-keyshortcuts"), /Alt\+ArrowLeft/u);
  columnHandle.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
    key: "Tab",
    bubbles: true,
    cancelable: true
  }));
  assert.equal(dom.window.document.activeElement, rowHandle);
  rowHandle.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
    key: "Escape",
    bubbles: true,
    cancelable: true
  }));
  assert.equal(dom.window.document.activeElement, editor.view.dom);

  cellBounds = { ...cellBounds, left: 520, right: 650 };
  wrapper.dispatchEvent(new dom.window.Event("scroll", { bubbles: false }));
  assert.equal(controls.style.visibility, "visible");
  assert.equal(addColumn.hidden, true, "an offscreen active column boundary hides its add control");
  assert.equal(columnHandle.hidden, true, "an offscreen active column hides its handle");
  assert.equal(addRow.hidden, false);
  assert.equal(rowHandle.hidden, false);

  cellBounds = { ...cellBounds, left: 120, right: 360 };
  rowBounds = { ...rowBounds, top: 330, bottom: 380 };
  wrapper.dispatchEvent(new dom.window.Event("scroll", { bubbles: false }));
  assert.equal(addColumn.hidden, false);
  assert.equal(addColumn.style.left, "338px", "horizontal table scroll recomputes the active boundary");
  assert.equal(addRow.hidden, true, "an offscreen active row boundary hides its add control");
  assert.equal(rowHandle.hidden, true, "an offscreen active row hides its handle");

  wrapperBounds = { left: 100, top: 900, right: 500, bottom: 1020, width: 400, height: 120 };
  cellBounds = { left: 100, top: 900, right: 320, bottom: 950, width: 220, height: 50 };
  rowBounds = { left: 100, top: 900, right: 500, bottom: 950, width: 400, height: 50 };
  wrapper.dispatchEvent(new dom.window.Event("scroll", { bubbles: false }));
  assert.equal(controls.style.visibility, "hidden", "the controls hide when the whole table leaves the viewport");
  const offscreenShortcut = editorDOMKey(editor, "Enter", { ctrlKey: true });
  assert.equal(offscreenShortcut.defaultPrevented, false);

  wrapperBounds = { left: 100, top: 200, right: 500, bottom: 320, width: 400, height: 120 };
  cellBounds = { left: 100, top: 200, right: 320, bottom: 250, width: 220, height: 50 };
  rowBounds = { left: 100, top: 200, right: 500, bottom: 250, width: 400, height: 50 };
  wrapper.dispatchEvent(new dom.window.Event("scroll", { bubbles: false }));
  assert.equal(controls.style.visibility, "visible");
  assert.equal(addColumn.hidden, false);
  assert.equal(addRow.hidden, false);
  assert.equal(columnHandle.hidden, false);
  assert.equal(rowHandle.hidden, false);

  wrapperBounds = { left: 28, top: 4, right: 332, bottom: 124, width: 304, height: 120 };
  cellBounds = { left: 28, top: 4, right: 180, bottom: 54, width: 152, height: 50 };
  rowBounds = { left: 28, top: 4, right: 332, bottom: 54, width: 304, height: 50 };
  wrapper.dispatchEvent(new dom.window.Event("scroll", { bubbles: false }));
  assert.equal(addColumn.hidden, true, "a clipped top edge hides its column add control");
  assert.equal(columnHandle.hidden, true, "a clipped top edge never pushes a handle onto table content");

  wrapperBounds = { left: 100, top: 200, right: 500, bottom: 320, width: 400, height: 120 };
  cellBounds = { left: 100, top: 200, right: 320, bottom: 250, width: 220, height: 50 };
  rowBounds = { left: 100, top: 200, right: 500, bottom: 250, width: 400, height: 50 };
  wrapper.dispatchEvent(new dom.window.Event("scroll", { bubbles: false }));

  addRow.click();
  assert.deepEqual(tableDimensions(editor), { rows: 3, columns: 2 });
  assert.match(editor.getMarkdown(), /\| A\s+\| B\s+\|/u);
  assert.equal(editor.commands.undo(), true);
  assert.deepEqual(tableDimensions(editor), { rows: 2, columns: 2 });

  addColumn.click();
  assert.deepEqual(tableDimensions(editor), { rows: 2, columns: 3 });
  assert.equal(editor.commands.undo(), true);
  assert.deepEqual(tableDimensions(editor), { rows: 2, columns: 2 });

  addRow.click();
  rowHandle.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
    key: "Delete",
    bubbles: true,
    cancelable: true
  }));
  assert.deepEqual(tableDimensions(editor), { rows: 2, columns: 2 });
  addColumn.click();
  columnHandle.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
    key: "Delete",
    bubbles: true,
    cancelable: true
  }));
  assert.deepEqual(tableDimensions(editor), { rows: 2, columns: 2 });
});

test("table handle shortcut is table-scoped while Tab keeps native cell traversal", () => {
  const { dom, api, editor } = setup({
    markdown: "| A | B |\n| --- | --- |\n| one | two |\n\nAfter"
  });
  const firstCell = firstNodePosition(editor, ["tableHeader", "tableCell"]);
  editor.commands.setTextSelection(firstCell.position + 2);
  const initialSelection = editor.state.selection.from;
  assert.equal(editorKey(editor, "Tab"), true);
  assert.notEqual(editor.state.selection.from, initialSelection, "Tab continues to traverse table cells");

  const inside = editorDOMKey(editor, "Enter", { ctrlKey: true });
  assert.equal(inside.defaultPrevented, true);
  const controls = dom.window.document.querySelector(".table-edge-controls");
  assert.equal(dom.window.document.activeElement, controls.querySelector("[data-command='columnHandle']"));
  assert.equal(controls.querySelector(".table-actions-menu"), null);

  let paragraphPosition = null;
  editor.state.doc.descendants((node, position) => {
    if (node.type.name === "paragraph" && node.textContent === "After") paragraphPosition = position;
  });
  editor.commands.setTextSelection(paragraphPosition + 1);
  const outside = editorDOMKey(editor, "Enter", { ctrlKey: true });
  assert.equal(outside.defaultPrevented, false, "the shortcut is not claimed outside a table");
  assert.equal(controls.hidden, true);
  api.destroy();
});

test("image description editor preserves intentional empty alt text, title, and undo", () => {
  const { dom, api, editor } = setup({
    markdown: '![Old description](./assets/diagram.png "Old title")'
  });
  const image = firstNodePosition(editor, "blockedImage");
  assert.ok(image);
  assert.equal(editor.commands.setNodeSelection(image.position), true);
  assert.equal(api.openImageEditor(), true);

  const form = dom.window.document.querySelector("form.image-editor-popover[role='dialog']");
  const alt = form.querySelector("input[name='alt']");
  const title = form.querySelector("input[name='title']");
  assert.equal(form.hidden, false);
  assert.equal(dom.window.document.activeElement, alt);
  assert.equal(alt.value, "Old description");
  assert.equal(title.value, "Old title");
  assert.match(form.querySelector(".image-alt-hint").textContent, /decorative image/i);

  alt.value = "";
  title.value = "Attention flow";
  submit(dom, form);
  assert.equal(form.hidden, true);
  assert.equal(editor.getMarkdown(), '![](./assets/diagram.png "Attention flow")');
  assert.equal(editor.commands.undo(), true);
  assert.equal(editor.getMarkdown(), '![Old description](./assets/diagram.png "Old title")');
});

test("link editor accepts fragments and safe tutorial assets while rejecting executable or ambiguous paths", () => {
  assert.equal(normalizeSafeLinkTarget("#masking"), "#masking");
  assert.equal(normalizeSafeLinkTarget("./src/attention.py#L12"), "./src/attention.py#L12");
  assert.equal(normalizeSafeLinkTarget("../notebooks/demo.ipynb"), null);
  assert.equal(normalizeSafeLinkTarget("./assets/attention diagram.svg"), null);
  for (const unsafe of [
    "javascript:alert(1)",
    "data:text/html,boom",
    "file:///tmp/secret",
    "/etc/passwd",
    "//host/share",
    ".\\secret.md",
    "./%2e%2e/secret.md",
    "./safe/../secret.md",
    "./bad\0name.md"
  ]) {
    assert.equal(normalizeSafeLinkTarget(unsafe), null, unsafe);
  }

  const { dom, editor } = setup({ markdown: "Tutorial" });
  editor.commands.setTextSelection({ from: 1, to: 9 });
  assert.equal(editorKey(editor, "k", { metaKey: true }), true);
  const form = dom.window.document.querySelector("form.link-editor-popover");
  const url = form.querySelector("input[name='url']");
  url.value = "#masking";
  submit(dom, form);
  assert.equal(editor.getMarkdown(), "[Tutorial](#masking)");

  editor.commands.setTextSelection(2);
  editorKey(editor, "k", { metaKey: true });
  url.value = "./src/attention.py#L12";
  submit(dom, form);
  assert.equal(editor.getMarkdown(), "[Tutorial](./src/attention.py#L12)");

  editor.commands.setTextSelection(2);
  editorKey(editor, "k", { metaKey: true });
  url.value = "javascript:alert(1)";
  submit(dom, form);
  assert.equal(form.hidden, false);
  assert.equal(url.getAttribute("aria-invalid"), "true");
  assert.match(form.querySelector(".link-editor-error").textContent, /safe \.\/ path inside this document folder/i);
  assert.equal(editor.getMarkdown(), "[Tutorial](./src/attention.py#L12)");
});

test("fragment links jump to stable Unicode and duplicate heading targets", () => {
  const outline = sourceDocumentOutline([
    "# 从零实现 Self-Attention",
    "",
    "## 1. 张量形状",
    "",
    "## 3. 架构图",
    "",
    "## 3. 架构图"
  ].join("\n"));
  assert.deepEqual(
    outlineWithFragments(outline).map(({ fragment }) => fragment),
    ["从零实现-self-attention", "1-张量形状", "3-架构图", "3-架构图-1"]
  );
  assert.equal(
    headingForFragment(outline, "#1-%E5%BC%A0%E9%87%8F%E5%BD%A2%E7%8A%B6")?.text,
    "1. 张量形状"
  );
  assert.equal(headingForFragment(outline, "#3-架构图-1")?.position, outline.at(-1).position);
  assert.equal(headingForFragment(outline, "#missing"), null);

  const markdown = [
    "[Jump](#3-架构图-1)",
    "",
    "## 3. 架构图",
    "",
    "First",
    "",
    "## 3. 架构图",
    "",
    "Second"
  ].join("\n");
  const { dom, editor } = setup({ markdown });
  const headings = [];
  editor.state.doc.descendants((node, position) => {
    if (node.type.name === "heading") headings.push({ node, position });
  });
  const link = Array.from(dom.window.document.querySelectorAll("a[href]")).find(
    (candidate) => decodeURIComponent(candidate.getAttribute("href")) === "#3-架构图-1"
  );
  assert.ok(link);
  link.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.equal(editor.state.selection.from, headings.at(-1).position + 1);
});

test("a Unicode heading rename repairs duplicate fragments atomically and undo restores both", () => {
  const markdown = [
    "[First](#架构图)",
    "",
    "[Second](#%E6%9E%B6%E6%9E%84%E5%9B%BE-1)",
    "",
    "## 架构图",
    "",
    "First body",
    "",
    "## 架构图",
    "",
    "Second body"
  ].join("\n");
  const { dom, api, editor } = setup({ markdown });
  const headings = [];
  editor.state.doc.descendants((node, position) => {
    if (node.type.name === "heading") headings.push({ node, position });
  });
  editor.view.dispatch(editor.state.tr.insertText(
    "系统架构",
    headings[0].position + 1,
    headings[0].position + 1 + headings[0].node.content.size
  ));

  const hrefs = Array.from(dom.window.document.querySelectorAll("a[href]"), (link) => (
    link.getAttribute("href")
  ));
  assert.deepEqual(hrefs, ["#系统架构", "#%E6%9E%B6%E6%9E%84%E5%9B%BE"]);
  assert.match(dom.window.document.querySelector(".heading-link-status").textContent, /2 internal heading links updated/u);

  assert.equal(editor.commands.undo(), true);
  assert.deepEqual(
    Array.from(dom.window.document.querySelectorAll("a[href]"), (link) => link.getAttribute("href")),
    ["#架构图", "#%E6%9E%B6%E6%9E%84%E5%9B%BE-1"]
  );
  assert.equal(editor.state.doc.textContent.includes("系统架构"), false);
  api.destroy();
});

test("ambiguous multi-heading edits keep fragment links and show a visible warning", () => {
  assert.equal(
    headingFragmentRepairPlan(
      [{ level: 2, text: "One" }, { level: 2, text: "Two" }],
      [{ level: 2, text: "Alpha" }, { level: 2, text: "Beta" }]
    ).kind,
    "ambiguous"
  );
  const { dom, api, editor } = setup({
    markdown: "[One](#one) [Two](#two)\n\n## One\n\n## Two"
  });
  const headings = [];
  editor.state.doc.descendants((node, position) => {
    if (node.type.name === "heading") headings.push({ node, position });
  });
  let transaction = editor.state.tr;
  for (const [index, replacement] of [[1, "Beta"], [0, "Alpha"]]) {
    const heading = headings[index];
    transaction = transaction.insertText(
      replacement,
      heading.position + 1,
      heading.position + 1 + heading.node.content.size
    );
  }
  editor.view.dispatch(transaction);
  assert.deepEqual(
    Array.from(dom.window.document.querySelectorAll("a[href]"), (link) => link.getAttribute("href")),
    ["#one", "#two"]
  );
  const status = dom.window.document.querySelector(".heading-link-status");
  assert.equal(status.hidden, false);
  assert.match(status.textContent, /kept unchanged.+ambiguously/u);
  api.destroy();
});

test("card-focused Markdown shortcuts own headings and strikethrough", () => {
  const { editor } = setup({ markdown: "Shortcut text" });
  editor.commands.focus("end", { scrollIntoView: false });

  for (let level = 1; level <= 6; level += 1) {
    assert.equal(editorKey(editor, String(level), { metaKey: true }), true);
    assert.equal(editor.state.doc.firstChild.type.name, "heading");
    assert.equal(editor.state.doc.firstChild.attrs.level, level);
  }
  assert.equal(editorKey(editor, "0", { metaKey: true }), true);
  assert.equal(editor.state.doc.firstChild.type.name, "paragraph");

  editor.commands.selectAll();
  assert.equal(editorKey(editor, "s", { metaKey: true, shiftKey: true }), true);
  assert.match(editor.getMarkdown(), /~~Shortcut text~~/);
});
