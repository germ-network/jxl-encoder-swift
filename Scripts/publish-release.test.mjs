import assert from "node:assert/strict";
import { access, copyFile, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const publisher = path.join(repository, "Scripts/publish-release.sh");

async function fixture({ version = "2.4.0", changelog = "# Changelog\n\n## 2.4.0\n\nRelease notes\n", existingRelease = false } = {}) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "publish-release-"));
  const bin = path.join(directory, "bin");
  const tempDir = path.join(directory, "tmp");
  await mkdir(path.join(directory, "Scripts"));
  await mkdir(bin);
  await mkdir(tempDir);
  await writeFile(path.join(directory, "package.json"), JSON.stringify({ version }));
  await writeFile(path.join(directory, "CHANGELOG.md"), changelog);
  await copyFile(path.join(repository, "Scripts/release-notes.mjs"), path.join(directory, "Scripts/release-notes.mjs"));
  const script = `#!/usr/bin/env bash
set -eu
printf 'CALL\\tgit' >> "$CALL_LOG"
for arg in "$@"; do printf '\\t%s' "$arg" >> "$CALL_LOG"; done
printf '\\n' >> "$CALL_LOG"
case "$1" in
  rev-parse) printf '%s\\n' "$FIXTURE_ROOT" ;;
  push)
    [[ "\${FAIL_PUSH:-0}" != 1 ]] || exit 1
    refspec="$3"
    if [[ -f "$REMOTE_TAG" ]]; then
      remote_sha="$(cat "$REMOTE_TAG")"
      if [[ "$remote_sha" != "$LOCAL_TAG_SHA" ]]; then
        force=0
        for arg in "$@"; do [[ "$arg" != --force ]] || force=1; done
        [[ "$force" == 1 ]] || exit 1
        printf '%s\\n' "$LOCAL_TAG_SHA" > "$REMOTE_TAG"
      fi
    else
      printf '%s\\n' "$LOCAL_TAG_SHA" > "$REMOTE_TAG"
    fi
    printf '%s\\n' "$refspec" >> "$PUSH_LOG"
    ;;
  ls-remote) [[ "\${VERIFY_FAIL:-0}" != 1 && -f "$REMOTE_TAG" ]] || exit 2; printf 'remote-sha\\t%s\\n' "$5" ;;
esac
`;
  await writeFile(path.join(bin, "git"), script, { mode: 0o755 });
  const gh = `#!/usr/bin/env bash
set -eu
printf 'CALL\\tgh' >> "$CALL_LOG"
for arg in "$@"; do printf '\\t%s' "$arg" >> "$CALL_LOG"; done
printf '\\n' >> "$CALL_LOG"
case "$1" in
  release)
    case "$2" in
      view)
        if [[ "\${GH_VIEW_FAIL:-0}" == 1 ]]; then printf '%s\\n' 'HTTP 503: Gateway' >&2; exit 1; fi
        [[ -f "$EXISTING_RELEASE" ]] || { printf '%s\\n' 'release not found' >&2; exit 1; }
        ;;
      create)
        notes=''
        previous=''
        for arg in "$@"; do
          if [[ "$previous" == --notes-file ]]; then notes="$arg"; fi
          previous="$arg"
        done
        printf '%s\\n' "$notes" > "$NOTES_PATH"
        cp "$notes" "$NOTES_CAPTURE"
        if [[ "\${CREATE_FAIL_ONCE:-0}" == 1 && ! -f "$CREATE_FAILED" ]]; then touch "$CREATE_FAILED"; exit 1; fi
        touch "$CREATED_RELEASE"
        ;;
    esac
    ;;
esac
`;
  await writeFile(path.join(bin, "gh"), gh, { mode: 0o755 });
  const files = {
    callLog: path.join(directory, "calls"),
    created: path.join(directory, "created-release"),
    createFailed: path.join(directory, "create-failed"),
    existing: path.join(directory, "existing-release"),
    notesCapture: path.join(directory, "notes-capture"),
    notesPath: path.join(directory, "notes-path"),
    pushLog: path.join(directory, "pushes"),
    remoteTag: path.join(directory, "remote-tag")
  };
  await writeFile(files.callLog, "");
  if (existingRelease) await writeFile(files.existing, "leave as-is");
  const env = {
    ...process.env,
    PATH: `${bin}:${process.env.PATH}`,
    CALL_LOG: files.callLog,
    CREATED_RELEASE: files.created,
    CREATE_FAILED: files.createFailed,
    EXISTING_RELEASE: files.existing,
    FIXTURE_ROOT: directory,
    LOCAL_TAG_SHA: "local-tag-sha",
    NOTES_CAPTURE: files.notesCapture,
    NOTES_PATH: files.notesPath,
    PUSH_LOG: files.pushLog,
    REMOTE_TAG: files.remoteTag,
    TMPDIR: tempDir
  };
  return { directory, env, files, tempDir, run: () => spawnSync("bash", [publisher], { cwd: directory, env, encoding: "utf8" }) };
}

