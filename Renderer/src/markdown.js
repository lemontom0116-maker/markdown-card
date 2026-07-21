import { Extension, InputRule, Node, mergeAttributes, textblockTypeInputRule } from "@tiptap/core";
import { CodeBlockLowlight } from "@tiptap/extension-code-block-lowlight";
import { Link, isAllowedUri as isAllowedLinkUri } from "@tiptap/extension-link";
import { TaskItem, TaskList } from "@tiptap/extension-list";
import { TableKit } from "@tiptap/extension-table";
import { Placeholder } from "@tiptap/extensions";
import { Markdown } from "@tiptap/markdown";
import { Fragment } from "@tiptap/pm/model";
import { NodeSelection, Plugin, TextSelection } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import { StarterKit } from "@tiptap/starter-kit";
import katex from "katex";
import { common, createLowlight } from "lowlight";
import { editorIsComposing, isIMECompositionEvent } from "./input-guards.js";
import { mermaidAccessibleLabel, renderMermaidInto } from "./mermaid-renderer.js";
import {
  headingFragmentRepairPlan,
  outlineWithFragments,
  richDocumentOutline
} from "./writing-tools.js";
import {
  documentImagePresentation,
  managedAttachmentID
} from "./document-images.js";
import { createRendererPluginExtensions, parseYouTubeURL } from "./plugins.js";
import { renderSmartLinkIcon } from "./smart-link-icons.js";

const EXTERNAL_PROTOCOL = /^(https?:|mailto:)/i;
const lowlight = createLowlight(common);
const explicitLowlight = {
  highlight: lowlight.highlight.bind(lowlight),
  highlightAuto(value) {
    return { type: "root", children: [{ type: "text", value }] };
  },
  listLanguages: lowlight.listLanguages.bind(lowlight),
  registered: lowlight.registered?.bind(lowlight)
};
const LANGUAGE_ALIASES = new Map([
  ["py", "python"],
  ["python3", "python"],
  ["js", "javascript"],
  ["jsx", "javascript"],
  ["ts", "typescript"],
  ["tsx", "typescript"],
  ["c++", "cpp"],
  ["cc", "cpp"],
  ["sh", "bash"],
  ["zsh", "bash"],
  ["shell", "bash"],
  ["objc", "objectivec"],
  ["objective-c", "objectivec"],
  ["md", "markdown"],
  ["yml", "yaml"],
  ["rs", "rust"]
]);

