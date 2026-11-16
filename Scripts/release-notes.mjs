import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const DEFAULT_MAX = 120_000;

export function changelogSection(changelog, version) {
  if (typeof changelog !== "string" || typeof version !== "string" || !version.trim()) {
    throw new TypeError("A changelog and version are required");
  }
  const lines = changelog.replace(/\r\n?/g, "\n").split("\n");
  let sectionDepth = 0;
  let start = -1;
  let end = lines.length;
  let fence = null;
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const fenceMatch = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (fence) {
      if (fenceMatch && fenceMatch[1][0] === fence.char && fenceMatch[1].length >= fence.length && !fenceMatch[2].trim()) fence = null;
      continue;
    }
    if (fenceMatch) {
      fence = { char: fenceMatch[1][0], length: fenceMatch[1].length };
      continue;
    }
    const heading = line.match(/^(#{1,6})\s+(.+?)\s*#*\s*$/);
    if (!heading) continue;
    if (start >= 0 && heading[1].length === sectionDepth) {
      end = index;
      break;
    }
    if (start < 0 && heading[2].trim().replace(/^v(?=\d)/, "") === version.trim().replace(/^v(?=\d)/, "")) {
      start = index + 1;
      sectionDepth = heading[1].length;
    }
  }
  if (start < 0) throw new Error(`Missing changelog section for ${version}`);
  const section = lines.slice(start, end).join("\n").trim();
  if (!section) throw new Error(`Empty changelog section for ${version}`);
  return section;
}

export function releaseNotes(section, { tag, max = DEFAULT_MAX }) {
  if (typeof section !== "string" || !section.trim()) throw new Error("Release notes section must not be empty");
  if (typeof tag !== "string" || !tag.trim()) throw new Error("A release tag is required");
  const footer = `[Full changelog](https://github.com/germ-network/jxl-encoder-swift/blob/${encodeURIComponent(tag)}/CHANGELOG.md)`;
  if (!Number.isSafeInteger(max) || max <= footer.length + 4) throw new RangeError("Release notes budget is invalid or too small");
  const normalized = section.replace(/\r\n?/g, "\n").trim();
  const complete = `${normalized}\n\n${footer}`;
  if (complete.length <= max) return complete;

  const notice = "[Release notes truncated; see the full changelog.]";
  const lines = normalized.split("\n");
  let body = "";
  let fence = null;
  for (const line of lines) {
    const match = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    const nextFence = fence
      ? (match && match[1][0] === fence.char && match[1].length >= fence.length && !match[2].trim() ? null : fence)
      : (match ? { char: match[1][0], length: match[1].length } : null);
    const candidateBody = body ? `${body}\n${line}` : line;
    const closure = nextFence ? `\n${nextFence.char.repeat(nextFence.length)}\n\n` : "\n\n";
    const candidate = `${candidateBody}${closure}${notice}\n\n${footer}`;
    if (candidate.length > max) {
      if (!body && !fence && line.length + closure.length + notice.length + footer.length + 2 > max) continue;
      break;
    }
    body = candidateBody;
    fence = nextFence;
  }
  const closure = fence ? `\n${fence.char.repeat(fence.length)}` : "";
  const result = `${body}${closure}\n\n${notice}\n\n${footer}`;
  if (result.length > max) throw new RangeError("Release notes budget cannot fit the required footer");
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const [version, ...args] = process.argv.slice(2);
    const options = new Map();
    for (let index = 0; index < args.length; index += 2) {
      if (!args[index]?.startsWith("--") || args[index + 1] === undefined) throw new Error("Expected --tag, --changelog, or --max option values");
      const name = args[index].slice(2);
      if (!["tag", "changelog", "max"].includes(name)) throw new Error(`Unknown option --${name}`);
      options.set(name, args[index + 1]);
    }
    const tag = options.get("tag");
    const changelogPath = options.get("changelog") ?? "CHANGELOG.md";
    const max = options.has("max") ? Number(options.get("max")) : DEFAULT_MAX;
    const changelog = await readFile(changelogPath, "utf8");
    process.stdout.write(releaseNotes(changelogSection(changelog, version), { tag, max }));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
