import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { JSDOM } from "jsdom";
import { installMarkdownCard } from "../src/app.js";
import { rendererPluginRegistry } from "../src/plugins.js";

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

function dispatchInputKey(dom, input, key) {
  return input.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
    key,
    bubbles: true,
    cancelable: true
  }));
}

function nextFrame(dom) {
  return new Promise((resolve) => dom.window.requestAnimationFrame(resolve));
}

async function attachRendererStyles(dom) {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  const style = dom.window.document.createElement("style");
  style.textContent = css;
  dom.window.document.head.appendChild(style);
  return css;
}

test("Command-K creates, edits, removes, and cancels links from one accessible panel", () => {
  const { dom, editor, messages } = setup({ markdown: "Label" });
  const document = dom.window.document;
  const popover = document.querySelector("form.link-editor-popover[role='dialog']");
  const textInput = popover.querySelector("input[name='text']");
  const urlInput = popover.querySelector("input[name='url']");

  editor.commands.setTextSelection({ from: 1, to: 6 });
  assert.equal(pressKey(editor, "k", { metaKey: true }), true);
  assert.equal(popover.hidden, false);
  assert.equal(popover.getAttribute("aria-label"), "Add link");
  assert.equal(textInput.value, "Label");
  assert.equal(document.activeElement, urlInput);

  urlInput.value = "example.com/guide";
  assert.equal(dispatchInputKey(dom, urlInput, "Enter"), false);
  assert.equal(popover.hidden, true);
  assert.equal(editor.getMarkdown(), "[Label](https://example.com/guide)");

  editor.commands.setTextSelection(2);
  assert.equal(pressKey(editor, "k", { metaKey: true }), true);
  assert.equal(popover.getAttribute("aria-label"), "Edit link");
  assert.equal(urlInput.value, "https://example.com/guide");
  textInput.value = "Docs";
  urlInput.value = "https://docs.example.com/start";
  dispatchInputKey(dom, urlInput, "Enter");
  assert.equal(editor.getMarkdown(), "[Docs](https://docs.example.com/start)");

  editor.commands.setTextSelection(2);
  pressKey(editor, "k", { metaKey: true });
  const remove = popover.querySelector("button.link-editor-remove");
  assert.equal(remove.hidden, false);
  remove.click();
  assert.equal(editor.getMarkdown(), "Docs");

  editor.commands.setTextSelection({ from: 1, to: 5 });
  pressKey(editor, "k", { metaKey: true });
  textInput.value = "Discarded";
  urlInput.value = "https://discarded.example";
  assert.equal(dispatchInputKey(dom, urlInput, "Escape"), false);
  assert.equal(popover.hidden, true);
  assert.equal(editor.getMarkdown(), "Docs");
  assert.deepEqual(
    { from: editor.state.selection.from, to: editor.state.selection.to },
    { from: 1, to: 5 }
  );
  assert.equal(messages.some((message) => message.type === "hideRequested"), false);
  assert.equal(pressKey(editor, "l", { metaKey: true }), false, "Mod-L is no longer a second link path");
});

test("link panel closes without restoring a previous card selection on switch and destroy", () => {
  const { dom, api, editor } = setup({ markdown: "First card" });
  const popover = dom.window.document.querySelector(".link-editor-popover");
  editor.commands.setTextSelection({ from: 1, to: 6 });
  pressKey(editor, "k", { metaKey: true });
  assert.equal(popover.hidden, false);

  api.render({ cardID: "card-two", markdown: "Second card", revision: 0 });
  assert.equal(popover.hidden, true);
  assert.equal(editor.getMarkdown(), "Second card");
  assert.notDeepEqual(
    { from: editor.state.selection.from, to: editor.state.selection.to },
    { from: 1, to: 6 }
  );

  editor.commands.setTextSelection({ from: 1, to: 7 });
  pressKey(editor, "k", { metaKey: true });
  assert.equal(popover.hidden, false);
  api.destroy();
  assert.equal(dom.window.document.querySelector(".link-editor-popover"), null);
});

