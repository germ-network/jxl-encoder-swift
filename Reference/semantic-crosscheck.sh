#!/usr/bin/env bash
# Compare Swift decisions with the pinned decoder's interpretation of its files.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
HARNESS="$HERE/build/harness/jxl-harness"
if [ ! -x "$HARNESS" ]; then bash "$HERE/build-harness.sh"; fi
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
export JXL_CROSSCHECK_DIR="$OUT"
swift test --filter '^JXLEncoderTests.SemanticCrossCheckTests/write'
for file in "$OUT"/*.jxl; do
  "$HARNESS" dump "$file" > "${file%.jxl}.harness.sem"
done
for name in flower_512_d1 flower_1024; do
  "$HARNESS" dump "$OUT/$name.jxl" entropy_layout > "$OUT/$name.layout.sem"
done
for size in 512 1024; do
  "$HARNESS" encode "$HERE/../Tests/JXLEncoderTests/Fixtures/semantic/flower_$size.ppm" 1 \
    "$OUT/reference_flower_$size.jxl" 2
  "$HARNESS" dump "$OUT/reference_flower_$size.jxl" entropy_layout \
    > "$OUT/reference_flower_$size.layout.sem"
done
python3 - "$HERE/../Tests/JXLEncoderTests/Fixtures/semantic/pixel_lifecycle_2057x521.ppm" "$OUT" "$HARNESS" <<'PYCODE'
import re, subprocess, sys
from pathlib import Path

source, output, harness = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
data=source.read_bytes()
match=re.match(rb'P6\s+(\d+)\s+(\d+)\s+255\s', data)
assert match and tuple(map(int, match.groups())) == (2057, 521)
payload=data[match.end():]
row=2057*3
crop=output/'pixel_lifecycle_2057x257.ppm'
crop.write_bytes(b'P6\n2057 257\n255\n'+b''.join(payload[y*row:(y+1)*row] for y in range(257)))
stream=output/'reference_2057x257.jxl'
subprocess.run([harness, 'encode', str(crop), '1', str(stream), '2'], check=True)
layout=output/'reference_2057x257.layout.sem'
with layout.open('w') as result:
    subprocess.run([harness, 'dump', str(stream), 'entropy_layout'], stdout=result, check=True)
raw=output/'reference_2057x257_raw.jxl'
subprocess.run([harness, 'encode', str(crop), '1', str(raw), '0'], check=True)
raw_layout=output/'reference_2057x257_raw.layout.sem'
with raw_layout.open('w') as result:
    subprocess.run([harness, 'dump', str(raw), 'entropy_layout'], stdout=result, check=True)
fields={}
for line in raw_layout.read_text().splitlines()[1:]:
    parts=line.split(); fields[parts[0]]=list(map(int, parts[3:]))
selectors=fields['entropy_layout.ac_selectors']
assert selectors[8*4+1] == 8 and selectors[8*4+3] == 1
section_id=selectors[8*4+2]
section_ids=fields['entropy_layout.section_ids']
section_offset=fields['entropy_layout.section_offsets'][section_ids.index(section_id)]
mutated=bytearray(raw.read_bytes())
mutated[section_offset] ^= 1
mutated_path=output/'reference_2057x257_selector_mutation.jxl'
mutated_path.write_bytes(mutated)
result=subprocess.run([harness, 'dump', str(mutated_path), 'entropy_layout'],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
assert result.returncode != 0, 'selector mutation unexpectedly decoded'
PYCODE
swift test --skip-build --filter '^JXLEncoderTests.SemanticCrossCheckTests/(harnessAgreesWithEmitters|mutationsDifferInMutatedFieldOnly|actualSwiftLayoutsDecode)'
swift test --skip-build --filter '^JXLEncoderTests.EntropyReferenceTests/(streamingLayoutMatchesReferenceAboveEightGroups|entropyMutationIsReportedByItsExactField)'
JXL_ENTROPY_STREAM_EXPORT_DIR="$OUT" swift test --skip-build \
  --filter '^JXLEncoderTests.EntropyReferenceTests/smallFrameSharesOne(AC|Prefix)CodeAcrossIndependentGroupStreams'
JXL_ENTROPY_STREAM_EXPORT_DIR="$OUT" bash "$HERE/entropy-stream-crosscheck.sh"
echo 'PASS semantic cross-check: six encodes and two decoded mutations'
