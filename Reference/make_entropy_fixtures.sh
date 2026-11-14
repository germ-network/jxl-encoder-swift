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
sorted_entropy="$tmp.entropy"
trap 'rm -f "$tmp" "$sorted_entropy" "$tmp.modular.0" "$tmp.modular.1" "$tmp.tree-input.ppm" "$tmp.tree.jxl" "$tmp.tree-layout.sem"' EXIT
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

generate_coefficient_natural() {
	local name=coefficient_natural_dct8
	local input="$out/$name.input.sem"
	{
		printf 'jxl-semantic-dump 1\n'
		printf 'input.coefficient_natural.strategy i 1 0\n'
	} > "$input"
	"$harness" coefficient-order natural > "$out/$name.expected.sem"
	local input_hash expected_hash
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\tDCT8 strategy=0\t-\tDCT8 natural-order API input\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$input_hash" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_coeff_order.cc\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tAcStrategy::ComputeNaturalCoeffOrder; hwy=NEON\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" >> "$tmp"
}

generate_coefficient_sample() {
	local name=coefficient_sampled_group_boundary width=33 height=32
	local speed=6 zero0=1 zero1=8 exception_group=0 exception_slot=0 exception_position=8
	local input="$out/$name.input.sem" raw="$tmp.coeff"
	{
		printf 'jxl-semantic-dump 1\n'
		printf 'input.coefficient_sampling.blocks i 2 %s %s\n' "$width" "$height"
		printf 'input.coefficient_sampling.speed_tier i 1 %s\n' "$speed"
		printf 'input.coefficient_sampling.zero_positions i 2 %s %s\n' "$zero0" "$zero1"
		printf 'input.coefficient_sampling.first_exception i 3 %s %s %s\n' \
			"$exception_group" "$exception_slot" "$exception_position"
	} > "$input"
	"$harness" coefficient-order sample "$width" "$height" "$speed" \
		"$zero0" "$zero1" "$exception_group" "$exception_slot" \
		"$exception_position" > "$raw"
	local observed groups rejected selected zero_true zero_false count1 count8
	observed="$(awk -F '\t' -v fixture="$name" '$1 == fixture { print $4, $5, $6, $7, $8, $9, $10 }' \
		"$root/Reference/coefficient_sampling_observations.tsv")"
	read -r groups rejected selected zero_true zero_false count1 count8 <<< "$observed"
	{
		head -n 1 "$raw"
		tail -n +2 "$raw"
		printf 'entropy.coefficient_sampling.rejected_blocks i 1 %s\n' "$rejected"
		printf 'entropy.coefficient_sampling.selected_blocks i 1 %s\n' "$selected"
		printf 'entropy.coefficient_sampling.selected_counts i 2 %s %s\n' "$count1" "$count8"
		printf 'entropy.coefficient_sampling.zero_false i 1 %s\n' "$zero_false"
		printf 'entropy.coefficient_sampling.zero_true i 1 %s\n' "$zero_true"
	} > "$out/$name.expected.sem"
	local input_hash expected_hash
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\t33x32 DCT8 blocks; zeros at positions 1,8; group0/block0/position8 exception\t-\tSpeedTier::kCheetah=6; 2 groups\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$input_hash" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_coeff_order.cc,Reference/coefficient_sampling_observations.tsv\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tComputeCoeffOrder and unchanged-source LLVM coverage counters; hwy=NEON\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" >> "$tmp"
}