function fencedCodeSource(token) {
  const firstLine = String(token?.raw ?? "").split(/\r?\n/u, 1)[0];
  const match = firstLine.match(/^ {0,3}(`{3,}|~{3,})(.*)$/u);
  if (!match) return { fence: null, info: null };
  return {
    fence: match[1],
    info: match[2].trim() || null
  };
}

export function normalizeCodeLanguage(value) {
  const language = String(value ?? "")
    .trim()
    .split(/\s+/, 1)[0]
    .toLowerCase();
  return LANGUAGE_ALIASES.get(language) ?? language;
}

export function codeBlockDisplayTitle(value) {
  const info = String(value ?? "").trim();
  const match = info.match(/(?:^|\s)title=(?:"((?:\\.|[^"])*)"|'((?:\\.|[^'])*)'|([^\s]+))/u);
  if (!match) return null;
  const title = String(match[1] ?? match[2] ?? match[3] ?? "")
    .replace(/\\([\\"'])/gu, "$1")
    .trim();
  return title ? title.slice(0, 160) : null;
}

function codeBlockAccessibilityLabel(language, title) {
  const description = [title, language ? `${language} code block` : "Code block"]
    .filter(Boolean)
    .join(", ");
  return `${description}. Press Command-Return at the end to exit.`;
}

function applyCodeBlockPresentation(element, node) {
  const language = normalizeCodeLanguage(node.attrs?.language);
  const title = codeBlockDisplayTitle(node.attrs?.sourceInfo);
  if (language) element.dataset.language = language;
  else delete element.dataset.language;
  if (title) element.dataset.codeTitle = title;
  else delete element.dataset.codeTitle;
  element.setAttribute("aria-label", codeBlockAccessibilityLabel(language, title));
}

function decodedInternalFragment(value) {
  const href = String(value ?? "");
  if (!href.startsWith("#")) return null;
  try {
    return decodeURIComponent(href.slice(1)) || null;
  } catch {
    return null;
  }
}

function replacementFragmentHref(originalHref, fragment) {
  return /%[0-9A-F]{2}/iu.test(String(originalHref ?? ""))
    ? `#${encodeURIComponent(fragment)}`
    : `#${fragment}`;
}

function internalFragmentTargets(documentNode) {
  const targets = new Set();
  documentNode?.descendants((node) => {
    if (!node.isText) return;
    for (const mark of node.marks ?? []) {
      if (mark.type.name !== "link") continue;
      const fragment = decodedInternalFragment(mark.attrs?.href);
      if (fragment) targets.add(fragment);
    }
  });
  return targets;
}

function transactionIsConfinedToHeading(transaction, previousHeading, nextHeading, previousDoc, nextDoc) {
  if (!transaction?.docChanged || !previousHeading || !nextHeading) return false;
  const previousStart = previousHeading.position - 1;
  const nextStart = nextHeading.position - 1;
  const previousNode = previousDoc.nodeAt(previousStart);
  const nextNode = nextDoc.nodeAt(nextStart);
  if (previousNode?.type.name !== "heading" || nextNode?.type.name !== "heading") return false;
  const previousEnd = previousStart + previousNode.nodeSize;
  const nextEnd = nextStart + nextNode.nodeSize;
  for (const step of transaction.steps) {
    const serialized = step.toJSON?.() ?? {};
    if (!Number.isInteger(serialized.from) || !Number.isInteger(serialized.to)) continue;
    const insidePrevious = serialized.from >= previousStart && serialized.to <= previousEnd;
    const insideNext = serialized.from >= nextStart && serialized.to <= nextEnd;
    if (!insidePrevious && !insideNext) return false;
  }
  let sawRange = false;
  let confined = true;
  for (const stepMap of transaction.mapping.maps) {
    stepMap.forEach((oldStart, oldEnd, newStart, newEnd) => {
      sawRange = true;
      if (oldStart < previousStart || oldEnd > previousEnd
          || newStart < nextStart || newEnd > nextEnd) {
        confined = false;
      }
    });
  }
  return sawRange && confined;
}

function announceHeadingLinkRepair(editor, detail) {
  const ownerDocument = editor.view?.dom?.ownerDocument;
  const CustomEventType = ownerDocument?.defaultView?.CustomEvent;
  if (!ownerDocument || !CustomEventType) return;
  ownerDocument.dispatchEvent(new CustomEventType("markdowncard:heading-link-repair", { detail }));
}

const HeadingLinkRepair = Extension.create({
  name: "headingLinkRepair",

  addProseMirrorPlugins() {
    const editor = this.editor;
    return [new Plugin({
      appendTransaction(transactions, oldState, newState) {
        if (!transactions.some((transaction) => transaction.docChanged)
            || transactions.some((transaction) => (
              Object.keys(transaction.meta ?? {}).some((key) => key.startsWith("history$"))
            ))
            || transactions.some((transaction) => transaction.getMeta("markdownCardHeadingLinkRepair"))) {
          return null;
        }

        const previousHeadings = richDocumentOutline(oldState.doc);
        const nextHeadings = richDocumentOutline(newState.doc);
        const repair = headingFragmentRepairPlan(previousHeadings, nextHeadings);
        const previousTargets = internalFragmentTargets(oldState.doc);
        if (repair.kind === "none") return null;

        if (repair.kind !== "safe") {
          const hadHeadingTarget = outlineWithFragments(previousHeadings).some(
            (heading) => previousTargets.has(heading.fragment)
          );
          if (hadHeadingTarget) {
            announceHeadingLinkRepair(editor, {
              kind: "warning",
              message: "Heading links were kept unchanged because this edit changed the outline ambiguously."
            });
          }
          return null;
        }

        const changes = new Map(repair.changes.map((change) => [change.from, change.to]));
        const updates = [];
        newState.doc.descendants((node, position) => {
          if (!node.isText) return;
          for (const mark of node.marks ?? []) {
            if (mark.type.name !== "link") continue;
            const oldFragment = decodedInternalFragment(mark.attrs?.href);
            const newFragment = changes.get(oldFragment);
            if (!newFragment) continue;
            updates.push({
              from: position,
              to: position + node.nodeSize,
              mark,
              href: replacementFragmentHref(mark.attrs?.href, newFragment)
            });
          }
        });
        if (!updates.length) return null;

        const docTransactions = transactions.filter((transaction) => transaction.docChanged);
        const changedIndex = repair.changedIndex;
        const confined = docTransactions.length === 1 && transactionIsConfinedToHeading(
          docTransactions[0],
          previousHeadings[changedIndex],
          nextHeadings[changedIndex],
          oldState.doc,
          newState.doc
        );
        if (!confined) {
          announceHeadingLinkRepair(editor, {
            kind: "warning",
            message: "Heading links were kept unchanged because the same edit also changed other content."
          });
          return null;
        }

        const transaction = newState.tr;
        for (const update of updates) {
          transaction.removeMark(update.from, update.to, update.mark);
          transaction.addMark(
            update.from,
            update.to,
            update.mark.type.create({ ...update.mark.attrs, href: update.href })
          );
        }
        transaction.setMeta("markdownCardHeadingLinkRepair", true);
        announceHeadingLinkRepair(editor, {
          kind: "repaired",
          message: `${updates.length} internal heading link${updates.length === 1 ? "" : "s"} updated.`
        });
        return transaction;
      }
    })];
  }
});

const LanguageCodeBlock = CodeBlockLowlight.extend({
  addAttributes() {
    return {
      ...(this.parent?.() ?? {}),
      sourceInfo: { default: null, rendered: false },
      sourceFence: { default: null, rendered: false }
    };
  },

  parseMarkdown(token, helpers) {
    if (
      token.raw?.startsWith("```") === false
      && token.raw?.startsWith("~~~") === false
      && token.codeBlockStyle !== "indented"
    ) {
      return [];
    }
    const source = fencedCodeSource(token);
    const language = normalizeCodeLanguage(token.lang) || null;
    return helpers.createNode(
      "codeBlock",
      { language, sourceInfo: source.info, sourceFence: source.fence },
      token.text ? [helpers.createTextNode(token.text)] : []
    );
  },

  renderMarkdown(node, helpers) {
    const language = normalizeCodeLanguage(node.attrs?.language);
    const sourceInfo = String(node.attrs?.sourceInfo ?? "").trim();
    const info = sourceInfo && normalizeCodeLanguage(sourceInfo) === language
      ? sourceInfo
      : language;
    const sourceFence = String(node.attrs?.sourceFence ?? "");
    const fenceCharacter = /^~{3,}$/u.test(sourceFence) ? "~" : "`";
    const sourceFenceLength = sourceFence.length >= 3
      && Array.from(sourceFence).every((character) => character === fenceCharacter)
      ? sourceFence.length
      : 3;
    if (!node.content) {
      const emptyFence = fenceCharacter.repeat(sourceFenceLength);
      return `${emptyFence}${info}\n\n${emptyFence}`;
    }
    const content = helpers.renderChildren(node.content);
    const runExpression = fenceCharacter === "`" ? /`+/gu : /~+/gu;
    const longestFenceRun = Math.max(
      0,
      ...Array.from(content.matchAll(runExpression), (match) => match[0].length)
    );
    const fence = fenceCharacter.repeat(Math.max(sourceFenceLength, 3, longestFenceRun + 1));
    return [`${fence}${info}`, content, fence].join("\n");
  },

  renderHTML({ node, HTMLAttributes }) {
    const language = normalizeCodeLanguage(node.attrs?.language);
    const title = codeBlockDisplayTitle(node.attrs?.sourceInfo);
    const codeAttributes = {
      "data-code-block": "true",
      "aria-label": codeBlockAccessibilityLabel(language, title)
    };
    if (language) codeAttributes["data-language"] = language;
    if (title) codeAttributes["data-code-title"] = title;
    return [
      "pre",
      mergeAttributes(this.options.HTMLAttributes, HTMLAttributes, codeAttributes),
      [
        "code",
        {
          class: language ? `${this.options.languageClassPrefix}${language}` : null
        },
        0
      ]
    ];
  },

  addNodeView() {
    return ({ node }) => {
      let currentNode = node;
      const language = normalizeCodeLanguage(node.attrs?.language);
      const ownerDocument = globalThis.document;
      const code = ownerDocument.createElement("code");
      code.spellcheck = false;

      if (language !== "mermaid") {
        const pre = ownerDocument.createElement("pre");
        pre.dataset.codeBlock = "true";
        applyCodeBlockPresentation(pre, node);
        if (language) {
          code.className = `language-${language}`;
        }
        pre.appendChild(code);
        return {
          dom: pre,
          contentDOM: code,
          update(updatedNode) {
            if (updatedNode.type !== currentNode.type
                || normalizeCodeLanguage(updatedNode.attrs?.language) !== language) return false;
            currentNode = updatedNode;
            applyCodeBlockPresentation(pre, updatedNode);
            return true;
          }
        };
      }

      const figure = ownerDocument.createElement("figure");
      figure.className = "mermaid-node";
      figure.dataset.language = "mermaid";
      const preview = ownerDocument.createElement("div");
      preview.className = "mermaid-preview";
      preview.setAttribute("role", "img");
      preview.setAttribute("aria-label", mermaidAccessibleLabel(currentNode.textContent));
      const status = ownerDocument.createElement("figcaption");
      status.className = "mermaid-status";
      status.setAttribute("role", "status");
      status.setAttribute("aria-live", "polite");
      const source = ownerDocument.createElement("pre");
      source.className = "mermaid-source";
      source.dataset.codeBlock = "true";
      source.dataset.language = "mermaid";
      code.className = "language-mermaid";
      code.setAttribute("aria-label", "Editable Mermaid diagram source");
      source.appendChild(code);
      figure.append(preview, status, source);

      const ownerWindow = ownerDocument.defaultView;
      let renderTimer = null;
      let renderVersion = 0;
      let destroyed = false;
      const render = async () => {
        const version = ++renderVersion;
        const diagram = currentNode.textContent;
        figure.dataset.state = "loading";
        preview.setAttribute("aria-label", mermaidAccessibleLabel(diagram));
        status.textContent = "Rendering Mermaid diagram…";
        try {
          await renderMermaidInto(preview, diagram);
          if (destroyed || version !== renderVersion) return;
          figure.dataset.state = "ready";
          status.textContent = "Mermaid diagram rendered offline. Source remains editable below.";
        } catch (error) {
          if (destroyed || version !== renderVersion) return;
          figure.dataset.state = "error";
          preview.replaceChildren();
          const message = ownerDocument.createElement("span");
          message.className = "mermaid-error";
          message.textContent = `Mermaid error: ${String(error?.message ?? error ?? "Invalid diagram")}`;
          preview.appendChild(message);
          status.textContent = "Diagram could not be rendered. Fix the editable Mermaid source below.";
        }
      };
      const scheduleRender = () => {
        if (renderTimer != null) ownerWindow?.clearTimeout(renderTimer);
        renderTimer = ownerWindow?.setTimeout(() => {
          renderTimer = null;
          render();
        }, 120) ?? null;
      };
      render();

      return {
        dom: figure,
        contentDOM: code,
        update(updatedNode) {
          if (updatedNode.type !== currentNode.type
              || normalizeCodeLanguage(updatedNode.attrs?.language) !== "mermaid") return false;
          const sourceChanged = updatedNode.textContent !== currentNode.textContent;
          currentNode = updatedNode;
          if (sourceChanged) scheduleRender();
          return true;
        },
        ignoreMutation(mutation) {
          return mutation.target !== code && !code.contains(mutation.target);
        },
        destroy() {
          destroyed = true;
          renderVersion += 1;
          if (renderTimer != null) ownerWindow?.clearTimeout(renderTimer);
        }
      };
    };
  },

  addInputRules() {
    return [
      textblockTypeInputRule({
        find: /^```([A-Za-z0-9_+#.-]+)?[\s\n]$/,
        type: this.type,
        getAttributes: (match) => ({
          language: normalizeCodeLanguage(match[1]) || null,
          sourceInfo: match[1] || null,
          sourceFence: "```"
        })
      }),
      textblockTypeInputRule({
        find: /^~~~([A-Za-z0-9_+#.-]+)?[\s\n]$/,
        type: this.type,
        getAttributes: (match) => ({
          language: normalizeCodeLanguage(match[1]) || null,
          sourceInfo: match[1] || null,
          sourceFence: "~~~"
        })
      })
    ];
  }
});

function convertCurrentTaskRowToBullet(state, transaction = state.tr) {
  const { $from } = state.selection;
  let itemDepth = null;
  let listDepth = null;
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    const nodeName = $from.node(depth).type.name;
    if (itemDepth == null && nodeName === "taskItem") itemDepth = depth;
    if (itemDepth != null && nodeName === "taskList") {
      listDepth = depth;
      break;
    }
  }
  if (itemDepth == null || listDepth == null || itemDepth !== listDepth + 1) {
    return false;
  }

  const taskList = $from.node(listDepth);
  const itemIndex = $from.index(listDepth);
  const taskItem = taskList.child(itemIndex);
  const paragraphIndex = $from.index(itemDepth);
  const paragraph = taskItem.child(paragraphIndex);
  if (paragraph !== $from.parent || paragraph.type.name !== "paragraph") return false;

  const children = [];
  taskItem.forEach((child, _offset, index) => {
    if (index !== paragraphIndex) {
      children.push(child);
      return;
    }

    // Input rules run before the trailing space is inserted. Discard the
    // marker to the left of the caret while preserving any existing text to
    // its right.
    children.push(child.type.create(child.attrs, child.content.cut($from.parentOffset)));
  });

  const listItem = state.schema.nodes.listItem.create(null, children);
  const bulletList = state.schema.nodes.bulletList.create(null, listItem);
  const items = Array.from(taskList.content.content);
  const before = items.slice(0, itemIndex);
  const after = items.slice(itemIndex + 1);
  const replacement = [];
  if (before.length) replacement.push(taskList.copy(Fragment.fromArray(before)));
  const bulletListStart = $from.before(listDepth)
    + replacement.reduce((size, node) => size + node.nodeSize, 0);
  replacement.push(bulletList);
  if (after.length) replacement.push(taskList.copy(Fragment.fromArray(after)));

  transaction.replaceWith(
    $from.before(listDepth),
    $from.after(listDepth),
    Fragment.fromArray(replacement)
  );
  transaction.setSelection(TextSelection.create(transaction.doc, bulletListStart + 3));
  return true;
}

const ContextualTaskItem = TaskItem.extend({
  addInputRules() {
    return [
      new InputRule({
        find: /^\s*([-+*])\s$/,
        handler: ({ state }) => {
          const { $from } = state.selection;
          let isInsideTask = false;
          for (let depth = $from.depth; depth > 0; depth -= 1) {
            if ($from.node(depth).type.name === "taskItem") {
              isInsideTask = true;
              break;
            }
          }
          if (!isInsideTask) return null;

          // Convert only this task row, at its current depth. Tiptap's generic
          // toggleBulletList command lifts a nested task row before changing
          // its node type, which unexpectedly detaches the child from its
          // checked parent.
          if (!convertCurrentTaskRowToBullet(state)) return null;
        }
      }),
      new InputRule({
        find: /^\s*(\[([ xX]?)\])\s$/,
        handler: (props) => {
          const { $from } = props.state.selection;
          let bulletDepth = null;
          let itemDepth = null;
          for (let depth = $from.depth; depth > 0; depth -= 1) {
            const nodeName = $from.node(depth).type.name;
            if (itemDepth == null && nodeName === "listItem") itemDepth = depth;
            if (nodeName === "bulletList") {
              bulletDepth = depth;
              break;
            }
          }
          if (bulletDepth == null || itemDepth == null) return null;

          const bulletList = $from.node(bulletDepth);
          const itemIndex = $from.index(bulletDepth);
          const listItem = bulletList.child(itemIndex);
          const paragraphIndex = $from.index(itemDepth);
          const children = [];
          listItem.forEach((child, _offset, index) => {
            if (index !== paragraphIndex) {
              children.push(child);
              return;
            }

            // Input rules run before the triggering space is inserted. Preserve
            // everything after the caret so converting `- [] |text` consumes
            // only the task marker instead of replacing the existing text.
            const trailingContent = child.content.cut($from.parentOffset);
            children.push(child.type.create(child.attrs, trailingContent));
          });
          const checked = String(
            props.match[props.match.length - 1] ?? ""
          ).toLowerCase() === "x";
          const taskItem = this.type.create({ checked }, children);
          const taskList = props.state.schema.nodes.taskList.create(null, taskItem);
          const items = [];
          bulletList.forEach((child) => items.push(child));
          const before = items.slice(0, itemIndex);
          const after = items.slice(itemIndex + 1);
          const replacement = [];
          if (before.length) replacement.push(bulletList.copy(Fragment.fromArray(before)));
          const taskListStart = $from.before(bulletDepth)
            + replacement.reduce((size, node) => size + node.nodeSize, 0);
          replacement.push(taskList);
          if (after.length) replacement.push(bulletList.copy(Fragment.fromArray(after)));

          const from = $from.before(bulletDepth);
          const listEnd = from + bulletList.nodeSize;
          const trailingNode = props.state.doc.nodeAt(listEnd);
          const removesInputRuleSentinel = itemIndex === bulletList.childCount - 1
            && trailingNode?.type.name === "paragraph"
            && trailingNode.content.size === 0;
          const to = listEnd + (removesInputRuleSentinel ? trailingNode.nodeSize : 0);
          props.state.tr.replaceWith(
            from,
            to,
            Fragment.fromArray(replacement)
          );
          props.state.tr.setSelection(
            TextSelection.near(props.state.tr.doc.resolve(taskListStart + 3))
          );
        }
      })
    ];
  }
});

function escapeMarkdownText(value) {
  return String(value ?? "").replace(/([\\\[\]])/g, "\\$1");
}

function escapeDestination(value) {
  return String(value ?? "").replace(/[()\\]/g, "\\$&");
}

function isValidMath(latex, displayMode) {
  try {
    katex.renderToString(latex, {
      displayMode,
      output: "htmlAndMathml",
      strict: "ignore",
      throwOnError: true,
      trust: false
    });
    return true;
  } catch {
    return false;
  }
}

function replaceParagraphWithBlockMath(state, blockMathType) {
  const { selection } = state;
  const { $from } = selection;
  if (
    !selection.empty
    || $from.parent.type.name !== "paragraph"
    || $from.parent.textContent !== "$$"
    || $from.parentOffset !== $from.parent.content.size
  ) {
    return null;
  }

  const paragraphStart = $from.before($from.depth);
  const paragraphEnd = paragraphStart + $from.parent.nodeSize;
  const mathNode = blockMathType.create({ latex: "", autoEdit: true });
  const isLastNode = paragraphEnd >= state.doc.content.size;
  const replacement = isLastNode
    ? Fragment.fromArray([mathNode, state.schema.nodes.paragraph.create()])
    : mathNode;
  const transaction = state.tr.replaceWith(paragraphStart, paragraphEnd, replacement);
  const selectionPosition = Math.min(
    transaction.doc.content.size,
    paragraphStart + mathNode.nodeSize + (isLastNode ? 1 : 0)
  );
  transaction.setSelection(TextSelection.near(transaction.doc.resolve(selectionPosition)));
  return transaction;
}

function createMathNode({ name, inline, delimiter }) {
  return Node.create({
    name,
    group: inline ? "inline" : "block",
    inline,
    atom: true,
    selectable: true,
    draggable: false,

    addAttributes() {
      return {
        latex: { default: "" },
        autoEdit: { default: false, rendered: false }
      };
    },

    parseHTML() {
      return [{ tag: `${inline ? "span" : "div"}[data-type="${name}"]` }];
    },

    renderHTML({ HTMLAttributes }) {
      return [inline ? "span" : "div", mergeAttributes(HTMLAttributes, {
        "data-type": name,
        "data-latex": HTMLAttributes.latex
      })];
    },

    markdownTokenName: name,
    parseMarkdown(token) {
      return { type: name, attrs: { latex: String(token.latex ?? "").trim() } };
    },
    renderMarkdown(node) {
      const latex = String(node.attrs?.latex ?? "");
      return inline ? `$${latex}$` : `$$\n${latex}\n$$`;
    },
    markdownTokenizer: {
      name,
      level: inline ? "inline" : "block",
      start: (source) => source.indexOf(delimiter),
      tokenize: (source) => {
        const match = inline
          ? source.match(/^\$(?!\$)([^$\n]+?)\$(?!\$)/)
          : source.match(/^\$\$\s*\n?([\s\S]+?)\n?\s*\$\$(?:\n|$)/);
        if (!match || !isValidMath(match[1].trim(), !inline)) return undefined;
        return { type: name, raw: match[0], latex: match[1].trim() };
      }
    },

    addInputRules() {
      const rules = [
        new InputRule({
          find: inline ? /(?:^|\s)(\$([^$\n]+)\$)$/ : /^\$\$([^$]+)\$\$$/,
          handler: ({ state, range, match }) => {
            const source = inline ? match[2] : match[1];
            if (!isValidMath(source, !inline)) return;
            const full = inline ? match[1] : match[0];
            const from = inline ? range.to - full.length : range.from;
            state.tr.replaceWith(from, range.to, this.type.create({ latex: source.trim() }));
          }
        })
      ];
      if (!inline) {
        rules.unshift(new InputRule({
          find: /^\$\$\s$/,
          handler: ({ state }) => {
            replaceParagraphWithBlockMath(state, this.type);
          }
        }));
      }
      return rules;
    },

    addKeyboardShortcuts() {
      if (inline) return {};
      return {
        Enter: () => {
          const transaction = replaceParagraphWithBlockMath(this.editor.state, this.type);
          if (!transaction) return false;
          this.editor.view.dispatch(transaction.scrollIntoView());
          return true;
        }
      };
    },

    addNodeView() {
      return ({ node, getPos, editor }) => {
        const wrapper = document.createElement(inline ? "span" : "div");
        wrapper.className = inline ? "math-node math-node-inline" : "math-node math-node-block";
        wrapper.dataset.type = name;
        wrapper.dataset.latex = node.attrs.latex;
        let currentNode = node;
        let editing = false;

        const render = () => {
          wrapper.replaceChildren();
          wrapper.classList.remove("is-editing", "has-error");
          try {
            katex.render(currentNode.attrs.latex, wrapper, {
              displayMode: !inline,
              output: "htmlAndMathml",
              strict: "ignore",
              throwOnError: true,
              trust: false
            });
          } catch {
            wrapper.textContent = `${delimiter}${currentNode.attrs.latex}${delimiter}`;
            wrapper.classList.add("has-error");
          }
        };

        const beginEditing = (event) => {
          if (editing || !editor.isEditable) return;
          event?.preventDefault();
          event?.stopPropagation();
          editing = true;
          wrapper.classList.add("is-editing");
          wrapper.replaceChildren();
          const input = document.createElement(inline ? "input" : "textarea");
          input.className = "math-source";
          input.value = currentNode.attrs.latex;
          input.setAttribute("aria-label", inline ? "Edit inline formula" : "Edit block formula");
          input.spellcheck = false;
          if (inline) input.size = Math.max(3, input.value.length);

          let finalized = false;
          let composing = false;
          let pendingBlurCommit = false;
          let handleBlur = null;
          const finish = (shouldCommit) => {
            if (finalized) return;
            finalized = true;
            editing = false;
            if (handleBlur) input.removeEventListener("blur", handleBlur);
            if (!shouldCommit) {
              if (!inline && currentNode.attrs.autoEdit) {
                const position = getPos();
                if (typeof position === "number") {
                  editor.view.dispatch(editor.state.tr.replaceWith(
                    position,
                    position + currentNode.nodeSize,
                    editor.schema.nodes.paragraph.create(null, editor.schema.text("$$"))
                  ));
                }
                editor.commands.focus();
                return;
              }
              render();
              editor.commands.focus();
              return;
            }
            const position = getPos();
            const latex = input.value;
            if (typeof position !== "number") return;
            if (!inline && !latex.trim()) {
              editor.view.dispatch(editor.state.tr.replaceWith(
                position,
                position + currentNode.nodeSize,
                editor.schema.nodes.paragraph.create(null, editor.schema.text("$$"))
              ));
              editor.commands.focus();
              return;
            }
            if (isValidMath(latex, !inline)) {
              editor.view.dispatch(editor.state.tr.setNodeMarkup(position, undefined, {
                latex,
                autoEdit: false
              }));
              const updatedNode = editor.state.doc.nodeAt(position);
              if (updatedNode?.type.name === name) {
                currentNode = updatedNode;
                render();
              }
            } else if (!inline) {
              editor.view.dispatch(editor.state.tr.setNodeMarkup(position, undefined, {
                latex,
                autoEdit: false
              }));
              const updatedNode = editor.state.doc.nodeAt(position);
              if (updatedNode?.type.name === name) {
                currentNode = updatedNode;
                render();
              }
            } else {
              const visibleSource = `${delimiter}${latex}${delimiter}`;
              const transaction = editor.state.tr;
              if (inline) {
                transaction.replaceWith(position, position + currentNode.nodeSize, editor.schema.text(visibleSource));
              } else {
                transaction.replaceWith(
                  position,
                  position + currentNode.nodeSize,
                  editor.schema.nodes.paragraph.create(null, editor.schema.text(visibleSource))
                );
              }
              editor.view.dispatch(transaction);
            }
            editor.commands.focus();
          };
          const commit = () => finish(true);

          input.addEventListener("compositionstart", () => {
            composing = true;
          });
          input.addEventListener("compositionend", () => {
            composing = false;
            if (pendingBlurCommit) {
              pendingBlurCommit = false;
              commit();
            }
          });
          handleBlur = () => {
            if (composing) {
              pendingBlurCommit = true;
              return;
            }
            commit();
          };
          input.addEventListener("blur", handleBlur);
          input.addEventListener("keydown", (event) => {
            if (composing || isIMECompositionEvent(event, editor.view)) return;
            if (event.key === "Escape") {
              event.preventDefault();
              event.stopPropagation();
              finish(false);
            } else if (event.key === "Enter" && (inline || event.metaKey)) {
              event.preventDefault();
              commit();
            }
          });
          wrapper.appendChild(input);
          input.focus({ preventScroll: true });
          const caret = input.value.length;
          input.setSelectionRange(caret, caret);
        };

        const handleMouseDown = (event) => {
          if (editing && event.target === wrapper.querySelector(".math-source")) {
            event.stopPropagation();
            return;
          }
          if (event.button !== 0) return;
          beginEditing(event);
        };

        wrapper.addEventListener("mousedown", handleMouseDown);
        render();
        if (!inline && currentNode.attrs.autoEdit) {
          const requestFrame = wrapper.ownerDocument.defaultView?.requestAnimationFrame
            ?? ((callback) => setTimeout(callback, 0));
          requestFrame(() => beginEditing());
        }

        return {
          dom: wrapper,
          update(updatedNode) {
            if (updatedNode.type.name !== name) return false;
            currentNode = updatedNode;
            wrapper.dataset.latex = currentNode.attrs.latex;
            if (!editing) render();
            return true;
          },
          stopEvent(event) {
            return wrapper.contains(event.target);
          },
          destroy() {
            wrapper.removeEventListener("mousedown", handleMouseDown);
          }
        };
      };
    }
  });
}

const InlineMath = createMathNode({ name: "inlineMath", inline: true, delimiter: "$" });
const BlockMath = createMathNode({ name: "blockMath", inline: false, delimiter: "$$" });

function footnoteDOMIdentifier(label) {
  return encodeURIComponent(String(label ?? "footnote").trim().toLowerCase())
    .replace(/%/gu, "_")
    .replace(/[^a-z0-9_.~-]/gu, "-") || "footnote";
}

const FootnoteReference = Node.create({
  name: "footnoteReference",
  inline: true,
  group: "inline",
  atom: true,
  selectable: true,

  addAttributes() {
    return {
      label: { default: "note" },
      number: { default: null, rendered: false },
      occurrence: { default: 1, rendered: false }
    };
  },

  renderHTML({ node }) {
    const label = String(node.attrs.label ?? "note");
    const identifier = footnoteDOMIdentifier(label);
    const number = Number.isInteger(node.attrs.number) ? node.attrs.number : label;
    const occurrence = Number.isInteger(node.attrs.occurrence) ? node.attrs.occurrence : 1;
    return [
      "sup",
      {
        class: "footnote-reference",
        id: `fnref-${identifier}${occurrence > 1 ? `-${occurrence}` : ""}`,
        "data-footnote-reference": label,
        contenteditable: "false"
      },
      [
        "a",
        {
          href: `#fn-${identifier}`,
          role: "doc-noteref",
          "aria-label": `Footnote ${number}: ${label}`
        },
        String(number)
      ]
    ];
  },

  markdownTokenName: "footnoteReference",
  parseMarkdown(token) {
    return { type: "footnoteReference", attrs: { label: String(token.label ?? "note") } };
  },
  renderMarkdown(node) {
    return `[^${String(node.attrs?.label ?? "note")}]`;
  },
  markdownTokenizer: {
    name: "footnoteReference",
    level: "inline",
    start: (source) => source.indexOf("[^") ,
    tokenize: (source) => {
      const match = source.match(/^\[\^([^\]\s]+)\]/u);
      if (!match) return undefined;
      return { type: "footnoteReference", raw: match[0], label: match[1] };
    }
  }
});

function footnoteDefinitionToken(source, lexer) {
  const firstLineEnd = source.indexOf("\n");
  const firstLine = firstLineEnd < 0 ? source : source.slice(0, firstLineEnd);
  const match = firstLine.match(/^\[\^([^\]\s]+)\]:[ \t]*(.*)$/u);
  if (!match) return undefined;

  const body = [match[2]];
  let consumed = firstLineEnd < 0 ? source.length : firstLineEnd + 1;
  while (consumed < source.length) {
    const nextBreak = source.indexOf("\n", consumed);
    const lineEnd = nextBreak < 0 ? source.length : nextBreak;
    const line = source.slice(consumed, lineEnd);
    const continuation = line.match(/^(?: {2,4}|\t)(.*)$/u);
    if (!continuation) break;
    body.push(continuation[1]);
    consumed = nextBreak < 0 ? source.length : nextBreak + 1;
  }
  const text = body.join("\n").trimEnd();
  return {
    type: "footnoteDefinition",
    raw: source.slice(0, consumed),
    label: match[1],
    text,
    tokens: lexer.inlineTokens(text.replace(/\n/gu, " "))
  };
}

