import { JSDOM } from "jsdom";
import { installMarkdownCard } from "../src/app.js";

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
dom.window.webkit = {
  messageHandlers: {
    markdownCard: { postMessage() {} }
  }
};

const api = installMarkdownCard(dom.window, dom.window.document);
api.render({
  cardID: "footnote-survival-probe",
  markdown: "First[^mask], repeated[^mask], then another[^other].\n\n[^other]: Other body.\n\n[^mask]: Editable **mask** body.",
  revision: 0
});

// A MutationObserver feedback loop starves both timers forever. Running this
// probe in a child process lets the parent test enforce a real wall-clock
// deadline instead of relying on a timer in the already-starved event loop.
setTimeout(() => {
  const editor = api.getEditor();
  let definition = null;
  editor.state.doc.descendants((node, position) => {
    if (!definition && node.type.name === "footnoteDefinition" && node.attrs.label === "mask") {
      definition = { node, position };
    }
  });
  if (!definition) throw new Error("mask footnote definition was not parsed");
  editor.commands.insertContentAt(
    definition.position + definition.node.nodeSize - 1,
    " updated"
  );

  setTimeout(() => {
    const document = dom.window.document;
    const references = [...document.querySelectorAll("[data-footnote-reference='mask']")];
    const maskDefinition = document.querySelector("[data-footnote-definition='mask']");
    const otherDefinition = document.querySelector("[data-footnote-definition='other']");
    const result = {
      referenceNumbers: references.map((reference) => reference.querySelector("a")?.textContent),
      referenceIDs: references.map((reference) => reference.id),
      maskNumber: maskDefinition?.querySelector(".footnote-number")?.textContent,
      otherNumber: otherDefinition?.querySelector(".footnote-number")?.textContent,
      maskBacklink: maskDefinition?.querySelector(".footnote-backlink")?.getAttribute("href"),
      markdown: api.getState().markdown
    };
    process.stdout.write(`${JSON.stringify(result)}\n`);
    api.destroy();
    dom.window.close();
    process.exit(0);
  }, 30);
}, 30);