async function cleanup(item) {
  await rm(item.directory, { recursive: true, force: true });
}

async function exists(file) {
  try { await access(file); return true; } catch { return false; }
}

async function assertNoTemporaryNotes(item) {
  assert.deepEqual(await readdir(item.tempDir), []);
}

test('pushes the exact version tag before creating a release with verified tag and generated notes', async () => {
  const item = await fixture();
  try {
    const result = item.run();
    assert.equal(result.status, 0, result.stderr);
    const calls = await readFile(item.files.callLog, "utf8");
    const pushCall = "CALL\tgit\tpush\torigin\trefs/tags/v2.4.0:refs/tags/v2.4.0";
    const verifyCall = "CALL\tgit\tls-remote\t--exit-code\t--tags\torigin\trefs/tags/v2.4.0";
    const callLines = calls.trimEnd().split("\n");
    const pushIndex = callLines.indexOf(pushCall);
    const verifyIndex = callLines.indexOf(verifyCall);
    const createIndex = callLines.findIndex((line) => line.startsWith("CALL\tgh\trelease\tcreate\t"));
    assert.notEqual(pushIndex, -1);
    assert.notEqual(verifyIndex, -1);
    assert.ok(pushIndex < verifyIndex);
    assert.ok(verifyIndex < createIndex);
    const notesPath = (await readFile(item.files.notesPath, "utf8")).trim();
    assert.deepEqual(callLines[createIndex].split("\t"), ["CALL", "gh", "release", "create", "v2.4.0", "--verify-tag", "--notes-file", notesPath]);
    assert.equal(await readFile(item.files.pushLog, "utf8"), "refs/tags/v2.4.0:refs/tags/v2.4.0\n");
    const notes = await readFile(item.files.notesCapture, "utf8");
    assert.match(notes, /Release notes/);
    assert.match(notes, /blob\/v2\.4\.0\/CHANGELOG\.md/);
    assert.equal(await exists(notesPath), false);
    await assertNoTemporaryNotes(item);
  } finally { await cleanup(item); }
});

test('refuses release creation when the tag push fails', async () => {
  const item = await fixture();
  item.env.FAIL_PUSH = "1";
  try {
    const result = item.run();
    assert.notEqual(result.status, 0);
    const calls = await readFile(item.files.callLog, "utf8");
    assert.match(calls, /CALL\tgit\tpush/);
    assert.doesNotMatch(calls, /ls-remote|release\tcreate/);
    await assertNoTemporaryNotes(item);
  } finally { await cleanup(item); }
});

test('refuses release creation when remote tag verification fails', async () => {
  const item = await fixture();
  item.env.VERIFY_FAIL = "1";
  try {
    const result = item.run();
    assert.notEqual(result.status, 0);
    const calls = await readFile(item.files.callLog, "utf8");
    assert.match(calls, /CALL\tgit\tls-remote/);
    assert.doesNotMatch(calls, /release\tcreate/);
    await assertNoTemporaryNotes(item);
  } finally { await cleanup(item); }
});

