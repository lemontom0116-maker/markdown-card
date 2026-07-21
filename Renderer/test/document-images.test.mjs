import test from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { installMarkdownCard } from "../src/app.js";
import {
  documentImagePresentation,
  documentImageURL,
  managedAttachmentID,
  safeDocumentImagePath
} from "../src/document-images.js";

function setupRenderer(payload = {}) {
  const dom = new JSDOM(
    '<!doctype html><html data-theme="dark"><body><main id="renderer"></main></body></html>',
    { url: "https://markdown-card.invalid/", pretendToBeVisual: true }
  );
  dom.window.matchMedia = () => ({
    matches: false,
    addEventListener() {},
    removeEventListener() {}
  });
  globalThis.window = dom.window;
  globalThis.document = dom.window.document;
  globalThis.Node = dom.window.Node;
  globalThis.HTMLElement = dom.window.HTMLElement;
  globalThis.Element = dom.window.Element;
  globalThis.DocumentFragment = dom.window.DocumentFragment;
  globalThis.MutationObserver = dom.window.MutationObserver;
  globalThis.DOMParser = dom.window.DOMParser;
  globalThis.getSelection = dom.window.getSelection.bind(dom.window);
  globalThis.requestAnimationFrame = dom.window.requestAnimationFrame.bind(dom.window);
  globalThis.cancelAnimationFrame = dom.window.cancelAnimationFrame.bind(dom.window);
  if (!dom.window.Range.prototype.getClientRects) {
    dom.window.Range.prototype.getClientRects = () => [];
  }
  if (!dom.window.Range.prototype.getBoundingClientRect) {
    dom.window.Range.prototype.getBoundingClientRect = () => ({
      x: 0, y: 0, top: 0, left: 0, bottom: 0, right: 0, width: 0, height: 0
    });
  }
  dom.window.webkit = { messageHandlers: { markdownCard: { postMessage() {} } } };
  const api = installMarkdownCard(dom.window, dom.window.document);
  api.render({ cardID: "card-one", markdown: "", revision: 0, ...payload });
  return { dom, api, editor: api.getEditor() };
}

test("classifies managed attachments without treating arbitrary images as attachments", () => {
  assert.equal(
    managedAttachmentID("attachments/34d1880c-35d5-4c7e-9620-40c3140b003c.png"),
    "34d1880c-35d5-4c7e-9620-40c3140b003c"
  );
  assert.equal(managedAttachmentID("./assets/attention.png"), null);
});

test("keeps relative images blocked until native document access is available", () => {
  const blocked = documentImagePresentation({
    cardID: "card-one",
    source: "./assets/attention.png",
    alt: "Attention flow",
    documentImagesAvailable: false
  });
  assert.equal(blocked.kind, "blocked");
  assert.match(blocked.message, /Link or save/);

  const allowed = documentImagePresentation({
    cardID: "card-one",
    source: "./assets/attention.png",
    alt: "Attention flow",
    title: "QK transpose V",
    documentImagesAvailable: true
  });
  assert.deepEqual(allowed, {
    kind: "document",
    src: "mdcard-asset://document/card-one?path=assets%2Fattention.png",
    alt: "Attention flow",
    title: "QK transpose V"
  });
});

test("accepts document-local image paths and canonicalizes a leading dot segment", () => {
  assert.equal(safeDocumentImagePath("./assets/attention flow.png"), "assets/attention flow.png");
  assert.equal(safeDocumentImagePath("images/注意力.png"), "images/注意力.png");
  assert.equal(
    documentImageURL("F5012677-C9EC-4525-B0FB-80585ABD409F", "./images/注意力 flow.png"),
    "mdcard-asset://document/F5012677-C9EC-4525-B0FB-80585ABD409F?path=images%2F%E6%B3%A8%E6%84%8F%E5%8A%9B%20flow.png"
  );
});

test("rejects traversal, arbitrary files, remote URLs, protocol-relative paths, and backslashes", () => {
  for (const source of [
    "../private.png",
    "assets/../private.png",
    "/tmp/private.png",
    "~/private.png",
    "file:///etc/passwd",
    "https://example.com/remote.png",
    "data:image/png;base64,AAAA",
    "//server/share.png",
    "assets\\private.png",
    ""
  ]) {
    assert.equal(safeDocumentImagePath(source), null, source);
  }
});

test("a bound document renders only safe relative images and preserves Markdown source", () => {
  const markdown = [
    '![Attention flow](./assets/attention.png "Diagram")',
    "![Traversal](../private.png)",
    "![Remote](https://example.com/remote.png)"
  ].join("\n\n");
  const { dom, api, editor } = setupRenderer({ markdown });
  const canvas = dom.window.document.querySelector(".ProseMirror");

  assert.equal(canvas.querySelectorAll("img.document-image").length, 0);
  assert.match(canvas.querySelector(".image-blocked").textContent, /Link or save/);
  assert.equal(api.peekState().markdown, markdown);
  assert.equal(api.setDocumentImagesAvailable("another-card", true), false);
  assert.equal(api.setDocumentImagesAvailable("card-one", true), true);

  const image = canvas.querySelector("img.document-image");
  assert.ok(image);
  assert.equal(
    image.getAttribute("src"),
    "mdcard-asset://document/card-one?path=assets%2Fattention.png"
  );
  assert.equal(image.alt, "Attention flow");
  assert.equal(image.title, "Diagram");
  assert.equal(canvas.querySelectorAll("img.document-image").length, 1);
  assert.equal(canvas.querySelectorAll(".image-blocked").length, 2);
  assert.equal(api.peekState().markdown, markdown);

  image.dispatchEvent(new dom.window.Event("error"));
  assert.match(canvas.querySelector(".image-unavailable").textContent, /Image unavailable/);
  assert.equal(api.peekState().markdown, markdown);
  api.destroy();
});
