#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
HARNESS="$HERE/build/harness/jxl-harness"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
for name in stream_shared_ans stream_shared_prefix; do
  fixture="$ROOT/Tests/JXLEncoderTests/Fixtures/entropy/$name"
  input="$fixture.expected.sem"
  if [[ -n "${JXL_ENTROPY_STREAM_EXPORT_DIR:-}" ]]; then
    input="$JXL_ENTROPY_STREAM_EXPORT_DIR/$name.current.sem"
  fi
  "$HARNESS" entropy-verify-streams "$input" \
    > "$SCRATCH/$name.receipt.sem"
  cmp "$fixture.receipt.sem" "$SCRATCH/$name.receipt.sem"
done
python3 - "$HARNESS" "$ROOT/Tests/JXLEncoderTests/Fixtures/entropy" "$SCRATCH" <<'PYCODE'
import subprocess, sys
from pathlib import Path

harness, fixtures, scratch = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
mutations = {
    "ans_boundary": ("stream_shared_ans.expected.sem", "entropy.streams.bit_counts i 2 32 32", "entropy.streams.bit_counts i 2 32 33", "entropy.streams.bytes i 8 64 81 1 19 192 152 0 19", "entropy.streams.bytes i 9 64 81 1 19 192 152 0 19 0", None),
    "ans_final_state": ("stream_shared_ans.expected.sem", None, None, "entropy.streams.bytes i 8 64 81 1 19 192 152 0 19", "entropy.streams.bytes i 8 64 81 1 19 192 152 0 18", "final ANS state mismatch"),
    "ans_code_padding": ("stream_shared_ans.expected.sem", None, None, "entropy.streams.code_bytes i 5 34 138 5 0 2", "entropy.streams.code_bytes i 5 34 138 5 0 130", None),
    "prefix_padding": ("stream_shared_prefix.expected.sem", "entropy.streams.bit_counts i 2 8 8", "entropy.streams.bit_counts i 2 8 7", "entropy.streams.bytes i 2 170 51", "entropy.streams.bytes i 2 170 179", None),
}
for name, (fixture, old, new, bytes_old, bytes_new, diagnostic) in mutations.items():
    text = (fixtures / fixture).read_text()
    if old is not None:
        assert old in text
        text = text.replace(old, new)
    if bytes_old is not None:
        assert bytes_old in text
        text = text.replace(bytes_old, bytes_new)
    path = scratch / f"{name}.sem"
    path.write_text(text)
    result = subprocess.run([harness, "entropy-verify-streams", str(path)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    assert result.returncode != 0, name
    if diagnostic:
        assert diagnostic in result.stderr, (name, result.stderr)
PYCODE