generate_coefficient_counts() {
	local name="$1"; shift
	local input="$out/$name.input.sem" counts=() max_count=0 value csv raw="$tmp.coeff"
	local sample_width=8392231 sample_height=1 sample_speed=6
	local zero0=1 zero1=8 exception_group=0 exception_slot=0 exception_position=8
	counts=("$@")
	for value in "${counts[@]}"; do ((value > max_count)) && max_count="$value"; done
	csv="$(IFS=,; printf '%s' "${counts[*]}")"
	{
		printf 'jxl-semantic-dump 1\n'
		printf 'input.coefficient_order.blocks i 1 %s\n' "$max_count"
		printf 'input.coefficient_order.counts i %s' "${#counts[@]}"
		printf ' %s' "${counts[@]}"
		printf '\n'
		if [[ "$name" == coefficient_sort_boundary ]]; then
			printf 'input.coefficient_sampling.blocks i 2 %s %s\n' "$sample_width" "$sample_height"
			printf 'input.coefficient_sampling.speed_tier i 1 %s\n' "$sample_speed"
			printf 'input.coefficient_sampling.zero_positions i 2 %s %s\n' "$zero0" "$zero1"
			printf 'input.coefficient_sampling.first_exception i 3 %s %s %s\n' \
				"$exception_group" "$exception_slot" "$exception_position"
		fi
	} > "$input"
	"$harness" coefficient-order counts "$max_count" "$csv" > "$raw"
	if [[ "$name" == coefficient_sort_boundary ]]; then
		local sampled_raw="$tmp.coeff.sampled" sampled_order observed
		"$harness" coefficient-order sample "$sample_width" "$sample_height" \
			"$sample_speed" "$zero0" "$zero1" "$exception_group" \
			"$exception_slot" "$exception_position" > "$sampled_raw"
		sampled_order="$(sed -n 's/^entropy.coefficient_sampling.order i 64 //p' "$sampled_raw")"
		observed="$(awk -F '\t' -v fixture="$name" '$1 == fixture { print $6, $9, $10 }' \
			"$root/Reference/coefficient_sampling_observations.tsv")"
		local selected count1 count8
		read -r selected count1 count8 <<< "$observed"
		{
			head -n 1 "$raw"
			tail -n +2 "$raw"
			printf 'entropy.coefficient_order.sampled_blocks i 1 %s\n' "$selected"
			printf 'entropy.coefficient_order.sampled_counts i 2 %s %s\n' "$count1" "$count8"
			printf 'entropy.coefficient_order.sampled_order i 64 %s\n' "$sampled_order"
		} > "$out/$name.expected.sem"
	else
		cp "$raw" "$out/$name.expected.sem"
	fi
	local input_hash expected_hash
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\tinline raster zero-count inputs\t-\tactual source count-to-order input; block count=%s\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$input_hash" "$max_count" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_coeff_order.cc,Reference/coefficient_sampling_observations.tsv\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tComputeCoeffOrder SpeedTier::kWombat over prescribed zero counts; sampled boundary adds unchanged-source LLVM coverage; hwy=NEON\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" >> "$tmp"
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

generate_tree() {
	local name="$1" kind="$2" total_pixels="$3" bitdepth="$4"
	local prevprop="$5" dc_group_count="$6" projection_root="$7"
	local input="$out/$name.input.sem"
	{
		printf 'jxl-semantic-dump 1\n'
		printf 'input.tree.kind i 1 %s\n' "$kind"
		printf 'input.tree.total_pixels i 1 %s\n' "$total_pixels"
		printf 'input.tree.bitdepth i 1 %s\n' "$bitdepth"
		printf 'input.tree.prevprop i 1 %s\n' "$prevprop"
		printf 'input.tree.dc_group_count i 1 %s\n' "$dc_group_count"
		printf 'input.tree.projection_root i 1 %s\n' "$projection_root"
	} > "$input"
	"$harness" entropy tree "$kind" "$total_pixels" "$bitdepth" "$prevprop" \
		> "$out/$name.expected.sem"
	local input_hash expected_hash
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\tinline tree parameters in generator\t-\tkind=%s pixels=%s bitdepth=%s prevprop=%s dc_group_count=%s projection_root=%s\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$input_hash" "$kind" "$total_pixels" "$bitdepth" \
		"$prevprop" "$dc_group_count" "$projection_root" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_entropy.cc\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tPredefinedTree + TokenizeTree kind=%s pixels=%s bitdepth=%s prevprop=%s hwy=NEON\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" "$kind" "$total_pixels" \
		"$bitdepth" "$prevprop" >> "$tmp"
}

generate_tree_entropy() {
	local name=tree_entropy_cheetah
	local input="$out/$name.input.sem"
	local tokens=($(awk '$1 == "input.tree_entropy.tokens" { for (i = 4; i <= NF; i++) print $i }' "$input"))
	[[ ${#tokens[@]} -eq 626 ]]
	"$harness" entropy tree-entropy 6 0 0 313 "${tokens[@]}" \
		> "$out/$name.expected.sem"
	local input_hash expected_hash
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tSources/JXLEncoder/ContextTree.swift\tReference/make_entropy_fixtures.sh\tstaticTokens with token[1] patched for dcGroupCount=2\t-\tCheetah tree token stream; contexts=6\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$input_hash" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_entropy.cc\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tCheetah ForModular histogram coding and tree token serialization; hwy=NEON\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" >> "$tmp"
}

generate_acmeta_tree() {
	local name="$1" rect="$2" first_blocks="$3"
	local map=$(((rect + 7) / 8))
	local cfl_area=$((map * map))
	local ac_area=$((first_blocks * 2))
	local epf_area=$((rect * rect))
	local total_pixels=$((cfl_area * 2 + ac_area + epf_area))
	local input="$out/$name.input.sem"
	{
		printf 'jxl-semantic-dump 1\n'
		printf 'input.tree.kind i 1 4\n'
		printf 'input.tree.total_pixels i 1 %s\n' "$total_pixels"
		printf 'input.tree.bitdepth i 1 8\n'
		printf 'input.tree.prevprop i 1 0\n'
		printf 'input.tree.dc_group_count i 1 1\n'
		printf 'input.tree.projection_root i 1 1\n'
		printf 'input.tree.channel_areas i 4 %s %s %s %s\n' \
			"$cfl_area" "$cfl_area" "$ac_area" "$epf_area"
	} > "$input"
	"$harness" entropy tree 4 "$total_pixels" 8 0 > "$out/$name.expected.sem"
	local input_hash expected_hash
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\tinline AC metadata channel layout\t-\tAC metadata: 2 CfL channels %sx%s, ACS/QF %s first blocks x2, EPF %sx%s; total_pixels=%s\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$input_hash" "$map" "$map" "$first_blocks" "$rect" "$rect" "$total_pixels" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_entropy.cc\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tPredefinedTree(kACMeta) from actual AC metadata channel areas; hwy=NEON\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" >> "$tmp"
}

generate_acmeta_channels() {
	local width="$1" height="$2"
	local name="acmeta_channels_${width}x${height}"
	local cmap_width=$(((width + 7) / 8))
	local cmap_count=$((cmap_width * ((height + 7) / 8)))
	local block_count=$((width * height))
	local -a ytox=() ytob=() acs=() qf=() epf=()
	local index input="$out/$name.input.sem"
	for ((index = 0; index < cmap_count; index++)); do
		ytox+=($(((index * 3 + 1) % 7 - 3)))
		ytob+=($(((index * 5 + 2) % 9 - 4)))
	done
	for ((index = 0; index < block_count; index++)); do
		acs+=(0)
		case $((index % 5)) in
			0) qf+=(1) ;;
			1) qf+=(4) ;;
			2) qf+=(7) ;;
			3) qf+=(12) ;;
			4) qf+=(16) ;;
		esac
		epf+=(4)
	done
	{
		printf 'jxl-semantic-dump 1\n'
		printf 'input.ac_metadata.width i 1 %s\ninput.ac_metadata.height i 1 %s\n' "$width" "$height"
		printf 'input.ac_metadata.ytox i %s' "${#ytox[@]}"; printf ' %s' "${ytox[@]}"
		printf '\ninput.ac_metadata.ytob i %s' "${#ytob[@]}"; printf ' %s' "${ytob[@]}"
		printf '\ninput.ac_metadata.acs i %s' "${#acs[@]}"; printf ' %s' "${acs[@]}"
		printf '\ninput.ac_metadata.raw_quant_field i %s' "${#qf[@]}"; printf ' %s' "${qf[@]}"
		printf '\ninput.ac_metadata.epf i %s' "${#epf[@]}"; printf ' %s' "${epf[@]}"
		printf '\n'
	} > "$input"
	"$harness" entropy ac-metadata "$width" "$height" "$block_count" \
		"${ytox[@]}" "${ytob[@]}" "${acs[@]}" "${qf[@]}" "${epf[@]}" \
		> "$out/$name.expected.sem"
	local input_hash expected_hash
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\tinline AC metadata channel samples\t-\tblock grid=%sx%s, DCT8 first blocks; qf edges 1,4,7,12,16; EPF=4\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$input_hash" "$width" "$height" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_entropy.cc\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tModularCompress with PredefinedTree(kACMeta); per-channel leaf contexts and residuals; hwy=NEON\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" >> "$tmp"
}

