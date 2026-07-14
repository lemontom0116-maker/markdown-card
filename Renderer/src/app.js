import { Editor } from "@tiptap/core";
import { TextSelection } from "@tiptap/pm/state";
import { createEditorExtensions, isExternalURL, protectUnsafeMarkdown } from "./markdown.js";

const VALID_APPEARANCES = new Set(["light", "dark", "system"]);
const MAXIMUM_CLIPBOARD_IMAGE_SIZE = 16 * 1024 * 1024;
const LOCAL_ATTACHMENT_PATTERN = /^attachments\/([A-Fa-f0-9-]{36})\.png$/;

function cloneEditorDocument(editor) {
  return JSON.parse(JSON.stringify(editor.getJSON()));
}

function managedAttachmentIDs(document) {
  const identifiers = new Set();
  const visit = (node) => {
    if (!node || typeof node !== "object") return;
    const source = String(node.attrs?.src ?? "");
    const attachmentID = node.type === "blockedImage"
      ? source.match(LOCAL_ATTACHMENT_PATTERN)?.[1]
      : null;
    if (attachmentID) identifiers.add(attachmentID.toLowerCase());
    if (Array.isArray(node.content)) node.content.forEach(visit);
  };
  visit(document);
  return [...identifiers];
}

function normalizedAttachmentBaseURL(value) {
  try {
    const url = new URL(String(value ?? ""));
    if (url.protocol !== "file:") return null;
    url.search = "";
    url.hash = "";
    if (!url.pathname.endsWith("/")) url.pathname += "/";
    return url.href;
  } catch {
    return null;
  }
}

function markdownForCopy(editor, attachmentBaseURL) {
  const baseURL = normalizedAttachmentBaseURL(attachmentBaseURL);
  if (!baseURL) throw new Error("A valid local attachment directory is required");
  const document = cloneEditorDocument(editor);

  const rewrite = (node) => {
    if (!node || typeof node !== "object") return;
    const source = String(node.attrs?.src ?? "");
    const attachmentID = node.type === "blockedImage"
      ? source.match(LOCAL_ATTACHMENT_PATTERN)?.[1]
      : null;
    if (attachmentID) {
      node.attrs = {
        ...node.attrs,
        src: new URL(`${attachmentID.toLowerCase()}.png`, baseURL).href
      };
    }
    if (Array.isArray(node.content)) node.content.forEach(rewrite);
  };

  rewrite(document);
  return editor.storage.markdown.manager.serialize(document);
}

function markdownExportBundle(editor) {
  const document = cloneEditorDocument(editor);
  return {
    markdown: editor.storage.markdown.manager.serialize(document),
    attachmentIDs: managedAttachmentIDs(document)
  };
}

