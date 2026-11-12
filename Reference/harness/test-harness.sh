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
for check in version_reports_pin_and_neon pin_check_clean_after_build semantic_writer_matches_golden stage_dump_roundtrip stages_reproduce_committed_fixtures semantic_fixtures_reproduce actual_entropy_prefix_streams actual_entropy_jpeg_reference stage2_fixtures_reproduce dump_rejects_non_codestream entropy_rejects_unsafe_histogram_config entropy_context_map_decisions_match_fixtures; do
  "$check"
  echo "PASS $check"
done
bash "$HERE/test-jpeg.sh"
