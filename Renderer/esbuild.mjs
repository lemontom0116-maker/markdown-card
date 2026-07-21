import { build } from "esbuild";
import { copyFile, mkdir, rm, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const rendererRoot = path.dirname(fileURLToPath(import.meta.url));
const outputRoot = path.resolve(rendererRoot, "../Resources/Renderer");

await rm(outputRoot, { recursive: true, force: true });
await mkdir(outputRoot, { recursive: true });

const sharedBuildOptions = {
  absWorkingDir: rendererRoot,
  bundle: true,
  legalComments: "none",
  minify: true,
  platform: "browser",
  target: ["safari17"]
};

await Promise.all([
  build({
    ...sharedBuildOptions,
    entryPoints: ["src/index.js"],
    outfile: path.join(outputRoot, "renderer.js"),
    assetNames: "assets/[name]-[hash]",
    loader: {
      ".woff": "file",
      ".woff2": "file",
      ".ttf": "file"
    }
  }),
  build({
    ...sharedBuildOptions,
    entryPoints: ["src/mermaid-vendor.js"],
    format: "iife",
    outfile: path.join(outputRoot, "mermaid-vendor.js")
  })
]);

await copyFile(
  path.join(rendererRoot, "templates/index.html"),
  path.join(outputRoot, "index.html")
);

await copyFile(
  path.join(rendererRoot, "THIRD_PARTY_NOTICES.txt"),
  path.join(outputRoot, "THIRD_PARTY_NOTICES.txt")
);

const [rendererStats, vendorStats] = await Promise.all([
  stat(path.join(outputRoot, "renderer.js")),
  stat(path.join(outputRoot, "mermaid-vendor.js"))
]);
const mebibytes = (bytes) => `${(bytes / 1024 / 1024).toFixed(2)} MiB`;
console.log(
  `Renderer written to ${outputRoot} (startup ${mebibytes(rendererStats.size)}, lazy Mermaid ${mebibytes(vendorStats.size)})`
);
