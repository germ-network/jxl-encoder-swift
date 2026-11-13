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
stages_reproduce_committed_fixtures() {
  bash "$REFERENCE/make_stage_fixtures.sh" "$SCRATCH/stages"
  python3 - "$REFERENCE/.." "$SCRATCH/stages" <<'PYCODE'
import csv,hashlib,sys
from pathlib import Path
root=Path(sys.argv[1]); output=Path(sys.argv[2])
rows=[line for line in (root/'Reference/provenance.tsv').read_text().splitlines() if not line.startswith('#')]
by_name={Path(r[0]).name:r[2] for r in csv.reader(rows,delimiter='\t') if r[1]=='fixture'}
for path in output.glob('*.dump'):
 assert hashlib.sha256(path.read_bytes()).hexdigest()==by_name[path.name], path.name
assert len(list(output.glob('*.dump')))==6
PYCODE
}
semantic_fixtures_reproduce() {
  # e4's uniform field cannot distinguish row-major from transposed output.
  "$HARNESS" selftest --quant-field "$SCRATCH/quant.sem"
  grep -Fx 'quant_field.raw i 6 1 2 3 11 12 13' "$SCRATCH/quant.sem"
  bash "$REFERENCE/make_semantic_fixtures.sh" "$SCRATCH/semantic"
  python3 - "$REFERENCE/.." "$SCRATCH/semantic" <<'PYCODE'
import hashlib,sys
from pathlib import Path
root=Path(sys.argv[1]); output=Path(sys.argv[2])
rows={r[0]:r for line in (root/'Reference/provenance.tsv').read_text().splitlines() if not line.startswith('#') for r in [line.split('\t')]}
expected={'edge','multigroup','flower_512_d1','flower_512_d3','flower_1024','ac_entropy_flat_singleton','ac_entropy_static_prefix'}
assert {p.stem for p in output.glob('*.sem')}==expected
for p in output.glob('*'):
 if p.suffix not in ('.sem','.ppm'): continue
 path='Tests/JXLEncoderTests/Fixtures/semantic/'+p.name
 assert hashlib.sha256(p.read_bytes()).hexdigest()==rows[path][2], path
for name in expected-{'ac_entropy_flat_singleton','ac_entropy_static_prefix'}:
 fields={line.split()[0]:line.split()[1:] for line in (output/(name+'.sem')).read_text().splitlines()[1:]}
 required={'image_header.size','image_header.transfer_function','image_header.color_space','image_header.white_point','image_header.primaries','image_header.rendering_intent','image_header.xyb','image_header.num_extra_channels','image_sample_format.floating_point','image_sample_format.bits_per_sample','image_sample_format.exponent_bits_per_sample','frame.encoding','frame.groups','frame.dc_groups','frame.passes','frame_flags.flags','gaborish.enabled','epf.iterations','x_matrix_scale.value','b_matrix_scale.value','quant_matrix.dct8.c0','quant_matrix.dct8.c1','quant_matrix.dct8.c2','inverse_quant_matrix.dct8.c0','inverse_quant_matrix.dct8.c1','inverse_quant_matrix.dct8.c2','dc_quant_matrix.values','inverse_dc_quant_matrix.values','coeff_order.nondefault_orders','coeff_order.dct8.c0','coeff_order.dct8.c1','coeff_order.dct8.c2','block_context.dc_thresholds.c0','block_context.dc_thresholds.c1','block_context.dc_thresholds.c2','block_context.qf_thresholds','block_context.ctx_map','block_context.num_ctxs','context_map.num_histograms','context_map.ac','quant_field.raw','quant_field.global_scale','quant_field.quant_dc','ac_entropy.kind','ac_entropy.table_count','ac_entropy.uint_config','ac_entropy.lz77_enabled','ac_entropy_alphabet.ans_log_alpha_size'}
 size={'edge':(32,32),'multigroup':(301,301),'flower_512_d1':(512,512),'flower_512_d3':(512,512),'flower_1024':(1024,1024)}[name]
 assert list(map(int,fields['image_header.size'][2:]))==list(size)
 assert int(fields['quant_field.raw'][1])==((size[0]+7)//8)*((size[1]+7)//8)
 assert fields['frame.encoding']==['i','1','0'] and fields['image_header.xyb']==['i','1','1']
 assert fields['frame.passes']==['i','1','1']
 assert fields['epf.iterations']==['i','1','2' if name=='flower_512_d3' else '1']
 for channel in range(3):
  assert fields[f'quant_matrix.dct8.c{channel}'][:2]==['f','64']
  assert fields[f'inverse_quant_matrix.dct8.c{channel}'][:2]==['f','64']
 assert fields['dc_quant_matrix.values'][:2]==['f','3']
 assert fields['inverse_dc_quant_matrix.values'][:2]==['f','3']
 if fields['ac_entropy.kind'][2]=='1': required|={'ac_entropy.ans.alphabet_lengths','ac_entropy.ans.frequencies'}
 else: required|={'ac_entropy.prefix.alphabet_lengths','ac_entropy.prefix.singleton_symbols','ac_entropy.prefix.depths'}
 assert set(fields)==required, name
 for channel in range(3): assert sorted(map(int,fields[f'coeff_order.dct8.c{channel}'][2:]))==list(range(64))
 assert fields['frame.groups']==['i','1',str(((size[0]+255)//256)*((size[1]+255)//256))]
PYCODE
}
actual_entropy_prefix_streams() {
  "$HARNESS" encode "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/semantic/ac_entropy_flat.ppm" 1 "$SCRATCH/ac_entropy_flat.jxl"
  "$HARNESS" dump "$SCRATCH/ac_entropy_flat.jxl" ac_entropy > "$SCRATCH/ac_entropy_flat.sem"
  grep -Fx 'ac_entropy.prefix.alphabet_lengths i 1 1' "$SCRATCH/ac_entropy_flat.sem"
  grep -Fx 'ac_entropy.prefix.singleton_symbols i 1 0' "$SCRATCH/ac_entropy_flat.sem"
  grep -Fx 'ac_entropy.prefix.depths i 1 0' "$SCRATCH/ac_entropy_flat.sem"
  "$HARNESS" dump "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/edge_whole.jxl" ac_entropy > "$SCRATCH/ac_entropy_static.sem"
  python3 - "$SCRATCH/ac_entropy_static.sem" <<'PYCODE'
import sys
fields={line.split()[0]:line.split()[1:] for line in open(sys.argv[1]).read().splitlines()[1:]}
assert fields['ac_entropy.kind']==['i','1','0']
depths=list(map(int,fields['ac_entropy.prefix.depths'][2:]))
assert max(depths)>8
PYCODE
}
actual_entropy_jpeg_reference() {
  bash "$REFERENCE/make_ac_entropy_jpeg_fixture.sh" "$SCRATCH/ac_entropy_jpeg_2x1.sem"
  cmp "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/semantic/ac_entropy_jpeg_2x1.sem" "$SCRATCH/ac_entropy_jpeg_2x1.sem"
}
dump_rejects_non_codestream() {
  printf 'not a codestream' > "$SCRATCH/invalid.jxl"
  if "$HARNESS" dump "$SCRATCH/invalid.jxl"; then return 1; fi
  "$HARNESS" encode "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/edge_linear.dump" 1 "$SCRATCH/edge.jxl"
  "$HARNESS" dump "$SCRATCH/edge.jxl" > "$SCRATCH/edge.sem"
  head -c 4 "$SCRATCH/edge.jxl" > "$SCRATCH/truncated.jxl"
  if "$HARNESS" dump "$SCRATCH/truncated.jxl"; then return 1; fi
  if "$HARNESS" dump "$SCRATCH/edge.jxl" nonexistent; then return 1; fi
}
entropy_rejects_unsafe_histogram_config() {
  if "$HARNESS" entropy histogram 4 fast 1; then return 1; fi
  if "$HARNESS" entropy histogram 9 fast 1; then return 1; fi
  local -a counts=()
  for ((index = 0; index < 33; index++)); do counts+=(0); done
  if "$HARNESS" entropy histogram 5 fast "${counts[@]}"; then return 1; fi
  if "$HARNESS" entropy histogram 7 fast 2147483647 2147483647 2; then return 1; fi
  if "$HARNESS" entropy cluster fast 2 2147483647 2147483647 2; then return 1; fi
  if "$HARNESS" entropy context-map 0 0; then return 1; fi
  if "$HARNESS" entropy context-map 2 0 2; then return 1; fi
  if "$HARNESS" entropy context-map 16 0 1 --mtf 0; then return 1; fi
}
entropy_context_map_decisions_match_fixtures() {
  "$HARNESS" entropy context-map 2 0 1 0 1 0 1 > "$SCRATCH/context_simple.sem"
  cmp "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/entropy/context_simple_two_histograms.expected.sem" "$SCRATCH/context_simple.sem"
  "$HARNESS" entropy context-map 2 0 1 0 1 0 1 --mtf 0 1 1 1 1 1 > "$SCRATCH/context_profitability.sem"
  cmp "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/entropy/context_simple_profitability.expected.sem" "$SCRATCH/context_profitability.sem"
  "$HARNESS" entropy context-map 16 0 1 --mtf 0 1 > "$SCRATCH/context_tie.sem"
  cmp "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/entropy/context_tie_raw_mtf.expected.sem" "$SCRATCH/context_tie.sem"
}
stage2_fixtures_reproduce() {
  bash "$REFERENCE/make_stage2_fixtures.sh" "$SCRATCH/stage2"
  python3 - "$REFERENCE/.." "$SCRATCH/stage2" <<'PYCODE'
import hashlib,sys
from pathlib import Path
root=Path(sys.argv[1]); output=Path(sys.argv[2])
manifest={line.split('\t')[0]:line.split('\t') for line in (root/'Reference/provenance.tsv').read_text().splitlines() if not line.startswith('#')}
fixtures=sorted(p for p in output.iterdir() if p.is_file())
names={'bounded_quantized.sem','edge_fixed_quantized.sem','coded_dimensions.sem','distance_params.sem','distance_filters.sem','dc_boundary.sem','dc_boundary.ppm','quant_bias.sem'}
for stem in ('flower_1024','pixel_lifecycle_2057x521'):
 names.update({stem+'.ppm',stem+'.ac.bin',stem+'.dc.bin',stem+'.stages.sem'})
expected={name:manifest['Tests/JXLEncoderTests/Fixtures/semantic/'+name][2] for name in names}
assert {p.name for p in fixtures}==names
for fixture in fixtures:
 assert hashlib.sha256(fixture.read_bytes()).hexdigest()==expected[fixture.name], fixture.name
PYCODE
}
entropy_tree_decisions_match_fixtures() {
  "$HARNESS" entropy tree 6 8192 8 0 > "$SCRATCH/tree_8192.sem"
  cmp "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/entropy/tree_gradient_fixed_8192_dc1.expected.sem" "$SCRATCH/tree_8192.sem"
  "$HARNESS" entropy tree 6 8193 8 0 > "$SCRATCH/tree_8193.sem"
  cmp "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/entropy/tree_gradient_fixed_8193_dc2.expected.sem" "$SCRATCH/tree_8193.sem"
  if "$HARNESS" entropy tree 6 0 8 0; then return 1; fi
}
entropy_modular_decisions_match_fixtures() {
  local expected="$REFERENCE/../Tests/JXLEncoderTests/Fixtures/entropy/modular_dc_gradient_rows.expected.sem"
  local -a first=(3 2 8 6 8193 0 3 1 0 2 4 5 6 7 8 9 -3 -1 2 3 6 10 30 20 10 0 -10 -20)
  local -a second=(2 3 8 6 8193 0 4 1 0 2 7 8 9 10 11 12 -4 -2 0 2 4 6 -30 -20 -10 0 10 20)
  "$HARNESS" entropy modular "${first[@]}" > "$SCRATCH/modular0.sem"
  "$HARNESS" entropy modular "${second[@]}" > "$SCRATCH/modular1.sem"
  for group in 0 1; do
    python3 - "$expected" "$SCRATCH/modular$group.sem" "$group" <<'PYCODE'
import sys
from pathlib import Path
expected=Path(sys.argv[1]).read_text().splitlines()
actual=Path(sys.argv[2]).read_text().splitlines()
group=sys.argv[3]
fields=["jxl-semantic-dump 1"]
prefix=f"entropy.modular.group{group}."
fields.extend(line.replace(prefix,"entropy.modular.",1) for line in expected[1:] if line.startswith(prefix))
assert fields==actual
PYCODE
  done
}
entropy_modular_rejects_unsafe_inputs() {
  local -a samples=(3 2 8 6 8193 0 3 1 0 2 4 5 6 7 8 9 -3 -1 2 3 6 10 30 20 10 0 -10 -20)
  local -a zero_width=(0 "${samples[@]:1}")
  local -a duplicate_order=(3 2 8 6 8193 0 3 1 1 2 "${samples[@]:10}")
  if "$HARNESS" entropy modular "${zero_width[@]}"; then return 1; fi
  if "$HARNESS" entropy modular "${duplicate_order[@]}"; then return 1; fi
  if "$HARNESS" entropy modular "${samples[@]:0:10}"; then return 1; fi
  if "$HARNESS" entropy modular 3 2 8 6 8193 0 3 1 0 2 4 5 6 7 8 40000 -3 -1 2 3 6 10 30 20 10 0 -10 -20; then return 1; fi
}
entropy_ac_tokens_match_fixtures() {
  python3 - "$HARNESS" "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/entropy" <<'PYCODE'
import subprocess,sys
from pathlib import Path
harness=sys.argv[1]; fixtures=Path(sys.argv[2])
for name in ('ac_tokens_tiny_map','ac_tokens_default_map'):
    fields={}
    for line in (fixtures/f'{name}.input.sem').read_text().splitlines()[1:]:
        parts=line.split(); fields[parts[0]]=parts[3:]
    keys=('width','height','context_count','context_map','order','qdc','qf','channel0','channel1','channel2')
    args=['entropy','ac-tokens']+[value for key in keys for value in fields[f'input.ac_tokens.{key}']]
    result=subprocess.run([harness,*args],text=True,capture_output=True)
    assert result.returncode==0, (name,result.stderr)
    assert result.stdout==(fixtures/f'{name}.expected.sem').read_text(), name
    if name=='ac_tokens_tiny_map':
        cases=[]
        zero=list(args); zero[2]='0'; cases.append(zero)
        contexts=list(args); contexts[4]='3'; cases.append(contexts)
        duplicate=list(args); duplicate[3+3+39+1]=duplicate[3+3+39]; cases.append(duplicate)
        oversized_qdc=list(args); oversized_qdc[3+3+39+64]= '256'; cases.append(oversized_qdc)
        oversized_coeff=list(args); oversized_coeff[3+3+39+64+8]='2147483648'; cases.append(oversized_coeff)
        for case in cases:
            assert subprocess.run([harness,*case],capture_output=True).returncode!=0
PYCODE
}
independent_entropy_streams_match_swift_bytes() {
  bash "$REFERENCE/entropy-stream-crosscheck.sh"
}
for check in version_reports_pin_and_neon pin_check_clean_after_build semantic_writer_matches_golden stage_dump_roundtrip stages_reproduce_committed_fixtures semantic_fixtures_reproduce actual_entropy_prefix_streams actual_entropy_jpeg_reference stage2_fixtures_reproduce dump_rejects_non_codestream entropy_rejects_unsafe_histogram_config entropy_context_map_decisions_match_fixtures entropy_tree_decisions_match_fixtures entropy_modular_decisions_match_fixtures entropy_modular_rejects_unsafe_inputs entropy_ac_tokens_match_fixtures independent_entropy_streams_match_swift_bytes; do
  "$check"
  echo "PASS $check"
done
bash "$HERE/test-jpeg.sh"
