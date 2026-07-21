function longestRun(value, character) {
  let longest = 0;
  let current = 0;
  for (const candidate of value) {
    if (candidate === character) {
      current += 1;
      longest = Math.max(longest, current);
    } else {
      current = 0;
    }
  }
  return longest;
}

function wrapSelection(value, start, end, opening, closing = opening) {
  const selected = value.slice(start, end);
  const before = value.slice(Math.max(0, start - opening.length), start);
  const after = value.slice(end, end + closing.length);
  if (before === opening && after === closing) {
    return {
      value: `${value.slice(0, start - opening.length)}${selected}${value.slice(end + closing.length)}`,
      start: start - opening.length,
      end: end - opening.length
    };
  }
  return {
    value: `${value.slice(0, start)}${opening}${selected}${closing}${value.slice(end)}`,
    start: start + opening.length,
    end: end + opening.length
  };
}

function wrapInlineCode(value, start, end) {
  const selected = value.slice(start, end);
  const fence = "`".repeat(Math.max(1, longestRun(selected, "`") + 1));
  const needsPadding = selected.startsWith("`")
    || selected.endsWith("`")
    || (selected.startsWith(" ") && selected.endsWith(" ") && selected.trim());
  const padding = needsPadding ? " " : "";
  const opening = `${fence}${padding}`;
  const closing = `${padding}${fence}`;
  return wrapSelection(value, start, end, opening, closing);
}

function transformHeading(value, start, end, level) {
  const lineStart = value.lastIndexOf("\n", Math.max(0, start - 1)) + 1;
  const followingBreak = value.indexOf("\n", end);
  const lineEnd = followingBreak < 0 ? value.length : followingBreak;
  const block = value.slice(lineStart, lineEnd);
  const prefix = level > 0 ? `${"#".repeat(level)} ` : "";
  const transformed = block
    .split("\n")
    .map((line) => `${prefix}${line.replace(/^#{1,6}(?:[ \t]+|$)/u, "")}`)
    .join("\n");
  const deltaBefore = start - lineStart;
  const deltaAfter = lineEnd - end;
  return {
    value: `${value.slice(0, lineStart)}${transformed}${value.slice(lineEnd)}`,
    start: Math.min(lineStart + transformed.length, lineStart + Math.max(0, deltaBefore + prefix.length)),
    end: Math.max(lineStart, lineStart + transformed.length - deltaAfter)
  };
}

function addLink(value, start, end) {
  const selected = value.slice(start, end);
  const label = selected || "text";
  const destination = "https://";
  const replacement = `[${label}](${destination})`;
  const offset = start + label.length + 3;
  return {
    value: `${value.slice(0, start)}${replacement}${value.slice(end)}`,
    start: offset,
    end: offset + destination.length
  };
}

export function sourceShortcutFromEvent(event) {
  if (!event?.metaKey || event.altKey || event.ctrlKey) return null;
  const key = String(event.key ?? "").toLowerCase();
  if (event.shiftKey) return key === "s" ? "strike" : null;
  if (["b", "i", "e", "k"].includes(key)) return key;
  if (/^[0-6]$/u.test(key)) return `h${key}`;
  return null;
}

export function transformMarkdownSource(value, start, end, shortcut) {
  const source = String(value ?? "");
  const from = Math.max(0, Math.min(Number(start ?? 0), source.length));
  const to = Math.max(from, Math.min(Number(end ?? from), source.length));
  switch (shortcut) {
  case "b": return wrapSelection(source, from, to, "**");
  case "i": return wrapSelection(source, from, to, "*");
  case "e": return wrapInlineCode(source, from, to);
  case "k": return addLink(source, from, to);
  case "strike": return wrapSelection(source, from, to, "~~");
  default:
    if (/^h[0-6]$/u.test(shortcut)) {
      return transformHeading(source, from, to, Number(shortcut.slice(1)));
    }
    return null;
  }
}