const FootnoteDefinition = Node.create({
  name: "footnoteDefinition",
  group: "block",
  content: "inline*",
  defining: true,

  addAttributes() {
    return {
      label: { default: "note" },
      number: { default: null, rendered: false },
      hasReference: { default: false, rendered: false }
    };
  },

  renderHTML({ node }) {
    const label = String(node.attrs.label ?? "note");
    const identifier = footnoteDOMIdentifier(label);
    const number = Number.isInteger(node.attrs.number) ? node.attrs.number : label;
    return [
      "aside",
      {
        class: "footnote-definition",
        id: `fn-${identifier}`,
        role: "doc-endnote",
        "data-footnote-definition": label
      },
      ["span", { class: "footnote-number", "aria-hidden": "true" }, `${number}.`],
      ["span", { class: "footnote-body" }, 0],
      [
        "a",
        {
          class: "footnote-backlink",
          href: `#fnref-${identifier}`,
          role: "doc-backlink",
          "aria-label": `Back to footnote ${number} reference`,
          hidden: node.attrs.hasReference ? null : "",
          contenteditable: "false"
        },
        "↩"
      ]
    ];
  },

  markdownTokenName: "footnoteDefinition",
  parseMarkdown(token, helpers) {
    return helpers.createNode(
      "footnoteDefinition",
      { label: String(token.label ?? "note") },
      helpers.parseInline(token.tokens ?? [])
    );
  },
  renderMarkdown(node, helpers) {
    const label = String(node.attrs?.label ?? "note");
    const body = helpers.renderChildren(node.content ?? []).replace(/\n/gu, "\n    ");
    return `[^${label}]: ${body}`;
  },
  markdownTokenizer: {
    name: "footnoteDefinition",
    level: "block",
    start: (source) => source.search(/^\[\^[^\]\s]+\]:/mu),
    tokenize: (source, _tokens, lexer) => footnoteDefinitionToken(source, lexer)
  }
});

