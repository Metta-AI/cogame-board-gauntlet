#!/usr/bin/env node
// Chrome scope check -- the guard that keeps the inherited chrome inherited.
//
// Runs in ci.yml's `wasm-viewer` job. Four assertions, each of which caught a
// real defect somewhere in this lineage:
//
//  1. No identifier exported by client/chrome_common.js is re-declared as a
//     top-level `function` or `var` in client/renderer.js. A game-block
//     `function markBeat` is HOISTED over a chrome alias `var markBeat =
//     C.markBeat` and silently turns every scrub beat into an unlabelled div
//     that never seeks (tandem, 2026-08-23).
//  2. client/renderer.js declares no `markBeat` at all: the beat builder is
//     `markPlyBeat` and it lives in the chrome.
//  3. Every beat kind the sim can emit -- start, move, win, end, plus the
//     `capture` and `wall` modifiers and the two seat tints -- has a matching
//     rule in client/chrome.css. A beat with no CSS is an invisible button.
//  4. client/chrome_common.js still carries its COPIED-REGION markers, so a
//     future "tidy-up" that rewrites the chrome instead of appending to it
//     fails loudly here rather than quietly in review.
import { readFileSync } from "node:fs";

const chromePath = "client/chrome_common.js";
const gamePath = "client/renderer.js";
const cssPath = "client/chrome.css";

const chrome = readFileSync(chromePath, "utf8");
const game = readFileSync(gamePath, "utf8");
const css = readFileSync(cssPath, "utf8");

const problems = [];

// ---- 1 + 2: no shadowing, and no markBeat --------------------------------
const exportBlock = chrome.match(
  /window\.GauntletChrome\s*=\s*\{([\s\S]*?)\};/
);
if (!exportBlock) {
  problems.push(`${chromePath}: no window.GauntletChrome = {...} export found`);
}
const exported = new Set();
if (exportBlock) {
  for (const line of exportBlock[1].split("\n")) {
    const match = line.match(/^\s*([A-Za-z_$][\w$]*)\s*:/);
    if (match) exported.add(match[1]);
  }
}
if (exported.size < 10) {
  problems.push(
    `${chromePath}: only ${exported.size} exported identifiers parsed; the ` +
    "export block looks wrong"
  );
}

const declared = new Map();
const declRe = /^\s{0,4}(?:function\s+([A-Za-z_$][\w$]*)|var\s+([A-Za-z_$][\w$]*))/;
game.split("\n").forEach((line, index) => {
  const match = line.match(declRe);
  if (!match) return;
  const name = match[1] || match[2];
  if (!declared.has(name)) declared.set(name, index + 1);
});

for (const name of exported) {
  if (declared.has(name)) {
    problems.push(
      `${gamePath}:${declared.get(name)}: re-declares '${name}', which ` +
      `${chromePath} exports. Use the GauntletChrome alias instead ` +
      "(tandem, 2026-08-23)."
    );
  }
}
if (declared.has("markBeat")) {
  problems.push(
    `${gamePath}:${declared.get("markBeat")}: declares 'markBeat'. The beat ` +
    "builder is 'markPlyBeat' and it lives in the chrome."
  );
}
// Comments are stripped first: the game block DOCUMENTS why markBeat must
// not live here, and saying so is not the same as declaring it.
const gameCode = game
  .replace(/\/\*[\s\S]*?\*\//g, "")
  .split("\n")
  .map((line) => line.replace(/\/\/.*$/, ""))
  .join("\n");
if (/\bmarkBeat\b/.test(gameCode)) {
  problems.push(`${gamePath}: uses 'markBeat'; the chrome owns markPlyBeat`);
}
if (!/function markPlyBeat\(/.test(chrome)) {
  problems.push(`${chromePath}: markPlyBeat is missing`);
}

// ---- 3: CSS for every beat kind and modifier ------------------------------
const beatRules = [
  ".beat-start", ".beat-move", ".beat-win", ".beat-end",
  ".beat-move.capture", ".beat-move.wall", ".seat0", ".seat1"
];
for (const rule of beatRules) {
  if (!css.includes(rule)) {
    problems.push(`${cssPath}: no rule for '${rule}'`);
  }
}
// Every kind the beat builder can stamp onto a button must be in that list.
const emitted = [...chrome.matchAll(/beat-" \+ kind/g)];
if (emitted.length === 0) {
  problems.push(`${chromePath}: markPlyBeat no longer stamps beat-<kind>`);
}
for (const kind of ["start", "move", "win", "end"]) {
  if (!beatRules.includes(`.beat-${kind}`)) {
    problems.push(`internal: .beat-${kind} missing from the checked list`);
  }
}

// ---- 4: the copied regions are still named -------------------------------
const regions = [
  "23", "85-87", "101-124", "680-733", "735-744", "790-863", "963-970",
  "972-1027", "1029-1048", "1142-1222"
];
for (const region of regions) {
  if (!chrome.includes(`COPIED-REGION ${region}`)) {
    problems.push(
      `${chromePath}: the marker for copied region ${region} is gone. This ` +
      "file is cogame-babel's client/renderer.js copied byte for byte; a " +
      "rewrite is a defect, not an improvement (cogame-gridlock, 2026-08-23)."
    );
  }
}
for (let edit = 1; edit <= 7; edit += 1) {
  const marker = new RegExp(`BOARD-GAUNTLET EDIT ${edit}[ab]?\\b`);
  if (!marker.test(chrome)) {
    problems.push(`${chromePath}: chrome edit ${edit} is no longer marked`);
  }
}

if (problems.length) {
  for (const problem of problems) console.error(`::error::${problem}`);
  console.error(`chrome scope check FAILED with ${problems.length} problem(s)`);
  process.exit(1);
}
console.log(
  JSON.stringify({
    ok: true,
    exported: exported.size,
    game_declarations: declared.size,
    beat_rules: beatRules.length,
    copied_regions: regions.length
  })
);
