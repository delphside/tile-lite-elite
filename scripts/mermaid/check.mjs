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
//   node scripts/mermaid/check.mjs [--require] [path ...]
//   node scripts/mermaid/check.mjs --help
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = process.cwd();
const SKIP = new Set(["node_modules", "target", ".git", "old-crates", "dist"]);
const require_deps = process.argv.includes("--require");

if (process.argv.includes("--help") || process.argv.includes("-h")) {
  console.log(`usage: check.mjs [--require] [path ...]

Parses every mermaid diagram it can find and reports the broken ones.

  path ...    files or directories to check. Without any, the whole tree
              below the working directory, skipping node_modules, target,
              .git, old-crates and dist.
  --require   exit 1 rather than 0 when mermaid and jsdom are not installed,
              so CI can insist the check actually ran.

Exits 0 when every diagram parses, 1 when one does not, and 2 when a path
given on the command line does not exist.`);
  process.exit(0);
}

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

// **Paths on the command line are checked instead of the whole tree.** Until
// 2026-09-22 they were accepted and silently ignored, so
// `check.mjs some/file.md` scanned the repository, reported everything else
// passing, and said nothing about the file asked for. That is worse than
// refusing the argument: it answers a question nobody asked, in a voice that
// sounds like an answer to the one they did. Found by using it to verify a
// diagram before it was committed -- the check passed and had not looked.
//
// **Above the dependency guard, deliberately.** It sat below until a review on
// 2026-09-22 pointed out that the guard exits first: on a checkout without
// `npm install --prefix scripts/mermaid`, a typo'd path printed *mermaid/jsdom
// not installed* and exited 0, so a bad argument read as success. Validating an
// argument needs no renderer, and a check that cannot run should still refuse
// a question it cannot answer.
const asked = process.argv.slice(2).filter((a) => !a.startsWith("--"));
for (const path of asked) {
  try {
    statSync(path);
  } catch {
    console.error(`mermaid: no such file: ${path}`);
    process.exit(2);
  }
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

const files = asked.length
  ? asked.flatMap((p) => (statSync(p).isDirectory() ? walk(p) : [p]))
  : walk(ROOT);
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
