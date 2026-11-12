#!/usr/bin/env python3
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

harness, params_path, output_dir = map(Path, sys.argv[1:4])
params = {}
for line in params_path.read_text().splitlines()[1:]:
    parts = line.split()
    params[parts[0]] = parts[3:]
input_bits = [int(value) for value in params['distance_params.inputs']]
output_dir.mkdir(parents=True, exist_ok=True)
ppm = output_dir / 'dc_boundary.ppm'
ppm.write_bytes(b'P6\n32 32\n255\n' + bytes((x * 31 + y * 17 + c * 53) % 256 for y in range(32) for x in range(32) for c in range(3)))
channels = [[], [], []]
block_counts = []
with tempfile.TemporaryDirectory(prefix='jxl-dc-boundaries-') as temp:
    temp = Path(temp)
    for index, bits in enumerate(input_bits):
        distance = struct.unpack('<f', struct.pack('<I', bits))[0]
        codestream, ac, dc, stages = [temp / f'{index}-{suffix}' for suffix in ('jxl', 'ac.bin', 'dc.bin', 'stages.sem')]
        subprocess.run([str(harness), 'encode', str(ppm), format(distance, '.9g'), str(codestream)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([str(harness), 'pixel-stages', str(ppm), str(codestream), str(ac), str(dc), str(stages), format(distance, '.9g')], check=True, stdout=subprocess.DEVNULL)
        values = struct.unpack('<' + 'i' * (len(dc.read_bytes()) // 4), dc.read_bytes())
        block_count = len(values) // 3
        block_counts.append(block_count)
        for channel in range(3):
            channels[channel].extend(values[channel * block_count:(channel + 1) * block_count])

lines = ['jxl-semantic-dump 1']
def emit(name, values):
    lines.append(f'{name} i {len(values)} ' + ' '.join(map(str, values)))
emit('dc_boundary.inputs', input_bits)
emit('dc_boundary.blocks_per_distance', block_counts)
emit('dc_boundary.neon_target', [1])
for channel, values in enumerate(channels):
    emit(f'dc_boundary.c{channel}', values)
(output_dir / 'dc_boundary.sem').write_text('\n'.join(lines) + '\n')
