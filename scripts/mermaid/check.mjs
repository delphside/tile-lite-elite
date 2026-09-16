#!/usr/bin/env node
// check-mermaid.mjs — does every mermaid diagram in the repository parse?
//
// #340. A diagram that does not parse renders as an error box on GitHub and is
// invisible to everything else: markdownlint sees an opaque code fence, so a
// diagram is exactly as checked as a paragraph of prose. One was broken for 39
// days and found by a person reading a pull request.
//
// **Mermaid's own grammar, never a second opinion.** Only mermaid agrees with
// what GitHub renders; a parser of our own would be wrong in a different way.
//
// Needs `mermaid` and `jsdom`. Without them it says so and exits 0 — a check,
// not a gate, until the dependency is a decided cost. `--require` makes their
// absence a failure, which is what CI would pass once that is settled.
//
//   node scripts/mermaid/check.mjs [--require]
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = process.cwd();
const SKIP = new Set(["node_modules", "target", ".git", "old-crates", "dist"]);
const require_deps = process.argv.includes("--require");

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (SKIP.has(name)) continue;
    const path = join(dir, name);
    const st = statSync(path);
    if (st.isDirectory()) walk(path, out);
    else if (name.endsWith(".md") || name.endsWith(".mmd")) out.push(path);
  }
  return out;
}

/** Every diagram in a file, with the line its fence opens on. */
function diagrams(path) {
  const text = readFileSync(path, "utf8");
  if (path.endsWith(".mmd")) return [{ line: 1, source: text }];
  const lines = text.split("\n");
  const found = [];
  let start = -1, body = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (start < 0 && /^\s*```+\s*mermaid\s*$/.test(line)) { start = i + 1; body = []; continue; }
    if (start >= 0) {
      if (/^\s*```+\s*$/.test(line)) { found.push({ line: start, source: body.join("\n") }); start = -1; }
      else body.push(line);
    }
  }
  return found;
}

let mermaid;
try {
  const { JSDOM } = await import("jsdom");
  const dom = new JSDOM("<!DOCTYPE html><body></body>", { pretendToBeVisual: true });
  globalThis.window = dom.window;
  globalThis.document = dom.window.document;
  mermaid = (await import("mermaid")).default;
  mermaid.initialize({ startOnLoad: false });
} catch {
  console.log("  mermaid/jsdom not installed — diagrams not parsed");
  console.log("  npm install --prefix scripts/mermaid mermaid jsdom");
  process.exit(require_deps ? 1 : 0);
}

const files = walk(ROOT);
let count = 0, bad = 0;
for (const path of files) {
  for (const { line, source } of diagrams(path)) {
    if (!source.trim()) continue;
    count++;
    try {
      await mermaid.parse(source);
    } catch (error) {
      bad++;
      const first = String(error.message || error).split("\n").slice(0, 3).join("\n      ");
      console.log(`  FAIL ${relative(ROOT, path)}:${line}\n      ${first}`);
    }
  }
}
console.log(`  ${count} diagram(s) parsed, ${bad} broken`);
process.exit(bad ? 1 : 0);
