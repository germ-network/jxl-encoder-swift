#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
harness="$root/Reference/build/harness/jxl-harness"
out="$root/Tests/JXLEncoderTests/Fixtures/entropy"
test -x "$harness"
linked="$(sed -n 's/^LIBJXL_DIR:[^=]*=//p' "$root/Reference/build/harness/CMakeCache.txt")"
test -n "$linked"
"$root/Reference/pin-check.sh" "$linked"
source "$root/Reference/libjxl.pin"
version="$("$harness" version)"
grep -Fx "libjxl=$LIBJXL_COMMIT" <<< "$version"
grep -Fx 'hwy=NEON' <<< "$version"
mkdir -p "$out"
pin="$LIBJXL_COMMIT"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
head -n 2 "$root/Reference/provenance.tsv" > "$tmp"
awk -F '\t' 'NR > 2 && $1 !~ /^Tests\/JXLEncoderTests\/Fixtures\/entropy\//' \
	"$root/Reference/provenance.tsv" >> "$tmp"

generate() {
	local name="$1" log_alpha="$2" strategy="$3"; shift 3
	local input="$out/$name.input.sem"
	{
		printf 'jxl-semantic-dump 1\n'
		printf 'input.histogram.counts i %s' "$#"
		if (($# > 0)); then printf ' %s' "$@"; fi
		printf '\ninput.histogram.log_alpha_size i 1 %s\n' "$log_alpha"
		case "$strategy" in
			fast) printf 'input.histogram.strategy i 1 0\n' ;;
			approximate) printf 'input.histogram.strategy i 1 1\n' ;;
			precise) printf 'input.histogram.strategy i 1 2\n' ;;
		esac
	} > "$input"
	"$harness" entropy histogram "$log_alpha" "$strategy" "$@" > "$out/$name.expected.sem"
	local input_hash expected_hash
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\tinline case parameters in generator\t-\thistogram strategy=%s log_alpha_size=%s\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$input_hash" "$strategy" "$log_alpha" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_entropy.cc\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\thistogram strategy=%s log_alpha_size=%s hwy=NEON\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" "$strategy" "$log_alpha" >> "$tmp"
}

generate_cluster() {
	local name="$1" mode="$2" limit="$3"; shift 3
	local input="$out/$name.input.sem" encoded_mode
	case "$mode" in fast) encoded_mode=0 ;; best) encoded_mode=1 ;; esac
	local lengths=() flat=() row
	for row in "$@"; do
		local -a counts
		IFS=',' read -r -a counts <<< "$row"
		lengths+=("${#counts[@]}")
		flat+=("${counts[@]}")
	done
	{
		printf 'jxl-semantic-dump 1\n'
		printf 'input.clusters.mode i 1 %s\n' "$encoded_mode"
		printf 'input.clusters.limit i 1 %s\n' "$limit"
		printf 'input.clusters.lengths i %s' "${#lengths[@]}"
		printf ' %s' "${lengths[@]}"
		printf '\ninput.clusters.counts i %s' "${#flat[@]}"
		printf ' %s' "${flat[@]}"
		printf '\n'
	} > "$input"
	"$harness" entropy cluster "$mode" "$limit" "$@" > "$out/$name.expected.sem"
	local input_hash expected_hash input_list
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	input_list="${*// /;}"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\tinline cluster parameters in generator\t-\tmode=%s limit=%s counts=%s\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$input_hash" "$mode" "$limit" "$input_list" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_entropy.cc\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tmode=%s limit=%s hwy=NEON\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" "$mode" "$limit" >> "$tmp"
}