generate_modular_group() {
	local group="$1" width="$2" height="$3" group_id="$4"
	shift 4
	local -a channel0=("$1" "$2" "$3" "$4" "$5" "$6")
	shift 6
	local -a channel1=("$1" "$2" "$3" "$4" "$5" "$6")
	shift 6
	local -a channel2=("$1" "$2" "$3" "$4" "$5" "$6")
	local generated="$tmp.modular.$group"
	"$harness" entropy modular "$width" "$height" 8 6 8193 0 \
		"$group_id" 1 0 2 "${channel0[@]}" "${channel1[@]}" "${channel2[@]}" \
		> "$generated"
	awk -v group="$group" 'NR > 1 { sub(/^entropy[.]modular[.]/, "entropy.modular.group" group "."); print }' \
		"$generated"
}

generate_modular() {
	local name="modular_dc_gradient_rows"
	local input="$out/$name.input.sem"
	{
		printf 'jxl-semantic-dump 1\n'
		printf 'input.modular.tree_kind i 1 6\n'
		printf 'input.modular.total_pixels i 1 8193\n'
		printf 'input.modular.bitdepth i 1 8\n'
		printf 'input.modular.prevprop i 1 0\n'
		printf 'input.modular.context_offset i 1 11\n'
		printf 'input.modular.dc_group_count i 1 2\n'
		printf 'input.modular.group0.width i 1 3\ninput.modular.group0.height i 1 2\n'
		printf 'input.modular.group0.group_id i 1 3\n'
		printf 'input.modular.group0.channel_order i 3 1 0 2\n'
		printf 'input.modular.group0.channel0 i 6 4 5 6 7 8 9\n'
		printf 'input.modular.group0.channel1 i 6 -3 -1 2 3 6 10\n'
		printf 'input.modular.group0.channel2 i 6 30 20 10 0 -10 -20\n'
		printf 'input.modular.group1.width i 1 2\ninput.modular.group1.height i 1 3\n'
		printf 'input.modular.group1.group_id i 1 4\n'
		printf 'input.modular.group1.channel_order i 3 1 0 2\n'
		printf 'input.modular.group1.channel0 i 6 7 8 9 10 11 12\n'
		printf 'input.modular.group1.channel1 i 6 -4 -2 0 2 4 6\n'
		printf 'input.modular.group1.channel2 i 6 -30 -20 -10 0 10 20\n'
	} > "$input"
	{
		printf 'jxl-semantic-dump 1\n'
		generate_modular_group 0 3 2 3 4 5 6 7 8 9 -3 -1 2 3 6 10 30 20 10 0 -10 -20
		generate_modular_group 1 2 3 4 7 8 9 10 11 12 -4 -2 0 2 4 6 -30 -20 -10 0 10 20
	} > "$out/$name.expected.sem"
	local input_hash expected_hash
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\tinline modular samples in generator\t-\ttwo 3-channel DC groups; gradient tree kind=6 pixels=8193 bitdepth=8; stream IDs=3,4; channel order=1,0,2\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$input_hash" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_entropy.cc\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tModularCompress with PredefinedTree(kGradientFixedDC); raw leaf IDs and packed residuals; hwy=NEON\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" >> "$tmp"
}

