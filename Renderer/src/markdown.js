import { Extension, InputRule, Node, mergeAttributes, textblockTypeInputRule } from "@tiptap/core";
import { CodeBlockLowlight } from "@tiptap/extension-code-block-lowlight";
import { TaskItem, TaskList } from "@tiptap/extension-list";
import { TableKit } from "@tiptap/extension-table";
import { Markdown } from "@tiptap/markdown";
import { Fragment } from "@tiptap/pm/model";
import { TextSelection } from "@tiptap/pm/state";
import { StarterKit } from "@tiptap/starter-kit";
import katex from "katex";
import { common, createLowlight } from "lowlight";
import { createRendererPluginExtensions } from "./plugins.js";

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

export function normalizeCodeLanguage(value) {
  const language = String(value ?? "")
    .trim()
    .split(/\s+/, 1)[0]
    .toLowerCase();
  return LANGUAGE_ALIASES.get(language) ?? language;
}

const LanguageCodeBlock = CodeBlockLowlight.extend({
  parseMarkdown(token, helpers) {
    if (
      token.raw?.startsWith("```") === false
      && token.raw?.startsWith("~~~") === false
      && token.codeBlockStyle !== "indented"
    ) {
      return [];
    }
    const language = normalizeCodeLanguage(token.lang) || null;
    return helpers.createNode(
      "codeBlock",
      { language },
      token.text ? [helpers.createTextNode(token.text)] : []
    );
  },

  renderMarkdown(node, helpers) {
    const language = normalizeCodeLanguage(node.attrs?.language);
    if (!node.content) return `\`\`\`${language}\n\n\`\`\``;
    return [`\`\`\`${language}`, helpers.renderChildren(node.content), "```"].join("\n");
  },

  addInputRules() {
    const attributes = (match) => ({ language: normalizeCodeLanguage(match[1]) || null });
    return [
      textblockTypeInputRule({
        find: /^```([A-Za-z0-9_+#.-]+)?[\s\n]$/,
        type: this.type,
        getAttributes: attributes
      }),
      textblockTypeInputRule({
        find: /^~~~([A-Za-z0-9_+#.-]+)?[\s\n]$/,
        type: this.type,
        getAttributes: attributes
      })
    ];
  }
});

const ContextualTaskItem = TaskItem.extend({
  addInputRules() {
    return [new InputRule({
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
        const checked = String(props.match[props.match.length - 1] ?? "").toLowerCase() === "x";
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
        props.state.tr.setSelection(TextSelection.near(props.state.tr.doc.resolve(taskListStart + 3)));
      }
    })];
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
          const finish = (shouldCommit) => {
            if (finalized) return;
            finalized = true;
            editing = false;
            input.removeEventListener("blur", commit);
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

          input.addEventListener("blur", commit);
          input.addEventListener("keydown", (event) => {
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
const LOCAL_ATTACHMENT_PATTERN = /^attachments\/([A-Fa-f0-9-]{36})\.png$/;

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
      title: { default: null }
    };
  },

  renderHTML({ node }) {
    const attachmentID = String(node.attrs.src ?? "").match(LOCAL_ATTACHMENT_PATTERN)?.[1];
    if (attachmentID) {
      return ["img", {
        class: "local-attachment",
        src: `mdcard-asset://attachment/${attachmentID}.png`,
        "data-source": node.attrs.src,
        alt: node.attrs.alt || "Pasted image",
        title: node.attrs.title || null,
        draggable: "false"
      }];
    }
    return ["span", {
      class: "image-blocked",
      "data-source": node.attrs.src,
      role: "note",
      "aria-label": `Image blocked: ${node.attrs.alt || "image"}`
    }, `Image blocked · ${node.attrs.alt || "image"}`];
  },

  markdownTokenName: "image",
  parseMarkdown(token) {
    return {
      type: "blockedImage",
      attrs: {
        src: String(token.href ?? ""),
        alt: String(token.text ?? "image"),
        title: token.title == null ? null : String(token.title)
      }
    };
  },
  renderMarkdown(node) {
    const alt = escapeMarkdownText(node.attrs?.alt || "image");
    const src = escapeDestination(node.attrs?.src || "");
    const title = node.attrs?.title ? ` \"${String(node.attrs.title).replace(/\"/g, "\\\"")}\"` : "";
    return `![${alt}](${src}${title})`;
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

function indentList(editor, reverse) {
  const itemName = listItemAtSelection(editor);
  if (!itemName) return false;
  if (reverse) editor.commands.liftListItem(itemName);
  else editor.commands.sinkListItem(itemName);
  return true;
}

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

    return {
      "Mod-b": () => this.editor.commands.toggleBold(),
      "Mod-i": () => this.editor.commands.toggleItalic(),
      "Mod-Shift-s": () => this.editor.commands.toggleStrike(),
      "Mod-e": () => this.editor.commands.toggleCode(),
      "Mod-Alt-1": () => this.editor.commands.toggleHeading({ level: 1 }),
      "Mod-Alt-2": () => this.editor.commands.toggleHeading({ level: 2 }),
      "Mod-Alt-3": () => this.editor.commands.toggleHeading({ level: 3 }),
      "Mod-Shift-7": () => this.editor.commands.toggleOrderedList(),
      "Mod-Shift-8": () => this.editor.commands.toggleBulletList(),
      "Mod-Shift-9": () => this.editor.commands.toggleTaskList(),
      "Mod-Enter": toggleTaskAtSelection,
      "Tab": () => indentCodeBlock(this.editor, false) || indentList(this.editor, false),
      "Shift-Tab": () => indentCodeBlock(this.editor, true) || indentList(this.editor, true),
      "Mod-l": () => {
        if (this.editor.isActive("link")) return this.editor.commands.unsetLink();
        const { from, to } = this.editor.state.selection;
        const selected = this.editor.state.doc.textBetween(from, to, "");
        if (!EXTERNAL_PROTOCOL.test(selected)) return false;
        return this.editor.commands.setLink({ href: selected });
      }
    };
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
    const marker = line.match(/^\s{0,3}(`{3,}|~{3,})/)?.[1];
    if (marker) {
      if (!fence) fence = marker[0];
      else if (marker[0] === fence) fence = null;
      return line;
    }
    if (fence) return line;
    return line.replace(/<(?=\/?(?:script|style|iframe|object|embed|form|img|video|audio|link|meta|[a-z][\w-]*)\b)/gi, "&lt;");
  }).join("\n");
}

export function createEditorExtensions() {
  return [
    StarterKit.configure({
      codeBlock: false,
      trailingNode: false,
      heading: { levels: [1, 2, 3, 4, 5, 6] },
      link: {
        openOnClick: false,
        autolink: false,
        linkOnPaste: true,
        protocols: ["http", "https", "mailto"]
      }
    }),
    LanguageCodeBlock.configure({ lowlight: explicitLowlight, defaultLanguage: null }),
    TableKit.configure({ table: { resizable: false } }),
    TaskList,
    ContextualTaskItem.configure({ nested: true }),
    InlineMath,
    BlockMath,
    BlockedImage,
    ...createRendererPluginExtensions(),
    Markdown.configure({
      indentation: { style: "space", size: 2 },
      markedOptions: { gfm: true, breaks: false }
    }),
    MarkdownInlineRules,
    RaycastShortcuts
  ];
}

export function isExternalURL(value) {
  return EXTERNAL_PROTOCOL.test(String(value ?? ""));
}
