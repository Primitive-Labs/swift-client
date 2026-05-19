// Minimal Vite config for the E2E JS mini-app. We don't actually build
// or serve — vite-node consumes this only to know the project root and
// to enable the `?raw` import shape that the v2-generated barrel uses
// for `import modelsToml from "./schema.toml?raw"`.
//
// Keep this file present even if empty: vite-node's resolver treats the
// nearest config-bearing dir as the root, and putting it next to
// `main.ts` means relative imports against the codegen output dir
// (`./generated/`) resolve the way `pnpm exec vite-node main.ts`
// expects.
import { defineConfig } from "vite";

export default defineConfig({});