generate_modular_wp() {
	local name="modular_dc_wp_fixed_8192"
	local input="$out/$name.input.sem"
	{
		printf 'jxl-semantic-dump 1\n'
		printf 'input.modular.tree_kind i 1 5\n'
		printf 'input.modular.total_pixels i 1 8192\n'
		printf 'input.modular.bitdepth i 1 8\n'
		printf 'input.modular.prevprop i 1 0\n'
		printf 'input.modular.context_offset i 1 11\n'
		printf 'input.modular.predictor i 1 6\n'
		printf 'input.modular.wp_tree_mode i 1 1\n'
		printf 'input.modular.dc_group_count i 1 1\n'
		printf 'input.modular.group0.width i 1 3\ninput.modular.group0.height i 1 2\n'
		printf 'input.modular.group0.group_id i 1 3\n'
		printf 'input.modular.group0.channel_order i 3 1 0 2\n'
		printf 'input.modular.group0.channel0 i 6 4 5 6 7 8 9\n'
		printf 'input.modular.group0.channel1 i 6 -3 -1 2 3 6 10\n'
		printf 'input.modular.group0.channel2 i 6 30 20 10 0 -10 -20\n'
	} > "$input"
	"$harness" entropy modular 3 2 8 5 8192 0 3 1 0 2 \
		4 5 6 7 8 9 -3 -1 2 3 6 10 30 20 10 0 -10 -20 \
		> "$out/$name.expected.sem"
	local input_hash expected_hash
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\texplicit 3x2 DC group samples\t-\tkind=kWPFixedDC pixels=8192 bitdepth=8 prevprop=0; Weighted/kWPOnly; not frame-derived\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$input_hash" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_entropy.cc\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tPredefinedTree(kWPFixedDC) + ModularCompress with Weighted/kWPOnly; hwy=NEON\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" >> "$tmp"
}

