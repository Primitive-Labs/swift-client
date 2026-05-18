#!/usr/bin/env node
// Schema loader harness — feeds a TOML file through js-bao's
// `loadSchemaFromTomlString` and dumps the result as JSON on stdout.
// The Swift side (`CrossPlatformTomlSchemaParityTests`) invokes this
// with the fixture path, then normalizes both outputs and asserts
// field-by-field equality against its own `TomlSchemaLoader` output.
//
// Usage:
//   node schema-loader.cjs <path-to.toml>

const fs = require("fs");
const path = require("path");

const { loadSchemaFromTomlString } = require("js-bao");

function main() {
  const tomlPath = process.argv[2];
  if (!tomlPath) {
    console.error("usage: schema-loader.cjs <path-to.toml>");
    process.exit(2);
  }
  const absPath = path.resolve(tomlPath);
  const toml = fs.readFileSync(absPath, "utf8");
  const schemas = loadSchemaFromTomlString(toml);
  process.stdout.write(JSON.stringify(schemas));
}

try {
  main();
} catch (e) {
  console.error(e && e.stack || String(e));
  process.exit(1);
}
