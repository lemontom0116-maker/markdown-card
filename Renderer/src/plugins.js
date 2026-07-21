import { Extension, Node, mergeAttributes } from "@tiptap/core";
import { createTable } from "@tiptap/extension-table";
import { Fragment } from "@tiptap/pm/model";
import { Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import { isIMECompositionEvent } from "./input-guards.js";

const VIDEO_ID_PATTERN = /^[A-Za-z0-9_-]{11}$/;
const YOUTUBE_MARKDOWN_PATTERN = /^\[!\[YouTube video\]\(https:\/\/i\.ytimg\.com\/vi\/([A-Za-z0-9_-]{11})\/hqdefault\.jpg\)\]\(https:\/\/www\.youtube\.com\/watch\?v=\1\)(?:\n|$)/;
const TAG_COMMAND_PATTERN = /^\/tag[\t ]+(.+)$/iu;
const TAG_FORBIDDEN_CHARACTER_PATTERN = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/u;
const tagCommandMetaKey = new PluginKey("markdownCardTagCommand");

function graphemeCount(value) {
  if (typeof Intl?.Segmenter === "function") {
    return [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(value)].length;
  }
  return [...value].length;
}

export function normalizeTagCommandName(value) {
  const raw = String(value ?? "");
  if (TAG_FORBIDDEN_CHARACTER_PATTERN.test(raw)) return null;
  const normalized = raw.normalize("NFC").trim().replace(/\s+/gu, " ");
  if (!normalized || graphemeCount(normalized) > 64) return null;
  if (new TextEncoder().encode(normalized).byteLength > 256) return null;
  return normalized;
}

export function tagCommandFromTransaction(transaction) {
  const payload = transaction?.getMeta?.(tagCommandMetaKey);
  const tagName = normalizeTagCommandName(payload?.tagName);
  return tagName ? { tagName } : null;
}

export function parseYouTubeURL(value) {
  let url;
  try {
    url = new URL(String(value ?? "").trim());
  } catch {
    return null;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;

  const host = url.hostname.toLowerCase().replace(/^www\./, "").replace(/^m\./, "");
  let videoID = null;
  if (host === "youtu.be") {
    videoID = url.pathname.split("/").filter(Boolean)[0] ?? null;
  } else if (host === "youtube.com") {
    if (url.pathname === "/watch") {
      videoID = url.searchParams.get("v");
    } else {
      const parts = url.pathname.split("/").filter(Boolean);
      if (["shorts", "embed"].includes(parts[0])) videoID = parts[1] ?? null;
    }
  }

  if (!videoID || !VIDEO_ID_PATTERN.test(videoID)) return null;
  return {
    videoID,
    url: `https://www.youtube.com/watch?v=${videoID}`,
    thumbnailURL: `https://i.ytimg.com/vi/${videoID}/hqdefault.jpg`
  };
}

export function youtubeMarkdown(videoID) {
  if (!VIDEO_ID_PATTERN.test(String(videoID ?? ""))) return "";
  return `[![YouTube video](https://i.ytimg.com/vi/${videoID}/hqdefault.jpg)](https://www.youtube.com/watch?v=${videoID})`;
}

const YouTubeCard = Node.create({
  name: "youtubeCard",
  group: "block",
  atom: true,
  selectable: true,
  draggable: false,

  addAttributes() {
    return {
      videoID: { default: "" },
      url: { default: "" }
    };
  },

  parseHTML() {
    return [{ tag: 'div[data-type="youtubeCard"]' }];
  },

  renderHTML({ HTMLAttributes }) {
    return ["div", mergeAttributes(HTMLAttributes, {
      "data-type": "youtubeCard",
      "data-video-id": HTMLAttributes.videoID,
      "data-external-url": HTMLAttributes.url
    })];
  },

  markdownTokenName: "youtubeCard",
  markdownTokenizer: {
    name: "youtubeCard",
    level: "block",
    start: (source) => source.indexOf("[![YouTube video]") ,
    tokenize: (source) => {
      const match = source.match(YOUTUBE_MARKDOWN_PATTERN);
      if (!match) return undefined;
      return {
        type: "youtubeCard",
        raw: match[0],
        videoID: match[1],
        url: `https://www.youtube.com/watch?v=${match[1]}`
      };
    }
  },
  parseMarkdown(token) {
    return {
      type: "youtubeCard",
      attrs: {
        videoID: String(token.videoID ?? ""),
        url: String(token.url ?? "")
      }
    };
  },
  renderMarkdown(node) {
    return youtubeMarkdown(node.attrs?.videoID);
  },

  addNodeView() {
    return ({ node }) => {
      const wrapper = document.createElement("div");
      wrapper.className = "youtube-card";
      wrapper.dataset.type = "youtubeCard";
      wrapper.dataset.videoId = node.attrs.videoID;
      wrapper.dataset.externalUrl = node.attrs.url;
      wrapper.setAttribute("role", "link");
      wrapper.setAttribute("aria-label", "YouTube video cover");
      wrapper.setAttribute("title", "Open YouTube video");

      const image = document.createElement("img");
      image.className = "youtube-card-image";
      image.src = `mdcard-asset://youtube/${node.attrs.videoID}`;
      image.alt = "YouTube video";
      image.draggable = false;

      const fallback = document.createElement("div");
      fallback.className = "youtube-card-fallback";
      fallback.textContent = "YouTube video";
      fallback.hidden = true;

      const play = document.createElement("span");
      play.className = "youtube-card-play";
      play.setAttribute("aria-hidden", "true");

      image.addEventListener("error", () => {
        image.hidden = true;
        fallback.hidden = false;
        wrapper.classList.add("has-error");
      });
      image.addEventListener("load", () => wrapper.classList.add("is-loaded"));

      const openVideo = (event) => {
        if (event.button !== 0) return;
        event.preventDefault();
        event.stopPropagation();
        const EventType = wrapper.ownerDocument.defaultView.CustomEvent;
        wrapper.dispatchEvent(new EventType("markdowncard:open-external", {
          bubbles: true,
          detail: { url: node.attrs.url }
        }));
      };
      wrapper.addEventListener("click", openVideo);
      wrapper.append(image, fallback, play);

      return {
        dom: wrapper,
        stopEvent(event) {
          return event.type === "click";
        },
        destroy() {
          wrapper.removeEventListener("click", openVideo);
        }
      };
    };
  }
});

export const rendererPluginRegistry = Object.freeze([
  Object.freeze({
    id: "youtube",
    command: "youtube",
    title: "YouTube",
    description: "Add a video cover",
    kind: "blockNode",
    parseInput: parseYouTubeURL,
    nodeName: "youtubeCard"
  }),
  Object.freeze({
    id: "table",
    command: "table",
    title: "Table",
    description: "Insert a 3 × 3 table",
    kind: "editorCommand",
    topLevelOnly: true
  }),
  Object.freeze({
    id: "tag",
    command: "tag",
    title: "Tag",
    description: "Add to a card series",
    kind: "metadataCommand",
    parseInput: normalizeTagCommandName,
    topLevelOnly: true
  })
]);

function slashContext(state) {
  const { $from, empty } = state.selection;
  if (!empty || $from.parent.type.name !== "paragraph") return null;
  const textBefore = $from.parent.textBetween(0, $from.parentOffset, "", "");
  const match = textBefore.match(/^\/([A-Za-z]*)$/);
  if (!match) return null;
  return {
    from: $from.start(),
    to: state.selection.from,
    query: match[1].toLowerCase(),
    topLevel: $from.depth === 1
  };
}

function matchingPlugins(query, context) {
  return rendererPluginRegistry.filter((plugin) => (
    plugin.command.startsWith(query)
      && (!plugin.topLevelOnly || context?.topLevel === true)
  ));
}

function insertDefaultTable(state, dispatch, context) {
  const { $from } = state.selection;
  if (!context?.topLevel || $from.parent.type.name !== "paragraph") return false;
  const paragraphPosition = $from.before($from.depth);
  const paragraph = $from.parent;
  const table = createTable(state.schema, 3, 3, true);
  const isLastNode = paragraphPosition + paragraph.nodeSize >= state.doc.content.size;
  const replacement = isLastNode
    ? Fragment.fromArray([table, state.schema.nodes.paragraph.create()])
    : table;
  const transaction = state.tr.replaceWith(
    paragraphPosition,
    paragraphPosition + paragraph.nodeSize,
    replacement
  );
  const firstCellPosition = Math.min(
    transaction.doc.content.size,
    paragraphPosition + 4
  );
  transaction.setSelection(TextSelection.near(transaction.doc.resolve(firstCellPosition)));
  transaction.setMeta("markdownCardImmediate", true);
  dispatch?.(transaction.scrollIntoView());
  return true;
}

function tagCommandAt(state, position) {
  const { $from, empty } = state.selection;
  if (!empty || $from.depth !== 1) return null;
  const node = state.doc.nodeAt(position);
  if (
    node?.type.name !== "paragraph"
    || $from.parent !== node
    || $from.parentOffset !== node.content.size
    || node.content.content.some((child) => !child.isText)
  ) {
    return null;
  }
  const match = node.textContent.match(TAG_COMMAND_PATTERN);
  if (!match) return null;
  const tagName = normalizeTagCommandName(match[1]);
  return tagName ? { node, tagName } : null;
}

function submitTagCommand(state, dispatch, position, command) {
  if (!command) return false;
  const transaction = state.tr;
  if (state.doc.childCount === 1) {
    transaction.replaceWith(
      position,
      position + command.node.nodeSize,
      state.schema.nodes.paragraph.create()
    );
  } else {
    transaction.delete(position, position + command.node.nodeSize);
  }
  const selectionPosition = Math.min(position, transaction.doc.content.size);
  transaction.setSelection(TextSelection.near(transaction.doc.resolve(selectionPosition)));
  transaction.setMeta(tagCommandMetaKey, { tagName: command.tagName });
  transaction.setMeta("addToHistory", false);
  dispatch?.(transaction.scrollIntoView());
  return true;
}

function paragraphPluginAt(state, position) {
  const node = state.doc.nodeAt(position);
  if (node?.type.name !== "paragraph") return null;
  const match = node.textContent.match(/^\/youtube\s+(\S+)\s*$/i);
  if (!match) return null;
  const youtube = parseYouTubeURL(match[1]);
  return youtube ? { node, youtube } : null;
}

function standaloneYouTubeAt(state, position) {
  const node = state.doc.nodeAt(position);
  if (node?.type.name !== "paragraph") return null;
  const source = node.textContent.trim();
  if (!source || source !== node.textContent) return null;
  const youtube = parseYouTubeURL(source);
  return youtube ? { node, youtube } : null;
}

function pluginPasteTarget(state) {
  const { $from, $to } = state.selection;
  if ($from.parent !== $to.parent || $from.parent.type.name !== "paragraph") return null;
  if (!/^\/youtube\s*$/i.test($from.parent.textContent)) return null;
  return {
    node: $from.parent,
    position: $from.before($from.depth)
  };
}

function replaceParagraphWithYouTube(state, dispatch, position, match) {
  if (!match) return false;
  const youtubeNode = state.schema.nodes.youtubeCard.create(match.youtube);
  const isLastNode = position + match.node.nodeSize >= state.doc.content.size;
  const replacement = isLastNode
    ? Fragment.fromArray([youtubeNode, state.schema.nodes.paragraph.create()])
    : youtubeNode;
  const transaction = state.tr.replaceWith(position, position + match.node.nodeSize, replacement);
  const nextPosition = Math.min(
    transaction.doc.content.size,
    position + youtubeNode.nodeSize + (isLastNode ? 1 : 0)
  );
  transaction.setSelection(TextSelection.near(transaction.doc.resolve(nextPosition)));
  dispatch?.(transaction.scrollIntoView());
  return true;
}

function convertPluginParagraph(state, dispatch, position) {
  return replaceParagraphWithYouTube(
    state,
    dispatch,
    position,
    paragraphPluginAt(state, position)
  );
}

const slashPluginKey = new PluginKey("markdownCardSlashPlugins");

const SlashPluginMenu = Extension.create({
  name: "slashPluginMenu",
  priority: 120,

  addProseMirrorPlugins() {
    let selectedIndex = 0;
    let dismissedSignature = null;
    let menuElement = null;
    let lastPresentationSignature = null;
    let lastPresentationHandledNatively = false;

    const choose = (view, plugin) => {
      const context = slashContext(view.state);
      if (!context || !plugin || (plugin.topLevelOnly && !context.topLevel)) return false;
      if (plugin.kind === "editorCommand" && plugin.id === "table") {
        return insertDefaultTable(view.state, view.dispatch, context);
      }
      view.dispatch(view.state.tr.insertText(`/${plugin.command} `, context.from, context.to));
      view.focus();
      return true;
    };

    const dispatchPresentation = (view, presentation) => {
      const signature = JSON.stringify(presentation);
      if (signature === lastPresentationSignature) {
        return lastPresentationHandledNatively;
      }
      const ownerDocument = view.dom.ownerDocument;
      const EventType = ownerDocument.defaultView.CustomEvent;
      const event = new EventType("markdowncard:slash-menu-change", {
        detail: presentation,
        bubbles: false,
        cancelable: true
      });
      ownerDocument.dispatchEvent(event);
      lastPresentationSignature = signature;
      lastPresentationHandledNatively = event.defaultPrevented;
      return lastPresentationHandledNatively;
    };

    const hideMenu = (view) => {
      menuElement?.replaceChildren();
      menuElement?.setAttribute("hidden", "");
      dispatchPresentation(view, { visible: false });
    };

    return [new Plugin({
      key: slashPluginKey,
      props: {
        handlePaste(view, event) {
          const source = event.clipboardData?.getData("text/plain")?.trim() ?? "";
          const youtube = parseYouTubeURL(source);
          if (!youtube) return false;
          const pluginTarget = pluginPasteTarget(view.state);
          if (pluginTarget) {
            event.preventDefault();
            return replaceParagraphWithYouTube(
              view.state,
              view.dispatch,
              pluginTarget.position,
              { node: pluginTarget.node, youtube }
            );
          }
          const { selection } = view.state;
          const { $from, $to } = selection;
          let paragraph = null;
          let paragraphPosition = null;
          if ($from.parent === $to.parent && $from.parent.type.name === "paragraph") {
            const coversParagraph = $from.parent.content.size === 0
              || ($from.parentOffset === 0 && $to.parentOffset === $from.parent.content.size);
            if (coversParagraph) {
              paragraph = $from.parent;
              paragraphPosition = $from.before($from.depth);
            }
          } else if (
            view.state.doc.childCount === 1
            && view.state.doc.firstChild?.type.name === "paragraph"
            && selection.from === 0
            && selection.to === view.state.doc.content.size
          ) {
            paragraph = view.state.doc.firstChild;
            paragraphPosition = 0;
          }
          if (!paragraph || paragraphPosition == null) return false;
          event.preventDefault();
          return replaceParagraphWithYouTube(
            view.state,
            view.dispatch,
            paragraphPosition,
            { node: paragraph, youtube }
          );
        },
        handleKeyDown(view, event) {
          if (isIMECompositionEvent(event, view)) return false;
          const context = slashContext(view.state);
          if (event.key === "Enter") {
            const paragraphPosition = view.state.selection.$from.before();
            if (submitTagCommand(
              view.state,
              view.dispatch,
              paragraphPosition,
              tagCommandAt(view.state, paragraphPosition)
            )) {
              event.preventDefault();
              return true;
            }
            if (convertPluginParagraph(view.state, view.dispatch, paragraphPosition)) return true;
            const { selection } = view.state;
            const { $from } = selection;
            const canFinishStandaloneURL = selection.empty
              && $from.parent.type.name === "paragraph"
              && $from.parentOffset === $from.parent.content.size;
            if (canFinishStandaloneURL && replaceParagraphWithYouTube(
              view.state,
              view.dispatch,
              paragraphPosition,
              standaloneYouTubeAt(view.state, paragraphPosition)
            )) {
              event.preventDefault();
              return true;
            }
          }
          if (!context) return false;
          const signature = `${context.from}:${context.to}:${context.query}`;
          if (dismissedSignature === signature) return false;
          const plugins = matchingPlugins(context.query, context);
          if (!plugins.length) return false;
          if (event.key === "ArrowDown") {
            event.preventDefault();
            selectedIndex = (selectedIndex + 1) % plugins.length;
            slashPluginKey.getState(view.state)?.refresh?.();
            return true;
          }
          if (event.key === "ArrowUp") {
            event.preventDefault();
            selectedIndex = (selectedIndex - 1 + plugins.length) % plugins.length;
            slashPluginKey.getState(view.state)?.refresh?.();
            return true;
          }
          if (event.key === "Enter") {
            event.preventDefault();
            return choose(view, plugins[selectedIndex] ?? plugins[0]);
          }
          if (event.key === "Escape") {
            event.preventDefault();
            dismissedSignature = signature;
            hideMenu(view);
            return true;
          }
          return false;
        }
      },
      state: {
        init: () => ({ refresh: () => {} }),
        apply: (_transaction, value) => value
      },
      view(editorView) {
        menuElement = document.createElement("div");
        menuElement.className = "slash-plugin-menu";
        menuElement.setAttribute("role", "listbox");
        menuElement.hidden = true;
        document.body.appendChild(menuElement);

        const render = (view) => {
          const context = slashContext(view.state);
          const signature = context ? `${context.from}:${context.to}:${context.query}` : null;
          if (!context || dismissedSignature === signature) {
            hideMenu(view);
            return;
          }
          if (dismissedSignature && dismissedSignature !== signature) dismissedSignature = null;
          const plugins = matchingPlugins(context.query, context);
          if (!plugins.length) {
            hideMenu(view);
            return;
          }
          selectedIndex = Math.min(selectedIndex, plugins.length - 1);
          let anchor;
          try {
            const coordinates = view.coordsAtPos(context.to);
            anchor = {
              left: coordinates.left,
              top: coordinates.top,
              bottom: coordinates.bottom
            };
          } catch {
            anchor = { left: 24, top: 54, bottom: 66 };
          }
          const handledNatively = dispatchPresentation(view, {
            visible: true,
            selectedIndex,
            anchor,
            items: plugins.map((plugin) => ({
              id: plugin.id,
              title: plugin.title,
              description: plugin.description
            }))
          });
          if (handledNatively) {
            menuElement.hidden = true;
            menuElement.replaceChildren();
            return;
          }
          menuElement.replaceChildren();
          plugins.forEach((plugin, index) => {
            const item = document.createElement("button");
            item.type = "button";
            item.className = "slash-plugin-item";
            item.dataset.pluginId = plugin.id;
            item.setAttribute("role", "option");
            item.setAttribute("aria-selected", index === selectedIndex ? "true" : "false");
            const title = document.createElement("strong");
            title.textContent = plugin.title;
            const description = document.createElement("span");
            description.textContent = plugin.description;
            item.append(title, description);
            item.addEventListener("mousedown", (event) => {
              event.preventDefault();
              choose(view, plugin);
            });
            menuElement.appendChild(item);
          });
          menuElement.hidden = false;
          menuElement.style.left = `${Math.max(12, anchor.left)}px`;
          menuElement.style.top = `${anchor.bottom + 6}px`;
        };

        const chooseFromNativePanel = (event) => {
          const context = slashContext(editorView.state);
          if (!context) return;
          const pluginID = String(event.detail?.id ?? "");
          const plugin = matchingPlugins(context.query, context).find(
            (candidate) => candidate.id === pluginID
          );
          if (choose(editorView, plugin)) event.preventDefault();
        };
        const dismissFromNative = (event) => {
          const context = slashContext(editorView.state);
          dismissedSignature = context
            ? `${context.from}:${context.to}:${context.query}`
            : null;
          hideMenu(editorView);
          event.preventDefault();
        };
        const resumeFromNative = () => {
          dismissedSignature = null;
          render(editorView);
        };
        const refreshPosition = () => render(editorView);
        const scrollContainer = editorView.dom.closest("#renderer");
        const ownerWindow = editorView.dom.ownerDocument.defaultView;
        editorView.dom.ownerDocument.addEventListener(
          "markdowncard:choose-slash-command",
          chooseFromNativePanel
        );
        editorView.dom.ownerDocument.addEventListener(
          "markdowncard:dismiss-slash-menu",
          dismissFromNative
        );
        editorView.dom.ownerDocument.addEventListener(
          "markdowncard:resume-slash-menu",
          resumeFromNative
        );
        scrollContainer?.addEventListener("scroll", refreshPosition, { passive: true });
        ownerWindow.addEventListener("resize", refreshPosition);

        slashPluginKey.getState(editorView.state).refresh = () => render(editorView);
        render(editorView);
        return {
          update: render,
          destroy() {
            hideMenu(editorView);
            editorView.dom.ownerDocument.removeEventListener(
              "markdowncard:choose-slash-command",
              chooseFromNativePanel
            );
            editorView.dom.ownerDocument.removeEventListener(
              "markdowncard:dismiss-slash-menu",
              dismissFromNative
            );
            editorView.dom.ownerDocument.removeEventListener(
              "markdowncard:resume-slash-menu",
              resumeFromNative
            );
            scrollContainer?.removeEventListener("scroll", refreshPosition);
            ownerWindow.removeEventListener("resize", refreshPosition);
            menuElement?.remove();
            menuElement = null;
          }
        };
      }
    })];
  }
});

export function createRendererPluginExtensions() {
  return [YouTubeCard, SlashPluginMenu];
}
