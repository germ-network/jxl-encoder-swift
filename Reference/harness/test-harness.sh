#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFERENCE="$(dirname "$HERE")"
HARNESS="$REFERENCE/build/harness/jxl-harness"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
source "$REFERENCE/libjxl.pin"
version_reports_pin_and_neon() {
  "$HARNESS" version > "$SCRATCH/version"
  grep -Fx "libjxl=$LIBJXL_COMMIT" "$SCRATCH/version"
  grep -Fx 'hwy=NEON' "$SCRATCH/version"
}
pin_check_clean_after_build() {
  local linked
  linked="$(sed -n 's/^LIBJXL_DIR:[^=]*=//p' "$REFERENCE/build/harness/CMakeCache.txt")"
  test -n "$linked"
  "$REFERENCE/pin-check.sh" "$linked"
}
semantic_writer_matches_golden() {
  "$HARNESS" selftest "$SCRATCH/golden.sem" "$SCRATCH/test.dump"
  cmp "$HERE/golden.sem" "$SCRATCH/golden.sem"
}
stage_dump_roundtrip() {
  "$HARNESS" selftest "$SCRATCH/golden.sem" "$SCRATCH/test.dump"
  "$HARNESS" selftest --read "$SCRATCH/test.dump"
  python3 - "$SCRATCH/test.dump" <<'PYCODE'
import struct,sys
from pathlib import Path
p=Path(sys.argv[1]); data=p.read_bytes()
assert struct.unpack('<4I',data[:16]) == (0x304d5544,3,2,3)
assert struct.unpack('<18f',data[16:]) == tuple(float(i)-4 for i in range(18))
p.write_bytes(data[:-1])
PYCODE
  if "$HARNESS" selftest --read "$SCRATCH/test.dump"; then return 1; fi
}
for check in version_reports_pin_and_neon pin_check_clean_after_build semantic_writer_matches_golden stage_dump_roundtrip; do
  "$check"
  echo "PASS $check"
done
