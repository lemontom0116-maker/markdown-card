import test from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { renderMermaidInto } from "../src/mermaid-renderer.js";

test("Mermaid vendor stays unloaded until first diagram and is shared by concurrent renders", async () => {
  const dom = new JSDOM(
    "<!doctype html><html><head></head><body><div id='one'></div><div id='two'></div></body></html>",
    { url: "file:///Applications/Markdown%20Card.app/Contents/Resources/Renderer/index.html" }
  );
  const { document } = dom.window;
  const appendedScripts = [];
  const originalAppend = document.head.append.bind(document.head);
  document.head.append = (...nodes) => {
    for (const node of nodes) {
      if (node.tagName !== "SCRIPT") continue;
      appendedScripts.push(node);
      dom.window.__markdownCardMermaidVendor = {
        initialize(options) {
          this.options = options;
        },
        async render(identifier, source) {
          return { svg: `<svg xmlns="http://www.w3.org/2000/svg" data-id="${identifier}"><text>${source}</text></svg>` };
        }
      };
      queueMicrotask(() => node.dispatchEvent(new dom.window.Event("load")));
    }
    return originalAppend(...nodes);
  };

  assert.equal(document.querySelector("script[data-markdown-card-vendor='mermaid']"), null);
  await Promise.all([
    renderMermaidInto(document.querySelector("#one"), "flowchart LR\nA --> B"),
    renderMermaidInto(document.querySelector("#two"), "sequenceDiagram\nA->>B: hello")
  ]);

  assert.equal(appendedScripts.length, 1, "one local vendor script serves all diagrams in the card");
  assert.equal(new URL(appendedScripts[0].src).protocol, "file:");
  assert.match(appendedScripts[0].src, /\/Renderer\/mermaid-vendor\.js$/u);
  assert.equal(dom.window.__markdownCardMermaidVendor.options.securityLevel, "strict");
  assert.equal(document.querySelectorAll("svg[role='img']").length, 2);
});

test("Injected test renderer bypasses the vendor script", async () => {
  const dom = new JSDOM("<!doctype html><html><head></head><body><div></div></body></html>");
  dom.window.__markdownCardMermaidRenderer = async () => ({
    svg: '<svg xmlns="http://www.w3.org/2000/svg"><text>fixture</text></svg>'
  });

  await renderMermaidInto(dom.window.document.querySelector("div"), "flowchart LR");

  assert.equal(dom.window.document.querySelector("script"), null);
  assert.equal(dom.window.document.querySelector("svg text").textContent, "fixture");
});