function footnoteNavigationTransaction(state) {
  // Keep navigation presentation in ProseMirror state. Mutating view.dom after
  // rendering makes ProseMirror's DOM observer parse our own changes and can
  // create an unbounded observer/update feedback loop.
  const numbers = new Map();
  const referenceCounts = new Map();
  const transaction = state.tr;
  let changed = false;

  state.doc.descendants((node, position) => {
    if (node.type.name !== "footnoteReference") return;
    const label = String(node.attrs.label ?? "note");
    if (!numbers.has(label)) numbers.set(label, numbers.size + 1);
    const number = numbers.get(label);
    const occurrence = (referenceCounts.get(label) ?? 0) + 1;
    referenceCounts.set(label, occurrence);
    if (node.attrs.number !== number || node.attrs.occurrence !== occurrence) {
      transaction.setNodeMarkup(position, undefined, { ...node.attrs, number, occurrence });
      changed = true;
    }
  });

  state.doc.descendants((node, position) => {
    if (node.type.name !== "footnoteDefinition") return;
    const label = String(node.attrs.label ?? "note");
    if (!numbers.has(label)) numbers.set(label, numbers.size + 1);
    const number = numbers.get(label);
    const hasReference = referenceCounts.has(label);
    if (node.attrs.number !== number || node.attrs.hasReference !== hasReference) {
      transaction.setNodeMarkup(position, undefined, { ...node.attrs, number, hasReference });
      changed = true;
    }
  });

  if (!changed) return null;
  transaction.setMeta("addToHistory", false);
  transaction.setMeta("markdownCardFootnoteNavigation", true);
  return transaction;
}

const FootnoteNavigation = Extension.create({
  name: "footnoteNavigation",
  addProseMirrorPlugins() {
    return [new Plugin({
      appendTransaction(transactions, _oldState, newState) {
        if (!transactions.some((transaction) => transaction.docChanged)) return null;
        return footnoteNavigationTransaction(newState);
      },
      view(view) {
        const transaction = footnoteNavigationTransaction(view.state);
        if (transaction) view.dispatch(transaction);
        return {};
      }
    })];
  }
});

function normalizedImageWidth(value) {
  if (value == null || value === "") return null;
  const number = Number.parseInt(String(value).replace(/%$/u, ""), 10);
  return Number.isFinite(number) && number >= 10 && number <= 100 ? number : null;
}

function normalizedImageAlignment(value) {
  const alignment = String(value ?? "").toLowerCase();
  return ["left", "center", "right"].includes(alignment) ? alignment : null;
}

