import { build } from "esbuild";
import { copyFile, mkdir, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const rendererRoot = path.dirname(fileURLToPath(import.meta.url));
const outputRoot = path.resolve(rendererRoot, "../Resources/Renderer");

await rm(outputRoot, { recursive: true, force: true });
await mkdir(outputRoot, { recursive: true });

await build({
  absWorkingDir: rendererRoot,
  entryPoints: ["src/index.js"],
  bundle: true,
  outfile: path.join(outputRoot, "renderer.js"),
  assetNames: "assets/[name]-[hash]",
  loader: {
    ".woff": "file",
    ".woff2": "file",
    ".ttf": "file"
  },
  legalComments: "none",
  minify: true,
  platform: "browser",
  target: ["safari17"]
});

await copyFile(
  path.join(rendererRoot, "templates/index.html"),
  path.join(outputRoot, "index.html")
);

console.log(`Renderer written to ${outputRoot}`);
