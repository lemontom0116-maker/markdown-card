const mermaidInstancePromises = new WeakMap();
const mermaidVendorGlobal = "__markdownCardMermaidVendor";
const mermaidVendorScript = "./mermaid-vendor.js";
let mermaidRenderSequence = 0;

function configuredMermaid(ownerDocument) {
  const ownerWindow = ownerDocument.defaultView;
  if (!ownerWindow) return Promise.reject(new Error("Mermaid requires a browser window"));

  const existingPromise = mermaidInstancePromises.get(ownerWindow);
  if (existingPromise) return existingPromise;

  const instancePromise = loadMermaidVendor(ownerDocument)
    .then((mermaid) => {
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: "strict",
        htmlLabels: false,
        suppressErrorRendering: true,
        deterministicIds: true,
        deterministicIDSeed: "markdown-card",
        flowchart: { htmlLabels: false, useMaxWidth: true }
      });
      return mermaid;
    })
    .catch((error) => {
      mermaidInstancePromises.delete(ownerWindow);
      throw error;
    });
  mermaidInstancePromises.set(ownerWindow, instancePromise);
  return instancePromise;
}

function loadMermaidVendor(ownerDocument) {
  const ownerWindow = ownerDocument.defaultView;
  const loadedVendor = ownerWindow?.[mermaidVendorGlobal];
  if (loadedVendor) return Promise.resolve(loadedVendor.default ?? loadedVendor);

  return new Promise((resolve, reject) => {
    const script = ownerDocument.createElement("script");
    script.src = mermaidVendorScript;
    script.async = true;
    script.dataset.markdownCardVendor = "mermaid";

    script.addEventListener("load", () => {
      const vendor = ownerWindow?.[mermaidVendorGlobal];
      if (!vendor) {
        script.remove();
        reject(new Error("The local Mermaid vendor loaded without an API"));
        return;
      }
      resolve(vendor.default ?? vendor);
    }, { once: true });
    script.addEventListener("error", () => {
      script.remove();
      reject(new Error("Unable to load the local Mermaid renderer"));
    }, { once: true });

    ownerDocument.head.append(script);
  });
}

function removeUnsafeSVGContent(container) {
  for (const element of container.querySelectorAll(
    "script, foreignObject, iframe, object, embed, audio, video"
  )) {
    element.remove();
  }
  for (const element of container.querySelectorAll("*")) {
    for (const attribute of [...element.attributes]) {
      const name = attribute.name.toLowerCase();
      const value = attribute.value.trim().toLowerCase();
      if (name.startsWith("on") || (name === "href" && value.startsWith("javascript:"))) {
        element.removeAttribute(attribute.name);
      }
    }
  }
}

export function mermaidAccessibleLabel(source) {
  const firstMeaningfulLine = String(source ?? "")
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .find((line) => line && !line.startsWith("%%"));
  return firstMeaningfulLine
    ? `Mermaid diagram: ${firstMeaningfulLine.slice(0, 160)}`
    : "Mermaid diagram";
}

export async function renderMermaidInto(container, source) {
  const ownerWindow = container.ownerDocument.defaultView;
  const override = ownerWindow?.__markdownCardMermaidRenderer;
  const render = typeof override === "function"
    ? override
    : async (identifier, diagram) => {
      const mermaid = await configuredMermaid(container.ownerDocument);
      return mermaid.render(identifier, diagram);
    };
  const identifier = `mdcard-mermaid-${++mermaidRenderSequence}`;
  const result = await render(identifier, String(source ?? ""));
  const svg = typeof result === "string" ? result : result?.svg;
  if (!svg || !/<svg\b/iu.test(svg)) throw new Error("Mermaid did not produce an SVG diagram");
  const staging = container.ownerDocument.createElement("div");
  staging.innerHTML = svg;
  removeUnsafeSVGContent(staging);
  const renderedSVG = staging.querySelector("svg");
  if (!renderedSVG) throw new Error("Mermaid produced an invalid SVG diagram");
  renderedSVG.setAttribute("role", "img");
  renderedSVG.setAttribute("aria-label", mermaidAccessibleLabel(source));
  renderedSVG.removeAttribute("height");
  renderedSVG.style.maxWidth = "100%";
  renderedSVG.style.height = "auto";
  container.replaceChildren(renderedSVG);
  return renderedSVG;
}
