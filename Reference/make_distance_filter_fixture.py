#!/usr/bin/env python3
import struct
import subprocess
import sys
from pathlib import Path

harness, params_path, output = map(Path, sys.argv[1:4])
params = {}
for line in params_path.read_text().splitlines()[1:]:
    parts = line.split()
    params[parts[0]] = parts[3:]
input_bits = [int(value) for value in params['distance_params.inputs']]

def field(text, name):
    for line in text.splitlines()[1:]:
        parts = line.split()
        if parts[0] == name:
            return [int(v) for v in parts[3:]]
    raise RuntimeError(f'missing {name}')

scratch = output.parent / 'distance-filter-work'
scratch.mkdir(parents=True, exist_ok=True)
ppm = scratch / 'input.ppm'
ppm.write_bytes(b'P6\n8 8\n255\n' + bytes((x * 31 + y * 17 + c * 53) % 256 for y in range(8) for x in range(8) for c in range(3)))
gaborish, epf, x_scale, b_scale = [], [], [], []
for i, bits in enumerate(input_bits):
    distance = struct.unpack('<f', struct.pack('<I', bits))[0]
    text_distance = format(distance, '.9g')
    codestream = scratch / f'{i}.jxl'
    subprocess.run([str(harness), 'encode', str(ppm), text_distance, str(codestream)], check=True, stdout=subprocess.DEVNULL)
    result = subprocess.run([str(harness), 'dump', str(codestream), 'gaborish', 'epf', 'x_matrix_scale', 'b_matrix_scale'], check=True, capture_output=True, text=True).stdout
    gaborish.extend(field(result, 'gaborish.enabled'))
    epf.extend(field(result, 'epf.iterations'))
    x_scale.extend(field(result, 'x_matrix_scale.value'))
    b_scale.extend(field(result, 'b_matrix_scale.value'))

lines = ['jxl-semantic-dump 1']
def emit(name, values):
    lines.append(f'{name} i {len(values)} ' + ' '.join(map(str, values)))
emit('distance_filters.inputs', input_bits)
emit('distance_filters.gaborish_effort4', gaborish)
emit('distance_filters.epf_iterations_effort4', epf)
emit('distance_filters.x_matrix_scale_effort4', x_scale)
emit('distance_filters.b_matrix_scale_effort4', b_scale)
output.write_text('\n'.join(lines) + '\n')
