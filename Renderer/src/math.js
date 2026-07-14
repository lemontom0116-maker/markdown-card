function isEscaped(source, position) {
  let slashCount = 0;
  for (let cursor = position - 1; cursor >= 0 && source[cursor] === "\\"; cursor -= 1) {
    slashCount += 1;
  }
  return slashCount % 2 === 1;
}

export function mathPlugin(md) {
  md.inline.ruler.after("escape", "markdown_card_inline_math", (state, silent) => {
    const start = state.pos;
    if (state.src[start] !== "$" || state.src[start + 1] === "$" || isEscaped(state.src, start)) {
      return false;
    }

    let end = start + 1;
    while (end < state.posMax) {
      if (state.src[end] === "\n") return false;
      if (state.src[end] === "$" && !isEscaped(state.src, end)) break;
      end += 1;
    }

    if (end >= state.posMax || end === start + 1) return false;

    const content = state.src.slice(start + 1, end);
    if (/^\s|\s$/.test(content)) return false;

    if (!silent) {
      const token = state.push("math_inline", "math", 0);
      token.content = content;
    }
    state.pos = end + 1;
    return true;
  });

  md.block.ruler.after(
    "blockquote",
    "markdown_card_block_math",
    (state, startLine, endLine, silent) => {
      const start = state.bMarks[startLine] + state.tShift[startLine];
      const max = state.eMarks[startLine];
      const openingLine = state.src.slice(start, max).trim();

      if (!openingLine.startsWith("$$")) return false;

      const oneLine = openingLine.length > 4 && openingLine.endsWith("$$");
      let content = oneLine ? openingLine.slice(2, -2).trim() : openingLine.slice(2);
      let nextLine = startLine + 1;
      let foundClosing = oneLine;

      while (!foundClosing && nextLine < endLine) {
        const lineStart = state.bMarks[nextLine] + state.tShift[nextLine];
        const lineEnd = state.eMarks[nextLine];
        const line = state.src.slice(lineStart, lineEnd);
        const trimmed = line.trim();

        if (trimmed.endsWith("$$")) {
          content += `${content ? "\n" : ""}${line.slice(0, line.lastIndexOf("$$"))}`;
          foundClosing = true;
          nextLine += 1;
          break;
        }

        content += `${content ? "\n" : ""}${line}`;
        nextLine += 1;
      }

      if (!foundClosing) return false;
      if (silent) return true;

      const token = state.push("math_block", "math", 0);
      token.block = true;
      token.content = content.trim();
      token.map = [startLine, nextLine];
      state.line = nextLine;
      return true;
    },
    { alt: ["paragraph", "reference", "blockquote", "list"] }
  );
}
