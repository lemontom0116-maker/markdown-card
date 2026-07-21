import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";
import { installMarkdownCard } from "../src/app.js";
import { transformMarkdownSource } from "../src/source-shortcuts.js";

function installDOMGlobals(window) {
  globalThis.window = window;
  globalThis.document = window.document;
  globalThis.Node = window.Node;
  globalThis.HTMLElement = window.HTMLElement;
  globalThis.Element = window.Element;
  globalThis.DocumentFragment = window.DocumentFragment;
  globalThis.MutationObserver = window.MutationObserver;
  globalThis.DOMParser = window.DOMParser;
  globalThis.getComputedStyle = window.getComputedStyle.bind(window);
  globalThis.getSelection = window.getSelection.bind(window);
  globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
  globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
  if (!window.Range.prototype.getClientRects) window.Range.prototype.getClientRects = () => [];
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

function setup(payload = {}, configureWindow = null) {
  const dom = makeDOM();
  const messages = [];
  configureWindow?.(dom.window);
  dom.window.webkit = {
    messageHandlers: {
      markdownCard: { postMessage: (message) => messages.push(message) }
    }
  };
  const api = installMarkdownCard(dom.window, dom.window.document);
  api.render({ cardID: "tutorial-card", markdown: "", revision: 0, ...payload });
  return { dom, api, editor: api.getEditor(), messages };
}

function editorKey(editor, key, options = {}) {
  const EventType = editor.view.dom.ownerDocument.defaultView.KeyboardEvent;
  const event = new EventType("keydown", {
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
  return { handled, event };
}

function key(target, keyValue, options = {}) {
  const EventType = target.ownerDocument?.defaultView?.KeyboardEvent
    ?? target.defaultView?.KeyboardEvent;
  const event = new EventType("keydown", {
    key: keyValue,
    bubbles: true,
    cancelable: true,
    ...options
  });
  target.dispatchEvent(event);
  return event;
}

function composition(target, type) {
  const event = new target.ownerDocument.defaultView.Event(type, { bubbles: true });
  target.dispatchEvent(event);
}

function firstNodePosition(editor, names) {
  const accepted = new Set(Array.isArray(names) ? names : [names]);
  let result = null;
  editor.state.doc.descendants((node, position) => {
    if (result == null && accepted.has(node.type.name)) result = { node, position };
  });
  return result;
}

function cellPositionWithText(editor, text) {
  let position = null;
  editor.state.doc.descendants((node, nodePosition) => {
    if (position == null
        && ["tableCell", "tableHeader"].includes(node.type.name)
        && node.textContent === text) {
      position = nodePosition;
    }
  });
  return position;
}

function submit(dom, form) {
  form.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
}

const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function runFootnoteSurvivalProbe(timeoutMilliseconds = 2_000) {
  const probePath = fileURLToPath(
    new URL("../test-support/footnote-survival-probe.mjs", import.meta.url)
  );
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [probePath], {
      cwd: fileURLToPath(new URL("..", import.meta.url)),
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";
    let finished = false;
    const watchdog = setTimeout(() => {
      if (finished) return;
      finished = true;
      child.kill("SIGKILL");
      reject(new Error(
        `footnote renderer did not yield after ${timeoutMilliseconds} ms; `
        + "possible MutationObserver feedback loop"
      ));
    }, timeoutMilliseconds);

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", (error) => {
      if (finished) return;
      finished = true;
      clearTimeout(watchdog);
      reject(error);
    });
    child.once("exit", (code, signal) => {
      if (finished) return;
      finished = true;
      clearTimeout(watchdog);
      if (code !== 0) {
        reject(new Error(`footnote probe exited with ${code ?? signal}: ${stderr}`));
        return;
      }
      resolve(JSON.parse(stdout));
    });
  });
}

