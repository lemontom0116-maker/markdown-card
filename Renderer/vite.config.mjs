import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import path from "node:path";

const rendererRoot = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  root: path.join(rendererRoot, "src"),
  server: {
    host: "127.0.0.1",
    allowedHosts: ["terminal.local", "localhost", "127.0.0.1"]
  },
  clearScreen: false
});
