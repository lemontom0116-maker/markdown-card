function escapedExpression(value) {
  return String(value ?? "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function textMatches(value, query) {
  if (!query) return [];
  const expression = new RegExp(escapedExpression(query), "giu");
  const matches = [];
  for (const match of String(value ?? "").matchAll(expression)) {
    if (match[0].length === 0) continue;
    matches.push({ index: match.index, length: match[0].length });
  }
  return matches;
}

export function sourceSearchMatches(source, query) {
  return textMatches(source, query).map(({ index, length }) => ({
    from: index,
    to: index + length
  }));
}

// Rich replacements deliberately stay inside one ProseMirror text node. This
// keeps the first version predictable around tables, atom nodes, and marks.
export function richSearchMatches(documentNode, query) {
  const matches = [];
  if (!documentNode || !query) return matches;
  documentNode.descendants((node, position) => {
    if (!node.isText || !node.text) return;
    for (const { index, length } of textMatches(node.text, query)) {
      matches.push({
        from: position + index,
        to: position + index + length
      });
    }
  });
  return matches;
}

export function richDocumentOutline(documentNode) {
  const headings = [];
  if (!documentNode) return headings;
  documentNode.descendants((node, position) => {
    if (node.type?.name !== "heading") return;
    const text = node.textContent.trim();
    if (!text) return;
    headings.push({
      level: Math.max(1, Math.min(6, Number(node.attrs?.level ?? 1))),
      text,
      position: position + 1
    });
  });
  return headings;
}

export function sourceDocumentOutline(source) {
  const lines = String(source ?? "").split(/(?<=\n)/u);
  const headings = [];
  let offset = 0;
  let fence = null;

  for (let index = 0; index < lines.length; index += 1) {
    const rawLine = lines[index];
    const line = rawLine.replace(/\r?\n$/u, "");
    const fenceMatch = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/u);
    if (fenceMatch && fence == null) {
      fence = {
        marker: fenceMatch[1][0],
        length: fenceMatch[1].length
      };
      offset += rawLine.length;
      continue;
    }
    if (
      fenceMatch
      && fence != null
      && fenceMatch[1][0] === fence.marker
      && fenceMatch[1].length >= fence.length
      && fenceMatch[2].trim() === ""
    ) {
      fence = null;
      offset += rawLine.length;
      continue;
    }

    if (fence == null) {
      const atx = line.match(/^ {0,3}(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$/u);
      if (atx) {
        const text = atx[2].trim();
        if (text) headings.push({ level: atx[1].length, text, position: offset });
      } else if (line.trim()) {
        const next = lines[index + 1]?.replace(/\r?\n$/u, "") ?? "";
        const setext = next.match(/^ {0,3}(=+|-+)[ \t]*$/u);
        if (setext) {
          headings.push({
            level: setext[1][0] === "=" ? 1 : 2,
            text: line.trim(),
            position: offset
          });
        }
      }
    }
    offset += rawLine.length;
  }
  return headings;
}

export function markdownHeadingSlug(value) {
  return String(value ?? "")
    .trim()
    .toLocaleLowerCase()
    .replace(/[\u200B-\u200D\uFEFF]/gu, "")
    .replace(/[^\p{Letter}\p{Number}\p{Mark}\s_-]/gu, "")
    .replace(/\s+/gu, "-");
}

export function outlineWithFragments(headings) {
  const occurrences = new Map();
  return Array.from(headings ?? [], (heading) => {
    const base = markdownHeadingSlug(heading?.text);
    const occurrence = occurrences.get(base) ?? 0;
    occurrences.set(base, occurrence + 1);
    return {
      ...heading,
      fragment: occurrence === 0 ? base : `${base}-${occurrence}`
    };
  });
}

// A heading rename can change more than the renamed heading's fragment. For
// example, renaming the first of two `## Diagram` headings moves the second
// heading from `diagram-1` to `diagram`. Keep identity by outline order, but
// only when exactly one heading text changed and the outline structure stayed
// stable. Callers must additionally verify that the document transaction was
// confined to that heading before applying this plan.
export function headingFragmentRepairPlan(previousHeadings, nextHeadings) {
  const previous = outlineWithFragments(previousHeadings);
  const next = outlineWithFragments(nextHeadings);
  if (previous.length !== next.length) {
    return { kind: "ambiguous", changedIndex: null, changes: [] };
  }

  const changed = [];
  for (let index = 0; index < previous.length; index += 1) {
    if (previous[index].level !== next[index].level) {
      return { kind: "ambiguous", changedIndex: null, changes: [] };
    }
    if (previous[index].text !== next[index].text) changed.push(index);
  }
  if (changed.length === 0) return { kind: "none", changedIndex: null, changes: [] };
  if (changed.length !== 1) {
    return { kind: "ambiguous", changedIndex: null, changes: [] };
  }

  const changedIndex = changed[0];
  if (!previous[changedIndex].fragment || !next[changedIndex].fragment) {
    return { kind: "ambiguous", changedIndex, changes: [] };
  }
  const changes = previous.flatMap((heading, index) => (
    heading.fragment !== next[index].fragment
      ? [{
          from: heading.fragment,
          to: next[index].fragment,
          headingIndex: index
        }]
      : []
  ));
  return {
    kind: changes.length ? "safe" : "none",
    changedIndex,
    changes
  };
}

export function headingForFragment(headings, target) {
  const rawTarget = String(target ?? "");
  if (!rawTarget.startsWith("#")) return null;
  let fragment;
  try {
    fragment = decodeURIComponent(rawTarget.slice(1));
  } catch {
    return null;
  }
  if (!fragment) return null;
  return outlineWithFragments(headings).find((heading) => heading.fragment === fragment) ?? null;
}

export function normalizeSafeLinkTarget(value) {
  const raw = String(value ?? "").trim();
  if (!raw || /[\0\\\r\n\t ]/u.test(raw)) return null;
  if (/^(?:https?:\/\/|mailto:)[^\s]+$/iu.test(raw)) return raw;
  if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(raw)) return `mailto:${raw}`;
  if (/^#[^\s]*$/u.test(raw)) return raw;
  if (/^\.\//u.test(raw)) {
    const path = raw.split(/[?#]/u, 1)[0];
    const remainder = path.slice(2);
    if (!remainder || remainder.startsWith("/")) return null;
    if (/%(?:00|2e|2f|5c)/iu.test(path)) return null;
    const segments = remainder.split("/");
    if (segments.some((segment) => {
      if (!segment || segment === "." || segment === ".." || segment.includes(":")) return true;
      try {
        const decoded = decodeURIComponent(segment);
        return decoded === "." || decoded === ".." || /[\0\\/]/u.test(decoded);
      } catch {
        return true;
      }
    })) return null;
    return raw;
  }
  if (/^(?:localhost|[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)(?::\d+)?(?:[/?#].*)?$/u.test(raw)) {
    return `https://${raw}`;
  }
  return null;
}
