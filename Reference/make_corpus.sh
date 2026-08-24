#!/usr/bin/env bash
# Regenerates the gap-measurement corpus (docs/gap-closure-plan.md, Phase A).
#
# Five real photos, one synthetic gradient, and two real JPEGs for the
# recompression path. Everything derives from the repo's own fixtures or from
# libjxl's testdata; nothing large is committed. The corpus lands in
# Reference/build/corpus, which is gitignored — rerun this after a clean
# checkout or a scratch wipe.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTDATA="${TESTDATA_DIR:-$HOME/tmp/automation/libjxl-full/testdata}"
OUT="$HERE/build/corpus"

if [ ! -d "$TESTDATA/external/wesaturate" ]; then
	echo "libjxl testdata not found at $TESTDATA" >&2
	echo "  git clone --depth 1 https://github.com/libjxl/testdata $TESTDATA" >&2
	echo "  (or set TESTDATA_DIR)" >&2
	exit 1
fi

mkdir -p "$OUT"
TOOL="$HERE/tools/make_corpus.swift"

swift "$TOOL" normalize \
	"$HERE/../Tests/JXLEncoderAppleTests/Fixtures/hopper_444.jpg" "$OUT" hopper
swift "$TOOL" normalize \
	"$TESTDATA/external/wesaturate/500px/cvo9xd_keong_macan_srgb8.png" "$OUT" macan
swift "$TOOL" normalize \
	"$TESTDATA/external/wesaturate/500px/tmshre_riaphotographs_srgb8.png" "$OUT" riaphoto
swift "$TOOL" normalize \
	"$TESTDATA/external/wesaturate/500px/u76c0g_bliznaca_srgb8.png" "$OUT" bliznaca
swift "$TOOL" normalize \
	"$TESTDATA/jxl/flower/flower.png" "$OUT" flower
swift "$TOOL" gradient "$OUT"

cp "$TESTDATA/jxl/flower/flower.png.im_q85_420.jpg" "$OUT/recomp_420.jpg"
cp "$TESTDATA/jxl/flower/flower.png.im_q85_444.jpg" "$OUT/recomp_444.jpg"

echo "corpus: $OUT"