generate_context_map() {
	local name="$1" num_histograms="$2" allow_ans="$3"; shift 3
	local input="$out/$name.input.sem"
	{
		printf 'jxl-semantic-dump 1\n'
		printf 'input.context_map.entries i %s' "$#"
		if (($# > 0)); then printf ' %s' "$@"; fi
		printf '\ninput.context_map.map_length i 1 %s\n' "$#"
		printf 'input.context_map.num_histograms i 1 %s\n' "$num_histograms"
		printf 'input.context_map.allow_ans i 1 %s\n' "$allow_ans"
	} > "$input"
	"$harness" entropy context-map "$num_histograms" "$@" > "$out/$name.expected.sem"
	local input_hash expected_hash input_list
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	input_list="${*// /;}"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\tinline context-map parameters in generator\t-\tnum_histograms=%s allow_ans=%s entries=%s\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$input_hash" "$num_histograms" "$allow_ans" "$input_list" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_entropy.cc\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tEncodeContextMap num_histograms=%s hwy=NEON\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" "$num_histograms" >> "$tmp"
}

generate_context_map_with_candidates() {
	local name="$1" num_histograms="$2"; shift 2
	local input="$out/$name.input.sem"
	local -a entries=() mtf_entries=()
	local section=entries value
	for value in "$@"; do
		if [[ "$value" == "--mtf" ]]; then section=mtf; continue; fi
		if [[ "$section" == entries ]]; then entries+=("$value"); else mtf_entries+=("$value"); fi
	done
	{
		printf 'jxl-semantic-dump 1\n'
		printf 'input.context_map.entries i %s' "${#entries[@]}"
		printf ' %s' "${entries[@]}"
		printf '\ninput.context_map.map_length i 1 %s' "${#entries[@]}"
		printf '\ninput.context_map.num_histograms i 1 %s\n' "$num_histograms"
		printf 'input.context_map.allow_ans i 1 1\n'
		printf 'input.context_map.mtf_entries i %s' "${#mtf_entries[@]}"
		printf ' %s' "${mtf_entries[@]}"
		printf '\n'
	} > "$input"
	"$harness" entropy context-map "$num_histograms" "${entries[@]}" --mtf "${mtf_entries[@]}" > "$out/$name.expected.sem"
	local input_hash expected_hash
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\tinline context-map candidates in generator\t-\tnum_histograms=%s\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$input_hash" "$num_histograms" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_entropy.cc\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tEncodeContextMap selected mode/bytes; BuildAndEncodeHistograms candidate costs and post-LZ77 token counts with default context-map params; hwy=NEON\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" >> "$tmp"
}

rm -f "$out"/ans_sparse_precise.* "$out"/ans_skewed_approximate.* \
	"$out"/ans_boundary_fast.* "$out"/ans_threshold48_fast.* \
	"$out"/ans_threshold64_fast.*
generate ans_singleton_precise 7 precise 0 0 0 10
generate ans_empty 7 fast
generate ans_all_zero 7 fast 0 0 0
generate ans_two_symbol_approximate 7 approximate 1 3
generate ans_precision_fast 7 fast 1800 1500 700 96
generate ans_sparse_precise 7 precise 0 3 0 0 15 0 1
generate ans_skewed_approximate 7 approximate 10000 1 4 16 256 1024
threshold48=()
threshold64=()
for ((index = 0; index < 48; index++)); do threshold48+=(1); done
for ((index = 0; index < 64; index++)); do threshold64+=(1); done
generate ans_alphabet48_fast 7 fast "${threshold48[@]}"
generate ans_alphabet64_fast 7 fast "${threshold64[@]}"
generate_cluster clusters_fast_identical fast 4 16,0 16,0
generate_cluster clusters_best_identical best 4 16,0 16,0
generate_cluster clusters_fast_merge fast 4 \
	23,24,113,132,138,100 102,2,10,28,39,12 27,2,142,84,128,21
generate_cluster clusters_best_merge best 4 \
	23,24,113,132,138,100 102,2,10,28,39,12 27,2,142,84,128,21
generate_cluster clusters_ties_fast fast 2 \
	40,40,0 40,0,40 0,40,40
generate_cluster clusters_farthest_fast fast 2 \
	50,50,0,0,0,0 50,50,0,0,0,0 0,0,40,40,0,0 0,0,0,0,30,30
generate_cluster clusters_distance_48_fast fast 4 12,12,0,0 0,0,12,12
generate_cluster clusters_distance_56_fast fast 4 14,14,0,0 0,0,14,14
generate_cluster clusters_distance_64_fast fast 4 16,16,0,0 0,0,16,16
over_eight_rows=()
for ((index = 0; index < 10; index++)); do
	row=()
	for ((symbol = 0; symbol < 20; symbol++)); do
		if ((symbol == index * 2 || symbol == index * 2 + 1)); then
			row+=(20)
		else
			row+=(0)
		fi
	done
	over_eight_rows+=("$(IFS=,; printf '%s' "${row[*]}")")
done
generate_cluster clusters_default_cap_fast fast 8 "${over_eight_rows[@]}"
generate_cluster clusters_over_eight_fast fast 9 "${over_eight_rows[@]}"

generate_context_map context_single_histogram 1 0 0 0 0 0
generate_context_map context_simple_two_histograms 2 0 0 1 0 1 0 1
context_alt=()
context_raw=()
for ((index = 0; index < 300; index++)); do
	context_alt+=($((index % 2)))
	context_raw+=($((((index * 73 + 19) ^ (index * 11)) % 16)))
done
context_alt_mtf=(0)
for ((index = 1; index < 300; index++)); do context_alt_mtf+=(1); done
generate_context_map_with_candidates context_mtf_ans 4 "${context_alt[@]}" --mtf "${context_alt_mtf[@]}"
generate_context_map context_raw_ans 16 1 "${context_raw[@]}"
context_99=()
context_100=()
for ((index = 0; index < 100; index++)); do
	value=$((((index * 73 + 19) ^ (index * 11)) % 16))
	if ((index < 99)); then context_99+=($value); fi
	context_100+=($value)
done
generate_context_map context_prefix_99 16 1 "${context_99[@]}"
generate_context_map context_ans_100 16 1 "${context_100[@]}"
generate_context_map_with_candidates context_simple_profitability 2 0 1 0 1 0 1 --mtf 0 1 1 1 1 1
generate_context_map_with_candidates context_tie_raw_mtf 16 0 1 --mtf 0 1
context_simple_tie_entries=(1 1 0 1 1 1 1 1 1 2 2 1 1 2 2 1 2 1 0 1 1 2 1 1 0 0 2 1 1 1 1 0 0 0 1 0 2 2 2 1 0 1 1 0 1 1 0 0)
context_simple_tie_mtf=(1 0 1 1 0 0 0 0 0 2 0 1 0 1 0 1 1 1 2 1 0 2 1 0 2 0 2 2 0 0 0 2 0 0 1 1 2 0 0 2 2 1 0 1 1 0 1 0)
generate_context_map_with_candidates context_simple_tie_candidate 3 "${context_simple_tie_entries[@]}" --mtf "${context_simple_tie_mtf[@]}"
context_rle_entries=()
context_rle_mtf=()
for ((symbol = 0; symbol < 4; symbol++)); do
	for ((repeat = 0; repeat < 20; repeat++)); do context_rle_entries+=($symbol); done
	context_rle_mtf+=($symbol)
	for ((repeat = 1; repeat < 20; repeat++)); do context_rle_mtf+=(0); done
done
generate_context_map_with_candidates context_raw_rle 4 "${context_rle_entries[@]}" --mtf "${context_rle_mtf[@]}"

{ head -n 2 "$tmp"; tail -n +3 "$tmp" | sort -t $'\t' -k1,1; } > "$root/Reference/provenance.tsv"
"$root/Reference/pin-check.sh" "$linked"
