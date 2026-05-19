#!/usr/bin/env node
// Run js-bao-codegen-v2 against the shared E2E schema.
//
// What this does:
//   1. Copies `../swift/Models/schema.toml` into `./generated/schema.toml`.
//      v2's barrel template hard-codes `import "./<basename>?raw"`, so the
//      TOML must sit beside the generated `index.ts`.
//   2. Invokes `js-bao-codegen-v2 generate --input generated/schema.toml
//      --output generated`. v2's pre-write cleanup only deletes
//      `*.generated.ts` and the literal `index.ts`, so re-runs don't
//      stomp on the copied schema.toml.
//
// Run via `pnpm run codegen` (from this dir) or directly with `node
// codegen.mjs`. The XCTest harness invokes this once per test class
// before spawning the JS subprocess so the generator output is fresh.

import { fileURLToPath } from "node:url";
import * as path from "node:path";
import * as fs from "node:fs/promises";
import { spawnSync } from "node:child_process";

const here = path.dirname(fileURLToPath(import.meta.url));
const schemaSrc = path.resolve(here, "../swift/Models/schema.toml");
const outDir = path.resolve(here, "generated");
const schemaDst = path.join(outDir, "schema.toml");

// Walk up from `here` looking for `node_modules/js-bao/dist/codegen-v2.cjs`.
// The E2E dir is buried deep under swift-client/Tests/...; the workspace's
// hoisted `node_modules` is six dirs up. Resolving by climb keeps the
// script working if the layout shifts a level.
async function findCodegenBin() {
  let dir = here;
  for (let i = 0; i < 12; i++) {
    const candidate = path.join(dir, "node_modules/js-bao/dist/codegen-v2.cjs");
    try {
      await fs.access(candidate);
      return candidate;
    } catch {}
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  throw new Error(
    "Could not find node_modules/js-bao/dist/codegen-v2.cjs by walking up from " +
      here +
      ". Run `pnpm install` at the workspace root."
  );
}

async function main() {
  await fs.mkdir(outDir, { recursive: true });
  await fs.copyFile(schemaSrc, schemaDst);

  const bin = await findCodegenBin();
  const result = spawnSync(
    process.execPath,
    [bin, "generate", "--input", schemaDst, "--output", outDir],
    { stdio: "inherit" }
  );
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

main().catch((err) => {
  console.error("codegen.mjs failed:", err && err.stack ? err.stack : err);
  process.exit(1);
});
