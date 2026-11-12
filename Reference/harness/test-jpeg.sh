#!/usr/bin/env bash
set -euo pipefail

jpeg_fixtures_reproduce() {
  local out="$SCRATCH/reproduced"
  bash "$REFERENCE/make_jpeg_semantic_fixtures.sh" "$out"
  local names='jpeg_hopper_gray_odd jpeg_hopper_420_restart jpeg_hopper_420_odd jpeg_hopper_420_sof1 jpeg_small_422 jpeg_small_440 jpeg_small_444 jpeg_flat_444 jpeg_flower_513x267_422 jpeg_flower_513x267_440 jpeg_flower_513x267_420'
  for name in $names; do
    cmp "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/semantic/$name.sem" "$out/$name.sem"
  done
  for name in jpeg_flat_444 jpeg_flower_513x267_440 jpeg_flower_513x267_420; do
    cmp "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/semantic/$name.jpg" "$out/$name.jpg"
  done
  python3 - "$REFERENCE/provenance.tsv" "$REFERENCE/.." <<'PYCODE'
import csv,hashlib,sys
from pathlib import Path
manifest=Path(sys.argv[1]); root=Path(sys.argv[2])
rows={row[0]:row for row in csv.reader(manifest.open(),delimiter='\t') if row and not row[0].startswith('#')}
pins={}
for line in (root/'Reference/libjxl.pin').read_text().splitlines():
 if '=' in line and not line.lstrip().startswith('#'):
  key,value=line.split('=',1); pins[key]=value.strip().strip('"\'')
expected={'jpeg_hopper_gray_odd','jpeg_hopper_420_restart','jpeg_hopper_420_odd','jpeg_hopper_420_sof1','jpeg_small_422','jpeg_small_440','jpeg_small_444','jpeg_flat_444','jpeg_flower_513x267_422','jpeg_flower_513x267_440','jpeg_flower_513x267_420'}
for name in expected:
 row=rows[f'Tests/JXLEncoderTests/Fixtures/semantic/{name}.sem']
 assert row[3]=='full-libjxl' and row[7]==f"libjxl {pins['LIBJXL_COMMIT']}", name
 assert all(part in row[8] for part in ('JxlEncoderAddJPEGFrame','effort=4','store_jpeg_metadata=1','threads=1','cjxl -j 1 --num_threads=1 --effort=4','hwy=NEON')), name
 assert hashlib.sha256((root/row[0]).read_bytes()).hexdigest()==row[2], name
 source=rows[row[6]]
 source_path=root/source[0]
 assert source[1]=='fixture' and hashlib.sha256(source_path.read_bytes()).hexdigest()==source[2], name
for name,sampling in [('jpeg_flat_444','1x1'),('jpeg_flower_513x267_440','1x2'),('jpeg_flower_513x267_420','2x2')]:
 row=rows[f'Tests/JXLEncoderTests/Fixtures/semantic/{name}.jpg']
 assert row[3]=='libjpeg-turbo' and row[7]==f"libjpeg-turbo {pins['JPEG_TURBO_VERSION']}" and f'sampling={sampling}' in row[8]
 assert hashlib.sha256((root/row[0]).read_bytes()).hexdigest()==row[2]
assert pins['JPEG_TURBO_VERSION']=='3.2.0'
PYCODE
}

