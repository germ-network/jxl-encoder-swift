#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
probe="$root/Reference/build/harness/jxl-ans-histogram-probe"
out="$root/Tests/JXLEncoderTests/Fixtures/entropy"
manifest="$root/Reference/provenance.tsv"
test -x "$probe"
pin="$(sed -n 's/^LIBJXL_COMMIT=//p' "$root/Reference/libjxl.pin" | tr -d '"')"
"$root/Reference/pin-check.sh" /Users/markdev/checkouts/common/libjxl
mkdir -p "$out"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
head -n 2 "$manifest" > "$tmp"
awk -F '\t' 'NR > 2 && $1 !~ /^Tests\/JXLEncoderTests\/Fixtures\/entropy\/ans_cost_/' \
	"$manifest" >> "$tmp"

generate() {
	local name="$1" strategy="$2" code="$3"; shift 3
	local input="$out/$name.input.sem"
	{
		printf 'jxl-semantic-dump 1\n'
		printf 'input.histogram.counts i %s' "$#"
		printf ' %s' "$@"
		printf '\ninput.histogram.log_alpha_size i 1 7\n'
		printf 'input.histogram.strategy i 1 %s\n' "$code"
	} > "$input"
	"$probe" "$strategy" "$@" > "$out/$name.expected.sem"
	local input_hash expected_hash
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_ans_histogram_fixtures.sh\tReference/make_ans_histogram_fixtures.sh\tinline histogram counts\t-\tstrategy=%s; log_alpha_size=7\tTests/JXLEncoderTests/ANSHistogramWriterTests.swift\n' \
		"$name" "$input_hash" "$strategy" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/ans_histogram_probe.cc\tReference/make_ans_histogram_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tdirect public Counts/Cost/Encode; method and shift inferred from Encode bits; source_data_bits derived from enc_ans.cc:362-376; NEON; hwy=NEON\tTests/JXLEncoderTests/ANSHistogramWriterTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" >> "$tmp"
}

generate ans_cost_sparse_precise precise 2 0 3 0 0 15 0 1
generate ans_cost_flat_alphabet47 fast 0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
generate ans_cost_approx_step2_witness approximate 1 90275 18441 21176 73088
generate ans_cost_precise_map_witness precise 2 17787 61992 38525 34605 12329
generate ans_cost_skewed_approximate approximate 1 10000 1 4 16 256 1024
generate ans_cost_scaled_fast fast 0 9294 684 593 7685 3091 9802 4825 1107
generate ans_cost_shift_2 precise 2 42 18 8 17
generate ans_cost_shift_3 precise 2 62 11 46 82 31 65 62 4 10 69 38 11 10 43 7 27 67 75 56
generate ans_cost_shift_5 precise 2 2779 2521 575 2846 1679 1125 583 3273 591 1262 173 1231
generate ans_cost_shift_7 precise 2 7286 7678 4771 8786 8869 4872 3194 3575 366 3714 6049 6727 8625 860 8008
generate ans_cost_shift_8 precise 2 397897963 483405759 16426304 57723528 563369613
generate ans_cost_shift_9 precise 2 163719583 253931501 257912820
generate ans_cost_shift_10 precise 2 94187685 61736198 27273578 268040367 7165427 163305188 178263426 132121952 46303738 211242280 153926632 73013283 135040079 182902730
generate ans_cost_shift_11 precise 2 624653344 674225821 367608513 395355614

mv "$tmp" "$manifest"
