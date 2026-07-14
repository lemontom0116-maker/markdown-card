import "katex/dist/katex.min.css";
import "./styles.css";
import { installMarkdownCard } from "./app.js";
import { previewMarkdown } from "./sample.js";

const api = installMarkdownCard(window, document);
const query = new URLSearchParams(window.location.search);

if (query.has("preview")) {
  api.render({
    cardID: "preview",
    title: "Monochrome Terminal",
    markdown: previewMarkdown,
    resolvedAppearance: query.get("theme") === "light" ? "light" : "dark",
    revision: 0
  });
}