jpeg_dump_supports_observed_frame_configuration() {
  local harness="$REFERENCE/build/harness/jxl-harness"
  "$harness" encode-jpeg "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/hopper_gray_odd.jpg" "$SCRATCH/gray.jxl"
  "$harness" dump "$SCRATCH/gray.jxl" frame ac_entropy context_map > "$SCRATCH/gray.sem"
  grep -Fx 'frame.encoding i 1 0' "$SCRATCH/gray.sem"
  "$harness" encode-jpeg "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/hopper_420_restart.jpg" "$SCRATCH/restart.jxl"
  "$harness" dump "$SCRATCH/restart.jxl" frame ac_entropy context_map > "$SCRATCH/restart.sem"
  python3 - "$SCRATCH/restart.jxl" "$SCRATCH" <<'PYCODE'
import sys
from pathlib import Path
root=Path(sys.argv[2]); data=Path(sys.argv[1]).read_bytes()
offset=12; stream=None; pieces=[]
while offset<len(data):
 size=int.from_bytes(data[offset:offset+4],'big'); typ=data[offset+4:offset+8]; header=8
 if size==1: size=int.from_bytes(data[offset+8:offset+16],'big'); header=16
 elif size==0: size=len(data)-offset
 assert size>=header
 if typ==b'jxlc': stream=data[offset+header:offset+size]
 if typ==b'jxlp':
  payload=data[offset+header:offset+size]; pieces.append((int.from_bytes(payload[:4],'big'),payload[4:]))
 offset+=size
if stream is None:
 pieces.sort(key=lambda item:item[0]&0x7fffffff)
 assert all((index&0x7fffffff)==i for i,(index,_) in enumerate(pieces))
 assert pieces[-1][0]&0x80000000
 stream=b''.join(part for _,part in pieces)
assert stream and stream[:2]==b'\xff\x0a'
def box(kind,payload,mode):
 if mode=='zero': return b'\0\0\0\0'+kind+payload
 if mode=='extended': return b'\0\0\0\1'+kind+(16+len(payload)).to_bytes(8,'big')+payload
 return (8+len(payload)).to_bytes(4,'big')+kind+payload
signature=b'\0\0\0\x0cJXL \r\n\x87\n'
ftyp=box(b'ftyp',b'jxl \0\0\0\0jxl ','short')
parts=(stream[:23],stream[23:101],stream[101:])
outputs={'short':signature+ftyp+box(b'jxlc',stream,'short'),
 'extended':signature+ftyp+box(b'jxlc',stream,'extended'),
 'zero':signature+ftyp+box(b'jxlc',stream,'zero'),
 'fragments':signature+ftyp+box(b'jxlp',(0).to_bytes(4,'big')+parts[0],'short')+box(b'jxlp',(1).to_bytes(4,'big')+parts[1],'short')+box(b'jxlp',(0x80000002).to_bytes(4,'big')+parts[2],'short'),
 'truncated':signature+ftyp+box(b'jxlc',stream,'short')[:-1],
 'conflict':signature+ftyp+box(b'jxlc',stream,'short')+box(b'jxlp',(0x80000000).to_bytes(4,'big')+stream,'short'),
 'missing-final':signature+ftyp+box(b'jxlp',(0).to_bytes(4,'big')+stream[:23],'short')+box(b'jxlp',(1).to_bytes(4,'big')+stream[23:],'short'),
 'out-of-order':signature+ftyp+box(b'jxlp',(1).to_bytes(4,'big')+parts[0],'short')+box(b'jxlp',(0).to_bytes(4,'big')+parts[1],'short')+box(b'jxlp',(0x80000002).to_bytes(4,'big')+parts[2],'short'),
 'short-jxlp':signature+ftyp+box(b'jxlp',b'\0\0\0','short'),
 'empty-jxlp':signature+ftyp+box(b'jxlp',(0x80000000).to_bytes(4,'big'),'short'),
 'extended-short':signature+ftyp+b'\0\0\0\1jxlc\0\0\0\0\0\0\0\x0c',
 'extended-truncated':signature+ftyp+b'\0\0\0\1jxlc\0\0\0\0',
 'missing-ftyp':signature+box(b'jxlc',stream,'short')}
for name,value in outputs.items(): (root/f'{name}.jxl').write_bytes(value)
PYCODE
  for wrapper in short extended zero fragments; do
    "$harness" dump "$SCRATCH/$wrapper.jxl" frame ac_entropy context_map > "$SCRATCH/$wrapper.sem"
    cmp "$SCRATCH/restart.sem" "$SCRATCH/$wrapper.sem"
  done
  for wrapper in truncated conflict missing-final out-of-order short-jxlp empty-jxlp extended-short extended-truncated missing-ftyp; do
    if "$harness" dump "$SCRATCH/$wrapper.jxl"; then return 1; fi
  done
  if "$harness" encode-jpeg "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/small_411.jpg" "$SCRATCH/411.jxl"; then return 1; fi
}

jpeg_encode_rejects_invalid_input() {
  local harness="$REFERENCE/build/harness/jxl-harness"
  : > "$SCRATCH/empty.jpg"
  printf 'not jpeg' > "$SCRATCH/non-jpeg.jpg"
  head -c 80 "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/hopper_420_restart.jpg" > "$SCRATCH/truncated.jpg"
  for input in "$SCRATCH/empty.jpg" "$SCRATCH/non-jpeg.jpg" "$SCRATCH/truncated.jpg"; do
    if "$harness" encode-jpeg "$input" "$SCRATCH/should-not-exist.jxl"; then return 1; fi
    test ! -s "$SCRATCH/should-not-exist.jxl"
  done
  if "$harness" encode-jpeg "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/hopper_420_restart.jpg" "$SCRATCH/missing/never.jxl"; then return 1; fi
  test ! -e "$SCRATCH/missing/never.jxl"
  if (ulimit -f 1; "$harness" encode-jpeg "$REFERENCE/../Tests/JXLEncoderTests/Fixtures/hopper_420_restart.jpg" "$SCRATCH/write-failure.jxl") >/dev/null 2>&1; then
    return 1
  fi
  test ! -e "$SCRATCH/write-failure.jxl"
}

REFERENCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
for test in jpeg_fixtures_reproduce jpeg_dump_supports_observed_frame_configuration jpeg_encode_rejects_invalid_input; do
  "$test"
  echo "PASS $test"
done
