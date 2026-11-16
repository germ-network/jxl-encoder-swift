import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { changelogSection, DEFAULT_MAX, releaseNotes } from "./release-notes.mjs";

const changelog = "# Changelog\n\n## 2.0.0\n\nnew release\n\n" + "```" + "md\n## 1.0.0\n" + "```" + "\n\n" + "~~~" + "md\n## 1.0.1\n" + "~~~" + "\n\n### 2.0.0 details\n\nmore details\n\n## 1.0.0\n\nold release\n";

test('extracts only the requested version section and ignores headings inside fences', () => {
  assert.equal(changelogSection(changelog, "2.0.0"), "new release\n\n```md\n## 1.0.0\n```\n\n~~~md\n## 1.0.1\n~~~\n\n### 2.0.0 details\n\nmore details");
  assert.ok(!changelogSection(changelog, "2.0.0").includes("old release"));
});

test('fails for a missing or empty version section', () => {
  assert.throws(() => changelogSection(changelog, "3.0.0"), /section/i);
  assert.throws(() => changelogSection("# Changelog\n\n## 3.0.0\n\n## 2.0.0\n", "3.0.0"), /empty/i);
});

test('preserves short notes and appends the permanent tagged changelog link', () => {
  const result = releaseNotes("First line\n\nSecond line", { tag: "v2.0.0" });
  assert.equal(result, "First line\n\nSecond line\n\n[Full changelog](https://github.com/germ-network/jxl-encoder-swift/blob/v2.0.0/CHANGELOG.md)");
});

test('caps oversized notes at 120000 UTF16 units including the footer', () => {
  const result = releaseNotes("x\n".repeat(70_000), { tag: "v2.0.0" });
  assert.ok(result.length <= DEFAULT_MAX);
  assert.match(result, /Full changelog/);
  assert.match(result, /truncated/i);
});

test('cuts at a complete line without splitting Unicode surrogate pairs', () => {
  const result = releaseNotes(`${"😀".repeat(20)}\n${"z".repeat(80)}\n`, { tag: "v1", max: 200 });
  assert.ok(result.length <= 200);
  assert.ok(result.isWellFormed());
  assert.ok(result.startsWith(`${"😀".repeat(20)}\n`));
  assert.ok(!/[\uD800-\uDBFF]$/.test(result));
  assert.ok(!result.includes("z".repeat(80)));
});

test('omits an oversized first line rather than cutting it midline', () => {
  const result = releaseNotes(`${"x".repeat(200)}\nsmall line`, { tag: "v1", max: 180 });
  assert.ok(result.length <= 180);
  assert.doesNotMatch(result.slice(0, result.indexOf("[Release notes truncated")), /x/);
  assert.match(result, /small line/);
});

test('closes an open backtick or tilde fence before the footer', () => {
  for (const fence of ["```js\n", "~~~js\n"]) {
    const result = releaseNotes(`${fence}${"body\n".repeat(100)}`, { tag: "v1", max: 240 });
    const footerAt = result.indexOf("Full changelog");
    const beforeFooter = result.slice(0, footerAt);
    assert.match(beforeFooter, /(?:```|~~~)\n\n\[Release notes truncated/);
    assert.ok(result.length <= 240);
  }
});

test('rejects invalid or insufficient budgets', () => {
  for (const max of [0, -1, 1, 2.5, Number.NaN, Infinity]) {
    assert.throws(() => releaseNotes("notes", { tag: "v1", max }), /budget|max/i);
  }
  assert.throws(() => releaseNotes("notes", { tag: "v1", max: 20 }), /budget|max/i);
});

test('CLI writes notes and fails without output for invalid input', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "release-notes-"));
  try {
    const file = path.join(directory, "CHANGELOG.md");
    await writeFile(file, "# Changelog\n\n## 1.2.3\n\nCLI notes\n\n## 1.2.2\n\nold\n");
    const run = (version) => spawnSync(process.execPath, ["Scripts/release-notes.mjs", version, "--tag", `v${version}`, "--changelog", file], { encoding: "utf8" });
    const ok = run("1.2.3");
    assert.equal(ok.status, 0, ok.stderr);
    assert.ok(ok.stdout.length <= DEFAULT_MAX);
    assert.match(ok.stdout, /CLI notes/);
    assert.match(ok.stdout, /blob\/v1\.2\.3\/CHANGELOG\.md/);
    await writeFile(file, "# Changelog\n\n## 1.2.3\n\n" + "x".repeat(500) + "\n\n## 1.2.2\n\nold\n");
    const capped = spawnSync(process.execPath, ["Scripts/release-notes.mjs", "1.2.3", "--tag", "v1.2.3", "--changelog", file, "--max", "180"], { encoding: "utf8" });
    assert.equal(capped.status, 0, capped.stderr);
    assert.ok(capped.stdout.length <= 180);
    assert.match(capped.stdout, /Release notes truncated/);
    assert.match(capped.stdout, /Full changelog/);
    const bad = run("9.9.9");
    assert.notEqual(bad.status, 0);
    assert.equal(bad.stdout, "");
    const typo = spawnSync(process.execPath, ["Scripts/release-notes.mjs", "1.2.3", "--tag", "v1.2.3", "--changelog", file, "--changelgo", "ignored"], { encoding: "utf8" });
    assert.notEqual(typo.status, 0);
    assert.equal(typo.stdout, "");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
