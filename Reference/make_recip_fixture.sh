#!/usr/bin/env bash
# Regenerates recip_estimate.bin on arm64 hardware using vrecpeq_f32.
set -euo pipefail

case "$(uname -m)" in
	arm64|aarch64) ;;
	*)
		echo "make_recip_fixture.sh requires an arm64 host (got $(uname -m))" >&2
		exit 1
		;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/build"
FIXTURES="$HERE/../Tests/JXLEncoderTests/Fixtures"
CXX="${CXX:-clang++}"

mkdir -p "$OUT"
"$CXX" -O2 -std=c++17 "$HERE/tools/genrecip.cc" -o "$OUT/genrecip"
"$OUT/genrecip" "$FIXTURES/recip_estimate.bin"

echo "recip_estimate.bin regenerated"
