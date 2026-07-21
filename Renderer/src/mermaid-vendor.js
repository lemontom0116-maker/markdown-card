import mermaid from "mermaid";

// This entry point is built as a separate classic IIFE. Keeping the API on the
// page global lets the main renderer load it lazily with a CSP-safe local
// <script>, which is more reliable for WKWebView file URLs than module chunks.
globalThis.__markdownCardMermaidVendor = mermaid;
