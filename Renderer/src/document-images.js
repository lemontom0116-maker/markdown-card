const LOCAL_ATTACHMENT_PATTERN = /^attachments\/([A-Fa-f0-9-]{36})\.png$/;
const ABSOLUTE_OR_SCHEME_PATTERN = /^(?:[A-Za-z][A-Za-z0-9+.-]*:|\/|~|\\)/u;

export function managedAttachmentID(source) {
  return String(source ?? "").match(LOCAL_ATTACHMENT_PATTERN)?.[1] ?? null;
}

// The renderer only classifies a path. Native code remains authoritative for
// resolving symlinks, enforcing the document root, and validating image bytes.
export function safeDocumentImagePath(source) {
  const raw = String(source ?? "").trim();
  if (!raw || raw.length > 4_096 || raw.includes("\0")) return null;
  if (ABSOLUTE_OR_SCHEME_PATTERN.test(raw) || raw.startsWith("//")) return null;

  const components = raw.split("/");
  while (components[0] === ".") components.shift();
  if (!components.length || components.some((component) => (
    component === "" || component === "." || component === ".." || component.includes("\\")
  ))) {
    return null;
  }
  return components.join("/");
}

export function documentImageURL(cardID, source) {
  const identifier = String(cardID ?? "").trim();
  const relativePath = safeDocumentImagePath(source);
  if (!identifier || !relativePath) return null;
  return `mdcard-asset://document/${encodeURIComponent(identifier)}?path=${encodeURIComponent(relativePath)}`;
}

export function documentImagePresentation({
  cardID,
  source,
  alt,
  title,
  documentImagesAvailable
}) {
  const alternativeText = alt == null ? "image" : String(alt);
  const optionalTitle = title == null || String(title).trim() === "" ? null : String(title);
  const attachmentID = managedAttachmentID(source);
  if (attachmentID) {
    return {
      kind: "attachment",
      src: `mdcard-asset://attachment/${attachmentID}.png`,
      alt: alternativeText || "Pasted image",
      title: optionalTitle
    };
  }

  const relativePath = safeDocumentImagePath(source);
  if (relativePath && documentImagesAvailable) {
    const src = documentImageURL(cardID, relativePath);
    if (src) {
      return { kind: "document", src, alt: alternativeText, title: optionalTitle };
    }
  }
  return {
    kind: "blocked",
    alt: alternativeText,
    title: optionalTitle,
    message: relativePath
      ? `Link or save this card as Markdown to load · ${alternativeText || "decorative image"}`
      : `Image blocked · ${alternativeText || "decorative image"}`
  };
}