generate_ac_tokens() {
	local name="$1" num_contexts="$2"; shift 2
	local input="$out/$name.input.sem"
	local -a context_map=("$@") order=() qdc=(0 0 0 0) qf=(1 1 1 1) coefficients=()
	local row block channel rank value count
	for ((row = 0; row < 8; row++)); do
		for ((block = 0; block < 8; block++)); do
			order+=("$((block * 8 + row))")
		done
	done
	local -a counts=(0 3 32 2 4 1 5 3 2 4 0 6)
	for ((channel = 0; channel < 3; channel++)); do
		for ((block = 0; block < 4; block++)); do
			local -a values=()
			for ((rank = 0; rank < 64; rank++)); do values+=(0); done
			count="${counts[channel * 4 + block]}"
			case "$count" in
				0) ;;
				1) values[${order[1]}]=$((channel + 2)) ;;
				2) values[${order[1]}]=$((channel + 2)); values[${order[5]}]=$((-channel - 3)) ;;
				3) values[${order[1]}]=$((channel + 2)); values[${order[4]}]=$((-channel - 3)); values[${order[63]}]=$((channel + 5)) ;;
				4) values[${order[1]}]=$((channel + 2)); values[${order[3]}]=$((-channel - 3)); values[${order[7]}]=$((channel + 4)); values[${order[63]}]=$((-channel - 5)) ;;
				5) for ((rank = 1; rank <= 5; rank++)); do values[${order[rank]}]=$((channel + rank + 1)); done ;;
				6) values[${order[1]}]=$((channel + 2)); values[${order[3]}]=$((-channel - 3)); values[${order[4]}]=$((channel + 4)); values[${order[8]}]=$((-channel - 5)); values[${order[14]}]=$((channel + 6)); values[${order[63]}]=$((-channel - 7)) ;;
				8) for ((rank = 1; rank <= 8; rank++)); do values[${order[rank]}]=$(((rank % 2 == 0 ? -1 : 1) * (channel + rank + 1))); done ;;
				32) for ((rank = 1; rank <= 32; rank++)); do values[${order[rank]}]=$(((rank % 2 == 0 ? -1 : 1) * (channel + rank + 1))); done ;;
			esac
			coefficients+=("${values[@]}")
		done
	done
	{
		printf 'jxl-semantic-dump 1\ninput.ac_tokens.width i 1 2\ninput.ac_tokens.height i 1 2\n'
		printf 'input.ac_tokens.strategy i 1 0\ninput.ac_tokens.dct8_order i 1 0\n'
		printf 'input.ac_tokens.channel_order i 3 1 0 2\n'
		printf 'input.ac_tokens.context_count i 1 %s\n' "$num_contexts"
		printf 'input.ac_tokens.context_map i %s' "${#context_map[@]}"
		printf ' %s' "${context_map[@]}"
		printf '\ninput.ac_tokens.order i %s' "${#order[@]}"
		printf ' %s' "${order[@]}"
		printf '\ninput.ac_tokens.qdc i %s' "${#qdc[@]}"
		printf ' %s' "${qdc[@]}"
		printf '\ninput.ac_tokens.qf i %s' "${#qf[@]}"
		printf ' %s' "${qf[@]}"
		printf '\n'
		for channel in 0 1 2; do
			printf 'input.ac_tokens.channel%s i %s' "$channel" "$((4 * 64))"
			for ((block = 0; block < 256; block++)); do
				printf ' %s' "${coefficients[channel * 256 + block]}"
			done
			printf '\n'
		done
	} > "$input"
	"$harness" entropy ac-tokens 2 2 "$num_contexts" \
		"${context_map[@]}" "${order[@]}" "${qdc[@]}" "${qf[@]}" \
		"${coefficients[@]}" > "$out/$name.expected.sem"
	local input_hash expected_hash
	input_hash="$(shasum -a 256 "$input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$out/$name.expected.sem" | cut -d ' ' -f 1)"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\tinline DCT8 coefficient groups in generator\t-\t2x2 blocks; strategy=0; order=explicit transpose; contexts=%s; qdc/qf recorded\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$input_hash" "$num_contexts" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_entropy.cc\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tTokenizeCoefficients DCT8; prescribed context map=%s; hwy=NEON\tTests/JXLEncoderTests/EntropyReferenceTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" "$num_contexts" >> "$tmp"
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