test('refuses release creation when note generation fails', async () => {
  const item = await fixture({ changelog: "# Changelog\n\n## 1.0.0\n\nOther notes\n" });
  try {
    const result = item.run();
    assert.notEqual(result.status, 0);
    const calls = await readFile(item.files.callLog, "utf8");
    assert.match(calls, /CALL\tgit\tpush/);
    assert.match(calls, /CALL\tgit\tls-remote/);
    assert.doesNotMatch(calls, /release\tcreate/);
    await assertNoTemporaryNotes(item);
  } finally { await cleanup(item); }
});

test('keeps an existing release unchanged', async () => {
  const item = await fixture({ existingRelease: true });
  try {
    const result = item.run();
    assert.equal(result.status, 0, result.stderr);
    const calls = await readFile(item.files.callLog, "utf8");
    assert.match(calls, /CALL\tgh\trelease\tview\tv2\.4\.0/);
    assert.doesNotMatch(calls, /release\tcreate/);
    assert.equal(await readFile(item.files.existing, "utf8"), "leave as-is");
    await assertNoTemporaryNotes(item);
  } finally { await cleanup(item); }

  const lookupFailure = await fixture();
  lookupFailure.env.GH_VIEW_FAIL = "1";
  try {
    const result = lookupFailure.run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /HTTP 503/);
    const calls = await readFile(lookupFailure.files.callLog, "utf8");
    assert.doesNotMatch(calls, /release\tcreate/);
    await assertNoTemporaryNotes(lookupFailure);
  } finally { await cleanup(lookupFailure); }
});

test('retries creation after a prior run pushed the tag but failed creation', async () => {
  const item = await fixture();
  item.env.CREATE_FAIL_ONCE = "1";
  try {
    const first = item.run();
    assert.notEqual(first.status, 0);
    assert.ok(await exists(item.files.notesPath), "publisher did not record its temporary notes path");
    const notesPath = (await readFile(item.files.notesPath, "utf8")).trim();
    assert.equal(await exists(notesPath), false);
    await assertNoTemporaryNotes(item);
    const tagBeforeRetry = await readFile(item.files.remoteTag, "utf8");
    const second = item.run();
    assert.equal(second.status, 0, second.stderr);
    assert.equal(await readFile(item.files.remoteTag, "utf8"), tagBeforeRetry);
    const calls = await readFile(item.files.callLog, "utf8");
    assert.equal((calls.match(/CALL\tgh\trelease\tcreate/g) ?? []).length, 2);
    assert.equal((await readFile(item.files.pushLog, "utf8")).split("\n").filter(Boolean).length, 2);
    assert.equal(await exists((await readFile(item.files.notesPath, "utf8")).trim()), false);
    await assertNoTemporaryNotes(item);
  } finally { await cleanup(item); }
});

test('passes prerelease classification for a prerelease version', async () => {
  const item = await fixture({ version: "2.4.0-rc.1", changelog: "# Changelog\n\n## 2.4.0-rc.1\n\nRelease candidate\n" });
  try {
    const result = item.run();
    assert.equal(result.status, 0, result.stderr);
    const calls = await readFile(item.files.callLog, "utf8");
    assert.match(calls, /CALL\tgh\trelease\tcreate\tv2\.4\.0-rc\.1\t--verify-tag\t--notes-file\t[^\n]+\t--prerelease/);
  } finally { await cleanup(item); }

  const metadata = await fixture({ version: "2.4.0+build-1", changelog: "# Changelog\n\n## 2.4.0+build-1\n\nStable build\n" });
  try {
    const result = metadata.run();
    assert.equal(result.status, 0, result.stderr);
    const calls = await readFile(metadata.files.callLog, "utf8");
    assert.match(calls, /CALL\tgh\trelease\tcreate\tv2\.4\.0\+build-1\t--verify-tag\t--notes-file/);
    assert.doesNotMatch(calls, /--prerelease/);
  } finally { await cleanup(metadata); }
});