function resolveSystemAppearance(window) {
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function postNative(window, message) {
  const handler = window.webkit?.messageHandlers?.markdownCard;
  if (typeof handler?.postMessage === "function") {
    handler.postMessage(message);
    return true;
  }

  window.dispatchEvent(new window.CustomEvent("markdowncard:native-message", { detail: message }));
  return false;
}

function clampSelection(editor, selection) {
  const max = Math.max(1, editor.state.doc.content.size);
  const from = Math.max(1, Math.min(Number(selection?.from ?? max), max));
  const to = Math.max(from, Math.min(Number(selection?.to ?? from), max));
  return { from, to };
}

export function installMarkdownCard(window, document) {
  const renderer = document.getElementById("renderer");
  if (!renderer) throw new Error("Markdown Card renderer root is missing");

  const systemQuery = window.matchMedia?.("(prefers-color-scheme: dark)");
  let requestedAppearance = VALID_APPEARANCES.has(document.documentElement.dataset.theme)
    ? document.documentElement.dataset.theme
    : "system";
  let resolvedAppearance = requestedAppearance === "system"
    ? resolveSystemAppearance(window)
    : requestedAppearance;
  let currentCardID = null;
  let currentRevision = 0;
  let markdown = "";
  let title = "Untitled";
  let applyingNativeDocument = false;
  let lastSelection = null;
  let lastSerializationMs = 0;
  let heightFrame = null;
  let lastReportedHeight = null;
  let lastHeightCardID = null;
  let lastAttachmentCardID = null;
  let lastAttachmentSignature = null;
  const pendingImagePastes = new Map();

  const requestLocalImagePaste = (file) => {
    if (!currentCardID || !file || !String(file.type).startsWith("image/")) return false;
    if (Number(file.size ?? 0) > MAXIMUM_CLIPBOARD_IMAGE_SIZE) return true;

    const requestID = window.crypto?.randomUUID?.()
      ?? `paste-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const requestCardID = currentCardID;
    pendingImagePastes.set(requestID, { cardID: requestCardID });

    const reader = new window.FileReader();
    reader.addEventListener("load", () => {
      const result = String(reader.result ?? "");
      const separator = result.indexOf(",");
      if (separator < 0) {
        pendingImagePastes.delete(requestID);
        return;
      }
      postNative(window, {
        type: "localImagePasteRequested",
        requestID,
        cardID: requestCardID,
        mimeType: file.type || "image/png",
        base64: result.slice(separator + 1),
        alt: file.name ? String(file.name).replace(/\.[^.]+$/, "") : "Pasted image"
      });
    });
    reader.addEventListener("error", () => pendingImagePastes.delete(requestID));
    reader.readAsDataURL(file);
    return true;
  };

  const measureContentHeight = () => {
    if (!currentCardID) return null;
    const style = window.getComputedStyle?.(renderer);
    const paddingTop = Number.parseFloat(style?.paddingTop ?? "0") || 0;
    const paddingBottom = Number.parseFloat(style?.paddingBottom ?? "0") || 0;
    const canvas = renderer.querySelector(".ProseMirror");
    const canvasHeight = Math.max(
      Number(canvas?.scrollHeight ?? 0),
      Number(canvas?.getBoundingClientRect?.().height ?? 0)
    );
    const height = Math.max(1, Math.ceil(canvasHeight + paddingTop + paddingBottom));
    if (lastHeightCardID !== currentCardID || lastReportedHeight == null
        || Math.abs(height - lastReportedHeight) >= 1) {
      lastHeightCardID = currentCardID;
      lastReportedHeight = height;
      postNative(window, {
        type: "contentHeightChanged",
        cardID: currentCardID,
        height
      });
    }
    return height;
  };

  const queueHeightMeasurement = () => {
    if (heightFrame != null) return;
    const requestFrame = window.requestAnimationFrame?.bind(window)
      ?? ((callback) => window.setTimeout(callback, 0));
    heightFrame = requestFrame(() => {
      heightFrame = null;
      measureContentHeight();
    });
  };

  const reportManagedAttachments = (force = false) => {
    if (!currentCardID) {
      lastAttachmentCardID = null;
      lastAttachmentSignature = null;
      return [];
    }
    const attachmentIDs = managedAttachmentIDs(editor.getJSON());
    const signature = attachmentIDs.join(":");
    if (force || lastAttachmentCardID !== currentCardID
        || lastAttachmentSignature !== signature) {
      lastAttachmentCardID = currentCardID;
      lastAttachmentSignature = signature;
      postNative(window, {
        type: "managedAttachmentsChanged",
        cardID: currentCardID,
        attachmentIDs
      });
    }
    return attachmentIDs;
  };

  const handlePluginExternal = (event) => {
    const url = String(event.detail?.url ?? "");
    if (!isExternalURL(url)) return;
    event.preventDefault();
    postNative(window, { type: "openExternalLink", url });
  };
  document.addEventListener("markdowncard:open-external", handlePluginExternal);

  const applyAppearance = (appearance) => {
    const requested = VALID_APPEARANCES.has(appearance) ? appearance : "dark";
    requestedAppearance = requested;
    resolvedAppearance = requested === "system" ? resolveSystemAppearance(window) : requested;

    document.documentElement.dataset.theme = resolvedAppearance;
    document.documentElement.style.colorScheme = resolvedAppearance;
    document.body.dataset.appearance = resolvedAppearance;
    queueHeightMeasurement();
    return resolvedAppearance;
  };

  const editor = new Editor({
    element: renderer,
    extensions: createEditorExtensions(),
    content: "",
    contentType: "markdown",
    autofocus: false,
    injectCSS: false,
    editorProps: {
      attributes: {
        class: "markdown-canvas",
        role: "textbox",
        "aria-label": "Markdown card editor",
        "aria-multiline": "true",
        spellcheck: "true"
      },
      handleDOMEvents: {
        mousedown: (_view, event) => {
          const link = event.target?.closest?.("a[href]");
          if (!link) return false;
          if (event.metaKey && isExternalURL(link.href)) {
            event.preventDefault();
            postNative(window, { type: "openExternalLink", url: link.href });
            return true;
          }
          return false;
        },
        click: (_view, event) => {
          const link = event.target?.closest?.("a[href]");
          if (!link) return false;
          event.preventDefault();
          if (event.metaKey && isExternalURL(link.href)) {
            postNative(window, { type: "openExternalLink", url: link.href });
          }
          return true;
        }
      },
      handlePaste: (_view, event) => {
        const imageItem = Array.from(event.clipboardData?.items ?? []).find(
          (item) => item.kind === "file" && String(item.type).startsWith("image/")
        );
        const file = imageItem?.getAsFile?.();
        if (!file) return false;
        event.preventDefault();
        return requestLocalImagePaste(file);
      }
    },
    onSelectionUpdate({ editor: currentEditor }) {
      lastSelection = {
        from: currentEditor.state.selection.from,
        to: currentEditor.state.selection.to
      };
    },
    onUpdate({ editor: currentEditor }) {
      if (applyingNativeDocument) return;
      const started = window.performance?.now?.() ?? Date.now();
      markdown = currentEditor.getMarkdown();
      const ended = window.performance?.now?.() ?? Date.now();
      lastSerializationMs = ended - started;
      currentRevision += 1;
      if (!currentCardID) return;
      postNative(window, {
        type: "markdownChanged",
        cardID: currentCardID,
        markdown,
        revision: currentRevision
      });
      reportManagedAttachments();
      queueHeightMeasurement();
    }
  });

  const contentObserver = typeof window.ResizeObserver === "function"
    ? new window.ResizeObserver(queueHeightMeasurement)
    : new window.MutationObserver(queueHeightMeasurement);
  if (typeof window.ResizeObserver === "function") {
    contentObserver.observe(editor.view.dom);
  } else {
    contentObserver.observe(editor.view.dom, { childList: true, subtree: true, characterData: true });
  }

  const replaceDocument = (nextMarkdown, preserveSelection) => {
    const savedSelection = preserveSelection
      ? (lastSelection ?? {
          from: editor.state.selection.from,
          to: editor.state.selection.to
        })
      : null;
    applyingNativeDocument = true;
    try {
      editor.commands.setContent(protectUnsafeMarkdown(nextMarkdown), {
        contentType: "markdown",
        emitUpdate: false
      });
      if (savedSelection) {
        const selection = clampSelection(editor, savedSelection);
        editor.view.dispatch(editor.state.tr.setSelection(
          TextSelection.create(editor.state.doc, selection.from, selection.to)
        ));
        lastSelection = selection;
      } else {
        lastSelection = null;
      }
    } finally {
      applyingNativeDocument = false;
    }
  };

  const render = (payload = {}) => {
    const nextCardID = payload.cardID == null ? null : String(payload.cardID);
    const nextRevision = Number(payload.revision ?? 0);
    const nextMarkdown = String(payload.markdown ?? "").replace(/\r\n?/g, "\n");
    const sameCard = nextCardID === currentCardID;
    const scrollTop = renderer.scrollTop;

    if (payload.resolvedAppearance) applyAppearance(payload.resolvedAppearance);
    title = String(payload.title ?? "Untitled");
    document.title = title || "Untitled";

    const stalePayload = sameCard && nextRevision < currentRevision;
    const shouldReplaceDocument = !sameCard
      || (!stalePayload && (nextMarkdown !== markdown || nextRevision > currentRevision));
    currentCardID = nextCardID;
    renderer.dataset.cardId = currentCardID ?? "";

    if (shouldReplaceDocument) {
      markdown = nextMarkdown;
      currentRevision = Math.max(0, nextRevision);
      replaceDocument(nextMarkdown, sameCard);
      renderer.scrollTop = sameCard ? scrollTop : 0;
    }
    reportManagedAttachments(!sameCard);
    queueHeightMeasurement();

    return {
      cardID: currentCardID,
      appearance: resolvedAppearance,
      empty: !markdown.trim(),
      revision: currentRevision
    };
  };

  const focusEditor = () => {
    if (lastSelection) {
      const selection = clampSelection(editor, lastSelection);
      editor.chain().focus(undefined, { scrollIntoView: false }).setTextSelection(selection).run();
    } else {
      editor.commands.focus("end", { scrollIntoView: false });
    }
    return true;
  };

  const setAppearance = (appearance) => applyAppearance(String(appearance ?? "dark").toLowerCase());

  const getMarkdownForCopy = (attachmentBaseURL) => markdownForCopy(editor, attachmentBaseURL);
  const getMarkdownExportBundle = () => markdownExportBundle(editor);

  const completeImagePaste = (payload = {}) => {
    const requestID = String(payload.requestID ?? "");
    const pending = pendingImagePastes.get(requestID);
    pendingImagePastes.delete(requestID);
    if (!pending || pending.cardID !== currentCardID) return false;
    const source = String(payload.source ?? "");
    if (payload.cardID !== currentCardID || !LOCAL_ATTACHMENT_PATTERN.test(source)) return false;

    const inserted = editor.chain().focus().insertContent({
      type: "blockedImage",
      attrs: {
        src: source,
        alt: String(payload.alt ?? "Pasted image").slice(0, 200) || "Pasted image",
        title: null
      }
    }).run();
    if (inserted) queueHeightMeasurement();
    return inserted;
  };

  applyAppearance(requestedAppearance);

  const onSystemAppearanceChange = () => {
    if (requestedAppearance === "system") applyAppearance("system");
  };
  systemQuery?.addEventListener?.("change", onSystemAppearanceChange);

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !event.defaultPrevented) {
      event.preventDefault();
      postNative(window, { type: "hideRequested", cardID: currentCardID });
    }
  });

  const api = {
    protocolVersion: 3,
    render,
    focusEditor,
    setAppearance,
    getMarkdownForCopy,
    getMarkdownExportBundle,
    completeImagePaste,
    measureContentHeight,
    getState() {
      return {
        cardID: currentCardID,
        requestedAppearance,
        resolvedAppearance,
        markdown,
        title,
        revision: currentRevision,
        selection: lastSelection,
        lastSerializationMs,
        editorJSON: editor.getJSON()
      };
    },
    getEditor() {
      return editor;
    },
    destroy() {
      systemQuery?.removeEventListener?.("change", onSystemAppearanceChange);
      document.removeEventListener("markdowncard:open-external", handlePluginExternal);
      contentObserver.disconnect();
      pendingImagePastes.clear();
      if (heightFrame != null) {
        const cancelFrame = window.cancelAnimationFrame?.bind(window)
          ?? window.clearTimeout?.bind(window);
        cancelFrame?.(heightFrame);
        heightFrame = null;
      }
      editor.destroy();
    }
  };

  window.MarkdownCard = api;
  window.markdownCard = api;
  postNative(window, { type: "rendererReady", protocolVersion: 3 });
  return api;
}