generate_tree tree_gradient_fixed_8192_dc1 6 8192 8 0 1 2
generate_tree tree_gradient_fixed_8193_dc2 6 8193 8 0 2 2
generate_tree tree_wp_fixed_8192_dc1 5 8192 8 0 1 2
generate_tree tree_wp_fixed_8193_dc2 5 8193 8 0 2 2
generate_acmeta_tree tree_acmeta_below_1024 16 8
generate_acmeta_tree tree_acmeta_above_1024 32 32
generate_tree_entropy
generate_acmeta_channels 16 16
generate_acmeta_channels 24 24
generate_modular
generate_modular_wp
tiny_context_map=()
for category in 0 2 2; do
	for ((index = 0; index < 13; index++)); do tiny_context_map+=("$category"); done
done
default_context_map=(0 1 2 2 3 3 4 5 6 6 6 6 6 7 8 9 9 10 11 12 13 14 14 14 14 14 7 8 9 9 10 11 12 13 14 14 14 14 14)
generate_ac_tokens ac_tokens_tiny_map 4 "${tiny_context_map[@]}"
generate_ac_tokens ac_tokens_default_map 15 "${default_context_map[@]}"

generate_coefficient_natural
generate_coefficient_sample
bounded_counts=()
for ((index = 0; index < 64; index++)); do bounded_counts+=(0); done
bounded_counts[1]=$(((1 << 22) - 1))
bounded_counts[8]=$(((1 << 22) - 2))
bounded_counts[16]=7
bounded_counts[9]=8
bounded_counts[2]=15
bounded_counts[3]=16
bounded_counts[10]=23
bounded_counts[17]=24
bounded_counts[24]=31
bounded_counts[25]=32
generate_coefficient_counts coefficient_sort_bounded "${bounded_counts[@]}"
boundary_counts=()
for ((index = 0; index < 64; index++)); do boundary_counts+=(0); done
boundary_counts[1]=4194312
boundary_counts[8]=4194311
generate_coefficient_counts coefficient_sort_boundary "${boundary_counts[@]}"