function parseImageAttributeBlock(source) {
  const attrs = {};
  const pattern = /([a-z][\w-]*)=(?:"((?:\\"|[^"])*)"|'((?:\\'|[^'])*)'|([^\s]+))/giu;
  for (const match of String(source ?? "").matchAll(pattern)) {
    const key = match[1].toLowerCase();
    const value = (match[2] ?? match[3] ?? match[4] ?? "")
      .replace(/\\(["'])/gu, "$1");
    if (key === "caption") attrs.caption = value;
    if (key === "width") attrs.width = normalizedImageWidth(value);
    if (key === "align" || key === "alignment") {
      attrs.alignment = normalizedImageAlignment(value);
    }
  }
  return attrs;
}

function renderImageAttributeBlock(attrs) {
  const values = [];
  const caption = String(attrs?.caption ?? "").trim();
  const width = normalizedImageWidth(attrs?.width);
  const alignment = normalizedImageAlignment(attrs?.alignment);
  if (caption) {
    values.push(`caption="${caption.replace(/\\/gu, "\\\\").replace(/"/gu, "\\\"")}"`);
  }
  if (width) values.push(`width="${width}%"`);
  if (alignment) values.push(`align="${alignment}"`);
  return values.length ? `{${values.join(" ")}}` : "";
}

const BlockedImage = Node.create({
  name: "blockedImage",
  inline: true,
  group: "inline",
  atom: true,
  selectable: true,

  addAttributes() {
    return {
      src: { default: "" },
      alt: { default: "image" },
      title: { default: null },
      caption: { default: null },
      width: { default: null },
      alignment: { default: null }
    };
  },

  renderHTML({ node }) {
    const attachmentID = managedAttachmentID(node.attrs.src);
    if (attachmentID) {
      return ["img", {
        class: "local-attachment",
        src: `mdcard-asset://attachment/${attachmentID}.png`,
        "data-source": node.attrs.src,
        alt: node.attrs.alt ?? "Pasted image",
        title: node.attrs.title || null,
        draggable: "false"
      }];
    }
    return ["span", {
      class: "image-blocked",
      "data-source": node.attrs.src,
      role: "note",
      "aria-label": `Image blocked: ${node.attrs.alt ?? "image"}`
    }, `Image blocked · ${node.attrs.alt ?? "image"}`];
  },

  addNodeView() {
    return ({ node }) => {
      const wrapper = document.createElement("span");
      wrapper.className = "blocked-image-node";
      let currentNode = node;

      const appendCaption = () => {
        const caption = String(currentNode.attrs.caption ?? "").trim();
        const width = normalizedImageWidth(currentNode.attrs.width);
        const alignment = normalizedImageAlignment(currentNode.attrs.alignment);
        wrapper.dataset.alignment = alignment ?? "auto";
        wrapper.style.setProperty("--image-display-width", width ? `${width}%` : "auto");
        wrapper.classList.toggle("has-caption", Boolean(caption));
        if (!caption) {
          wrapper.removeAttribute("role");
          wrapper.removeAttribute("aria-label");
          return;
        }
        wrapper.setAttribute("role", "figure");
        wrapper.setAttribute("aria-label", caption);
        const captionElement = document.createElement("span");
        captionElement.className = "image-caption";
        captionElement.textContent = caption;
        wrapper.appendChild(captionElement);
      };

      const showBlocked = (message, unavailable = false) => {
        const note = document.createElement("span");
        note.className = unavailable ? "image-blocked image-unavailable" : "image-blocked";
        note.dataset.source = String(currentNode.attrs.src ?? "");
        note.setAttribute("role", "note");
        note.setAttribute("aria-label", message);
        note.textContent = message;
        wrapper.replaceChildren(note);
        appendCaption();
      };

      const render = () => {
        const root = document.documentElement;
        const presentation = documentImagePresentation({
          cardID: root.dataset.documentCardId,
          source: currentNode.attrs.src,
          alt: currentNode.attrs.alt,
          title: currentNode.attrs.title,
          documentImagesAvailable: root.dataset.documentImagesAvailable === "true"
        });
        wrapper.dataset.source = String(currentNode.attrs.src ?? "");
        if (presentation.kind === "blocked") {
          showBlocked(presentation.message);
          return;
        }

        const image = document.createElement("img");
        image.className = presentation.kind === "attachment"
          ? "local-attachment"
          : "document-image";
        image.src = presentation.src;
        image.dataset.source = String(currentNode.attrs.src ?? "");
        image.alt = presentation.alt;
        if (presentation.title) image.title = presentation.title;
        image.draggable = false;
        const width = normalizedImageWidth(currentNode.attrs.width);
        if (width) image.style.width = `${width}%`;
        if (presentation.kind === "document") {
          image.addEventListener("error", () => {
            if (!wrapper.contains(image)) return;
            const alternative = presentation.alt || "decorative image";
            showBlocked(`Image unavailable · ${alternative}`, true);
          }, { once: true });
        }
        wrapper.replaceChildren(image);
        appendCaption();
      };

      const handleAvailabilityChange = (event) => {
        const eventCardID = String(event.detail?.cardID ?? "");
        if (eventCardID && eventCardID !== document.documentElement.dataset.documentCardId) return;
        render();
      };
      window.addEventListener("markdowncard:document-assets-changed", handleAvailabilityChange);
      render();

      return {
        dom: wrapper,
        update(updatedNode) {
          if (updatedNode.type.name !== "blockedImage") return false;
          currentNode = updatedNode;
          render();
          return true;
        },
        ignoreMutation() {
          return true;
        },
        destroy() {
          window.removeEventListener(
            "markdowncard:document-assets-changed",
            handleAvailabilityChange
          );
        }
      };
    };
  },

  markdownTokenName: "image",
  parseMarkdown(token) {
    return {
      type: "blockedImage",
      attrs: {
        src: String(token.href ?? ""),
        alt: String(token.text ?? "image"),
        title: token.title == null ? null : String(token.title),
        caption: token.imageAttrs?.caption ?? null,
        width: normalizedImageWidth(token.imageAttrs?.width),
        alignment: normalizedImageAlignment(token.imageAttrs?.alignment)
      }
    };
  },
  renderMarkdown(node) {
    const alt = escapeMarkdownText(node.attrs?.alt ?? "image");
    const src = escapeDestination(node.attrs?.src || "");
    const title = node.attrs?.title ? ` \"${String(node.attrs.title).replace(/\"/g, "\\\"")}\"` : "";
    const attributes = renderImageAttributeBlock(node.attrs);
    return `![${alt}](${src}${title})${attributes}`;
  },
  markdownTokenizer: {
    name: "image",
    level: "inline",
    start: (source) => source.indexOf("!["),
    tokenize: (source) => {
      const match = source.match(
        /^!\[([^\]]*)\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+(?:"([^"]*)"|'([^']*)'))?\s*\)(?:\{([^}\n]*)\})?/u
      );
      if (!match) return undefined;
      const href = match[2].startsWith("<") ? match[2].slice(1, -1) : match[2];
      return {
        type: "image",
        raw: match[0],
        href,
        text: match[1],
        title: match[3] ?? match[4] ?? null,
        imageAttrs: parseImageAttributeBlock(match[5])
      };
    }
  }
});

const CODE_INDENT = "    ";

function codeBlockContext(state) {
  const findDepth = ($position) => {
    for (let depth = $position.depth; depth > 0; depth -= 1) {
      if ($position.node(depth).type.name === "codeBlock") return depth;
    }
    return null;
  };
  const fromDepth = findDepth(state.selection.$from);
  const toDepth = findDepth(state.selection.$to);
  if (fromDepth == null || toDepth == null) return null;
  const fromStart = state.selection.$from.start(fromDepth);
  const toStart = state.selection.$to.start(toDepth);
  if (fromStart !== toStart) return null;
  return {
    node: state.selection.$from.node(fromDepth),
    start: fromStart
  };
}

function codeLineStarts(text, fromOffset, toOffset) {
  const first = text.lastIndexOf("\n", Math.max(0, fromOffset - 1)) + 1;
  const effectiveEnd = toOffset > fromOffset && text[toOffset - 1] === "\n"
    ? toOffset - 1
    : toOffset;
  const starts = [];
  let current = first;
  while (current <= effectiveEnd) {
    starts.push(current);
    const nextBreak = text.indexOf("\n", current);
    if (nextBreak < 0 || nextBreak + 1 > effectiveEnd) break;
    current = nextBreak + 1;
  }
  return starts;
}

function indentCodeBlock(editor, reverse) {
  return editor.commands.command(({ state, dispatch }) => {
    const context = codeBlockContext(state);
    if (!context) return false;
    const { from, to } = state.selection;
    if (!reverse && from === to) {
      dispatch?.(state.tr.insertText(CODE_INDENT, from, to).scrollIntoView());
      return true;
    }

    const text = context.node.textContent;
    const starts = codeLineStarts(text, from - context.start, to - context.start);
    const tr = state.tr;
    for (const offset of [...starts].reverse()) {
      const position = context.start + offset;
      if (!reverse) {
        tr.insertText(CODE_INDENT, position);
        continue;
      }
      const line = text.slice(offset);
      const removal = line.startsWith("\t") ? 1 : (line.match(/^ {1,4}/)?.[0].length ?? 0);
      if (removal > 0) tr.delete(position, position + removal);
    }
    tr.setSelection(state.selection.map(tr.doc, tr.mapping));
    dispatch?.(tr.scrollIntoView());
    return true;
  });
}

function listItemAtSelection(editor) {
  const { $from } = editor.state.selection;
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    const name = $from.node(depth).type.name;
    if (name === "taskItem" || name === "listItem") return name;
  }
  return null;
}

function sinkBulletListItemIntoPreviousTask(editor) {
  return editor.commands.command(({ state, dispatch }) => {
    const { $from, to } = state.selection;
    let itemDepth = null;
    for (let depth = $from.depth; depth > 0; depth -= 1) {
      if ($from.node(depth).type.name === "listItem") {
        itemDepth = depth;
        break;
      }
    }
    if (itemDepth == null) return false;

    const listDepth = itemDepth - 1;
    const containerDepth = listDepth - 1;
    const bulletList = $from.node(listDepth);
    if (bulletList.type.name !== "bulletList") return false;

    // Standard list sinking handles every item except the first. This fallback
    // bridges the otherwise invalid listItem -> taskItem boundary when an
    // adjacent bullet list follows a task list.
    const itemIndex = $from.index(listDepth);
    const listIndex = $from.index(containerDepth);
    if (itemIndex !== 0 || listIndex === 0 || to > $from.after(itemDepth)) return false;
    const container = $from.node(containerDepth);
    const previousTaskList = container.child(listIndex - 1);
    if (previousTaskList.type.name !== "taskList" || previousTaskList.childCount === 0) {
      return false;
    }

    const previousTaskIndex = previousTaskList.childCount - 1;
    const previousTask = previousTaskList.child(previousTaskIndex);
    const movedItem = bulletList.child(itemIndex);
    const taskChildren = Array.from(previousTask.content.content);
    const existingBulletList = taskChildren.at(-1)?.type.name === "bulletList"
      ? taskChildren.pop()
      : null;
    const existingItemCount = existingBulletList?.childCount ?? 0;
    const nestedBulletList = existingBulletList
      ? existingBulletList.copy(existingBulletList.content.append(Fragment.from(movedItem)))
      : bulletList.copy(Fragment.from(movedItem));
    const nestedListChildIndex = taskChildren.length;
    taskChildren.push(nestedBulletList);

    const updatedTask = previousTask.copy(Fragment.fromArray(taskChildren));
    const taskItems = Array.from(previousTaskList.content.content);
    taskItems[previousTaskIndex] = updatedTask;
    const updatedTaskList = previousTaskList.copy(Fragment.fromArray(taskItems));
    const remainingItems = Array.from(bulletList.content.content).slice(1);
    const replacement = remainingItems.length
      ? Fragment.fromArray([
          updatedTaskList,
          bulletList.copy(Fragment.fromArray(remainingItems))
        ])
      : Fragment.from(updatedTaskList);

    const listStart = $from.before(listDepth);
    const previousTaskListStart = listStart - previousTaskList.nodeSize;
    const itemStart = $from.before(itemDepth);
    const selectionOffsetFrom = state.selection.from - itemStart;
    const selectionOffsetTo = state.selection.to - itemStart;
    const previousTaskOffset = Array.from(previousTaskList.content.content)
      .slice(0, previousTaskIndex)
      .reduce((size, node) => size + node.nodeSize, 0);
    const nestedListOffset = taskChildren
      .slice(0, nestedListChildIndex)
      .reduce((size, node) => size + node.nodeSize, 0);
    const existingItemsOffset = existingBulletList
      ? Array.from(existingBulletList.content.content)
          .slice(0, existingItemCount)
          .reduce((size, node) => size + node.nodeSize, 0)
      : 0;
    const movedItemStart = previousTaskListStart
      + 1 + previousTaskOffset
      + 1 + nestedListOffset
      + 1 + existingItemsOffset;

    if (dispatch) {
      const transaction = state.tr.replaceWith(
        previousTaskListStart,
        listStart + bulletList.nodeSize,
        replacement
      );
      transaction.setSelection(TextSelection.create(
        transaction.doc,
        movedItemStart + selectionOffsetFrom,
        movedItemStart + selectionOffsetTo
      ));
      dispatch(transaction.scrollIntoView());
    }
    return true;
  });
}

function liftBulletListItemOutOfTask(editor) {
  return editor.commands.command(({ state, dispatch }) => {
    const { $from, to } = state.selection;
    let itemDepth = null;
    for (let depth = $from.depth; depth > 0; depth -= 1) {
      if ($from.node(depth).type.name === "listItem") {
        itemDepth = depth;
        break;
      }
    }
    if (itemDepth == null) return false;

    const listDepth = itemDepth - 1;
    const taskItemDepth = listDepth - 1;
    const taskListDepth = taskItemDepth - 1;
    const containerDepth = taskListDepth - 1;
    if (containerDepth < 0) return false;
    const bulletList = $from.node(listDepth);
    const taskItem = $from.node(taskItemDepth);
    const taskList = $from.node(taskListDepth);
    if (bulletList.type.name !== "bulletList"
        || taskItem.type.name !== "taskItem"
        || taskList.type.name !== "taskList") {
      return false;
    }

    const itemIndex = $from.index(listDepth);
    const nestedListIndex = $from.index(taskItemDepth);
    const taskIndex = $from.index(taskListDepth);
    if (itemIndex !== bulletList.childCount - 1
        || nestedListIndex !== taskItem.childCount - 1
        || taskIndex !== taskList.childCount - 1
        || to > $from.after(itemDepth)) {
      return false;
    }

    const movedItem = bulletList.child(itemIndex);
    const remainingNestedItems = Array.from(bulletList.content.content).slice(0, -1);
    const updatedTaskChildren = Array.from(taskItem.content.content).slice(0, nestedListIndex);
    if (remainingNestedItems.length) {
      updatedTaskChildren.push(bulletList.copy(Fragment.fromArray(remainingNestedItems)));
    }
    const updatedTask = taskItem.copy(Fragment.fromArray(updatedTaskChildren));
    const updatedTaskItems = Array.from(taskList.content.content);
    updatedTaskItems[taskIndex] = updatedTask;
    const updatedTaskList = taskList.copy(Fragment.fromArray(updatedTaskItems));

    const container = $from.node(containerDepth);
    const taskListIndex = $from.index(containerDepth);
    const nextNode = taskListIndex + 1 < container.childCount
      ? container.child(taskListIndex + 1)
      : null;
    const liftedBulletList = nextNode?.type.name === "bulletList"
      ? nextNode.copy(Fragment.from(movedItem).append(nextNode.content))
      : bulletList.copy(Fragment.from(movedItem));
    const replacement = Fragment.fromArray([updatedTaskList, liftedBulletList]);

    const taskListStart = $from.before(taskListDepth);
    const itemStart = $from.before(itemDepth);
    const selectionOffsetFrom = state.selection.from - itemStart;
    const selectionOffsetTo = state.selection.to - itemStart;
    const liftedItemStart = taskListStart + updatedTaskList.nodeSize + 1;
    const replacementEnd = taskListStart + taskList.nodeSize
      + (nextNode?.type.name === "bulletList" ? nextNode.nodeSize : 0);

    if (dispatch) {
      const transaction = state.tr.replaceWith(
        taskListStart,
        replacementEnd,
        replacement
      );
      transaction.setSelection(TextSelection.create(
        transaction.doc,
        liftedItemStart + selectionOffsetFrom,
        liftedItemStart + selectionOffsetTo
      ));
      dispatch(transaction.scrollIntoView());
    }
    return true;
  });
}

function indentList(editor, reverse) {
  const itemName = listItemAtSelection(editor);
  if (!itemName) return false;
  if (reverse) {
    return (itemName === "listItem" && liftBulletListItemOutOfTask(editor))
      || editor.commands.liftListItem(itemName);
  }
  return editor.commands.sinkListItem(itemName)
    || (itemName === "listItem" && sinkBulletListItemIntoPreviousTask(editor));
}

function deleteEmptyNestedListItem(editor) {
  return editor.commands.command(({ state, tr, dispatch }) => {
    const { selection } = state;
    const { $from } = selection;
    if (!selection.empty
        || $from.parent.type.name !== "paragraph"
        || $from.parent.content.size !== 0
        || $from.parentOffset !== 0) {
      return false;
    }

    let itemDepth = null;
    for (let depth = $from.depth; depth > 0; depth -= 1) {
      if (["listItem", "taskItem"].includes($from.node(depth).type.name)) {
        itemDepth = depth;
        break;
      }
    }
    if (itemDepth == null) return false;

    const listDepth = itemDepth - 1;
    const parentTaskDepth = listDepth - 1;
    if (parentTaskDepth < 1
        || $from.node(parentTaskDepth).type.name !== "taskItem") {
      return false;
    }

    const list = $from.node(listDepth);
    const item = $from.node(itemDepth);
    if (!["bulletList", "taskList"].includes(list.type.name)
        || item.childCount !== 1
        || item.firstChild !== $from.parent) {
      return false;
    }

    if (item.type.name === "taskItem") {
      // First Backspace removes the child checkbox without changing its
      // hierarchy. A following Backspace can then remove the empty bullet.
      if (!convertCurrentTaskRowToBullet(state, tr)) return false;
      if (dispatch) dispatch(tr.scrollIntoView());
      return true;
    }

    // Tiptap's default ListKeymap tries both listItem and taskItem handlers
    // for one Backspace. In this mixed nesting that can lift the child and
    // then unwrap the checked parent. Delete exactly one empty child instead.
    const removesWholeNestedList = list.childCount === 1;
    const from = $from.before(removesWholeNestedList ? listDepth : itemDepth);
    const to = $from.after(removesWholeNestedList ? listDepth : itemDepth);
    if (dispatch) dispatch(state.tr.delete(from, to).scrollIntoView());
    return true;
  });
}

function exitCodeBlockAtEnd(editor) {
  const context = codeBlockContext(editor.state);
  const { selection } = editor.state;
  if (!context || !selection.empty) return false;
  const codeEnd = context.start + context.node.content.size;
  if (selection.from !== codeEnd) return false;
  return editor.commands.exitCode();
}

function requestLinkEditor(editor) {
  const ownerWindow = editor.view.dom.ownerDocument.defaultView;
  const event = new ownerWindow.CustomEvent("markdowncard:edit-link", {
    bubbles: true,
    cancelable: true
  });
  editor.view.dom.dispatchEvent(event);
  return event.defaultPrevented;
}

const PROTECTED_MEDIA_NODES = new Set(["blockedImage", "youtubeCard"]);

function mediaDeletionDirection(event) {
  const key = String(event.key ?? "");
  const lowerKey = key.toLowerCase();
  if (key === "Delete" || (lowerKey === "d" && (event.ctrlKey || event.altKey))) return 1;
  if (key === "Backspace") return event.ctrlKey && event.altKey ? 1 : -1;
  if (lowerKey === "h" && event.ctrlKey) return -1;
  return 0;
}

const ProtectedMediaDeletion = Extension.create({
  name: "protectedMediaDeletion",
  priority: 200,
  addProseMirrorPlugins() {
    return [new Plugin({
      props: {
        handleKeyDown(view, event) {
          if (isIMECompositionEvent(event, view)) return false;
          const direction = mediaDeletionDirection(event);
          if (direction === 0) return false;
          const { selection } = view.state;

          // A held key must not turn the visible selection step into an
          // immediate deletion. Releasing and pressing again remains a fully
          // keyboard-accessible, explicit delete action.
          if (selection instanceof NodeSelection
              && PROTECTED_MEDIA_NODES.has(selection.node.type.name)) {
            return event.repeat;
          }
          if (!(selection instanceof TextSelection) || !selection.empty) return false;

          const adjacentNode = direction < 0
            ? selection.$from.nodeBefore
            : selection.$from.nodeAfter;
          if (!PROTECTED_MEDIA_NODES.has(adjacentNode?.type.name)) return false;
          const position = direction < 0
            ? selection.from - adjacentNode.nodeSize
            : selection.from;
          view.dispatch(
            view.state.tr.setSelection(NodeSelection.create(view.state.doc, position))
              .scrollIntoView()
          );
          return true;
        }
      }
    })];
  }
});

const RaycastShortcuts = Extension.create({
  name: "raycastShortcuts",
  priority: 110,
  addKeyboardShortcuts() {
    const toggleTaskAtSelection = () => {
      const { $from } = this.editor.state.selection;
      for (let depth = $from.depth; depth > 0; depth -= 1) {
        const node = $from.node(depth);
        if (node.type.name !== "taskItem") continue;
        const position = $from.before(depth);
        return this.editor.commands.command(({ tr }) => {
          tr.setNodeMarkup(position, undefined, { ...node.attrs, checked: !node.attrs.checked });
          return true;
        });
      }
      return false;
    };

    const shortcuts = {
      "Mod-b": () => this.editor.commands.toggleBold(),
      "Mod-i": () => this.editor.commands.toggleItalic(),
      "Mod-Shift-s": () => this.editor.commands.toggleStrike(),
      "Mod-e": () => this.editor.commands.toggleCode(),
      "Mod-0": () => this.editor.commands.setParagraph(),
      "Mod-1": () => this.editor.commands.toggleHeading({ level: 1 }),
      "Mod-2": () => this.editor.commands.toggleHeading({ level: 2 }),
      "Mod-3": () => this.editor.commands.toggleHeading({ level: 3 }),
      "Mod-4": () => this.editor.commands.toggleHeading({ level: 4 }),
      "Mod-5": () => this.editor.commands.toggleHeading({ level: 5 }),
      "Mod-6": () => this.editor.commands.toggleHeading({ level: 6 }),
      "Mod-Alt-1": () => this.editor.commands.toggleHeading({ level: 1 }),
      "Mod-Alt-2": () => this.editor.commands.toggleHeading({ level: 2 }),
      "Mod-Alt-3": () => this.editor.commands.toggleHeading({ level: 3 }),
      "Mod-Shift-7": () => this.editor.commands.toggleOrderedList(),
      "Mod-Shift-8": () => this.editor.commands.toggleBulletList(),
      "Mod-Shift-9": () => this.editor.commands.toggleTaskList(),
      "Mod-Enter": () => {
        if (codeBlockContext(this.editor.state)) {
          exitCodeBlockAtEnd(this.editor);
          return true;
        }
        return toggleTaskAtSelection();
      },
      "Backspace": () => deleteEmptyNestedListItem(this.editor),
      "Tab": () => indentCodeBlock(this.editor, false) || indentList(this.editor, false),
      "Shift-Tab": () => indentCodeBlock(this.editor, true) || indentList(this.editor, true),
      "Mod-k": () => requestLinkEditor(this.editor)
    };
    return Object.fromEntries(Object.entries(shortcuts).map(([key, command]) => [
      key,
      () => editorIsComposing(this.editor) ? false : command()
    ]));
  }
});

const MarkdownInlineRules = Extension.create({
  name: "markdownInlineRules",
  addInputRules() {
    return [
      new InputRule({
        find: /\[([^\]]+)\]\(((?:https?:\/\/|mailto:)[^\s)]+)(?:\s+\"([^\"]*)\")?\)$/i,
        handler: ({ state, range, match }) => {
          const [, label, href, title] = match;
          const link = state.schema.marks.link;
          if (!link || !isExternalURL(href)) return;
          state.tr.replaceWith(
            range.from,
            range.to,
            state.schema.text(label, [link.create({ href, title: title || null })])
          );
        }
      })
    ];
  }
});

export function protectUnsafeMarkdown(value) {
  const lines = String(value ?? "").replace(/\r\n?/g, "\n").split("\n");
  let fence = null;
  return lines.map((line) => {
    const match = line.match(/^\s{0,3}(`{3,}|~{3,})(.*)$/);
    if (match && !fence) {
      fence = { marker: match[1][0], length: match[1].length };
      return line;
    }
    if (
      match
      && fence
      && match[1][0] === fence.marker
      && match[1].length >= fence.length
      && match[2].trim() === ""
    ) {
      fence = null;
      return line;
    }
    if (fence) return line;
    return line.replace(/<(?=\/?(?:script|style|iframe|object|embed|form|img|video|audio|link|meta|[a-z][\w-]*)\b)/gi, "&lt;");
  }).join("\n");
}

const SMART_LINK_PROVIDERS = Object.freeze({
  apple: Object.freeze({
    id: "apple",
    label: "Apple",
    hostnames: Object.freeze([
      "apple.com",
      "www.apple.com",
      "support.apple.com",
      "developer.apple.com"
    ])
  }),
  github: Object.freeze({
    id: "github",
    label: "GitHub",
    hostnames: Object.freeze(["github.com", "www.github.com", "gist.github.com"])
  }),
  huggingface: Object.freeze({
    id: "huggingface",
    label: "Hugging Face",
    hostnames: Object.freeze(["huggingface.co", "www.huggingface.co", "hf.co"])
  }),
  zhihu: Object.freeze({
    id: "zhihu",
    label: "知乎",
    hostnames: Object.freeze(["zhihu.com", "www.zhihu.com", "zhuanlan.zhihu.com"])
  }),
  xiaohongshu: Object.freeze({
    id: "xiaohongshu",
    label: "小红书",
    hostnames: Object.freeze([
      "xiaohongshu.com",
      "www.xiaohongshu.com",
      "xhslink.com",
      "www.xhslink.com"
    ])
  }),
  x: Object.freeze({
    id: "x",
    label: "X",
    hostnames: Object.freeze([
      "x.com",
      "www.x.com",
      "mobile.x.com",
      "twitter.com",
      "www.twitter.com",
      "mobile.twitter.com"
    ])
  }),
  figma: Object.freeze({
    id: "figma",
    label: "Figma",
    hostnames: Object.freeze(["figma.com", "www.figma.com"])
  }),
  linear: Object.freeze({
    id: "linear",
    label: "Linear",
    hostnames: Object.freeze(["linear.app", "www.linear.app"])
  }),
  notion: Object.freeze({
    id: "notion",
    label: "Notion",
    hostnames: Object.freeze(["notion.so", "www.notion.so"]),
    hostnameSuffixes: Object.freeze(["notion.site"])
  }),
  slack: Object.freeze({
    id: "slack",
    label: "Slack",
    hostnames: Object.freeze(["slack.com", "app.slack.com"]),
    hostnameSuffixes: Object.freeze(["slack.com"])
  }),
  gmail: Object.freeze({
    id: "gmail",
    label: "Gmail",
    hostnames: Object.freeze(["gmail.com", "www.gmail.com", "mail.google.com"])
  }),
  googlecalendar: Object.freeze({
    id: "googlecalendar",
    label: "Google Calendar",
    hostnames: Object.freeze(["calendar.google.com"])
  }),
  googledrive: Object.freeze({
    id: "googledrive",
    label: "Google Drive",
    hostnames: Object.freeze(["drive.google.com"])
  }),
  googledocs: Object.freeze({
    id: "googledocs",
    label: "Google Docs",
    hostnames: Object.freeze([])
  }),
  googlesheets: Object.freeze({
    id: "googlesheets",
    label: "Google Sheets",
    hostnames: Object.freeze([])
  }),
  googleslides: Object.freeze({
    id: "googleslides",
    label: "Google Slides",
    hostnames: Object.freeze([])
  }),
  gitlab: Object.freeze({
    id: "gitlab",
    label: "GitLab",
    hostnames: Object.freeze(["gitlab.com", "www.gitlab.com"])
  }),
  arxiv: Object.freeze({
    id: "arxiv",
    label: "arXiv",
    hostnames: Object.freeze(["arxiv.org", "www.arxiv.org", "export.arxiv.org"])
  }),
  openreview: Object.freeze({
    id: "openreview",
    label: "OpenReview",
    hostnames: Object.freeze(["openreview.net", "www.openreview.net"])
  }),
  doi: Object.freeze({
    id: "doi",
    label: "DOI",
    hostnames: Object.freeze(["doi.org", "dx.doi.org"])
  }),
  paperswithcode: Object.freeze({
    id: "paperswithcode",
    label: "Papers with Code",
    hostnames: Object.freeze(["paperswithcode.com", "www.paperswithcode.com"])
  }),
  kaggle: Object.freeze({
    id: "kaggle",
    label: "Kaggle",
    hostnames: Object.freeze(["kaggle.com", "www.kaggle.com"])
  }),
  openai: Object.freeze({
    id: "openai",
    label: "OpenAI",
    hostnames: Object.freeze(["openai.com", "www.openai.com", "chatgpt.com", "www.chatgpt.com"]),
    hostnameSuffixes: Object.freeze(["openai.com"])
  }),
  googlecolab: Object.freeze({
    id: "googlecolab",
    label: "Google Colab",
    hostnames: Object.freeze(["colab.research.google.com"])
  }),
  youtube: Object.freeze({
    id: "youtube",
    label: "YouTube",
    hostnames: Object.freeze([
      "youtube.com",
      "www.youtube.com",
      "m.youtube.com",
      "youtu.be",
      "www.youtu.be"
    ])
  }),
  bilibili: Object.freeze({
    id: "bilibili",
    label: "哔哩哔哩",
    hostnames: Object.freeze([
      "bilibili.com",
      "www.bilibili.com",
      "m.bilibili.com",
      "b23.tv",
      "www.b23.tv"
    ])
  }),
  web: Object.freeze({
    id: "web",
    label: "Website",
    hostnames: Object.freeze([])
  })
});

const SMART_LINK_PROVIDER_BY_HOST = new Map(
  Object.values(SMART_LINK_PROVIDERS).flatMap((provider) => (
    provider.hostnames.map((hostname) => [hostname, provider])
  ))
);

const SMART_LINK_SUFFIX_PROVIDERS = Object.freeze(
  Object.values(SMART_LINK_PROVIDERS).flatMap((provider) => (
    (provider.hostnameSuffixes ?? []).map((hostname) => Object.freeze({ hostname, provider }))
  ))
);

const SMART_LINK_TITLE_PART_LIMIT = 64;
const SMART_LINK_TITLE_LIMIT = 120;
const SMART_LINK_CONTROL_CHARACTERS = /[\u0000-\u001f\u007f-\u009f]/gu;
const SMART_LINK_BIDI_CONTROLS = /[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/gu;
const SMART_LINK_MARKDOWN_REPLACEMENTS = Object.freeze({
  "\\": "＼",
  "[": "［",
  "]": "］",
  "*": "＊",
  _: "＿",
  "`": "｀",
  "~": "～",
  "|": "｜",
  "^": "＾",
  $: "＄"
});

function sanitizedSmartLinkText(value, limit = SMART_LINK_TITLE_PART_LIMIT) {
  const normalized = String(value ?? "")
    .normalize("NFC")
    .replace(SMART_LINK_CONTROL_CHARACTERS, " ")
    .replace(SMART_LINK_BIDI_CONTROLS, "")
    .replace(/\s+/gu, " ")
    .trim()
    .replace(/[\\[\]*_`~|^$]/gu, (character) => SMART_LINK_MARKDOWN_REPLACEMENTS[character]);
  return [...normalized].slice(0, limit).join("");
}

function classifiedSmartLink(value) {
  let url;
  try {
    url = new URL(String(value ?? ""));
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  if (url.username || url.password) return null;
  const hostname = url.hostname.toLowerCase().replace(/\.$/u, "");
  let provider;
  if (hostname === "docs.google.com") {
    const route = url.pathname.split("/").filter(Boolean)[0]?.toLowerCase();
    provider = route === "spreadsheets"
      ? SMART_LINK_PROVIDERS.googlesheets
      : route === "presentation"
        ? SMART_LINK_PROVIDERS.googleslides
        : SMART_LINK_PROVIDERS.googledocs;
  } else {
    provider = SMART_LINK_PROVIDER_BY_HOST.get(hostname)
      ?? SMART_LINK_SUFFIX_PROVIDERS.find(({ hostname: suffix }) => (
        hostname === suffix || hostname.endsWith(`.${suffix}`)
      ))?.provider
      ?? SMART_LINK_PROVIDERS.web;
  }
  return { provider, url };
}

export function smartLinkProviderForURL(value) {
  return classifiedSmartLink(value)?.provider ?? null;
}

function decodedURLPathSegments(url) {
  return url.pathname.split("/").filter(Boolean).map((segment) => {
    try {
      return sanitizedSmartLinkText(decodeURIComponent(segment));
    } catch {
      return sanitizedSmartLinkText(segment);
    }
  }).filter(Boolean);
}

function compactURLSlug(value) {
  return sanitizedSmartLinkText(String(value ?? "")
    .replace(/\.(?:html?|md)$/iu, "")
    .replace(/[-_]+/gu, " ")
    .replace(/\s+/gu, " ")
    .trim());
}

function githubSmartLinkTitle(url) {
  const segments = decodedURLPathSegments(url);
  if (url.hostname.toLowerCase() === "gist.github.com") {
    return segments[0] ? `${segments[0]} · Gist` : "GitHub Gist";
  }
  if (segments.length < 2) {
    return segments[0] ? `@${segments[0]} · GitHub` : "GitHub";
  }
  const repository = `${segments[0]}/${segments[1].replace(/\.git$/iu, "")}`;
  const itemKind = segments[2]?.toLowerCase();
  const itemNumber = segments[3];
  if (itemKind === "issues" && /^\d+$/u.test(itemNumber ?? "")) {
    return `${repository} · Issue #${itemNumber}`;
  }
  if (itemKind === "pull" && /^\d+$/u.test(itemNumber ?? "")) {
    return `${repository} · PR #${itemNumber}`;
  }
  if (itemKind === "discussions" && /^\d+$/u.test(itemNumber ?? "")) {
    return `${repository} · Discussion #${itemNumber}`;
  }
  return repository;
}

function huggingFaceSmartLinkTitle(url) {
  const segments = decodedURLPathSegments(url);
  const collection = segments[0]?.toLowerCase();
  if (["datasets", "spaces"].includes(collection) && segments.length >= 3) {
    const kind = collection === "datasets" ? "Dataset" : "Space";
    return `${segments[1]}/${segments[2]} · ${kind}`;
  }
  if (segments.length >= 2) return `${segments[0]}/${segments[1]}`;
  return segments[0] ? `${segments[0]} · Hugging Face` : "Hugging Face";
}

function zhihuSmartLinkTitle(url) {
  const segments = decodedURLPathSegments(url);
  const route = segments[0]?.toLowerCase();
  if (route === "question" && segments[1]) return `知乎问题 #${segments[1]}`;
  if ((route === "p" || route === "article") && segments[1]) {
    return `知乎文章 #${segments[1]}`;
  }
  if (route === "column" && segments[1]) return `知乎专栏 · ${segments[1]}`;
  if (route === "people" && segments[1]) return `知乎 · ${segments[1]}`;
  return "知乎链接";
}

function xSmartLinkTitle(url) {
  const segments = decodedURLPathSegments(url);
  const username = segments[0]?.replace(/^@/u, "");
  if (!username) return "X";
  if (segments[1]?.toLowerCase() === "status" && segments[2]) {
    return `@${username} · Post`;
  }
  return `@${username}`;
}

function appleSmartLinkTitle(url) {
  const hostname = url.hostname.toLowerCase();
  const segments = decodedURLPathSegments(url);
  const slug = compactURLSlug(segments.at(-1));
  const area = hostname === "developer.apple.com"
    ? "Apple Developer"
    : hostname === "support.apple.com"
      ? "Apple 支持"
      : "Apple";
  return slug ? `${area} · ${slug}` : area;
}

function repositorySmartLinkTitle(url, providerLabel) {
  const segments = decodedURLPathSegments(url);
  if (segments.length >= 2) {
    return `${segments[0]}/${segments[1].replace(/\.git$/iu, "")}`;
  }
  return segments[0] ? `${segments[0]} · ${providerLabel}` : providerLabel;
}

function arxivSmartLinkTitle(url) {
  const segments = decodedURLPathSegments(url);
  const route = segments.shift()?.toLowerCase();
  if (!["abs", "pdf", "html"].includes(route)) return "arXiv";
  const identifier = segments.join("/").replace(/\.pdf$/iu, "");
  return identifier ? `arXiv · ${identifier}` : "arXiv";
}

function openReviewSmartLinkTitle(url) {
  const identifier = sanitizedSmartLinkText(
    url.searchParams.get("id") ?? url.searchParams.get("forum") ?? ""
  );
  return identifier ? `OpenReview · ${identifier}` : "OpenReview";
}

function designDocumentSmartLinkTitle(url, providerLabel) {
  const segments = decodedURLPathSegments(url);
  const slug = compactURLSlug(segments.at(-1));
  return slug ? `${providerLabel} · ${slug}` : providerLabel;
}

function bilibiliSmartLinkTitle(url) {
  const segments = decodedURLPathSegments(url);
  const route = segments[0]?.toLowerCase();
  if (route === "video" && segments[1]) return `哔哩哔哩 · ${segments[1]}`;
  return "哔哩哔哩";
}

function genericSmartLinkTitle(url) {
  return sanitizedSmartLinkText(
    url.hostname.toLowerCase().replace(/\.$/u, "").replace(/^www\./u, ""),
    SMART_LINK_TITLE_LIMIT
  );
}

export function smartLinkTitleForURL(value) {
  const classified = classifiedSmartLink(value);
  if (!classified) return null;
  const { provider, url } = classified;
  let title;
  switch (provider.id) {
  case "apple": title = appleSmartLinkTitle(url); break;
  case "github": title = githubSmartLinkTitle(url); break;
  case "gitlab": title = repositorySmartLinkTitle(url, provider.label); break;
  case "huggingface": title = huggingFaceSmartLinkTitle(url); break;
  case "zhihu": title = zhihuSmartLinkTitle(url); break;
  case "xiaohongshu": title = url.hostname.toLowerCase().endsWith("xhslink.com")
    ? "小红书链接"
    : "小红书笔记"; break;
  case "x": title = xSmartLinkTitle(url); break;
  case "arxiv": title = arxivSmartLinkTitle(url); break;
  case "openreview": title = openReviewSmartLinkTitle(url); break;
  case "doi": {
    const identifier = decodedURLPathSegments(url).join("/");
    title = identifier ? `DOI · ${identifier}` : "DOI";
    break;
  }
  case "figma": title = designDocumentSmartLinkTitle(url, provider.label); break;
  case "linear": title = designDocumentSmartLinkTitle(url, provider.label); break;
  case "notion": title = designDocumentSmartLinkTitle(url, provider.label); break;
  case "paperswithcode": title = designDocumentSmartLinkTitle(url, provider.label); break;
  case "kaggle": title = designDocumentSmartLinkTitle(url, provider.label); break;
  case "openai": title = designDocumentSmartLinkTitle(url, provider.label); break;
  case "bilibili": title = bilibiliSmartLinkTitle(url); break;
  case "web": title = genericSmartLinkTitle(url); break;
  default: title = provider.label;
  }
  return sanitizedSmartLinkText(title, SMART_LINK_TITLE_LIMIT)
    || sanitizedSmartLinkText(provider.label, SMART_LINK_TITLE_LIMIT);
}

function markdownSafeSmartLinkHref(value) {
  const classified = classifiedSmartLink(value);
  if (!classified) return null;
  // URL.href canonicalizes whitespace, angle brackets, and authority backslashes.
  // Parentheses and query backslashes remain legal URL characters but are unsafe
  // in a bare Markdown link destination, so percent-encode them before storage.
  return classified.url.href.replace(/[()\\]/gu, (character) => (
    `%${character.codePointAt(0).toString(16).toUpperCase().padStart(2, "0")}`
  ));
}

export function standaloneSmartLinkForParagraph(node) {
  if (node?.type?.name !== "paragraph" || node.childCount === 0) return null;
  if (!String(node.textContent ?? "").trim()) return null;
  let href = null;
  let isStandaloneLink = true;
  node.forEach((child) => {
    if (!isStandaloneLink || !child.isText) {
      isStandaloneLink = false;
      return;
    }
    const linkMarks = child.marks.filter((mark) => mark.type.name === "link");
    if (linkMarks.length !== 1) {
      isStandaloneLink = false;
      return;
    }
    const childHref = String(linkMarks[0].attrs?.href ?? "");
    if (!href) href = childHref;
    else if (href !== childHref) isStandaloneLink = false;
  });
  if (!isStandaloneLink || !href) return null;
  const provider = smartLinkProviderForURL(href);
  return provider ? { href, provider } : null;
}

function smartLinkDecorationSet(documentNode) {
  const decorations = [];
  documentNode.descendants((node, position) => {
    const smartLink = standaloneSmartLinkForParagraph(node);
    if (!smartLink) return;
    decorations.push(Decoration.node(position, position + node.nodeSize, {
      class: "smart-link-block",
      "data-smart-link-provider": smartLink.provider.id
    }));
  });
  return DecorationSet.create(documentNode, decorations);
}

const SmartLinkBlocks = Extension.create({
  name: "smartLinkBlocks",
  addProseMirrorPlugins() {
    return [new Plugin({
      state: {
        init: (_configuration, state) => smartLinkDecorationSet(state.doc),
        apply(transaction, decorationSet, _oldState, newState) {
          return transaction.docChanged
            ? smartLinkDecorationSet(newState.doc)
            : decorationSet;
        }
      },
      props: {
        decorations(state) {
          return this.getState(state);
        }
      }
    })];
  }
});

function allowedLinkHref(href, options) {
  return options.isAllowedUri(href, {
    defaultValidate: (value) => Boolean(isAllowedLinkUri(value, options.protocols)),
    protocols: options.protocols,
    defaultProtocol: options.defaultProtocol
  });
}

function applySmartLinkMarkAttributes(anchor, icon, mark, options) {
  const attributes = { ...options.HTMLAttributes, ...mark.attrs };
  const href = String(attributes.href ?? "");
  const provider = smartLinkProviderForURL(href);
  const classNames = [options.HTMLAttributes?.class, attributes.class, provider ? "smart-link" : null]
    .flatMap((value) => String(value ?? "").split(/\s+/u))
    .filter(Boolean);
  if (provider) classNames.push(`smart-link-${provider.id}`);
  anchor.className = [...new Set(classNames)].join(" ");

  const safeHref = allowedLinkHref(href, options) ? href : "";
  anchor.setAttribute("href", safeHref);
  for (const name of ["target", "rel", "title"]) {
    const value = attributes[name];
    if (value == null || value === "") anchor.removeAttribute(name);
    else anchor.setAttribute(name, String(value));
  }

  if (!icon) return provider;
  icon.replaceChildren();
  icon.hidden = !provider;
  if (provider) {
    anchor.dataset.smartLinkProvider = provider.id;
    renderSmartLinkIcon(icon, provider.id);
  } else {
    delete anchor.dataset.smartLinkProvider;
  }
  return provider;
}

const SmartLink = Link.extend({
  addMarkView() {
    const options = this.options;
    return ({ mark, view }) => {
      const ownerDocument = view.dom.ownerDocument;
      const anchor = ownerDocument.createElement("a");
      const initialProvider = smartLinkProviderForURL(mark.attrs?.href);
      if (!initialProvider) {
        applySmartLinkMarkAttributes(anchor, null, mark, options);
        return {
          dom: anchor,
          contentDOM: anchor,
          update(nextMark) {
            if (nextMark.type.name !== "link") return false;
            if (smartLinkProviderForURL(nextMark.attrs?.href)) return false;
            applySmartLinkMarkAttributes(anchor, null, nextMark, options);
            return true;
          }
        };
      }
      const icon = ownerDocument.createElement("span");
      const title = ownerDocument.createElement("span");
      icon.className = "smart-link-icon";
      icon.setAttribute("aria-hidden", "true");
      icon.setAttribute("data-markdown-copy", "exclude");
      icon.setAttribute("contenteditable", "false");
      icon.setAttribute("draggable", "false");
      title.className = "smart-link-title";
      anchor.append(icon, title);
      applySmartLinkMarkAttributes(anchor, icon, mark, options);
      return {
        dom: anchor,
        contentDOM: title,
        update(nextMark) {
          if (nextMark.type.name !== "link") return false;
          if (!smartLinkProviderForURL(nextMark.attrs?.href)) return false;
          applySmartLinkMarkAttributes(anchor, icon, nextMark, options);
          return true;
        },
        ignoreMutation(mutation) {
          return mutation.target === icon
            || icon.contains(mutation.target);
        }
      };
    };
  }
});

export function insertSmartLinkFromPaste(view, value) {
  const source = String(value ?? "").trim();
  const provider = smartLinkProviderForURL(source);
  if (!source || /\s/u.test(source) || !provider) return false;
  // Let the dedicated YouTube extension keep producing its existing cover card.
  // Returning false here allows the next ProseMirror paste handler to own it.
  if (provider.id === "youtube" && parseYouTubeURL(source)) return false;
  const { state } = view;
  const { selection } = state;
  const hasEmptyTextSelection = selection instanceof TextSelection
    && selection.empty
    && selection.$from.parent.type.name === "paragraph"
    && selection.$from.parent.content.size === 0;
  const isPristineEmptyDocument = state.doc.childCount === 1
    && state.doc.firstChild?.type.name === "paragraph"
    && state.doc.firstChild.content.size === 0;
  if (!hasEmptyTextSelection && !isPristineEmptyDocument) return false;
  const linkType = state.schema.marks.link;
  const title = smartLinkTitleForURL(source);
  const safeHref = markdownSafeSmartLinkHref(source);
  if (!linkType || !title || !safeHref) return false;

  const linkedTitle = state.schema.text(title, [linkType.create({ href: safeHref })]);
  const transaction = state.tr;
  if (!hasEmptyTextSelection) {
    transaction.setSelection(TextSelection.create(transaction.doc, 1));
  }
  transaction
    .replaceSelectionWith(linkedTitle, false)
    .setMeta("markdownCardSmartLinkPaste", true)
    .scrollIntoView();
  view.dispatch(transaction);
  return true;
}

export function createEditorExtensions() {
  return [
    StarterKit.configure({
      codeBlock: false,
      trailingNode: false,
      heading: { levels: [1, 2, 3, 4, 5, 6] },
      link: false
    }),
    SmartLink.configure({
      openOnClick: false,
      autolink: false,
      linkOnPaste: true
    }),
    SmartLinkBlocks,
    LanguageCodeBlock.configure({ lowlight: explicitLowlight, defaultLanguage: null }),
    TableKit.configure({ table: { resizable: false, renderWrapper: true } }),
    TaskList,
    ContextualTaskItem.configure({ nested: true }),
    InlineMath,
    BlockMath,
    FootnoteReference,
    FootnoteDefinition,
    FootnoteNavigation,
    BlockedImage,
    ...createRendererPluginExtensions(),
    Placeholder.configure({
      placeholder: "Start writing… Type / for commands",
      showOnlyCurrent: true,
      showOnlyWhenEditable: true
    }),
    Markdown.configure({
      indentation: { style: "space", size: 2 },
      markedOptions: { gfm: true, breaks: false }
    }),
    HeadingLinkRepair,
    MarkdownInlineRules,
    ProtectedMediaDeletion,
    RaycastShortcuts
  ];
}

export function isExternalURL(value) {
  return EXTERNAL_PROTOCOL.test(String(value ?? ""));
}
