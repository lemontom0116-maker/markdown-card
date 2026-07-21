import { Editor, getMarkRange } from "@tiptap/core";
import { EditorState, NodeSelection, TextSelection } from "@tiptap/pm/state";
import {
  createElement as createLucideElement,
  GripHorizontal,
  GripVertical,
  Plus
} from "lucide";
import {
  createEditorExtensions,
  insertSmartLinkFromPaste,
  isExternalURL,
  protectUnsafeMarkdown
} from "./markdown.js";
import { tagCommandFromTransaction } from "./plugins.js";
import {
  documentIsComposing,
  installCompositionGuard,
  isIMECompositionEvent
} from "./input-guards.js";
import { safeDocumentImagePath } from "./document-images.js";
import {
  sourceShortcutFromEvent,
  transformMarkdownSource
} from "./source-shortcuts.js";
import {
  headingForFragment,
  normalizeSafeLinkTarget,
  richDocumentOutline,
  richSearchMatches,
  sourceDocumentOutline,
  sourceSearchMatches
} from "./writing-tools.js";

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
  const removeCompositionGuard = installCompositionGuard(document, (isComposing) => {
    postNative(window, {
      type: "editorCompositionChanged",
      isComposing
    });
  });

  const sourceEditor = document.createElement("textarea");
  sourceEditor.className = "source-editor";
  sourceEditor.setAttribute("aria-label", "Markdown source editor");
  sourceEditor.setAttribute("aria-multiline", "true");
  sourceEditor.spellcheck = false;
  sourceEditor.hidden = true;
  document.body.appendChild(sourceEditor);

  const sourceModeChip = document.createElement("button");
  sourceModeChip.type = "button";
  sourceModeChip.className = "source-mode-chip";
  sourceModeChip.textContent = "Markdown Source · ⇧⌘M for Rich";
  sourceModeChip.setAttribute("aria-label", "Return to Rich editor");
  sourceModeChip.hidden = true;
  document.body.appendChild(sourceModeChip);

  const headingLinkStatus = document.createElement("div");
  headingLinkStatus.className = "heading-link-status";
  headingLinkStatus.setAttribute("role", "status");
  headingLinkStatus.setAttribute("aria-live", "polite");
  headingLinkStatus.hidden = true;
  document.body.appendChild(headingLinkStatus);
  let headingLinkStatusTimer = null;
  const handleHeadingLinkRepair = (event) => {
    const message = String(event.detail?.message ?? "").trim();
    if (!message) return;
    headingLinkStatus.dataset.kind = event.detail?.kind === "warning" ? "warning" : "repaired";
    headingLinkStatus.textContent = message;
    headingLinkStatus.hidden = false;
    if (headingLinkStatusTimer != null) window.clearTimeout(headingLinkStatusTimer);
    headingLinkStatusTimer = window.setTimeout(() => {
      headingLinkStatusTimer = null;
      headingLinkStatus.hidden = true;
    }, 5000);
  };
  document.addEventListener("markdowncard:heading-link-repair", handleHeadingLinkRepair);

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
  let editorMode = "rich";
  let documentImagesAvailable = false;
  let title = "Untitled";
  let applyingNativeDocument = false;
  let lastSelection = null;
  let sourceSelection = { start: 0, end: 0 };
  let lastSerializationMs = 0;
  let serializationCount = 0;
  let pendingMarkdownPost = false;
  let serializationTimer = null;
  let sourceComposing = false;
  let sourceProjectionDirty = false;
  const sourceTransformUndoStack = [];
  const sourceTransformRedoStack = [];
  let heightFrame = null;
  let lastReportedHeight = null;
  let lastHeightCardID = null;
  let lastAttachmentCardID = null;
  let lastAttachmentSignature = null;
  let lastAttachmentIDs = [];
  let managedAttachmentsDirty = false;
  let attachmentScanCount = 0;
  let refreshFindPresentation = () => {};
  let refreshOutlinePresentation = () => {};
  let refreshContextualControls = () => {};
  let hideTableControls = () => {};
  let pasteTSV = () => false;
  let handleRichLinkMouseDown = () => false;
  let handleRichLinkMouseMove = () => false;
  let handleRichLinkMouseUp = () => false;
  let handleRichLinkClick = () => false;
  const pendingImagePastes = new Map();

  const requestLocalImagePaste = (file, insertionPosition = null) => {
    if (!currentCardID || !file || !String(file.type).startsWith("image/")) return false;
    if (Number(file.size ?? 0) > MAXIMUM_CLIPBOARD_IMAGE_SIZE) return true;

    const requestID = window.crypto?.randomUUID?.()
      ?? `paste-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const requestCardID = currentCardID;
    pendingImagePastes.set(requestID, {
      cardID: requestCardID,
      position: Number.isInteger(insertionPosition)
        ? insertionPosition
        : editor.state.selection.from
    });

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
    const style = window.getComputedStyle?.(
      editorMode === "source" ? sourceEditor : renderer
    );
    const paddingTop = Number.parseFloat(style?.paddingTop ?? "0") || 0;
    const paddingBottom = Number.parseFloat(style?.paddingBottom ?? "0") || 0;
    const canvas = editorMode === "source"
      ? sourceEditor
      : renderer.querySelector(".ProseMirror");
    const canvasHeight = Math.max(
      Number(canvas?.scrollHeight ?? 0),
      Number(canvas?.getBoundingClientRect?.().height ?? 0)
    );
    const contentHeight = editorMode === "source"
      ? canvasHeight
      : canvasHeight + paddingTop + paddingBottom;
    let overlayHeight = 0;
    for (const overlay of document.querySelectorAll(".markdown-card-overlay:not([hidden])")) {
      const overlayRect = overlay.getBoundingClientRect?.();
      const rendererRect = renderer.getBoundingClientRect?.();
      const overlayTop = Number.parseFloat(overlay.style.top)
        || Number(overlayRect?.top ?? 0);
      const measuredOverlayHeight = Number(overlayRect?.height ?? 0) || 44;
      const rendererTop = Number(rendererRect?.top ?? 0);
      overlayHeight = Math.max(
        overlayHeight,
        overlayTop + measuredOverlayHeight - rendererTop + 12
      );
    }
    const height = Math.max(1, Math.ceil(contentHeight), Math.ceil(overlayHeight));
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
      lastAttachmentIDs = [];
      managedAttachmentsDirty = false;
      return [];
    }
    if (!force && !managedAttachmentsDirty && lastAttachmentCardID === currentCardID) {
      return lastAttachmentIDs;
    }
    const attachmentIDs = managedAttachmentIDs(editor.getJSON());
    attachmentScanCount += 1;
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
    lastAttachmentIDs = attachmentIDs;
    managedAttachmentsDirty = false;
    return attachmentIDs;
  };

  const handlePluginExternal = (event) => {
    const url = String(event.detail?.url ?? "");
    if (!isExternalURL(url)) return;
    event.preventDefault();
    postNative(window, { type: "openExternalLink", url });
  };
  document.addEventListener("markdowncard:open-external", handlePluginExternal);

  const handleSlashCommandMenuChange = (event) => {
    if (window.__markdownCardNativeCapabilities?.slashCommandPanel !== true) return;
    const presentation = event.detail;
    if (!presentation || typeof presentation.visible !== "boolean") return;
    if (postNative(window, {
      ...presentation,
      type: "slashCommandMenuChanged",
      cardID: currentCardID
    })) {
      event.preventDefault();
    }
  };
  document.addEventListener(
    "markdowncard:slash-menu-change",
    handleSlashCommandMenuChange
  );

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

  const cancelSerializationTimer = () => {
    if (serializationTimer == null) return;
    window.clearTimeout(serializationTimer);
    serializationTimer = null;
  };

  const serializeRichMarkdown = () => {
    const started = window.performance?.now?.() ?? Date.now();
    markdown = editor.getMarkdown();
    const ended = window.performance?.now?.() ?? Date.now();
    lastSerializationMs = ended - started;
    serializationCount += 1;
    return markdown;
  };

  const postPendingMarkdown = () => {
    if (!pendingMarkdownPost || !currentCardID) return false;
    pendingMarkdownPost = false;
    postNative(window, {
      type: "markdownChanged",
      cardID: currentCardID,
      markdown,
      revision: currentRevision
    });
    return true;
  };

  const flushMarkdownChanges = () => {
    cancelSerializationTimer();
    if (editorMode === "source") {
      // Browsers normalize textarea line endings. Keep the native payload byte-for-byte
      // until the user actually changes Source text, so merely toggling modes is lossless.
      if (sourceProjectionDirty) markdown = sourceEditor.value;
      if (managedAttachmentsDirty && sourceProjectionDirty) synchronizeSourceProjection();
    } else if (pendingMarkdownPost) {
      serializeRichMarkdown();
    }
    reportManagedAttachments();
    postPendingMarkdown();
    return markdown;
  };

  const scheduleMarkdownFlush = () => {
    if (serializationTimer != null || sourceComposing) return;
    serializationTimer = window.setTimeout(() => {
      serializationTimer = null;
      flushMarkdownChanges();
    }, 90);
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
        mousedown: (view, event) => handleRichLinkMouseDown(view, event),
        mousemove: (view, event) => handleRichLinkMouseMove(view, event),
        mouseup: (view, event) => handleRichLinkMouseUp(view, event),
        click: (view, event) => handleRichLinkClick(view, event)
      },
      handlePaste: (_view, event) => {
        const imageItem = Array.from(event.clipboardData?.items ?? []).find(
          (item) => item.kind === "file" && String(item.type).startsWith("image/")
        );
        const file = imageItem?.getAsFile?.();
        if (file) {
          event.preventDefault();
          return requestLocalImagePaste(file);
        }
        const plainText = event.clipboardData?.getData?.("text/plain") ?? "";
        if (plainText.includes("\t") && pasteTSV(plainText)) {
          event.preventDefault();
          return true;
        }
        if (insertSmartLinkFromPaste(_view, plainText)) {
          event.preventDefault();
          return true;
        }
        return false;
      },
      handleDrop: (view, event, moved) => {
        if (moved || documentIsComposing(document)) return false;
        const file = Array.from(event.dataTransfer?.files ?? []).find(
          (candidate) => String(candidate.type).startsWith("image/")
        );
        if (!file) return false;
        const coordinates = view.posAtCoords?.({ left: event.clientX, top: event.clientY });
        const position = Number.isInteger(coordinates?.pos)
          ? coordinates.pos
          : view.state.selection.from;
        event.preventDefault();
        return requestLocalImagePaste(file, position);
      }
    },
    onSelectionUpdate({ editor: currentEditor }) {
      lastSelection = {
        from: currentEditor.state.selection.from,
        to: currentEditor.state.selection.to
      };
      refreshContextualControls();
    },
    onUpdate({ editor: currentEditor, transaction }) {
      if (applyingNativeDocument) return;
      currentRevision += 1;
      if (!currentCardID) return;
      managedAttachmentsDirty = true;
      const tagCommand = tagCommandFromTransaction(transaction);
      if (tagCommand) {
        cancelSerializationTimer();
        serializeRichMarkdown();
        pendingMarkdownPost = false;
        reportManagedAttachments();
        postNative(window, {
          type: "tagCommandSubmitted",
          cardID: currentCardID,
          tagName: tagCommand.tagName,
          markdown,
          revision: currentRevision
        });
      } else {
        pendingMarkdownPost = true;
        if (transaction.getMeta("markdownCardImmediate") === true) {
          flushMarkdownChanges();
        } else {
          scheduleMarkdownFlush();
        }
      }
      queueHeightMeasurement();
      refreshFindPresentation();
      refreshOutlinePresentation();
      refreshContextualControls();
    }
  });

  const linkEditor = document.createElement("form");
  linkEditor.className = "link-editor-popover markdown-card-overlay";
  linkEditor.setAttribute("role", "dialog");
  linkEditor.setAttribute("aria-label", "Edit link");
  linkEditor.hidden = true;

  const linkEditorHeading = document.createElement("strong");
  linkEditorHeading.className = "link-editor-heading";
  const makeLinkField = (label, name) => {
    const field = document.createElement("label");
    field.className = "link-editor-field";
    const caption = document.createElement("span");
    caption.textContent = label;
    const input = document.createElement("input");
    input.name = name;
    input.type = "text";
    input.autocomplete = "off";
    input.spellcheck = false;
    field.append(caption, input);
    return { field, input };
  };
  const { field: linkTextField, input: linkTextInput } = makeLinkField("Text", "text");
  const { field: linkURLField, input: linkURLInput } = makeLinkField("Link", "url");
  linkURLInput.inputMode = "url";
  linkURLInput.placeholder = "https://example.com";

  const linkEditorError = document.createElement("div");
  linkEditorError.className = "link-editor-error";
  linkEditorError.id = "markdown-card-link-error";
  linkEditorError.setAttribute("role", "alert");
  linkEditorError.hidden = true;
  linkURLInput.setAttribute("aria-describedby", linkEditorError.id);

  const linkEditorActions = document.createElement("div");
  linkEditorActions.className = "link-editor-actions";
  const removeLinkButton = document.createElement("button");
  removeLinkButton.type = "button";
  removeLinkButton.className = "link-editor-remove";
  removeLinkButton.textContent = "Remove";
  const linkEditorSpacer = document.createElement("span");
  linkEditorSpacer.className = "link-editor-spacer";
  const cancelLinkButton = document.createElement("button");
  cancelLinkButton.type = "button";
  cancelLinkButton.textContent = "Cancel";
  const applyLinkButton = document.createElement("button");
  applyLinkButton.type = "submit";
  applyLinkButton.className = "is-primary";
  applyLinkButton.textContent = "Apply";
  linkEditorActions.append(
    removeLinkButton,
    linkEditorSpacer,
    cancelLinkButton,
    applyLinkButton
  );
  linkEditor.append(
    linkEditorHeading,
    linkTextField,
    linkURLField,
    linkEditorError,
    linkEditorActions
  );
  document.body.appendChild(linkEditor);

  const LINK_HOVER_DELAY_MS = 1000;
  const LINK_HOVER_GRACE_MS = 180;
  const LINK_DRAG_THRESHOLD = 4;
  let linkEditorSession = null;
  let linkEditorDirty = false;
  let linkHoverTimer = null;
  let linkEditorCloseTimer = null;
  let hoveredLink = null;
  let linkPointerGesture = null;
  let pendingKeyboardLinkActivation = null;

  const normalizeLinkEditorURL = normalizeSafeLinkTarget;

  const linkFromEvent = (event) => {
    const link = event.target?.closest?.("a[href]") ?? null;
    return link && editor.view.dom.contains(link) ? link : null;
  };

  const containsEventTarget = (element, candidate) => Boolean(
    element && candidate?.nodeType && element.contains(candidate)
  );

  const cancelLinkHoverTimer = () => {
    if (linkHoverTimer == null) return;
    window.clearTimeout(linkHoverTimer);
    linkHoverTimer = null;
  };

  const cancelLinkEditorCloseTimer = () => {
    if (linkEditorCloseTimer == null) return;
    window.clearTimeout(linkEditorCloseTimer);
    linkEditorCloseTimer = null;
  };

  const cancelLinkHoverLifecycle = () => {
    cancelLinkHoverTimer();
    cancelLinkEditorCloseTimer();
    hoveredLink = null;
  };

  const normalizedComparableLinkTarget = (value) => (
    normalizeSafeLinkTarget(value) ?? String(value ?? "").trim()
  );

  const linkMarkAtRange = (from, to) => {
    const linkType = editor.state.schema.marks.link;
    let found = null;
    editor.state.doc.nodesBetween(from, to, (node) => {
      if (found || !node.isText) return;
      found = linkType.isInSet(node.marks) ?? null;
    });
    return found;
  };

  const linkRangeNearPosition = (position, expectedHref = null) => {
    const { doc, schema } = editor.state;
    const linkType = schema.marks.link;
    const maximum = doc.content.size;
    const expected = normalizedComparableLinkTarget(expectedHref);
    for (const offset of [0, 1, -1]) {
      const candidate = Math.max(0, Math.min(maximum, Number(position) + offset));
      let range = null;
      try {
        range = getMarkRange(doc.resolve(candidate), linkType);
      } catch {
        range = null;
      }
      if (!range) continue;
      const mark = linkMarkAtRange(range.from, range.to);
      if (!mark) continue;
      if (expectedHref != null
          && normalizedComparableLinkTarget(mark.attrs?.href) !== expected) continue;
      return { ...range, mark };
    }
    return null;
  };

  const linkContextFromDOM = (anchor) => {
    if (!anchor || !editor.view.dom.contains(anchor)) return null;
    const expectedHref = anchor.getAttribute("href") ?? "";
    const positions = [];
    const addDOMPosition = (node, offset) => {
      try {
        const position = editor.view.posAtDOM(node, offset);
        if (Number.isInteger(position)) positions.push(position);
      } catch {
        // Decorative smart-link nodes are intentionally outside the document model.
      }
    };
    const collectTextPositions = (node) => {
      if (node?.nodeType === 3) {
        addDOMPosition(node, 0);
        addDOMPosition(node, String(node.nodeValue ?? "").length);
        return;
      }
      for (const child of node?.childNodes ?? []) collectTextPositions(child);
    };
    const contentRoot = anchor.querySelector?.(".smart-link-title") ?? anchor;
    collectTextPositions(contentRoot);
    addDOMPosition(anchor, 0);
    addDOMPosition(anchor, anchor.childNodes?.length ?? 0);

    for (const position of positions) {
      const range = linkRangeNearPosition(position, expectedHref);
      if (!range) continue;
      return {
        from: range.from,
        to: range.to,
        existing: true,
        text: editor.state.doc.textBetween(range.from, range.to, ""),
        href: String(range.mark.attrs?.href ?? expectedHref),
        anchor
      };
    }

    // `posAtDOM` can be unavailable for a freshly-updated custom mark view.
    // Fall back to the matching document mark nearest the anchor's best DOM position.
    const expected = normalizedComparableLinkTarget(expectedHref);
    const fallbackRanges = [];
    editor.state.doc.descendants((node, position) => {
      if (!node.isText) return;
      const mark = editor.state.schema.marks.link.isInSet(node.marks);
      if (!mark || normalizedComparableLinkTarget(mark.attrs?.href) !== expected) return;
      const range = linkRangeNearPosition(position + 1, expectedHref);
      if (range && !fallbackRanges.some((item) => item.from === range.from && item.to === range.to)) {
        fallbackRanges.push(range);
      }
    });
    const range = fallbackRanges[0];
    return range ? {
      from: range.from,
      to: range.to,
      existing: true,
      text: editor.state.doc.textBetween(range.from, range.to, ""),
      href: String(range.mark.attrs?.href ?? expectedHref),
      anchor
    } : null;
  };

  const linkContext = () => {
    const { state } = editor;
    const { selection } = state;
    if (selection.$from.parent !== selection.$to.parent || !selection.$from.parent.inlineContent) {
      return null;
    }
    const linkType = state.schema.marks.link;
    const existingRange = getMarkRange(selection.$from, linkType);
    const from = existingRange?.from ?? selection.from;
    const to = existingRange?.to ?? selection.to;
    const mark = existingRange ? linkMarkAtRange(existingRange.from, existingRange.to) : null;
    return {
      from,
      to,
      existing: Boolean(existingRange),
      text: state.doc.textBetween(from, to, ""),
      href: existingRange
        ? String(mark?.attrs?.href ?? editor.getAttributes("link").href ?? "")
        : "",
      anchor: null
    };
  };

  const positionLinkEditor = (sessionOrPosition) => {
    const session = typeof sessionOrPosition === "object"
      ? sessionOrPosition
      : linkEditorSession;
    const position = typeof sessionOrPosition === "number"
      ? sessionOrPosition
      : session?.from;
    let coordinates;
    const anchorRect = session?.anchor?.isConnected !== false
      ? session?.anchor?.getBoundingClientRect?.()
      : null;
    if (anchorRect && (anchorRect.width > 0 || anchorRect.height > 0)) {
      coordinates = {
        left: anchorRect.left,
        top: anchorRect.top,
        bottom: anchorRect.bottom
      };
    } else {
      try {
        coordinates = editor.view.coordsAtPos(position);
      } catch {
        coordinates = { left: 24, top: 48, bottom: 66 };
      }
    }
    const width = Math.max(300, linkEditor.getBoundingClientRect?.().width || 336);
    const height = Math.max(180, linkEditor.getBoundingClientRect?.().height || 214);
    const viewportWidth = Number(window.innerWidth || document.documentElement.clientWidth || 720);
    const viewportHeight = Number(window.innerHeight || document.documentElement.clientHeight || 480);
    const left = Math.min(Math.max(12, coordinates.left), Math.max(12, viewportWidth - width - 12));
    const preferredTop = coordinates.bottom + 8;
    const top = preferredTop + height <= viewportHeight - 12
      ? preferredTop
      : Math.max(12, coordinates.top - height - 8);
    linkEditor.style.left = `${left}px`;
    linkEditor.style.top = `${top}px`;
  };

  const showLinkEditorError = (message) => {
    linkEditorError.textContent = message;
    linkEditorError.hidden = false;
    linkURLInput.setAttribute("aria-invalid", "true");
    if (linkEditorSession) positionLinkEditor(linkEditorSession);
    queueHeightMeasurement();
    linkURLInput.focus();
  };

  const closeLinkEditor = ({ restoreSelection } = {}) => {
    const session = linkEditorSession;
    const shouldRestoreSelection = restoreSelection ?? session?.restoreSelection ?? false;
    cancelLinkHoverLifecycle();
    linkEditor.hidden = true;
    delete linkEditor.dataset.openedBy;
    linkEditorError.hidden = true;
    linkEditorError.textContent = "";
    linkURLInput.removeAttribute("aria-invalid");
    linkEditorSession = null;
    linkEditorDirty = false;
    queueHeightMeasurement();
    if (!shouldRestoreSelection || !session) return;
    const maximum = editor.state.doc.content.size;
    const from = Math.max(1, Math.min(session.from, maximum));
    const to = Math.max(from, Math.min(session.to, maximum));
    editor.chain().focus(undefined, { scrollIntoView: false }).setTextSelection({ from, to }).run();
  };

  const otherContextualOverlayIsVisible = () => (
    [...document.querySelectorAll(".markdown-card-overlay:not([hidden])")]
      .some((overlay) => overlay !== linkEditor)
    || Boolean(document.querySelector(".table-edge-controls:not([hidden])"))
  );

  const openLinkEditor = ({
    context = linkContext(),
    focus = true,
    openedBy = "command"
  } = {}) => {
    if (!context) return false;
    if (editorMode !== "rich" || documentIsComposing(document)) return false;
    if (!focus && otherContextualOverlayIsVisible()) return false;
    if (focus) {
      closeFind({ restoreFocus: false });
      closeOutline({ restoreFocus: false });
      closeImageEditor({ restoreSelection: false });
      hideTableControls();
    }
    cancelLinkHoverTimer();
    cancelLinkEditorCloseTimer();
    linkEditorSession = {
      ...context,
      restoreSelection: focus,
      openedBy,
      initialText: context.text,
      initialHref: context.href
    };
    linkEditorDirty = false;
    linkEditorHeading.textContent = context.existing ? "Edit link" : "Add link";
    linkEditor.setAttribute("aria-label", linkEditorHeading.textContent);
    linkEditor.dataset.openedBy = openedBy;
    linkTextInput.value = context.text;
    linkURLInput.value = context.href;
    removeLinkButton.hidden = !context.existing;
    linkEditorError.hidden = true;
    linkURLInput.removeAttribute("aria-invalid");
    linkEditor.hidden = false;
    positionLinkEditor(linkEditorSession);
    queueHeightMeasurement();
    if (!focus) return true;
    if (context.text || context.existing) {
      linkURLInput.focus();
      linkURLInput.select();
    } else {
      linkTextInput.focus();
    }
    return true;
  };

  const replaceLinkRange = (text, href) => {
    const session = linkEditorSession;
    if (!session) return false;
    const linkType = editor.state.schema.marks.link;
    const replacement = text
      ? editor.state.schema.text(text, href ? [linkType.create({ href })] : [])
      : null;
    const transaction = replacement
      ? editor.state.tr.replaceWith(session.from, session.to, replacement)
      : editor.state.tr.delete(session.from, session.to);
    const caret = Math.min(transaction.doc.content.size, session.from + text.length);
    transaction.setSelection(TextSelection.near(transaction.doc.resolve(caret)));
    editor.view.dispatch(transaction.scrollIntoView());
    closeLinkEditor({ restoreSelection: false });
    editor.commands.focus(undefined, { scrollIntoView: false });
    return true;
  };

  const handleLinkEditorRequest = (event) => {
    if (!openLinkEditor({ focus: true, openedBy: "command" })) return;
    event.preventDefault();
  };
  document.addEventListener("markdowncard:edit-link", handleLinkEditorRequest);

  linkEditor.addEventListener("submit", (event) => {
    event.preventDefault();
    if (documentIsComposing(document)) return;
    const href = normalizeLinkEditorURL(linkURLInput.value);
    if (!href) {
      showLinkEditorError("Enter http, https, email, #fragment, or a safe ./ path inside this document folder.");
      return;
    }
    const text = linkTextInput.value || linkURLInput.value.trim();
    replaceLinkRange(text, href);
  });
  linkEditor.addEventListener("keydown", (event) => {
    if (isIMECompositionEvent(event)) return;
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      closeLinkEditor();
      return;
    }
    if (
      event.key === "Enter"
      && !event.altKey
      && !event.ctrlKey
      && !event.metaKey
      && !event.shiftKey
    ) {
      event.preventDefault();
      event.stopPropagation();
      if (typeof linkEditor.requestSubmit === "function") {
        linkEditor.requestSubmit(applyLinkButton);
      } else {
        linkEditor.dispatchEvent(new window.Event("submit", {
          bubbles: true,
          cancelable: true
        }));
      }
    }
  });
  removeLinkButton.addEventListener("click", () => {
    const text = linkTextInput.value || linkEditorSession?.text || "";
    replaceLinkRange(text, null);
  });
  cancelLinkButton.addEventListener("click", () => closeLinkEditor());

  const refreshLinkEditorDirtyState = () => {
    if (!linkEditorSession) {
      linkEditorDirty = false;
      return;
    }
    linkEditorDirty = linkTextInput.value !== linkEditorSession.initialText
      || linkURLInput.value !== linkEditorSession.initialHref;
  };
  linkTextInput.addEventListener("input", refreshLinkEditorDirtyState);
  linkURLInput.addEventListener("input", refreshLinkEditorDirtyState);

  const scheduleLinkEditorAutoClose = () => {
    cancelLinkEditorCloseTimer();
    if (linkEditor.hidden || linkEditorSession?.openedBy !== "hover") return;
    linkEditorCloseTimer = window.setTimeout(() => {
      linkEditorCloseTimer = null;
      if (linkEditor.hidden || linkEditorSession?.openedBy !== "hover") return;
      if (linkEditorDirty || linkEditor.contains(document.activeElement)) return;
      closeLinkEditor({ restoreSelection: false });
    }, LINK_HOVER_GRACE_MS);
  };

  linkEditor.addEventListener("mouseenter", cancelLinkEditorCloseTimer);
  linkEditor.addEventListener("mouseleave", (event) => {
    if (containsEventTarget(linkEditorSession?.anchor, event.relatedTarget)) {
      cancelLinkEditorCloseTimer();
      return;
    }
    scheduleLinkEditorAutoClose();
  });
  linkEditor.addEventListener("focusin", cancelLinkEditorCloseTimer);

  const handleLinkEditorOutsideMouseDown = (event) => {
    if (linkEditor.hidden || linkEditor.contains(event.target)) return;
    closeLinkEditor();
  };
  document.addEventListener("mousedown", handleLinkEditorOutsideMouseDown, true);

  const externalTargetForAnchor = (anchor) => {
    const rawTarget = anchor?.getAttribute?.("href") ?? "";
    const normalized = normalizeSafeLinkTarget(rawTarget);
    return normalized && isExternalURL(normalized)
      ? normalized
      : (isExternalURL(anchor?.href) ? String(anchor.href) : null);
  };

  const openExternalLinkOnce = (anchor) => {
    const externalTarget = externalTargetForAnchor(anchor);
    if (!externalTarget) return false;
    postNative(window, { type: "openExternalLink", url: externalTarget });
    return true;
  };

  const linkGestureShouldOpen = (event, anchor) => {
    if (event.button !== 0 || event.ctrlKey || event.altKey || event.shiftKey) return false;
    const gesture = linkPointerGesture;
    if (!gesture || gesture.anchor !== anchor) return true;
    if (gesture.moved) return false;
    const selection = editor.state.selection;
    return selection.empty;
  };

  handleRichLinkMouseDown = (_view, event) => {
    const anchor = linkFromEvent(event);
    if (!anchor) {
      linkPointerGesture = null;
      return false;
    }
    cancelLinkHoverTimer();
    if (event.button !== 0 || event.ctrlKey || event.altKey || event.shiftKey) {
      linkPointerGesture = null;
      return false;
    }
    linkPointerGesture = {
      anchor,
      x: Number(event.clientX ?? 0),
      y: Number(event.clientY ?? 0),
      moved: false
    };
    return false;
  };

  handleRichLinkMouseMove = (_view, event) => {
    if (!linkPointerGesture) return false;
    const dx = Number(event.clientX ?? 0) - linkPointerGesture.x;
    const dy = Number(event.clientY ?? 0) - linkPointerGesture.y;
    if (Math.hypot(dx, dy) > LINK_DRAG_THRESHOLD) linkPointerGesture.moved = true;
    return false;
  };

  handleRichLinkMouseUp = (_view, event) => {
    if (!linkPointerGesture) return false;
    const dx = Number(event.clientX ?? 0) - linkPointerGesture.x;
    const dy = Number(event.clientY ?? 0) - linkPointerGesture.y;
    if (Math.hypot(dx, dy) > LINK_DRAG_THRESHOLD || !editor.state.selection.empty) {
      linkPointerGesture.moved = true;
    }
    return false;
  };

  handleRichLinkClick = (_view, event) => {
    const anchor = linkFromEvent(event);
    if (!anchor) {
      linkPointerGesture = null;
      return false;
    }
    cancelLinkHoverTimer();
    if (event.button !== 0 || event.ctrlKey || event.altKey || event.shiftKey) {
      linkPointerGesture = null;
      return false;
    }
    event.preventDefault();
    if (event.detail === 0
        && pendingKeyboardLinkActivation?.anchor === anchor
        && pendingKeyboardLinkActivation.expiresAt >= Date.now()) {
      pendingKeyboardLinkActivation = null;
      linkPointerGesture = null;
      return true;
    }
    pendingKeyboardLinkActivation = null;
    const shouldOpen = linkGestureShouldOpen(event, anchor);
    linkPointerGesture = null;
    if (!shouldOpen) return true;

    const target = anchor.getAttribute("href") ?? "";
    if (target.startsWith("#")) {
      const heading = headingForFragment(getOutline(), target);
      if (heading) {
        jumpToHeading(heading.position);
      } else {
        let identifier = "";
        try {
          identifier = decodeURIComponent(target.slice(1));
        } catch {
          identifier = "";
        }
        const fragmentTarget = identifier ? document.getElementById(identifier) : null;
        fragmentTarget?.scrollIntoView?.({ block: "center", behavior: "auto" });
        fragmentTarget?.querySelector?.("a, button, input, textarea")?.focus?.({ preventScroll: true });
      }
      return true;
    }
    const safeTarget = normalizeSafeLinkTarget(target);
    if (safeTarget && /^\.\//u.test(safeTarget)) {
      postNative(window, {
        type: "openDocumentLink",
        cardID: currentCardID,
        href: safeTarget
      });
      return true;
    }
    openExternalLinkOnce(anchor);
    return true;
  };

  const handleRichLinkMouseOver = (event) => {
    const anchor = linkFromEvent(event);
    if (!anchor || containsEventTarget(anchor, event.relatedTarget)) return;
    if (!externalTargetForAnchor(anchor)) return;
    if (editorMode !== "rich" || documentIsComposing(document)) return;
    hoveredLink = anchor;
    cancelLinkEditorCloseTimer();
    if (!linkEditor.hidden && linkEditorSession?.anchor === anchor) return;
    cancelLinkHoverTimer();
    linkHoverTimer = window.setTimeout(() => {
      linkHoverTimer = null;
      if (hoveredLink !== anchor || !anchor.isConnected) return;
      if (!linkEditor.hidden || editorMode !== "rich" || documentIsComposing(document)) return;
      const context = linkContextFromDOM(anchor);
      if (!context) return;
      openLinkEditor({ context, focus: false, openedBy: "hover" });
    }, LINK_HOVER_DELAY_MS);
  };

  const handleRichLinkMouseOut = (event) => {
    const anchor = linkFromEvent(event);
    if (!anchor || containsEventTarget(anchor, event.relatedTarget)) return;
    if (!externalTargetForAnchor(anchor)) return;
    if (hoveredLink === anchor) hoveredLink = null;
    cancelLinkHoverTimer();
    if (containsEventTarget(linkEditor, event.relatedTarget)) {
      cancelLinkEditorCloseTimer();
      return;
    }
    if (linkEditorSession?.anchor === anchor) scheduleLinkEditorAutoClose();
  };

  const handleLinkKeyboardActivation = (event) => {
    if (isIMECompositionEvent(event, editor.view)) return;
    if (event.key !== "Enter" && event.key !== " ") return;
    const anchor = linkFromEvent(event);
    if (!anchor || event.ctrlKey || event.altKey || event.shiftKey) return;
    if (!externalTargetForAnchor(anchor)) return;
    event.preventDefault();
    cancelLinkHoverTimer();
    if (openExternalLinkOnce(anchor)) {
      pendingKeyboardLinkActivation = {
        anchor,
        expiresAt: Date.now() + 250
      };
    }
  };

  const handleLinkCompositionStart = () => {
    cancelLinkHoverTimer();
    if (!linkEditor.hidden && linkEditorSession?.openedBy === "hover"
        && !linkEditorDirty && !linkEditor.contains(document.activeElement)) {
      closeLinkEditor({ restoreSelection: false });
    }
  };

  renderer.addEventListener("mouseover", handleRichLinkMouseOver);
  renderer.addEventListener("mouseout", handleRichLinkMouseOut);
  renderer.addEventListener("keydown", handleLinkKeyboardActivation);
  document.addEventListener("compositionstart", handleLinkCompositionStart, true);

  const recordSourceMutation = ({ preserveTransformHistory = false } = {}) => {
    if (!preserveTransformHistory) {
      sourceTransformUndoStack.length = 0;
      sourceTransformRedoStack.length = 0;
    }
    markdown = sourceEditor.value;
    sourceProjectionDirty = true;
    managedAttachmentsDirty = true;
    currentRevision += 1;
    pendingMarkdownPost = true;
    scheduleMarkdownFlush();
    queueHeightMeasurement();
    refreshFindPresentation();
    refreshOutlinePresentation();
  };

  const sourceSnapshot = () => ({
    value: sourceEditor.value,
    start: sourceEditor.selectionStart,
    end: sourceEditor.selectionEnd
  });

  const restoreSourceSnapshot = (snapshot) => {
    sourceEditor.value = snapshot.value;
    sourceEditor.setSelectionRange(snapshot.start, snapshot.end);
    sourceSelection = { start: snapshot.start, end: snapshot.end };
    recordSourceMutation({ preserveTransformHistory: true });
  };

  const applySourceShortcut = (shortcut) => {
    const before = sourceSnapshot();
    const transformed = transformMarkdownSource(
      before.value,
      before.start,
      before.end,
      shortcut
    );
    if (!transformed || (
      transformed.value === before.value
      && transformed.start === before.start
      && transformed.end === before.end
    )) return false;
    sourceTransformUndoStack.push(before);
    sourceTransformRedoStack.length = 0;
    restoreSourceSnapshot(transformed);
    return true;
  };

  const undoSourceTransform = (redo = false) => {
    const fromStack = redo ? sourceTransformRedoStack : sourceTransformUndoStack;
    const toStack = redo ? sourceTransformUndoStack : sourceTransformRedoStack;
    const snapshot = fromStack.pop();
    if (!snapshot) return false;
    toStack.push(sourceSnapshot());
    restoreSourceSnapshot(snapshot);
    return true;
  };

  sourceEditor.addEventListener("compositionstart", () => {
    sourceComposing = true;
    cancelSerializationTimer();
  });
  sourceEditor.addEventListener("compositionend", () => {
    sourceComposing = false;
    markdown = sourceEditor.value;
    scheduleMarkdownFlush();
  });
  sourceEditor.addEventListener("input", recordSourceMutation);
  sourceEditor.addEventListener("keydown", (event) => {
    if (sourceComposing || isIMECompositionEvent(event)) return;
    const key = String(event.key ?? "").toLowerCase();
    if (event.metaKey && !event.altKey && !event.ctrlKey && key === "z") {
      if (!undoSourceTransform(event.shiftKey)) return;
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    const shortcut = sourceShortcutFromEvent(event);
    if (!shortcut || !applySourceShortcut(shortcut)) return;
    event.preventDefault();
    event.stopPropagation();
  });
  sourceEditor.addEventListener("select", () => {
    sourceSelection = {
      start: sourceEditor.selectionStart,
      end: sourceEditor.selectionEnd
    };
  });

  const findPanel = document.createElement("section");
  findPanel.className = "find-panel markdown-card-overlay";
  findPanel.setAttribute("role", "search");
  findPanel.setAttribute("aria-label", "Find and replace");
  findPanel.hidden = true;
  const findRow = document.createElement("div");
  findRow.className = "find-row";
  const findInput = document.createElement("input");
  findInput.type = "search";
  findInput.name = "find";
  findInput.placeholder = "Find";
  findInput.autocomplete = "off";
  findInput.spellcheck = false;
  findInput.setAttribute("aria-label", "Find text");
  const findCount = document.createElement("span");
  findCount.className = "find-count";
  findCount.setAttribute("aria-live", "polite");
  const previousFindButton = document.createElement("button");
  previousFindButton.type = "button";
  previousFindButton.textContent = "↑";
  previousFindButton.setAttribute("aria-label", "Previous match");
  const nextFindButton = document.createElement("button");
  nextFindButton.type = "button";
  nextFindButton.textContent = "↓";
  nextFindButton.setAttribute("aria-label", "Next match");
  const closeFindButton = document.createElement("button");
  closeFindButton.type = "button";
  closeFindButton.textContent = "×";
  closeFindButton.setAttribute("aria-label", "Close find");
  findRow.append(
    findInput,
    findCount,
    previousFindButton,
    nextFindButton,
    closeFindButton
  );
  const replaceRow = document.createElement("div");
  replaceRow.className = "replace-row";
  const replaceInput = document.createElement("input");
  replaceInput.type = "text";
  replaceInput.name = "replace";
  replaceInput.placeholder = "Replace";
  replaceInput.autocomplete = "off";
  replaceInput.spellcheck = false;
  replaceInput.setAttribute("aria-label", "Replacement text");
  const replaceButton = document.createElement("button");
  replaceButton.type = "button";
  replaceButton.textContent = "Replace";
  const replaceAllButton = document.createElement("button");
  replaceAllButton.type = "button";
  replaceAllButton.textContent = "All";
  replaceAllButton.setAttribute("aria-label", "Replace all safe matches");
  replaceRow.append(replaceInput, replaceButton, replaceAllButton);
  findPanel.append(findRow, replaceRow);
  document.body.appendChild(findPanel);

  let findMatches = [];
  let findMatchIndex = -1;

  const activeSearchMatches = () => (
    editorMode === "source"
      ? sourceSearchMatches(sourceEditor.value, findInput.value)
      : richSearchMatches(editor.state.doc, findInput.value)
  );

  const activeSearchOffset = () => (
    editorMode === "source" ? sourceEditor.selectionStart : editor.state.selection.from
  );

  const revealFindMatch = (index) => {
    if (!findMatches.length) return false;
    findMatchIndex = ((index % findMatches.length) + findMatches.length) % findMatches.length;
    const match = findMatches[findMatchIndex];
    if (editorMode === "source") {
      sourceEditor.setSelectionRange(match.from, match.to);
      const linesBefore = sourceEditor.value.slice(0, match.from).split("\n").length - 1;
      const lineHeight = Number.parseFloat(window.getComputedStyle?.(sourceEditor)?.lineHeight) || 21;
      sourceEditor.scrollTop = Math.max(0, linesBefore * lineHeight - sourceEditor.clientHeight / 2);
    } else {
      editor.view.dispatch(
        editor.state.tr.setSelection(
          TextSelection.create(editor.state.doc, match.from, match.to)
        ).scrollIntoView()
      );
      lastSelection = { from: match.from, to: match.to };
    }
    findCount.textContent = `${findMatchIndex + 1} of ${findMatches.length}`;
    return true;
  };

  refreshFindPresentation = (chooseFromSelection = false) => {
    if (findPanel.hidden) return [];
    const previous = findMatches[findMatchIndex];
    findMatches = activeSearchMatches();
    previousFindButton.disabled = findMatches.length === 0;
    nextFindButton.disabled = findMatches.length === 0;
    replaceButton.disabled = findMatches.length === 0;
    replaceAllButton.disabled = findMatches.length === 0;
    if (!findMatches.length) {
      findMatchIndex = -1;
      findCount.textContent = findInput.value ? "No matches" : "";
      return findMatches;
    }
    let nextIndex = previous
      ? findMatches.findIndex((match) => match.from === previous.from && match.to === previous.to)
      : -1;
    if (chooseFromSelection || nextIndex < 0) {
      const offset = activeSearchOffset();
      nextIndex = findMatches.findIndex((match) => match.from >= offset);
      if (nextIndex < 0) nextIndex = 0;
    }
    revealFindMatch(nextIndex);
    return findMatches;
  };

  const closeFind = ({ restoreFocus = true } = {}) => {
    if (findPanel.hidden) return false;
    findPanel.hidden = true;
    queueHeightMeasurement();
    if (restoreFocus) {
      if (editorMode === "source") sourceEditor.focus({ preventScroll: true });
      else editor.commands.focus(undefined, { scrollIntoView: false });
    }
    return true;
  };

  const openFind = ({ showReplace = false } = {}) => {
    closeLinkEditor({ restoreSelection: false });
    closeOutline({ restoreFocus: false });
    closeImageEditor({ restoreSelection: false });
    hideTableControls();
    findPanel.hidden = false;
    replaceRow.hidden = !showReplace;
    findPanel.style.top = "12px";
    findPanel.style.right = "12px";
    findPanel.style.left = "auto";
    refreshFindPresentation(true);
    queueHeightMeasurement();
    (showReplace && findInput.value ? replaceInput : findInput).focus();
    if (!showReplace || !findInput.value) findInput.select();
    return true;
  };

  const moveFindMatch = (delta) => {
    if (!findMatches.length) refreshFindPresentation(true);
    return revealFindMatch(findMatchIndex + delta);
  };

  const replaceCurrentMatch = () => {
    if (!findMatches.length || findMatchIndex < 0) return false;
    const match = findMatches[findMatchIndex];
    if (editorMode === "source") {
      sourceEditor.setRangeText(replaceInput.value, match.from, match.to, "end");
      recordSourceMutation();
    } else {
      editor.view.dispatch(
        editor.state.tr.insertText(replaceInput.value, match.from, match.to).scrollIntoView()
      );
    }
    refreshFindPresentation(true);
    return true;
  };

  const replaceAllMatches = () => {
    if (!findMatches.length) return false;
    if (editorMode === "source") {
      let nextSource = sourceEditor.value;
      for (const match of [...findMatches].reverse()) {
        nextSource = `${nextSource.slice(0, match.from)}${replaceInput.value}${nextSource.slice(match.to)}`;
      }
      sourceEditor.value = nextSource;
      recordSourceMutation();
    } else {
      const transaction = editor.state.tr;
      for (const match of [...findMatches].reverse()) {
        transaction.insertText(replaceInput.value, match.from, match.to);
      }
      editor.view.dispatch(transaction.scrollIntoView());
    }
    refreshFindPresentation(true);
    return true;
  };

  findInput.addEventListener("input", () => {
    if (!documentIsComposing(document)) refreshFindPresentation(true);
  });
  findInput.addEventListener("compositionend", () => refreshFindPresentation(true));
  findInput.addEventListener("keydown", (event) => {
    if (isIMECompositionEvent(event)) return;
    if (event.key === "Enter") {
      event.preventDefault();
      moveFindMatch(event.shiftKey ? -1 : 1);
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      closeFind();
    }
  });
  replaceInput.addEventListener("keydown", (event) => {
    if (isIMECompositionEvent(event)) return;
    if (event.key === "Enter") {
      event.preventDefault();
      replaceCurrentMatch();
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      closeFind();
    }
  });
  previousFindButton.addEventListener("click", () => moveFindMatch(-1));
  nextFindButton.addEventListener("click", () => moveFindMatch(1));
  closeFindButton.addEventListener("click", () => closeFind());
  replaceButton.addEventListener("click", replaceCurrentMatch);
  replaceAllButton.addEventListener("click", replaceAllMatches);

  const outlinePanel = document.createElement("section");
  outlinePanel.className = "outline-panel markdown-card-overlay";
  outlinePanel.setAttribute("role", "dialog");
  outlinePanel.setAttribute("aria-label", "Document outline");
  outlinePanel.hidden = true;
  const outlineHeader = document.createElement("div");
  outlineHeader.className = "outline-header";
  const outlineTitle = document.createElement("strong");
  outlineTitle.textContent = "Outline";
  const closeOutlineButton = document.createElement("button");
  closeOutlineButton.type = "button";
  closeOutlineButton.textContent = "×";
  closeOutlineButton.setAttribute("aria-label", "Close outline");
  outlineHeader.append(outlineTitle, closeOutlineButton);
  const outlineList = document.createElement("div");
  outlineList.className = "outline-list";
  outlineList.setAttribute("role", "list");
  outlinePanel.append(outlineHeader, outlineList);
  document.body.appendChild(outlinePanel);

  const getOutline = () => (
    editorMode === "source"
      ? sourceDocumentOutline(sourceEditor.value)
      : richDocumentOutline(editor.state.doc)
  );

  const jumpToHeading = (position) => {
    const numericPosition = Number(position);
    if (!Number.isFinite(numericPosition)) return false;
    if (editorMode === "source") {
      const offset = Math.max(0, Math.min(numericPosition, sourceEditor.value.length));
      sourceEditor.focus({ preventScroll: true });
      sourceEditor.setSelectionRange(offset, offset);
      const linesBefore = sourceEditor.value.slice(0, offset).split("\n").length - 1;
      const lineHeight = Number.parseFloat(window.getComputedStyle?.(sourceEditor)?.lineHeight) || 21;
      sourceEditor.scrollTop = Math.max(0, linesBefore * lineHeight - 12);
    } else {
      const maximum = editor.state.doc.content.size;
      const offset = Math.max(1, Math.min(numericPosition, maximum));
      editor.chain().focus(undefined, { scrollIntoView: false })
        .setTextSelection(offset).scrollIntoView().run();
    }
    return true;
  };

  refreshOutlinePresentation = () => {
    if (outlinePanel.hidden) return [];
    const headings = getOutline();
    outlineList.replaceChildren();
    if (!headings.length) {
      const empty = document.createElement("p");
      empty.className = "outline-empty";
      empty.textContent = "No headings";
      outlineList.appendChild(empty);
      return headings;
    }
    for (const heading of headings) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "outline-item";
      button.dataset.level = String(heading.level);
      button.dataset.position = String(heading.position);
      button.textContent = heading.text;
      button.title = `H${heading.level} · ${heading.text}`;
      button.addEventListener("click", () => {
        jumpToHeading(heading.position);
        closeOutline({ restoreFocus: false });
      });
      outlineList.appendChild(button);
    }
    return headings;
  };

  const closeOutline = ({ restoreFocus = true } = {}) => {
    if (outlinePanel.hidden) return false;
    outlinePanel.hidden = true;
    queueHeightMeasurement();
    if (restoreFocus) {
      if (editorMode === "source") sourceEditor.focus({ preventScroll: true });
      else editor.commands.focus(undefined, { scrollIntoView: false });
    }
    return true;
  };

  const openOutline = () => {
    closeLinkEditor({ restoreSelection: false });
    closeFind({ restoreFocus: false });
    closeImageEditor({ restoreSelection: false });
    hideTableControls();
    outlinePanel.hidden = false;
    outlinePanel.style.top = "12px";
    outlinePanel.style.right = "12px";
    outlinePanel.style.left = "auto";
    refreshOutlinePresentation();
    queueHeightMeasurement();
    outlineList.querySelector("button")?.focus();
    return true;
  };

  const toggleOutline = () => (
    outlinePanel.hidden ? openOutline() : closeOutline()
  );

  outlinePanel.addEventListener("keydown", (event) => {
    if (isIMECompositionEvent(event)) return;
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      closeOutline();
      return;
    }
    if (!["ArrowDown", "ArrowUp"].includes(event.key)) return;
    const buttons = [...outlineList.querySelectorAll("button")];
    if (!buttons.length) return;
    event.preventDefault();
    const index = Math.max(0, buttons.indexOf(document.activeElement));
    const next = event.key === "ArrowDown"
      ? (index + 1) % buttons.length
      : (index - 1 + buttons.length) % buttons.length;
    buttons[next].focus();
  });
  closeOutlineButton.addEventListener("click", () => closeOutline());

  const tableToolbar = document.createElement("div");
  tableToolbar.className = "table-edge-controls";
  tableToolbar.setAttribute("role", "group");
  tableToolbar.setAttribute("aria-label", "Table controls");
  tableToolbar.hidden = true;
  const tableSelectionContext = () => {
    const { $from } = editor.state.selection;
    let tableDepth = null;
    let rowDepth = null;
    for (let depth = $from.depth; depth > 0; depth -= 1) {
      const name = $from.node(depth).type.name;
      if (rowDepth == null && name === "tableRow") rowDepth = depth;
      if (name === "table") {
        tableDepth = depth;
        break;
      }
    }
    if (tableDepth == null || rowDepth == null) return null;
    return {
      tableDepth,
      rowDepth,
      table: $from.node(tableDepth),
      tablePosition: $from.before(tableDepth),
      rowIndex: $from.index(tableDepth),
      columnIndex: $from.index(rowDepth)
    };
  };

  const canReorderTable = (axis, delta) => {
    const context = tableSelectionContext();
    const moveBy = Number.isInteger(delta) ? delta : 0;
    if (!context || moveBy === 0) return false;
    if (axis === "row") {
      const target = context.rowIndex + moveBy;
      const firstRow = context.table.firstChild;
      const hasHeaderRow = firstRow?.childCount > 0 && Array.from(
        { length: firstRow.childCount },
        (_, index) => firstRow.child(index).type.name
      ).every((name) => name === "tableHeader");
      const firstMovableRow = hasHeaderRow ? 1 : 0;
      return context.rowIndex >= firstMovableRow
        && target >= firstMovableRow
        && target < context.table.childCount;
    }
    if (axis !== "column") return false;
    const target = context.columnIndex + moveBy;
    if (target < 0) return false;
    let portable = true;
    context.table.forEach((row) => {
      if (target >= row.childCount) portable = false;
      row.forEach((cell) => {
        if (Number(cell.attrs.colspan ?? 1) !== 1 || Number(cell.attrs.rowspan ?? 1) !== 1) {
          portable = false;
        }
      });
    });
    return portable;
  };

  const reorderTable = (axis, delta) => {
    const context = tableSelectionContext();
    if (!context || !canReorderTable(axis, delta)) return false;
    const rows = Array.from(
      { length: context.table.childCount },
      (_, index) => context.table.child(index)
    );
    let nextRowIndex = context.rowIndex;
    let nextColumnIndex = context.columnIndex;
    if (axis === "row") {
      nextRowIndex += delta;
      const [movedRow] = rows.splice(context.rowIndex, 1);
      rows.splice(nextRowIndex, 0, movedRow);
    } else {
      nextColumnIndex += delta;
      for (let rowIndex = 0; rowIndex < rows.length; rowIndex += 1) {
        const row = rows[rowIndex];
        const cells = Array.from({ length: row.childCount }, (_, index) => row.child(index));
        const [movedCell] = cells.splice(context.columnIndex, 1);
        cells.splice(nextColumnIndex, 0, movedCell);
        rows[rowIndex] = row.type.create(row.attrs, cells, row.marks);
      }
    }

    const replacement = context.table.type.create(context.table.attrs, rows, context.table.marks);
    const transaction = editor.state.tr.replaceWith(
      context.tablePosition,
      context.tablePosition + context.table.nodeSize,
      replacement
    );
    let cellPosition = context.tablePosition + 1;
    for (let index = 0; index < nextRowIndex; index += 1) cellPosition += rows[index].nodeSize;
    cellPosition += 1;
    const selectedRow = rows[nextRowIndex];
    for (let index = 0; index < nextColumnIndex; index += 1) {
      cellPosition += selectedRow.child(index).nodeSize;
    }
    const textPosition = Math.min(transaction.doc.content.size, cellPosition + 2);
    transaction.setSelection(TextSelection.near(transaction.doc.resolve(textPosition), 1));
    editor.view.dispatch(transaction.scrollIntoView());
    return true;
  };

  const parseTSVRows = (source) => String(source ?? "")
    .replace(/\r\n?/gu, "\n")
    .replace(/\n$/u, "")
    .split("\n")
    .map((row) => row.split("\t"));

  pasteTSV = (source) => {
    const values = parseTSVRows(source);
    const inputColumnCount = Math.max(0, ...values.map((row) => row.length));
    const context = tableSelectionContext();
    if (!context || !values.length || inputColumnCount < 2) return false;

    const existingRows = Array.from(
      { length: context.table.childCount },
      (_, index) => context.table.child(index)
    );
    const existingColumnCount = Math.max(
      1,
      ...existingRows.map((row) => row.childCount)
    );
    const rowCount = Math.max(existingRows.length, context.rowIndex + values.length);
    const columnCount = Math.max(
      existingColumnCount,
      context.columnIndex + inputColumnCount
    );
    const tableRowType = editor.schema.nodes.tableRow;
    const tableCellType = editor.schema.nodes.tableCell;
    const tableHeaderType = editor.schema.nodes.tableHeader;
    const paragraphType = editor.schema.nodes.paragraph;
    const firstRowUsesHeaders = existingRows[0]?.childCount > 0
      && Array.from(
        { length: existingRows[0].childCount },
        (_, index) => existingRows[0].child(index).type.name
      ).every((name) => name === "tableHeader");

    const rows = [];
    for (let rowIndex = 0; rowIndex < rowCount; rowIndex += 1) {
      const existingRow = existingRows[rowIndex];
      const cells = [];
      for (let columnIndex = 0; columnIndex < columnCount; columnIndex += 1) {
        const existingCell = existingRow && columnIndex < existingRow.childCount
          ? existingRow.child(columnIndex)
          : null;
        const pastedRow = values[rowIndex - context.rowIndex];
        const pastedValue = pastedRow?.[columnIndex - context.columnIndex];
        if (pastedValue !== undefined) {
          const type = existingCell?.type
            ?? (rowIndex === 0 && firstRowUsesHeaders ? tableHeaderType : tableCellType);
          const text = pastedValue
            ? editor.schema.text(pastedValue)
            : null;
          cells.push(type.create(existingCell?.attrs ?? null, paragraphType.create(null, text)));
        } else if (existingCell) {
          cells.push(existingCell);
        } else {
          const type = rowIndex === 0 && firstRowUsesHeaders ? tableHeaderType : tableCellType;
          cells.push(type.create(null, paragraphType.create()));
        }
      }
      rows.push(tableRowType.create(existingRow?.attrs ?? null, cells));
    }

    const replacement = context.table.type.create(context.table.attrs, rows);
    const transaction = editor.state.tr.replaceWith(
      context.tablePosition,
      context.tablePosition + context.table.nodeSize,
      replacement
    );
    const selectionPosition = Math.min(
      transaction.doc.content.size,
      context.tablePosition + 3
    );
    transaction.setSelection(TextSelection.near(transaction.doc.resolve(selectionPosition), 1));
    editor.view.dispatch(transaction.scrollIntoView());
    return true;
  };

  const tableButtons = new Map();

  const makeTableControlButton = ({ command, icon, title, className = "" }) => {
    const button = document.createElement("button");
    button.type = "button";
    button.dataset.command = command;
    button.className = className;
    button.setAttribute("aria-label", title);
    button.title = title;
    const glyph = createLucideElement(icon);
    glyph.setAttribute("class", "table-control-glyph");
    glyph.setAttribute("aria-hidden", "true");
    glyph.setAttribute("focusable", "false");
    button.appendChild(glyph);
    button.addEventListener("mousedown", (event) => event.preventDefault());
    return button;
  };

  const addColumnButton = makeTableControlButton({
    command: "addColumnAfter",
    icon: Plus,
    title: "Insert column after current column",
    className: "table-edge-button table-column-insert"
  });
  const addRowButton = makeTableControlButton({
    command: "addRowAfter",
    icon: Plus,
    title: "Insert row after current row",
    className: "table-edge-button table-row-insert"
  });
  const makeTableAxisHandle = (axis) => {
    const isRow = axis === "row";
    const direction = isRow ? "up or down" : "left or right";
    const button = makeTableControlButton({
      command: `${axis}Handle`,
      icon: isRow ? GripVertical : GripHorizontal,
      title: `${isRow ? "Row" : "Column"} handle — drag ${direction}; Delete removes it`,
      className: `table-axis-handle table-${axis}-handle`
    });
    button.dataset.axis = axis;
    button.setAttribute(
      "aria-label",
      `${isRow ? "Row" : "Column"} handle. Drag ${direction} to move; press Delete to remove.`
    );
    button.setAttribute(
      "aria-keyshortcuts",
      isRow ? "Alt+ArrowUp Alt+ArrowDown Delete" : "Alt+ArrowLeft Alt+ArrowRight Delete"
    );
    return button;
  };
  const columnHandle = makeTableAxisHandle("column");
  const rowHandle = makeTableAxisHandle("row");

  const runTableAction = (action) => {
    let ran = false;
    if (action.run) {
      ran = action.run() === true;
      if (ran) editor.commands.focus(undefined, { scrollIntoView: false });
    } else {
      const chain = editor.chain().focus(undefined, { scrollIntoView: false });
      if (typeof chain[action.command] === "function") {
        ran = chain[action.command]().run() === true;
      }
    }
    if (!ran) return false;
    refreshContextualControls();
    return true;
  };

  const registerTableAction = (button, action) => {
    button.addEventListener("click", () => runTableAction(action));
    tableButtons.set(action.command, { button, action });
  };

  registerTableAction(addColumnButton, {
    command: "addColumnAfter",
    title: "Insert column after current column"
  });
  registerTableAction(addRowButton, {
    command: "addRowAfter",
    title: "Insert row after current row"
  });
  const tableControlFocusOrder = [columnHandle, rowHandle, addColumnButton, addRowButton];
  for (const control of tableControlFocusOrder) control.tabIndex = -1;

  const setTableControlTabStop = (activeControl = null) => {
    for (const control of tableControlFocusOrder) {
      control.tabIndex = control === activeControl ? 0 : -1;
    }
  };

  const visibleTableControls = () => tableControlFocusOrder.filter(
    (control) => !control.hidden && !control.disabled
  );

  const focusEditorFromTableControls = () => {
    setTableControlTabStop();
    editor.view.focus();
  };

  const focusTableControlsFromKeyboard = () => {
    if (tableToolbar.hidden || !tableSelectionContext() || !positionTableToolbar()) return false;
    const target = visibleTableControls()[0];
    if (!target) return false;
    setTableControlTabStop(target);
    target.focus({ preventScroll: true });
    return true;
  };

  const handleTableControlKeyDown = (event) => {
    if (isIMECompositionEvent(event)) return;
    const control = event.currentTarget;
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      focusEditorFromTableControls();
      return;
    }
    if (event.key === "Tab") {
      event.preventDefault();
      event.stopPropagation();
      const controls = visibleTableControls();
      const currentIndex = controls.indexOf(control);
      const nextIndex = currentIndex + (event.shiftKey ? -1 : 1);
      if (currentIndex < 0 || nextIndex < 0 || nextIndex >= controls.length) {
        focusEditorFromTableControls();
        return;
      }
      setTableControlTabStop(controls[nextIndex]);
      controls[nextIndex].focus({ preventScroll: true });
      return;
    }

    const axis = control.dataset.axis;
    if (!axis) return;
    if (["Delete", "Backspace"].includes(event.key)) {
      event.preventDefault();
      event.stopPropagation();
      runTableAction({ command: axis === "row" ? "deleteRow" : "deleteColumn" });
      return;
    }
    const moveDelta = axis === "row"
      ? (event.altKey && event.key === "ArrowUp" ? -1 : (event.altKey && event.key === "ArrowDown" ? 1 : 0))
      : (event.altKey && event.key === "ArrowLeft" ? -1 : (event.altKey && event.key === "ArrowRight" ? 1 : 0));
    if (!moveDelta) return;
    event.preventDefault();
    event.stopPropagation();
    runTableAction({ run: () => reorderTable(axis, moveDelta) });
  };

  for (const control of tableControlFocusOrder) {
    control.addEventListener("keydown", handleTableControlKeyDown);
  }

  const tableHandleDragCleanups = [];
  const installTableHandleDrag = (handle, axis) => {
    let dragState = null;
    const dragDistance = (event, state = dragState) => {
      if (!state) return 0;
      return axis === "row"
        ? Number(event?.clientY ?? state.lastY) - state.startY
        : Number(event?.clientX ?? state.lastX) - state.startX;
    };
    const pointerMatches = (event) => dragState
      && (dragState.pointerID == null || event.pointerId == null || event.pointerId === dragState.pointerID);
    const finishDrag = (event, { commit = false } = {}) => {
      if (!dragState || (event && !pointerMatches(event))) return false;
      const state = dragState;
      dragState = null;
      handle.classList.remove("is-dragging");
      if (state.pointerID != null && handle.hasPointerCapture?.(state.pointerID)) {
        try { handle.releasePointerCapture(state.pointerID); } catch { /* already released */ }
      }
      const distance = dragDistance(event, state);
      if (!commit || !state.dragged || Math.abs(distance) < 18) return false;
      const direction = distance < 0 ? -1 : 1;
      let moveBy = direction * Math.max(
        1,
        Math.round(Math.abs(distance) / Math.max(24, state.stepSize))
      );
      while (Math.abs(moveBy) > 1 && !canReorderTable(axis, moveBy)) moveBy -= direction;
      return runTableAction({ run: () => reorderTable(axis, moveBy) });
    };
    const handlePointerDown = (event) => {
      if (event.button !== 0 || handle.disabled) return;
      event.preventDefault();
      event.stopPropagation();
      setTableControlTabStop(handle);
      handle.focus({ preventScroll: true });
      dragState = {
        pointerID: Number.isFinite(event.pointerId) ? event.pointerId : null,
        startX: Number(event.clientX || 0),
        startY: Number(event.clientY || 0),
        lastX: Number(event.clientX || 0),
        lastY: Number(event.clientY || 0),
        stepSize: Number(handle.dataset.dragStepSize || 0),
        dragged: false
      };
      if (dragState.pointerID != null) {
        try { handle.setPointerCapture?.(dragState.pointerID); } catch { /* unsupported capture */ }
      }
    };
    const handlePointerMove = (event) => {
      if (!pointerMatches(event)) return;
      dragState.lastX = Number(event.clientX ?? dragState.lastX);
      dragState.lastY = Number(event.clientY ?? dragState.lastY);
      if (Math.abs(dragDistance(event)) < 8) return;
      dragState.dragged = true;
      handle.classList.add("is-dragging");
    };
    const handlePointerUp = (event) => finishDrag(event, { commit: true });
    const cancelDrag = (event) => finishDrag(event, { commit: false });
    const cancelDragOnBlur = () => finishDrag(null, { commit: false });
    handle.addEventListener("pointerdown", handlePointerDown);
    handle.addEventListener("pointermove", handlePointerMove);
    handle.addEventListener("pointerup", handlePointerUp);
    handle.addEventListener("pointercancel", cancelDrag);
    handle.addEventListener("lostpointercapture", cancelDrag);
    window.addEventListener("blur", cancelDragOnBlur);
    return () => {
      finishDrag(null, { commit: false });
      handle.removeEventListener("pointerdown", handlePointerDown);
      handle.removeEventListener("pointermove", handlePointerMove);
      handle.removeEventListener("pointerup", handlePointerUp);
      handle.removeEventListener("pointercancel", cancelDrag);
      handle.removeEventListener("lostpointercapture", cancelDrag);
      window.removeEventListener("blur", cancelDragOnBlur);
    };
  };
  tableHandleDragCleanups.push(installTableHandleDrag(columnHandle, "column"));
  tableHandleDragCleanups.push(installTableHandleDrag(rowHandle, "row"));

  tableToolbar.append(columnHandle, rowHandle, addColumnButton, addRowButton);
  document.body.appendChild(tableToolbar);

  hideTableControls = () => {
    setTableControlTabStop();
    tableToolbar.hidden = true;
  };

  const handleTableControlsScroll = () => {
    if (!tableToolbar.hidden) positionTableToolbar();
  };
  renderer.addEventListener("scroll", handleTableControlsScroll, true);

  const selectionIsInTable = () => {
    const { $from } = editor.state.selection;
    for (let depth = $from.depth; depth > 0; depth -= 1) {
      if ($from.node(depth).type.name === "table") return true;
    }
    return false;
  };

  function positionTableToolbar() {
    const { $from } = editor.state.selection;
    let selectionDOM = null;
    try {
      selectionDOM = editor.view.domAtPos($from.pos)?.node ?? null;
    } catch {
      selectionDOM = null;
    }
    const selectionElement = selectionDOM?.nodeType === 1
      ? selectionDOM
      : selectionDOM?.parentElement;
    const cell = selectionElement?.closest?.("td, th") ?? null;
    const row = cell?.closest?.("tr") ?? null;
    const table = cell?.closest?.("table") ?? null;
    const wrapper = table?.closest?.(".tableWrapper") ?? table;
    let coordinates;
    try {
      coordinates = editor.view.coordsAtPos(editor.state.selection.from);
    } catch {
      coordinates = { left: 12, right: 84, top: 44, bottom: 62 };
    }
    const viewportWidth = Number(window.innerWidth || document.documentElement.clientWidth || 720);
    const viewportHeight = Number(window.innerHeight || document.documentElement.clientHeight || 480);
    const finite = (value, fallback) => Number.isFinite(Number(value)) ? Number(value) : fallback;
    const coordinateLeft = finite(coordinates.left, 12);
    const coordinateTop = finite(coordinates.top, 44);
    const coordinateRight = Math.max(coordinateLeft + 72, finite(coordinates.right, coordinateLeft + 72));
    const coordinateBottom = Math.max(coordinateTop + 18, finite(coordinates.bottom, coordinateTop + 18));
    const fallbackWrapperRect = {
      left: coordinateLeft,
      top: coordinateTop,
      right: Math.max(coordinateRight, coordinateLeft + 216),
      bottom: Math.max(coordinateBottom, coordinateTop + 80)
    };
    const normalizedRect = (candidate, fallback) => {
      const left = finite(candidate?.left, fallback.left);
      const top = finite(candidate?.top, fallback.top);
      const right = finite(candidate?.right, fallback.right);
      const bottom = finite(candidate?.bottom, fallback.bottom);
      return right > left && bottom > top ? { left, top, right, bottom } : fallback;
    };
    const rawWrapperRect = wrapper?.getBoundingClientRect?.();
    const wrapperHasArea = finite(rawWrapperRect?.right, 0) > finite(rawWrapperRect?.left, 0)
      && finite(rawWrapperRect?.bottom, 0) > finite(rawWrapperRect?.top, 0);
    const wrapperRect = normalizedRect(rawWrapperRect, fallbackWrapperRect);
    const cellRect = normalizedRect(cell?.getBoundingClientRect?.(), {
      left: coordinateLeft,
      top: coordinateTop,
      right: coordinateRight,
      bottom: coordinateBottom
    });
    const rowRect = normalizedRect(row?.getBoundingClientRect?.(), {
      left: wrapperRect.left,
      top: coordinateTop,
      right: wrapperRect.right,
      bottom: coordinateBottom
    });
    const rawRendererRect = renderer.getBoundingClientRect?.();
    const rendererHasArea = finite(rawRendererRect?.right, 0) > finite(rawRendererRect?.left, 0)
      && finite(rawRendererRect?.bottom, 0) > finite(rawRendererRect?.top, 0);
    const clipLeft = Math.max(0, rendererHasArea ? finite(rawRendererRect.left, 0) : 0);
    const clipTop = Math.max(0, rendererHasArea ? finite(rawRendererRect.top, 0) : 0);
    const clipRight = Math.min(
      viewportWidth,
      rendererHasArea ? finite(rawRendererRect.right, viewportWidth) : viewportWidth
    );
    const clipBottom = Math.min(
      viewportHeight,
      rendererHasArea ? finite(rawRendererRect.bottom, viewportHeight) : viewportHeight
    );
    const visibleWrapper = {
      left: Math.max(wrapperRect.left, clipLeft),
      top: Math.max(wrapperRect.top, clipTop),
      right: Math.min(wrapperRect.right, clipRight),
      bottom: Math.min(wrapperRect.bottom, clipBottom)
    };
    const wrapperIsVisible = visibleWrapper.right > visibleWrapper.left
      && visibleWrapper.bottom > visibleWrapper.top;
    tableToolbar.dataset.positionVisible = wrapperIsVisible ? "true" : "false";
    tableToolbar.style.visibility = wrapperIsVisible ? "visible" : "hidden";
    if (!wrapperIsVisible) {
      addColumnButton.hidden = true;
      addRowButton.hidden = true;
      columnHandle.hidden = true;
      rowHandle.hidden = true;
      const controlsHadFocus = tableToolbar.contains(document.activeElement);
      if (controlsHadFocus) editor.commands.focus(undefined, { scrollIntoView: false });
      return false;
    }

    const controlRadius = 22;
    const clampCenterX = (value) => Math.min(
      Math.max(controlRadius, Number(value) || controlRadius),
      Math.max(controlRadius, viewportWidth - controlRadius)
    );
    const clampCenterY = (value) => Math.min(
      Math.max(controlRadius, Number(value) || controlRadius),
      Math.max(controlRadius, viewportHeight - controlRadius)
    );
    const placeControl = (button, centerX, centerY) => {
      button.style.left = `${clampCenterX(centerX) - controlRadius}px`;
      button.style.top = `${clampCenterY(centerY) - controlRadius}px`;
    };

    const boundaryIsVisible = (value, minimum, maximum) => (
      Number(value) >= minimum - 0.5 && Number(value) <= maximum + 0.5
    );
    const columnBoundary = cellRect.right;
    const rowBoundary = rowRect.bottom;
    const topEdgeCenterY = wrapperRect.top;
    const leftEdgeCenterX = wrapperRect.left;
    const topEdgeHasSpace = !wrapperHasArea || (wrapperRect.top >= clipTop - 0.5
      && topEdgeCenterY >= controlRadius
      && topEdgeCenterY <= clipBottom - controlRadius);
    const leftEdgeHasSpace = !wrapperHasArea || (wrapperRect.left >= clipLeft - 0.5
      && leftEdgeCenterX >= controlRadius
      && leftEdgeCenterX <= clipRight - controlRadius);
    const columnIsVisible = cellRect.right > visibleWrapper.left
      && cellRect.left < visibleWrapper.right
      && cellRect.bottom > visibleWrapper.top
      && cellRect.top < visibleWrapper.bottom;
    const rowIsVisible = rowRect.bottom > visibleWrapper.top
      && rowRect.top < visibleWrapper.bottom;
    columnHandle.dataset.dragStepSize = String(Math.max(24, cellRect.right - cellRect.left));
    rowHandle.dataset.dragStepSize = String(Math.max(24, rowRect.bottom - rowRect.top));
    columnHandle.hidden = !columnIsVisible || !topEdgeHasSpace;
    rowHandle.hidden = !rowIsVisible || !leftEdgeHasSpace;
    addColumnButton.hidden = !topEdgeHasSpace || !boundaryIsVisible(
      columnBoundary,
      visibleWrapper.left,
      visibleWrapper.right
    );
    addRowButton.hidden = !leftEdgeHasSpace || !boundaryIsVisible(
      rowBoundary,
      visibleWrapper.top,
      visibleWrapper.bottom
    );
    const horizontalControlY = topEdgeCenterY;
    const rowControlX = leftEdgeCenterX;
    if (!addColumnButton.hidden) {
      placeControl(addColumnButton, columnBoundary, horizontalControlY);
    }
    if (!columnHandle.hidden) {
      const visibleCellCenterX = (
        Math.max(cellRect.left, visibleWrapper.left)
        + Math.min(cellRect.right, visibleWrapper.right)
      ) / 2;
      placeControl(columnHandle, visibleCellCenterX, horizontalControlY);
    }
    if (!addRowButton.hidden) {
      placeControl(addRowButton, rowControlX, rowBoundary);
    }
    if (!rowHandle.hidden) {
      const visibleRowCenterY = (
        Math.max(rowRect.top, visibleWrapper.top)
        + Math.min(rowRect.bottom, visibleWrapper.bottom)
      ) / 2;
      placeControl(rowHandle, rowControlX, visibleRowCenterY);
    }
    if (tableToolbar.contains(document.activeElement) && document.activeElement.hidden) {
      focusEditorFromTableControls();
    }
    return true;
  }

  refreshContextualControls = () => {
    const visible = editorMode === "rich"
      && selectionIsInTable()
      && findPanel.hidden
      && outlinePanel.hidden;
    tableToolbar.hidden = !visible;
    if (!visible) {
      setTableControlTabStop();
      queueHeightMeasurement();
      return false;
    }
    for (const [command, { button, action }] of tableButtons) {
      try {
        if (action.run) {
          button.disabled = action.canRun ? !action.canRun() : !tableSelectionContext();
          continue;
        }
        const commands = editor.can();
        button.disabled = typeof commands[command] !== "function" || !commands[command]();
      } catch {
        button.disabled = true;
      }
    }
    try {
      const commands = editor.can();
      rowHandle.disabled = typeof commands.deleteRow !== "function" || !commands.deleteRow();
      columnHandle.disabled = typeof commands.deleteColumn !== "function" || !commands.deleteColumn();
    } catch {
      rowHandle.disabled = true;
      columnHandle.disabled = true;
    }
    const positioned = positionTableToolbar();
    queueHeightMeasurement();
    return positioned;
  };

  const imageEditor = document.createElement("form");
  imageEditor.className = "image-editor-popover markdown-card-overlay";
  imageEditor.setAttribute("role", "dialog");
  imageEditor.setAttribute("aria-label", "Edit image");
  imageEditor.hidden = true;
  const imageEditorHeading = document.createElement("strong");
  imageEditorHeading.className = "link-editor-heading";
  imageEditorHeading.textContent = "Image";
  const { field: imageSourceField, input: imageSourceInput } = makeLinkField("Source", "source");
  imageSourceInput.maxLength = 4096;
  imageSourceInput.placeholder = "./assets/diagram.png";
  const { field: imageAltField, input: imageAltInput } = makeLinkField("Alt text", "alt");
  imageAltInput.maxLength = 200;
  imageAltInput.placeholder = "Describe the image";
  const { field: imageTitleField, input: imageTitleInput } = makeLinkField("Title", "title");
  imageTitleInput.maxLength = 200;
  imageTitleInput.placeholder = "Optional tooltip";
  const { field: imageCaptionField, input: imageCaptionInput } = makeLinkField("Caption", "caption");
  imageCaptionInput.maxLength = 300;
  imageCaptionInput.placeholder = "Optional visible caption";
  const makeImageSelect = (label, name, options) => {
    const field = document.createElement("label");
    field.className = "link-editor-field";
    const caption = document.createElement("span");
    caption.textContent = label;
    const select = document.createElement("select");
    select.name = name;
    for (const [value, text] of options) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = text;
      select.appendChild(option);
    }
    field.append(caption, select);
    return { field, select };
  };
  const { field: imageWidthField, select: imageWidthSelect } = makeImageSelect(
    "Width",
    "width",
    [["", "Auto"], ["25", "25%"], ["50", "50%"], ["75", "75%"], ["100", "100%"]]
  );
  const { field: imageAlignmentField, select: imageAlignmentSelect } = makeImageSelect(
    "Align",
    "alignment",
    [["", "Auto"], ["left", "Left"], ["center", "Center"], ["right", "Right"]]
  );
  const imageAltHint = document.createElement("div");
  imageAltHint.className = "image-alt-hint";
  imageAltHint.textContent = "Leave Alt text empty only for a decorative image.";
  const imageEditorError = document.createElement("div");
  imageEditorError.className = "link-editor-error image-editor-error";
  imageEditorError.setAttribute("role", "alert");
  imageEditorError.hidden = true;
  const imageEditorActions = document.createElement("div");
  imageEditorActions.className = "link-editor-actions";
  const cancelImageButton = document.createElement("button");
  cancelImageButton.type = "button";
  cancelImageButton.textContent = "Cancel";
  const applyImageButton = document.createElement("button");
  applyImageButton.type = "submit";
  applyImageButton.className = "is-primary";
  applyImageButton.textContent = "Apply";
  const imageEditorSpacer = document.createElement("span");
  imageEditorSpacer.className = "link-editor-spacer";
  imageEditorActions.append(imageEditorSpacer, cancelImageButton, applyImageButton);
  imageEditor.append(
    imageEditorHeading,
    imageSourceField,
    imageAltField,
    imageTitleField,
    imageCaptionField,
    imageWidthField,
    imageAlignmentField,
    imageAltHint,
    imageEditorError,
    imageEditorActions
  );
  document.body.appendChild(imageEditor);

  let imageEditorPosition = null;

  const selectedImageContext = () => {
    const selection = editor.state.selection;
    if (!(selection instanceof NodeSelection) || selection.node.type.name !== "blockedImage") {
      return null;
    }
    return { position: selection.from, node: selection.node };
  };

  const positionImageEditor = (position) => {
    let coordinates;
    try {
      coordinates = editor.view.coordsAtPos(position);
    } catch {
      coordinates = { left: 24, top: 48, bottom: 66 };
    }
    const rect = imageEditor.getBoundingClientRect?.();
    const width = Number(rect?.width ?? 0) || 336;
    const height = Number(rect?.height ?? 0) || 214;
    const viewportWidth = Number(window.innerWidth || document.documentElement.clientWidth || 720);
    const viewportHeight = Number(window.innerHeight || document.documentElement.clientHeight || 480);
    const left = Math.min(
      Math.max(12, coordinates.left),
      Math.max(12, viewportWidth - width - 12)
    );
    const preferredTop = coordinates.bottom + 8;
    const top = preferredTop + height <= viewportHeight - 12
      ? preferredTop
      : Math.max(12, coordinates.top - height - 8);
    imageEditor.style.left = `${left}px`;
    imageEditor.style.top = `${top}px`;
  };

  const closeImageEditor = ({ restoreSelection = true } = {}) => {
    if (imageEditor.hidden) return false;
    const position = imageEditorPosition;
    imageEditor.hidden = true;
    imageEditorError.hidden = true;
    imageEditorError.textContent = "";
    imageEditorPosition = null;
    queueHeightMeasurement();
    if (restoreSelection && position != null) {
      const node = editor.state.doc.nodeAt(position);
      if (node?.type.name === "blockedImage") {
        editor.view.dispatch(
          editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, position))
        );
        editor.commands.focus(undefined, { scrollIntoView: false });
      }
    }
    return true;
  };

  const openImageEditor = () => {
    if (editorMode !== "rich") return false;
    const context = selectedImageContext();
    if (!context) return false;
    closeLinkEditor({ restoreSelection: false });
    closeFind({ restoreFocus: false });
    closeOutline({ restoreFocus: false });
    imageEditorPosition = context.position;
    imageSourceInput.value = context.node.attrs.src ?? "";
    imageAltInput.value = context.node.attrs.alt ?? "";
    imageTitleInput.value = context.node.attrs.title ?? "";
    imageCaptionInput.value = context.node.attrs.caption ?? "";
    imageWidthSelect.value = context.node.attrs.width == null
      ? ""
      : String(context.node.attrs.width);
    imageAlignmentSelect.value = context.node.attrs.alignment ?? "";
    imageEditorError.hidden = true;
    imageEditorError.textContent = "";
    imageEditor.hidden = false;
    hideTableControls();
    positionImageEditor(context.position);
    queueHeightMeasurement();
    imageAltInput.focus();
    imageAltInput.select();
    return true;
  };

  imageEditor.addEventListener("submit", (event) => {
    event.preventDefault();
    if (documentIsComposing(document)) return;
    const position = imageEditorPosition;
    const node = position == null ? null : editor.state.doc.nodeAt(position);
    if (node?.type.name !== "blockedImage") {
      closeImageEditor({ restoreSelection: false });
      return;
    }
    const nextSource = imageSourceInput.value.trim();
    const managedSource = LOCAL_ATTACHMENT_PATTERN.test(nextSource);
    const safeRelativeSource = safeDocumentImagePath(nextSource) != null;
    if (!nextSource || (
      nextSource !== String(node.attrs.src ?? "")
      && !managedSource
      && !safeRelativeSource
    )) {
      imageEditorError.textContent = "Use a safe document-relative image path or a managed attachment.";
      imageEditorError.hidden = false;
      imageSourceInput.focus();
      return;
    }
    const transaction = editor.state.tr.setNodeMarkup(position, undefined, {
      ...node.attrs,
      src: nextSource,
      alt: imageAltInput.value,
      title: imageTitleInput.value.trim() || null,
      caption: imageCaptionInput.value.trim() || null,
      width: imageWidthSelect.value ? Number(imageWidthSelect.value) : null,
      alignment: imageAlignmentSelect.value || null
    });
    transaction.setSelection(NodeSelection.create(transaction.doc, position));
    editor.view.dispatch(transaction.scrollIntoView());
    closeImageEditor({ restoreSelection: false });
    editor.commands.focus(undefined, { scrollIntoView: false });
  });
  imageEditor.addEventListener("keydown", (event) => {
    if (isIMECompositionEvent(event)) return;
    if (event.key !== "Escape") return;
    event.preventDefault();
    event.stopPropagation();
    closeImageEditor();
  });
  cancelImageButton.addEventListener("click", () => closeImageEditor());
  document.addEventListener("dblclick", (event) => {
    if (editorMode !== "rich") return;
    const target = event.target?.closest?.(".markdown-canvas [data-source]");
    if (!target || !editor.view.dom.contains(target)) return;
    let position;
    try {
      position = editor.view.posAtDOM(target, 0);
    } catch {
      return;
    }
    if (editor.state.doc.nodeAt(position)?.type.name !== "blockedImage"
        && editor.state.doc.nodeAt(position - 1)?.type.name === "blockedImage") {
      position -= 1;
    }
    if (editor.state.doc.nodeAt(position)?.type.name !== "blockedImage") return;
    event.preventDefault();
    editor.view.dispatch(
      editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, position))
    );
    openImageEditor();
  });

  const handleImageEditorOutsideMouseDown = (event) => {
    if (imageEditor.hidden || imageEditor.contains(event.target)) return;
    closeImageEditor();
  };
  document.addEventListener("mousedown", handleImageEditorOutsideMouseDown, true);

  const handleLinkEditorViewportResize = () => {
    if (!linkEditor.hidden && linkEditorSession) {
      positionLinkEditor(linkEditorSession);
    }
    if (!imageEditor.hidden && imageEditorPosition != null) {
      positionImageEditor(imageEditorPosition);
    }
    if (!tableToolbar.hidden) positionTableToolbar();
    queueHeightMeasurement();
  };
  window.addEventListener("resize", handleLinkEditorViewportResize);
  const handleLinkEditorViewportScroll = () => {
    if (!linkEditor.hidden && linkEditorSession) positionLinkEditor(linkEditorSession);
  };
  renderer.addEventListener("scroll", handleLinkEditorViewportScroll, true);

  const contentObserver = typeof window.ResizeObserver === "function"
    ? new window.ResizeObserver(queueHeightMeasurement)
    : new window.MutationObserver(queueHeightMeasurement);
  if (typeof window.ResizeObserver === "function") {
    contentObserver.observe(editor.view.dom);
  } else {
    contentObserver.observe(editor.view.dom, { childList: true, subtree: true, characterData: true });
  }

  const replaceDocument = (nextMarkdown, preserveSelection, resetHistory) => {
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
      if (resetHistory) {
        editor.view.updateState(EditorState.create({
          schema: editor.schema,
          doc: editor.state.doc,
          selection: editor.state.selection,
          plugins: editor.state.plugins
        }));
      }
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

  const synchronizeSourceProjection = () => {
    if (!sourceProjectionDirty) return false;
    replaceDocument(sourceEditor.value, false, true);
    sourceProjectionDirty = false;
    sourceTransformUndoStack.length = 0;
    sourceTransformRedoStack.length = 0;
    return true;
  };

  const closeWritingPanels = ({ restoreFocus = false } = {}) => {
    closeLinkEditor({ restoreSelection: false });
    closeFind({ restoreFocus });
    closeOutline({ restoreFocus });
    closeImageEditor({ restoreSelection: false });
    hideTableControls();
  };

  const setEditorMode = (requestedMode, { focus = true } = {}) => {
    const nextMode = requestedMode === "source" ? "source" : "rich";
    if (nextMode === editorMode) {
      if (focus) {
        if (editorMode === "source") sourceEditor.focus({ preventScroll: true });
        else editor.commands.focus(undefined, { scrollIntoView: false });
      }
      return editorMode;
    }

    closeWritingPanels({ restoreFocus: false });
    flushMarkdownChanges();
    if (nextMode === "source") {
      sourceEditor.value = markdown;
      sourceProjectionDirty = false;
      renderer.hidden = true;
      sourceEditor.hidden = false;
      sourceModeChip.hidden = false;
      editorMode = "source";
      const start = Math.max(0, Math.min(sourceSelection.start, sourceEditor.value.length));
      const end = Math.max(start, Math.min(sourceSelection.end, sourceEditor.value.length));
      sourceEditor.setSelectionRange(start, end);
      if (focus) sourceEditor.focus({ preventScroll: true });
    } else {
      synchronizeSourceProjection();
      sourceEditor.hidden = true;
      sourceModeChip.hidden = true;
      renderer.hidden = false;
      editorMode = "rich";
      if (focus) editor.commands.focus(undefined, { scrollIntoView: false });
    }
    renderer.dataset.editorMode = editorMode;
    queueHeightMeasurement();
    refreshContextualControls();
    return editorMode;
  };

  const toggleEditorMode = () => setEditorMode(editorMode === "rich" ? "source" : "rich");
  sourceModeChip.addEventListener("click", () => setEditorMode("rich"));

  const render = (payload = {}) => {
    const nextCardID = payload.cardID == null ? null : String(payload.cardID);
    const nextRevision = Number(payload.revision ?? 0);
    const nextMarkdown = String(payload.markdown ?? "");
    const nextDocumentImagesAvailable = payload.documentImagesAvailable === true;
    const sameCard = nextCardID === currentCardID;
    const documentImageStateChanged = !sameCard
      || nextDocumentImagesAvailable !== documentImagesAvailable;
    const scrollTop = renderer.scrollTop;

    flushMarkdownChanges();

    if (!sameCard) {
      closeWritingPanels({ restoreFocus: false });
      sourceSelection = { start: 0, end: 0 };
    }

    if (payload.resolvedAppearance) applyAppearance(payload.resolvedAppearance);
    title = String(payload.title ?? "Untitled");
    document.title = title || "Untitled";

    const stalePayload = sameCard && nextRevision < currentRevision;
    const shouldReplaceDocument = !sameCard
      || (!stalePayload && (nextMarkdown !== markdown || nextRevision > currentRevision));
    currentCardID = nextCardID;
    documentImagesAvailable = nextDocumentImagesAvailable;
    renderer.dataset.cardId = currentCardID ?? "";
    document.documentElement.dataset.documentCardId = currentCardID ?? "";
    document.documentElement.dataset.documentImagesAvailable = documentImagesAvailable
      ? "true"
      : "false";

    if (shouldReplaceDocument) {
      cancelSerializationTimer();
      pendingMarkdownPost = false;
      markdown = nextMarkdown;
      currentRevision = Math.max(0, nextRevision);
      replaceDocument(nextMarkdown, sameCard, !sameCard);
      managedAttachmentsDirty = true;
      sourceProjectionDirty = false;
      sourceEditor.value = nextMarkdown;
      sourceTransformUndoStack.length = 0;
      sourceTransformRedoStack.length = 0;
      renderer.scrollTop = sameCard ? scrollTop : 0;
    }
    renderer.hidden = editorMode === "source";
    sourceEditor.hidden = editorMode !== "source";
    sourceModeChip.hidden = editorMode !== "source";
    renderer.dataset.editorMode = editorMode;
    reportManagedAttachments(!sameCard);
    queueHeightMeasurement();
    refreshFindPresentation(true);
    refreshOutlinePresentation();
    refreshContextualControls();
    if (documentImageStateChanged) {
      window.dispatchEvent(new window.CustomEvent(
        "markdowncard:document-assets-changed",
        { detail: { cardID: currentCardID, available: documentImagesAvailable } }
      ));
    }

    return {
      cardID: currentCardID,
      appearance: resolvedAppearance,
      empty: !markdown.trim(),
      revision: currentRevision,
      editorMode
    };
  };

  const dispatchSlashLifecycleEvent = (name) => {
    const event = new window.CustomEvent(name, { cancelable: true });
    document.dispatchEvent(event);
    return event.defaultPrevented;
  };

  const dismissSlashCommandMenu = () => {
    closeWritingPanels({ restoreFocus: false });
    return dispatchSlashLifecycleEvent("markdowncard:dismiss-slash-menu");
  };

  const resumeSlashCommandMenu = () => (
    dispatchSlashLifecycleEvent("markdowncard:resume-slash-menu")
  );

  const focusEditor = () => {
    if (editorMode === "source") {
      sourceEditor.focus({ preventScroll: true });
      const start = Math.max(0, Math.min(sourceSelection.start, sourceEditor.value.length));
      const end = Math.max(start, Math.min(sourceSelection.end, sourceEditor.value.length));
      sourceEditor.setSelectionRange(start, end);
      return true;
    }
    if (lastSelection) {
      const selection = clampSelection(editor, lastSelection);
      editor.chain().focus(undefined, { scrollIntoView: false }).setTextSelection(selection).run();
    } else {
      editor.commands.focus("end", { scrollIntoView: false });
    }
    resumeSlashCommandMenu();
    return true;
  };

  const setAppearance = (appearance) => applyAppearance(String(appearance ?? "dark").toLowerCase());

  const setDocumentImagesAvailable = (cardID, available) => {
    if (String(cardID ?? "") !== currentCardID) return false;
    const nextAvailable = available === true;
    if (nextAvailable === documentImagesAvailable) return true;
    documentImagesAvailable = nextAvailable;
    document.documentElement.dataset.documentImagesAvailable = nextAvailable ? "true" : "false";
    window.dispatchEvent(new window.CustomEvent(
      "markdowncard:document-assets-changed",
      { detail: { cardID: currentCardID, available: nextAvailable } }
    ));
    queueHeightMeasurement();
    return true;
  };

  const getMarkdownForCopy = (attachmentBaseURL) => {
    flushMarkdownChanges();
    if (editorMode === "source") {
      synchronizeSourceProjection();
    }
    if (managedAttachmentIDs(editor.getJSON()).length === 0) return markdown;
    return markdownForCopy(editor, attachmentBaseURL);
  };
  const getMarkdownExportBundle = () => {
    flushMarkdownChanges();
    if (editorMode === "source") {
      synchronizeSourceProjection();
    }
    return {
      markdown,
      attachmentIDs: managedAttachmentIDs(editor.getJSON())
    };
  };

  const completeImagePaste = (payload = {}) => {
    if (editorMode !== "rich") return false;
    const requestID = String(payload.requestID ?? "");
    const pending = pendingImagePastes.get(requestID);
    pendingImagePastes.delete(requestID);
    if (!pending || pending.cardID !== currentCardID) return false;
    const source = String(payload.source ?? "");
    if (payload.cardID !== currentCardID || !LOCAL_ATTACHMENT_PATTERN.test(source)) return false;

    const insertionPosition = Math.max(
      1,
      Math.min(Number(pending.position ?? editor.state.selection.from), editor.state.doc.content.size)
    );
    const inserted = editor.chain().focus().setTextSelection(insertionPosition).insertContent({
      type: "blockedImage",
      attrs: {
        src: source,
        alt: String(payload.alt ?? "Pasted image").slice(0, 200) || "Pasted image",
        title: null
      }
    }).run();
    if (inserted) {
      flushMarkdownChanges();
      queueHeightMeasurement();
    }
    return inserted;
  };

  const chooseSlashCommand = (id) => {
    const event = new window.CustomEvent("markdowncard:choose-slash-command", {
      detail: { id: String(id ?? "") },
      cancelable: true
    });
    document.dispatchEvent(event);
    return event.defaultPrevented;
  };

  applyAppearance(requestedAppearance);

  const onSystemAppearanceChange = () => {
    if (requestedAppearance === "system") applyAppearance("system");
  };
  systemQuery?.addEventListener?.("change", onSystemAppearanceChange);

  const handleDocumentKeyDown = (event) => {
    if (isIMECompositionEvent(event, editor.view)) return;
    const key = event.key.toLowerCase();
    if (
      event.ctrlKey
      && !event.metaKey
      && !event.altKey
      && !event.shiftKey
      && event.key === "Enter"
      && focusTableControlsFromKeyboard()
    ) {
      event.preventDefault();
      return;
    }
    if (event.metaKey && event.shiftKey && !event.altKey && !event.ctrlKey && key === "m") {
      event.preventDefault();
      toggleEditorMode();
      return;
    }
    if (event.metaKey && !event.shiftKey && !event.ctrlKey && key === "f") {
      event.preventDefault();
      openFind({ showReplace: event.altKey });
      return;
    }
    if (event.metaKey && event.shiftKey && !event.altKey && !event.ctrlKey && key === "o") {
      event.preventDefault();
      toggleOutline();
      return;
    }
    if (
      event.key === "Enter"
      && !event.metaKey
      && !event.altKey
      && !event.ctrlKey
      && !event.shiftKey
      && document.activeElement === editor.view.dom
      && openImageEditor()
    ) {
      event.preventDefault();
      return;
    }
    if (event.key === "Escape" && !linkEditor.hidden) {
      event.preventDefault();
      closeLinkEditor();
      return;
    }
    if (event.key === "Escape" && !findPanel.hidden) {
      event.preventDefault();
      closeFind();
      return;
    }
    if (event.key === "Escape" && !outlinePanel.hidden) {
      event.preventDefault();
      closeOutline();
      return;
    }
    if (event.key === "Escape" && !imageEditor.hidden) {
      event.preventDefault();
      closeImageEditor();
      return;
    }
    if (event.key === "Escape" && !event.defaultPrevented) {
      event.preventDefault();
      postNative(window, { type: "hideRequested", cardID: currentCardID });
    }
  };
  document.addEventListener("keydown", handleDocumentKeyDown);

  const api = {
    protocolVersion: 3,
    render,
    focusEditor,
    setAppearance,
    setDocumentImagesAvailable,
    setEditorMode,
    toggleEditorMode,
    flushMarkdownChanges,
    getMarkdownForCopy,
    getMarkdownExportBundle,
    openFind,
    closeFind,
    moveFindMatch,
    replaceCurrentMatch,
    replaceAllMatches,
    openOutline,
    closeOutline,
    toggleOutline,
    getOutline,
    jumpToHeading,
    openImageEditor,
    completeImagePaste,
    chooseSlashCommand,
    dismissSlashCommandMenu,
    measureContentHeight,
    getState() {
      flushMarkdownChanges();
      return {
        cardID: currentCardID,
        requestedAppearance,
        resolvedAppearance,
        markdown,
        title,
        revision: currentRevision,
        selection: editorMode === "source" ? sourceSelection : lastSelection,
        editorMode,
        documentImagesAvailable,
        lastSerializationMs,
        serializationCount,
        attachmentScanCount,
        pendingMarkdownPost,
        editorJSON: editor.getJSON()
      };
    },
    peekState() {
      return {
        cardID: currentCardID,
        markdown,
        revision: currentRevision,
        editorMode,
        documentImagesAvailable,
        lastSerializationMs,
        serializationCount,
        attachmentScanCount,
        pendingMarkdownPost
      };
    },
    getEditor() {
      return editor;
    },
    destroy() {
      flushMarkdownChanges();
      closeLinkEditor({ restoreSelection: false });
      closeFind({ restoreFocus: false });
      closeOutline({ restoreFocus: false });
      closeImageEditor({ restoreSelection: false });
      systemQuery?.removeEventListener?.("change", onSystemAppearanceChange);
      document.removeEventListener("markdowncard:open-external", handlePluginExternal);
      document.removeEventListener("markdowncard:edit-link", handleLinkEditorRequest);
      document.removeEventListener("markdowncard:heading-link-repair", handleHeadingLinkRepair);
      document.removeEventListener("mousedown", handleLinkEditorOutsideMouseDown, true);
      document.removeEventListener("mousedown", handleImageEditorOutsideMouseDown, true);
      document.removeEventListener("keydown", handleDocumentKeyDown);
      document.removeEventListener("compositionstart", handleLinkCompositionStart, true);
      renderer.removeEventListener("mouseover", handleRichLinkMouseOver);
      renderer.removeEventListener("mouseout", handleRichLinkMouseOut);
      renderer.removeEventListener("keydown", handleLinkKeyboardActivation);
      renderer.removeEventListener("scroll", handleTableControlsScroll, true);
      renderer.removeEventListener("scroll", handleLinkEditorViewportScroll, true);
      window.removeEventListener("resize", handleLinkEditorViewportResize);
      for (const cleanup of tableHandleDragCleanups) cleanup();
      linkEditor.remove();
      findPanel.remove();
      outlinePanel.remove();
      tableToolbar.remove();
      imageEditor.remove();
      sourceModeChip.remove();
      headingLinkStatus.remove();
      sourceEditor.remove();
      contentObserver.disconnect();
      pendingImagePastes.clear();
      removeCompositionGuard?.();
      cancelSerializationTimer();
      if (headingLinkStatusTimer != null) {
        window.clearTimeout(headingLinkStatusTimer);
        headingLinkStatusTimer = null;
      }
      if (heightFrame != null) {
        const cancelFrame = window.cancelAnimationFrame?.bind(window)
          ?? window.clearTimeout?.bind(window);
        cancelFrame?.(heightFrame);
        heightFrame = null;
      }
      editor.destroy();
      document.removeEventListener(
        "markdowncard:slash-menu-change",
        handleSlashCommandMenuChange
      );
    }
  };

  window.MarkdownCard = api;
  window.markdownCard = api;
  postNative(window, { type: "rendererReady", protocolVersion: 3 });
  return api;
}