primitive_uint_values=(0 1 15 16 17 20 24 28 32 63 64 255 256 1000 65535 65536 1048576)
primitive_signed_values=(0 1 -1 2 -2 100 -100 32767 -32768 1048576 -1048576)
primitive_histograms=(
	1,1,1,1
	5,0,3,0,1
	100,1,1,1,1,1,1,1
	1
	0,0,7
	1,2,4,8,16,32,64,128,256,512,1024,2048,4096,8192,16384
)
uint_input="$out/hybrid_uint_4_2_0.input.sem"
{
	printf 'jxl-semantic-dump 1\ninput.uint.config i 3 4 2 0\n'
	printf 'input.uint.values i %s' "${#primitive_uint_values[@]}"
	printf ' %s' "${primitive_uint_values[@]}"
	printf '\n'
} > "$uint_input"
"$harness" entropy-primitives uint 4 2 0 "${primitive_uint_values[@]}" \
	> "$out/hybrid_uint_4_2_0.expected.sem"
signed_input="$out/pack_signed_full_reference.input.sem"
{
	printf 'jxl-semantic-dump 1\ninput.signed.values i %s' "${#primitive_signed_values[@]}"
	printf ' %s' "${primitive_signed_values[@]}"
	printf '\n'
} > "$signed_input"
"$harness" entropy-primitives signed "${primitive_signed_values[@]}" \
	> "$out/pack_signed_full_reference.expected.sem"
huffman_input="$out/huffman_tree_full_reference.input.sem"
{
	printf 'jxl-semantic-dump 1\ninput.huffman.tree_limit i 1 15\n'
	printf 'input.huffman.lengths i %s' "${#primitive_histograms[@]}"
	printf ' %s' 4 5 8 1 3 15
	printf '\ninput.huffman.counts i 36'
	for histogram in "${primitive_histograms[@]}"; do
		IFS=',' read -r -a counts <<< "$histogram"
		printf ' %s' "${counts[@]}"
	done
	printf '\n'
} > "$huffman_input"
"$harness" entropy-primitives huffman 15 "${primitive_histograms[@]}" \
	> "$out/huffman_tree_full_reference.expected.sem"

for name in hybrid_uint_4_2_0 pack_signed_full_reference huffman_tree_full_reference; do
	local_input="$out/$name.input.sem"
	local_expected="$out/$name.expected.sem"
	input_hash="$(shasum -a 256 "$local_input" | cut -d ' ' -f 1)"
	expected_hash="$(shasum -a 256 "$local_expected" | cut -d ' ' -f 1)"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\tinline primitive parameters in generator\t-\tpinned API case inputs\tTests/JXLEncoderTests/EntropyTests.swift,Tests/JXLEncoderTests/PrefixCodeWriterTests.swift\n' \
		"$name" "$input_hash" >> "$tmp"
	printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/cmd_entropy_primitives.cc\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tpinned primitive outputs; hwy=NEON\tTests/JXLEncoderTests/EntropyTests.swift,Tests/JXLEncoderTests/PrefixCodeWriterTests.swift\n' \
		"$name" "$expected_hash" "$name" "$pin" >> "$tmp"
done

tree_name=tree_merged_multidc_2057x257
tree_input="$out/$tree_name.input.sem"
tree_expected="$out/$tree_name.expected.sem"
tree_source="$root/Tests/JXLEncoderTests/Fixtures/semantic/pixel_lifecycle_2057x521.ppm"
python3 - "$tree_source" "$tree_input" <<'PYCODE'
import hashlib, sys
from pathlib import Path
source, destination = map(Path, sys.argv[1:])
digest = hashlib.sha256(source.read_bytes()).digest()
text = ['jxl-semantic-dump 1']
text += [
    'input.tree_merged.source_sha256 i 32 ' + ' '.join(map(str, digest)),
    'input.tree_merged.crop_size i 2 2057 257',
    'input.tree_merged.effort i 1 4',
    'input.tree_merged.distance_milli i 1 1000',
    'input.tree_merged.output_mode i 1 2',
    'input.tree_merged.buffering i 1 0',
]
destination.write_text('\n'.join(text) + '\n')
PYCODE
python3 - "$tree_source" "$tmp.tree-input.ppm" <<'PYCODE'
import re, sys
from pathlib import Path
source, destination = map(Path, sys.argv[1:])
data = source.read_bytes()
match = re.match(rb'P6\s+(\d+)\s+(\d+)\s+255\s', data)
assert match and tuple(map(int, match.groups())) == (2057, 521)
payload = data[match.end():]
row = 2057 * 3
destination.write_bytes(b'P6\n2057 257\n255\n' + b''.join(
    payload[y * row:(y + 1) * row] for y in range(257)))