test("IME composition owns Enter, Escape, shortcuts, overlays, math, and slash commands", async () => {
  const { dom, api, editor, messages } = setup({
    markdown: "Formula $x$ and link text\n\n/tag 中文"
  });
  editor.commands.setTextSelection({ from: 1, to: 8 });
  assert.equal(editorKey(editor, "k", { metaKey: true }).handled, true);
  const linkForm = dom.window.document.querySelector("form.link-editor-popover");
  const linkURL = linkForm.querySelector("input[name='url']");
  composition(linkURL, "compositionstart");
  key(linkURL, "Enter");
  key(linkURL, "Escape");
  assert.equal(linkForm.hidden, false);
  assert.doesNotMatch(editor.getMarkdown(), /https:\/\//u);

  const modeEvent = key(dom.window.document, "m", { metaKey: true, shiftKey: true });
  const escapeEvent = key(dom.window.document, "Escape");
  assert.equal(modeEvent.defaultPrevented, false);
  assert.equal(escapeEvent.defaultPrevented, false);
  assert.equal(api.peekState().editorMode, "rich");
  assert.equal(messages.some((message) => message.type === "hideRequested"), false);
  composition(linkURL, "compositionend");
  key(linkURL, "Escape");
  assert.equal(linkForm.hidden, true);

  const math = dom.window.document.querySelector(".math-node-inline");
  math.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
  const mathSource = math.querySelector("input.math-source");
  composition(mathSource, "compositionstart");
  key(mathSource, "Enter", { metaKey: true });
  key(mathSource, "Escape");
  assert.ok(math.querySelector("input.math-source"));
  composition(mathSource, "compositionend");
  key(mathSource, "Escape");
  assert.equal(math.querySelector("input.math-source"), null);

  editor.commands.focus("end", { scrollIntoView: false });
  composition(editor.view.dom, "compositionstart");
  editorKey(editor, "Enter");
  assert.equal(messages.some((message) => message.type === "tagCommandSubmitted"), false);
  composition(editor.view.dom, "compositionend");

  api.setEditorMode("source", { focus: false });
  const source = dom.window.document.querySelector("textarea.source-editor");
  source.setSelectionRange(0, 7);
  composition(source, "compositionstart");
  key(source, "b", { metaKey: true });
  assert.equal(source.value.startsWith("**"), false);
  composition(source, "compositionend");
  api.destroy();

  const tableSession = setup({
    markdown: "| A | B |\n| --- | --- |\n| one | two |"
  });
  const tableCell = firstNodePosition(tableSession.editor, "tableHeader");
  tableSession.editor.commands.setTextSelection(tableCell.position + 2);
  const columnHandle = tableSession.dom.window.document.querySelector("[data-command='columnHandle']");
  composition(tableSession.editor.view.dom, "compositionstart");
  const guardedTableShortcut = key(
    tableSession.editor.view.dom,
    "Enter",
    { ctrlKey: true }
  );
  assert.equal(guardedTableShortcut.defaultPrevented, false);
  assert.notEqual(
    tableSession.dom.window.document.activeElement,
    columnHandle,
    "IME composition retains the table shortcut"
  );
  composition(tableSession.editor.view.dom, "compositionend");
  const availableTableShortcut = key(
    tableSession.editor.view.dom,
    "Enter",
    { ctrlKey: true }
  );
  assert.equal(availableTableShortcut.defaultPrevented, true);
  assert.equal(tableSession.dom.window.document.activeElement, columnHandle);
  tableSession.api.destroy();
});

test("IME composition state synchronizes to native and resets on blur, pagehide, and destroy", () => {
  const { dom, api, editor, messages } = setup({ markdown: "中文输入" });
  const compositionMessages = () => messages.filter(
    (message) => message.type === "editorCompositionChanged"
  );
  const canvas = editor.view.dom;

  assert.deepEqual(compositionMessages().map((message) => message.isComposing), [false]);

  composition(canvas, "compositionstart");
  composition(canvas, "compositionstart");
  assert.deepEqual(compositionMessages().map((message) => message.isComposing), [false, true]);

  composition(canvas, "compositionend");
  assert.equal(compositionMessages().at(-1).isComposing, true);
  dom.window.dispatchEvent(new dom.window.Event("blur"));
  assert.equal(compositionMessages().at(-1).isComposing, false);

  composition(canvas, "compositionstart");
  dom.window.dispatchEvent(new dom.window.Event("pagehide"));
  assert.deepEqual(
    compositionMessages().slice(-2).map((message) => message.isComposing),
    [true, false]
  );

  composition(canvas, "compositionstart");
  api.destroy();
  assert.deepEqual(
    compositionMessages().slice(-2).map((message) => message.isComposing),
    [true, false]
  );
});

test("Mermaid renders offline through a strict adapter, keeps editable source, and exposes errors", async () => {
  const markdown = "```mermaid\nflowchart LR\n  A --> B\n```";
  const success = setup({ markdown }, (window) => {
    window.__markdownCardMermaidRenderer = async (_id, source) => ({
      svg: `<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script><text>${source.length}</text></svg>`
    });
  });
  await wait(170);
  const figure = success.dom.window.document.querySelector("figure.mermaid-node");
  assert.ok(figure.querySelector(".mermaid-preview svg[role='img']"), figure.outerHTML);
  assert.equal(figure.querySelector("script"), null, "defense-in-depth removes executable SVG content");
  assert.match(figure.querySelector(".mermaid-source code").textContent, /A --> B/u);
  assert.match(success.api.getState().markdown, /```mermaid\nflowchart LR/u);
  assert.equal(figure.dataset.state, "ready");

  const failure = setup({ markdown }, (window) => {
    window.__markdownCardMermaidRenderer = async () => {
      throw new Error("Parse error on line 2");
    };
  });
  await wait(170);
  const failedFigure = failure.dom.window.document.querySelector("figure.mermaid-node");
  assert.equal(failedFigure.dataset.state, "error");
  assert.match(failedFigure.querySelector(".mermaid-error").textContent, /line 2/u);
  assert.match(failedFigure.querySelector(".mermaid-source").textContent, /A --> B/u);
  success.api.destroy();
  failure.api.destroy();
});

test("GFM-style footnotes render numbered references, definitions, backlinks, and reversible Markdown", () => {
  const markdown = "Mask before softmax.[^mask]\n\n[^mask]: Causal **mask** blocks future tokens.";
  const { dom, api } = setup({ markdown });
  const reference = dom.window.document.querySelector("sup[data-footnote-reference='mask']");
  const definition = dom.window.document.querySelector("aside[data-footnote-definition='mask']");
  assert.equal(reference.querySelector("a").textContent, "1");
  assert.equal(reference.querySelector("a").getAttribute("href"), "#fn-mask");
  assert.equal(definition.querySelector(".footnote-number").textContent, "1.");
  assert.equal(definition.querySelector("strong").textContent, "mask");
  assert.equal(definition.querySelector(".footnote-backlink").getAttribute("href"), "#fnref-mask");
  assert.match(api.getState().markdown, /Mask before softmax\.\[\^mask\]/u);
  assert.match(api.getState().markdown, /\[\^mask\]: Causal \*\*mask\*\* blocks future tokens\./u);
  api.destroy();
});

test("footnote navigation yields after render and editable-body transactions", async () => {
  const result = await runFootnoteSurvivalProbe();
  assert.deepEqual(result.referenceNumbers, ["1", "1"]);
  assert.deepEqual(result.referenceIDs, ["fnref-mask", "fnref-mask-2"]);
  assert.equal(result.maskNumber, "1.");
  assert.equal(result.otherNumber, "2.");
  assert.equal(result.maskBacklink, "#fnref-mask");
  assert.match(result.markdown, /\[\^mask\]: Editable \*\*mask\*\* body\. updated/u);
});

test("Source shortcuts transform selections and each transformation has one-step undo", () => {
  assert.deepEqual(
    transformMarkdownSource("alpha", 0, 5, "b"),
    { value: "**alpha**", start: 2, end: 7 }
  );
  assert.equal(transformMarkdownSource("`a` + b", 0, 7, "e").value, "`` `a` + b ``");
  assert.match(transformMarkdownSource("section", 0, 7, "h3").value, /^### section/u);
  assert.match(transformMarkdownSource("docs", 0, 4, "k").value, /^\[docs\]\(https:\/\/\)$/u);

  const { dom, api } = setup({ markdown: "alpha" });
  api.setEditorMode("source", { focus: false });
  const source = dom.window.document.querySelector("textarea.source-editor");
  source.setSelectionRange(0, 5);
  const bold = key(source, "b", { metaKey: true });
  assert.equal(bold.defaultPrevented, true);
  assert.equal(source.value, "**alpha**");
  const undo = key(source, "z", { metaKey: true });
  assert.equal(undo.defaultPrevented, true);
  assert.equal(source.value, "alpha");
  key(source, "z", { metaKey: true, shiftKey: true });
  assert.equal(source.value, "**alpha**");
  api.destroy();
});

test("table Markdown retains GFM headers and alignment while TSV paste stays one undo step", () => {
  const { dom, api, editor } = setup({
    markdown: "| A | B |\n| :---: | ---: |\n| one | two |"
  });
  const firstCell = firstNodePosition(editor, "tableHeader");
  editor.commands.setTextSelection(firstCell.position + 2);
  const controls = dom.window.document.querySelector(".table-edge-controls");
  assert.equal(controls.querySelector(".table-actions-menu"), null);
  assert.equal(controls.querySelector("[data-command='openTableMenu']"), null);
  const table = firstNodePosition(editor, "table").node;
  assert.equal(table.child(0).child(0).attrs.align, "center");
  assert.equal(table.child(1).child(0).attrs.align, "center");
  assert.equal(table.child(0).child(1).attrs.align, "right");
  assert.match(api.getState().markdown, /\| :---: \| ---: \|/u);

  assert.equal(editor.commands.toggleHeaderRow(), true);
  assert.equal(firstNodePosition(editor, "table").node.child(0).child(0).type.name, "tableCell");
  assert.equal(editor.commands.undo(), true);

  const paste = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", {
    value: { items: [], getData: (type) => type === "text/plain" ? "Stage\tShape\nQK\tB×T×T" : "" }
  });
  editor.view.dom.dispatchEvent(paste);
  assert.equal(paste.defaultPrevented, true);
  assert.match(editor.state.doc.textContent, /StageShapeQKB×T×T/u);
  assert.equal(editor.commands.undo(), true);
  assert.match(editor.state.doc.textContent, /ABonetwo/u);
  api.destroy();
});

test("table handles move rows by keyboard and columns by drag in portable one-step transactions", () => {
  const { dom, api, editor } = setup({
    markdown: "| A | B | C |\n| --- | --- | --- |\n| r1a | r1b | r1c |\n| r2a | r2b | r2c |"
  });
  editor.commands.setTextSelection(cellPositionWithText(editor, "r1a") + 2);
  const controls = dom.window.document.querySelector(".table-edge-controls");
  const rowHandle = controls.querySelector("button[data-command='rowHandle']");
  const columnHandle = controls.querySelector("button[data-command='columnHandle']");

  rowHandle.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
    key: "ArrowDown",
    altKey: true,
    bubbles: true,
    cancelable: true
  }));
  assert.match(editor.getMarkdown(), /\| r2a \| r2b \| r2c \|\n\| r1a \| r1b \| r1c \|/u);
  assert.equal(editor.commands.undo(), true);

  editor.commands.setTextSelection(cellPositionWithText(editor, "r1a") + 2);
  columnHandle.dispatchEvent(new dom.window.MouseEvent("pointerdown", {
    button: 0,
    clientX: 100,
    clientY: 100,
    bubbles: true,
    cancelable: true
  }));
  columnHandle.dispatchEvent(new dom.window.MouseEvent("pointermove", {
    clientX: 126,
    clientY: 100,
    bubbles: true,
    cancelable: true
  }));
  columnHandle.dispatchEvent(new dom.window.MouseEvent("pointerup", {
    button: 0,
    clientX: 136,
    clientY: 100,
    bubbles: true,
    cancelable: true
  }));
  assert.match(editor.getMarkdown(), /\| B\s+\| A\s+\| C\s+\|/u);
  assert.match(editor.getMarkdown(), /\| r1b \| r1a \| r1c \|/u);
  assert.equal(editor.commands.undo(), true);

  editor.commands.setTextSelection(cellPositionWithText(editor, "r1a") + 2);
  const beforeCancelledDrag = editor.getMarkdown();
  columnHandle.dispatchEvent(new dom.window.MouseEvent("pointerdown", {
    button: 0,
    clientX: 100,
    clientY: 100,
    bubbles: true,
    cancelable: true
  }));
  columnHandle.dispatchEvent(new dom.window.MouseEvent("pointermove", {
    clientX: 180,
    clientY: 100,
    bubbles: true,
    cancelable: true
  }));
  assert.equal(columnHandle.classList.contains("is-dragging"), true);
  columnHandle.dispatchEvent(new dom.window.MouseEvent("pointercancel", {
    clientX: 180,
    clientY: 100,
    bubbles: true,
    cancelable: true
  }));
  assert.equal(columnHandle.classList.contains("is-dragging"), false);
  assert.equal(editor.getMarkdown(), beforeCancelledDrag, "a cancelled drag never mutates the table");
  api.destroy();
});

test("image authoring round-trips source, caption, width, alignment, replacement, and undo", () => {
  const markdown = '![Flow](./assets/flow.png "Tooltip"){caption="Attention flow" width="75%" align="center"}';
  const { dom, api, editor } = setup({ markdown });
  const image = firstNodePosition(editor, "blockedImage");
  assert.equal(image.node.attrs.caption, "Attention flow");
  assert.equal(image.node.attrs.width, 75);
  assert.equal(image.node.attrs.alignment, "center");
  editor.commands.setNodeSelection(image.position);
  api.openImageEditor();
  const form = dom.window.document.querySelector("form.image-editor-popover");
  form.querySelector("input[name='source']").value = "./assets/flow-v2.png";
  form.querySelector("input[name='caption']").value = "Updated flow";
  form.querySelector("select[name='width']").value = "50";
  form.querySelector("select[name='alignment']").value = "right";
  submit(dom, form);

  assert.match(editor.getMarkdown(), /flow-v2\.png/u);
  assert.match(editor.getMarkdown(), /caption="Updated flow" width="50%" align="right"/u);
  const rendered = dom.window.document.querySelector(".blocked-image-node");
  assert.equal(rendered.dataset.alignment, "right");
  assert.equal(rendered.querySelector(".image-caption").textContent, "Updated flow");
  assert.equal(editor.commands.undo(), true);
  assert.equal(editor.getMarkdown(), markdown);
  api.destroy();
});

test("dragged image files use the drop position and complete as managed attachments", async () => {
  const { dom, api, editor, messages } = setup({ markdown: "Before\n\nAfter" });
  const file = new dom.window.File([new Uint8Array([137, 80, 78, 71])], "attention.png", {
    type: "image/png"
  });
  const drop = new dom.window.Event("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(drop, "dataTransfer", { value: { files: [file] } });
  Object.defineProperty(drop, "clientX", { value: 12 });
  Object.defineProperty(drop, "clientY", { value: 12 });
  const originalPosAtCoords = editor.view.posAtCoords.bind(editor.view);
  editor.view.posAtCoords = () => ({ pos: 1, inside: -1 });
  let handled = false;
  editor.view.someProp("handleDrop", (handler) => {
    if (handler(editor.view, drop, false)) handled = true;
  });
  editor.view.posAtCoords = originalPosAtCoords;
  assert.equal(handled, true);
  assert.equal(drop.defaultPrevented, true);
  await wait(20);
  const request = messages.find((message) => message.type === "localImagePasteRequested");
  assert.ok(request);
  editor.commands.focus("end", { scrollIntoView: false });
  const attachmentID = "55d1880c-35d5-4c7e-9620-40c3140b003c";
  assert.equal(api.completeImagePaste({
    requestID: request.requestID,
    cardID: "tutorial-card",
    source: `attachments/${attachmentID}.png`,
    alt: "Attention"
  }), true);
  assert.ok(dom.window.document.querySelector("img.local-attachment"));
  assert.ok(editor.getMarkdown().indexOf("![Attention]") < editor.getMarkdown().indexOf("Before"));
  api.destroy();
});

test("safe relative tutorial links post an openDocumentLink request without changing other links", () => {
  const { dom, api, messages } = setup({ markdown: "[Code](./src/attention.py#L12)" });
  const link = dom.window.document.querySelector("a[href]");
  link.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.deepEqual(
    messages.filter((message) => message.type === "openDocumentLink").at(-1),
    { type: "openDocumentLink", cardID: "tutorial-card", href: "./src/attention.py#L12" }
  );
  api.destroy();
});
