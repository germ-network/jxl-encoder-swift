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

{ head -n 2 "$tmp"; tail -n +3 "$tmp" | sort -t $'\t' -k1,1; } > "$root/Reference/provenance.tsv"
"$root/Reference/pin-check.sh" "$linked"