test("a short Sticky card grows for the link panel, restores on close, and repositions on resize", async () => {
  const { dom, api, editor, messages } = setup({ markdown: "Short" });
  const { document } = dom.window;
  const renderer = document.querySelector("#renderer");
  const canvas = document.querySelector(".ProseMirror");
  const popover = document.querySelector(".link-editor-popover");
  const urlInput = popover.querySelector("input[name='url']");
  const panelWidth = 336;
  const panelHeight = 214;

  Object.defineProperty(dom.window, "innerWidth", {
    configurable: true,
    writable: true,
    value: 360
  });
  Object.defineProperty(dom.window, "innerHeight", {
    configurable: true,
    writable: true,
    value: 154
  });
  Object.defineProperty(canvas, "scrollHeight", { configurable: true, value: 42 });
  canvas.getBoundingClientRect = () => ({
    x: 0,
    y: 0,
    top: 0,
    left: 0,
    right: 304,
    bottom: 42,
    width: 304,
    height: 42
  });
  renderer.getBoundingClientRect = () => ({
    x: 0,
    y: 0,
    top: 0,
    left: 0,
    right: dom.window.innerWidth,
    bottom: dom.window.innerHeight,
    width: dom.window.innerWidth,
    height: dom.window.innerHeight
  });
  popover.getBoundingClientRect = () => {
    const top = Number.parseFloat(popover.style.top) || 0;
    const left = Number.parseFloat(popover.style.left) || 0;
    return {
      x: left,
      y: top,
      top,
      left,
      right: left + panelWidth,
      bottom: top + panelHeight,
      width: panelWidth,
      height: panelHeight
    };
  };
  editor.view.coordsAtPos = () => ({ left: 18, right: 18, top: 20, bottom: 38 });

  const baselineHeight = api.measureContentHeight();
  const messageStart = messages.length;
  editor.commands.setTextSelection({ from: 1, to: 6 });
  assert.equal(pressKey(editor, "k", { metaKey: true }), true);
  await nextFrame(dom);

  const openedHeight = messages.slice(messageStart).filter(
    (message) => message.type === "contentHeightChanged"
  ).at(-1)?.height;
  assert.ok(openedHeight > baselineHeight);
  assert.equal(openedHeight, 12 + panelHeight + 12);

  dom.window.innerHeight = openedHeight;
  dom.window.dispatchEvent(new dom.window.Event("resize"));
  await nextFrame(dom);
  const top = Number.parseFloat(popover.style.top);
  const left = Number.parseFloat(popover.style.left);
  assert.ok(top >= 12);
  assert.ok(top + panelHeight <= dom.window.innerHeight - 12);
  assert.ok(left >= 12);
  assert.ok(left + panelWidth <= dom.window.innerWidth - 12);

  dispatchInputKey(dom, urlInput, "Escape");
  await nextFrame(dom);
  const restoredHeight = messages.filter(
    (message) => message.type === "contentHeightChanged"
  ).at(-1)?.height;
  assert.equal(popover.hidden, true);
  assert.equal(restoredHeight, baselineHeight);
});

test("slash table command inserts a real full-width 3 by 3 table with a header and no Tag metadata", async () => {
  const { dom, editor, messages } = setup();
  const tablePlugin = rendererPluginRegistry.find((plugin) => plugin.id === "table");
  assert.deepEqual(
    { command: tablePlugin?.command, kind: tablePlugin?.kind, topLevelOnly: tablePlugin?.topLevelOnly },
    { command: "table", kind: "editorCommand", topLevelOnly: true }
  );

  const messageStart = messages.length;
  typeText(editor, "/table");
  assert.equal(pressKey(editor, "Enter"), true);

  const wrapper = dom.window.document.querySelector(".ProseMirror > .tableWrapper");
  await attachRendererStyles(dom);
  const rows = [...wrapper.querySelectorAll("tbody > tr")];
  assert.ok(wrapper);
  assert.equal(wrapper.children.length, 1);
  assert.equal(wrapper.firstElementChild.tagName, "TABLE");
  assert.equal(rows.length, 3);
  assert.equal(rows[0].querySelectorAll(":scope > th").length, 3);
  assert.equal(rows[1].querySelectorAll(":scope > td").length, 3);
  assert.equal(rows[2].querySelectorAll(":scope > td").length, 3);
  assert.equal(
    dom.window.getComputedStyle(wrapper.firstElementChild).width,
    "100%",
    "a normal table fills its wrapper instead of leaving a blank right side"
  );
  assert.match(editor.getMarkdown(), /\|\s+\|\s+\|\s+\|/);
  assert.equal(editor.state.doc.lastChild.type.name, "paragraph");

  const tableMessages = messages.slice(messageStart);
  assert.equal(
    tableMessages.some((message) => message.type === "tagCommandSubmitted"),
    false
  );
  assert.equal(tableMessages.some((message) => message.type === "markdownChanged"), true);
});

