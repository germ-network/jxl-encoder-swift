#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
version="$(node -p 'require("./package.json").version')"
tag="v${version}"
notes_file="$(mktemp)"
lookup_error_file="$(mktemp)"
trap 'rm -f "$notes_file" "$lookup_error_file"' EXIT

git push origin "refs/tags/${tag}:refs/tags/${tag}"
git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null
node Scripts/release-notes.mjs "$version" --tag "$tag" > "$notes_file"

if gh release view "$tag" --json tagName >/dev/null 2>"$lookup_error_file"; then
  exit 0
fi
if ! grep -Eqi 'release not found|HTTP 404: Not Found' "$lookup_error_file"; then
  cat "$lookup_error_file" >&2
  exit 1
fi

release_args=("$tag" --verify-tag --notes-file "$notes_file")
if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z] ]]; then
  release_args+=(--prerelease)
fi
gh release create "${release_args[@]}"