PYCODE
"$harness" encode "$tmp.tree-input.ppm" 1 "$tmp.tree.jxl" 2 0
"$harness" dump "$tmp.tree.jxl" entropy_layout > "$tmp.tree-layout.sem"
python3 - "$tmp.tree-layout.sem" "$tree_expected" <<'PYCODE'
import sys
from pathlib import Path
source, destination = map(Path, sys.argv[1:])
fields = {line.split()[0]: line for line in source.read_text().splitlines()[1:]}
mapping = {
    'entropy_layout.group_count': 'entropy.tree_merged.group_count',
    'entropy_layout.dc_group_count': 'entropy.tree_merged.dc_group_count',
    'entropy_layout.modular_tree.node_count': 'entropy.tree_merged.node_count',
    'entropy_layout.modular_tree.nodes': 'entropy.tree_merged.nodes',
}
output = ['jxl-semantic-dump 1']
for original, expected in mapping.items():
    line = fields[original]
    output.append(expected + line[len(original):])
destination.write_text('\n'.join(output) + '\n')
PYCODE
tree_input_hash="$(shasum -a 256 "$tree_input" | cut -d ' ' -f 1)"
tree_expected_hash="$(shasum -a 256 "$tree_expected" | cut -d ' ' -f 1)"
printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tfixture\t%s\thand-supplied\tReference/make_entropy_fixtures.sh\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/semantic/pixel_lifecycle_2057x521.ppm\t-\tcrop=2057x257 effort=4 distance=1 output_mode=2 buffering=0\tEntropyReferenceTests.swift,SemanticCrossCheckTests.swift\n' \
	"$tree_name" "$tree_input_hash" >> "$tmp"
printf 'Tests/JXLEncoderTests/Fixtures/entropy/%s.expected.sem\tfixture\t%s\tfull-libjxl\tReference/harness/src/decoded_frame.cc,Reference/harness/src/capture_modular_tree.cc\tReference/make_entropy_fixtures.sh\tTests/JXLEncoderTests/Fixtures/entropy/%s.input.sem\tlibjxl %s\tdecoded merged tree; groups=18 dc_groups=2 hwy=NEON\tSemanticCrossCheckTests.swift\n' \
	"$tree_name" "$tree_expected_hash" "$tree_name" "$pin" >> "$tmp"

git -C "$root" show HEAD:Reference/provenance.tsv \
	| awk -F '\t' 'NR > 2 && $1 ~ /^Tests\/JXLEncoderTests\/Fixtures\/entropy\/stream_shared_(ans|prefix)\.(input|expected|receipt)\.sem$/' \
	>> "$tmp"

awk -F '\t' 'NR > 2 && $1 ~ /^Tests\/JXLEncoderTests\/Fixtures\/entropy\//' \
	"$tmp" | sort -t $'\t' -k1,1 > "$sorted_entropy"
{
	head -n 2 "$tmp"
	awk -F '\t' -v entropy_file="$sorted_entropy" \
		'$1 == "Tests/JXLEncoderTests/Fixtures/hopper_420_odd.coef" {
			while ((getline line < entropy_file) > 0) print line
			close(entropy_file)
		}
		NR > 2 && $1 ~ /^Tests\/JXLEncoderTests\/Fixtures\/entropy\// { next }
		NR > 2 { print }' "$tmp"
} > "$root/Reference/provenance.tsv"
"$root/Reference/pin-check.sh" "$linked"