test("a generated wide table is horizontally contained at Sticky card width", async () => {
  const markdown = [
    "| A | B | C | D | E | F |",
    "| - | - | - | - | - | - |",
    "| 1 | 2 | 3 | 4 | 5 | 6 |"
  ].join("\n");
  const { dom } = setup({ markdown });
  await attachRendererStyles(dom);
  const document = dom.window.document;
  const renderer = document.querySelector("#renderer");
  renderer.style.width = "360px";
  const wrapper = document.querySelector(".ProseMirror > .tableWrapper");
  const table = wrapper.querySelector(":scope > table");
  const headerCells = [...table.querySelectorAll("tr:first-child > th")];
  const wrapperStyle = dom.window.getComputedStyle(wrapper);
  const tableStyle = dom.window.getComputedStyle(table);
  const cellStyle = dom.window.getComputedStyle(headerCells[0]);
  const stickyContentWidth = 360 - (28 * 2);

  assert.equal(headerCells.length, 6);
  assert.equal(table.parentElement, wrapper);
  assert.equal(wrapperStyle.overflowX, "auto");
  assert.equal(wrapperStyle.maxWidth, "100%");
  assert.equal(tableStyle.width, "100%", "the table stretches to the wrapper before intrinsic overflow");
  assert.ok(
    Number.parseFloat(cellStyle.minWidth) * headerCells.length > stickyContentWidth,
    "the real six-column table is wider than Sticky's content area and its wrapper owns the scroll"
  );
});

