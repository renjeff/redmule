#!/usr/bin/env python3
"""Check which X matrix values the engine actually receives at each pass."""
import sys, re, os
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'golden-model', 'MX'))
from mx_fp_golden import mxfp8_decode_bits, encode_block_fp16_to_mx

def parse_c_header_array(fn):
    with open(fn) as f:
        return [int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]+', f.read())]

def fp16_to_float(bits):
    return float(np.array([bits], dtype=np.uint16).view(np.float16)[0])

def encode_decode_mx(fp16_vals, bs=32):
    result = []
    for b in range(0, len(fp16_vals), bs):
        block = fp16_vals[b:b+bs]
        if len(block) < bs:
            block += [0] * (bs - len(block))
        exp, fp8_vals = encode_block_fp16_to_mx(block)
        for fp8 in fp8_vals:
            result.append(mxfp8_decode_bits(fp8, exp))
    return result

M, N, K = 96, 96, 96
ARRAY_WIDTH = 32
ARRAY_HEIGHT = 32
MX_BLOCK = 32

x_fp16 = parse_c_header_array('sw/inc/x_input.h')
x_q = encode_decode_mx(x_fp16, MX_BLOCK)

# X_q[m][n] = x_q[m*N + n] for m=0..95, n=0..95

# Read engine X inputs
x_lines = []
with open('target/sim/vsim/engine_x_inputs.txt') as f:
    for line in f:
        vals = [int(x, 16) for x in line.strip().split()]
        x_lines.append(vals)

# x_lines[i][w*32+h] = x_buffer_q[w][h] = engine x_input_i[w][h]

# The engine has 704 X lines. With 32 h_shifts per x_shift_cnt pass:
# Pass 0: lines 0-31 (first 32 h_shifts)
# Pass 1: lines 32-63 (second 32 h_shifts, buf_r_addr flipped)
# Pass 2: lines 64-95 (after x_buffer reload, new N-tile)
# etc.

# For a fully-populated line (after warmup, ~line 31):
# x_buffer_q[w][h] should correspond to X_q[m_tile*32 + w, n_offset + h]
# The question is: what is n_offset for each pass?

# Check at the END of each pass (line 31, 63, 95, ...) when all ports are updated
def check_x_line(line_idx, expected_m_start):
    """Check which N-indices the X data at this line corresponds to."""
    vals = x_lines[line_idx]
    n_mapping = {}  # w -> list of (h, n_match)

    for w in range(min(4, ARRAY_WIDTH)):  # Check first 4 rows
        m = expected_m_start + w
        matches = []
        for h in range(ARRAY_HEIGHT):
            v = vals[w * 32 + h]
            if v == 0:
                matches.append((h, 'zero'))
                continue
            # Find which n gives this value
            found = [n for n in range(N) if x_q[m*N + n] == v]
            if len(found) == 1:
                matches.append((h, found[0]))
            elif len(found) > 1:
                matches.append((h, f'ambig:{found[:5]}'))
            else:
                matches.append((h, 'nomatch'))
        n_mapping[w] = matches
    return n_mapping

# Check key lines
for pass_idx in range(min(22, len(x_lines) // 32)):
    line_idx = min(pass_idx * 32 + 31, len(x_lines) - 1)  # Last line of pass
    nz = sum(1 for v in x_lines[line_idx] if v != 0)
    if nz < 900:
        continue  # Skip warmup

    mapping = check_x_line(line_idx, 0)  # M-tile 0
    # Extract the most likely n_offset from row w=0
    n_vals = []
    for h, nv in mapping[0]:
        if isinstance(nv, int):
            n_vals.append((h, nv))

    if n_vals:
        # Check if n = h + offset for all unique matches
        offsets = [nv - h for h, nv in n_vals]
        if len(set(offsets)) <= 2:
            offset = offsets[0] if offsets else '?'
            print(f"Pass {pass_idx} (line {line_idx}): n_offset = {offset} (verified on {len(n_vals)}/{ARRAY_HEIGHT} values)")
        else:
            print(f"Pass {pass_idx} (line {line_idx}): mixed offsets: {offsets[:8]}...")
    else:
        print(f"Pass {pass_idx} (line {line_idx}): no unique matches found")

# Also check: for pass 0 and pass 1, are the n_offsets different?
# Pass 0 (lines 0-31, buf_r_addr=0): expect n_offset=0 (N-tile 0, page 0)
# Pass 1 (lines 32-63, buf_r_addr=1): expect n_offset=32 (N-tile 0, page 1)
# Pass 2 (lines 64-95, after reload): expect n_offset=64 (N-tile 1, page 0)

print("\n--- Detailed n-index check for row w=0, passes 0-6 ---")
for pass_idx in range(min(7, len(x_lines) // 32)):
    line_idx = pass_idx * 32 + 31  # Last line of pass
    if line_idx >= len(x_lines):
        break
    nz = sum(1 for v in x_lines[line_idx] if v != 0)
    if nz < 512:
        print(f"  Pass {pass_idx} (line {line_idx}): only {nz}/1024 non-zero, skipping")
        continue

    vals = x_lines[line_idx]
    m = 0  # Row w=0
    h_to_n = []
    for h in range(32):
        v = vals[m * 32 + h]
        if v == 0:
            h_to_n.append('Z')
            continue
        found = [n for n in range(N) if x_q[m*N + n] == v]
        if len(found) == 1:
            h_to_n.append(str(found[0]))
        elif len(found) == 0:
            h_to_n.append('?')
        else:
            h_to_n.append(f'{found[0]}+')

    print(f"  Pass {pass_idx} (line {line_idx}): h→n = [{', '.join(h_to_n[:16])}...]")

# For pass boundaries, check if the x_buffer data changes correctly
print("\n--- x_buffer page transition at pass boundaries ---")
for boundary in [31, 63, 95, 127, 159, 191]:
    if boundary + 1 >= len(x_lines):
        break
    # Count how many values change between consecutive lines
    diff = sum(1 for w in range(32) for h in range(32)
               if x_lines[boundary][w*32+h] != x_lines[boundary+1][w*32+h])
    # Also check: does the data at line boundary+1 start matching a new n_offset?
    vals_before = x_lines[boundary]
    vals_after = x_lines[boundary+1]

    # Check row 0 to see what n-indices appear
    n_before = None
    n_after = None
    v = vals_before[0]  # w=0, h=0
    if v != 0:
        found = [n for n in range(N) if x_q[0*N + n] == v]
        n_before = found[:3] if found else '?'
    v = vals_after[0]  # w=0, h=0
    if v != 0:
        found = [n for n in range(N) if x_q[0*N + n] == v]
        n_after = found[:3] if found else '?'

    print(f"  Line {boundary}→{boundary+1}: {diff}/1024 changed, w=0,h=0: n={n_before}→{n_after}")