test("large viewports constrain and center the canvas while the Sticky breakpoint stays compact", async () => {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  const largeViewport = css.match(
    /@media\s*\(min-width:\s*800px\)\s*\{[\s\S]*?\.markdown-canvas\s*\{([\s\S]*?)\}/
  )?.[1] ?? "";
  const stickyViewport = css.match(
    /@media\s*\(max-width:\s*620px\)\s*\{[\s\S]*?#renderer\s*\{([\s\S]*?)\}/
  )?.[1] ?? "";
  const desktopCells = css.match(/th,\s*\n?td\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  const stickyCells = css.match(
    /@media\s*\(max-width:\s*620px\)\s*\{[\s\S]*?th,\s*\n?\s*td\s*\{([\s\S]*?)\}/
  )?.[1] ?? "";
  const wrappedTable = css.match(/\.tableWrapper table\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  const tableWrapper = css.match(/\.tableWrapper\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  const edgeTargets = css.match(
    /\.table-edge-button,\s*\n?\.table-axis-handle\s*\{([\s\S]*?)\}/
  )?.[1] ?? "";
  const tableHandle = css.match(/\.table-axis-handle \.table-control-glyph\s*\{([\s\S]*?)\}/)?.[1] ?? "";
  assert.match(largeViewport, /max-width:\s*840px/);
  assert.match(largeViewport, /margin-inline:\s*auto/);
  assert.match(stickyViewport, /padding:\s*6px 28px 24px/);
  assert.match(desktopCells, /min-width:\s*72px/);
  assert.match(desktopCells, /padding:\s*8px 10px/);
  assert.match(stickyCells, /min-width:\s*60px/);
  assert.match(stickyCells, /padding:\s*8px/);
  assert.match(wrappedTable, /width:\s*100%/);
  assert.match(wrappedTable, /min-width:\s*100%/);
  assert.doesNotMatch(wrappedTable, /width:\s*max-content/);
  assert.doesNotMatch(
    tableWrapper,
    /padding(?:-[a-z]+)?:/,
    "table controls must not create a blank top row or left column inside the table border"
  );
  assert.doesNotMatch(
    tableWrapper,
    /background:/,
    "the table wrapper must not paint a second rail behind the table"
  );
  assert.match(edgeTargets, /width:\s*44px/);
  assert.match(edgeTargets, /height:\s*44px/);
  assert.match(tableHandle, /box-shadow:\s*none/);
  assert.match(tableHandle, /background:\s*transparent/);
  assert.doesNotMatch(css, /\.table-actions-menu/);
  assert.doesNotMatch(css, /\.table-menu-trigger/);
  assert.ok(60 * 3 <= 360 - (28 * 2), "the default table fits the Sticky content width");
  assert.ok(60 * 6 > 360 - (28 * 2), "a six-column table still needs horizontal scroll");
  assert.match(css, /@media\s*\(prefers-reduced-motion:\s*reduce\)/);
});

test("empty-card hint discovers slash commands without becoming Markdown", async () => {
  const { dom, api, editor } = setup();
  const canvas = dom.window.document.querySelector(".ProseMirror");
  const placeholder = canvas.querySelector("p[data-placeholder]");
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");

  assert.equal(placeholder.dataset.placeholder, "Start writing… Type / for commands");
  assert.equal(canvas.textContent, "");
  assert.equal(api.getState().markdown, "");
  assert.equal(editor.getMarkdown(), "");
  assert.match(css, /content:\s*attr\(data-placeholder\)/);

  typeText(editor, "/");
  assert.equal(canvas.querySelector("[data-placeholder]"), null);
  assert.equal(dom.window.document.querySelector(".slash-plugin-menu").hidden, false);
  assert.ok(dom.window.document.querySelector('[data-plugin-id="table"]'));
});

test("code blocks show a real language hint and Command-Enter exits only from the end", async () => {
  const withLanguage = setup({ markdown: "```python\nprint('hi')\n```" });
  const pre = withLanguage.dom.window.document.querySelector("pre[data-code-block='true']");
  assert.equal(pre.dataset.language, "python");
  assert.match(pre.getAttribute("aria-label"), /^python code block\./);

  const code = withLanguage.editor.state.doc.firstChild;
  const codeEnd = 1 + code.content.size;
  withLanguage.editor.commands.setTextSelection(codeEnd);
  assert.equal(pressKey(withLanguage.editor, "Enter", { metaKey: true }), true);
  assert.equal(withLanguage.editor.state.doc.childCount, 2);
  assert.equal(withLanguage.editor.state.doc.lastChild.type.name, "paragraph");
  assert.equal(withLanguage.editor.state.selection.$from.parent.type.name, "paragraph");

  const middle = setup({ markdown: "```python\nprint('hi')\n```" });
  middle.editor.commands.setTextSelection(3);
  assert.equal(
    pressKey(middle.editor, "Enter", { metaKey: true }),
    true,
    "the custom shortcut consumes Tiptap's broader default without exiting"
  );
  assert.equal(middle.editor.state.doc.childCount, 1);

  const withoutLanguage = setup({ markdown: "```\nplain text\n```" });
  const plainPre = withoutLanguage.dom.window.document.querySelector("pre[data-code-block='true']");
  assert.equal(plainPre.hasAttribute("data-language"), false);
  assert.match(plainPre.getAttribute("aria-label"), /^Code block\./);

  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.match(css, /pre\[data-code-block="true"\]\[data-language\]::before/);
  assert.match(css, /content:\s*attr\(data-language\)\s+" · ⌘↵ exit"/);
  assert.match(css, /pre\[data-code-block="true"\]\[data-code-title\]\[data-language\]::before/);
  assert.match(css, /attr\(data-code-title\)\s+" · "\s+attr\(data-language\)/);
  assert.match(css, /content:\s*"Code block · ⌘↵ exit"/);
  assert.match(css, /\.source-mode-chip\s*\{[^}]*font-size:\s*12px/su);
  assert.match(css, /pre\[data-code-block="true"\]::before\s*\{[^}]*font-size:\s*12px/su);
});
