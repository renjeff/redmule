#!/usr/bin/env python3
"""Verify that engine X/W inputs match expected MX-quantized data."""
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
TOT_DEPTH = 64
MX_BLOCK = 32

# Load and quantize inputs
x_fp16 = parse_c_header_array('sw/inc/x_input.h')
w_fp16 = parse_c_header_array('sw/inc/w_input.h')

x_q = encode_decode_mx(x_fp16, MX_BLOCK)
w_q = encode_decode_mx(w_fp16, MX_BLOCK)

# X is M×N row-major: X[m][n] = x_q[m*N + n]
# W is N×K row-major: W[n][k] = w_q[n*K + k]

# Read engine X inputs: 1024 values per line (32w × 32h)
x_lines = []
with open('target/sim/vsim/engine_x_inputs.txt') as f:
    for line in f:
        vals = [int(x, 16) for x in line.strip().split()]
        x_lines.append(vals)

# Read engine W inputs: 32 values per line
w_lines = []
with open('target/sim/vsim/engine_w_inputs.txt') as f:
    for line in f:
        vals = [int(x, 16) for x in line.strip().split()]
        w_lines.append(vals)

print(f"Engine X lines: {len(x_lines)} of {len(x_lines[0])} values")
print(f"Engine W lines: {len(w_lines)} of {len(w_lines[0])} values")

# Each X line has x_buffer_q[w_idx][h_idx] for w=0..31, h=0..31
# x_buffer_q[w][h] represents the current engine input for PE row w, column h
# After transposition: x_buffer_o[w][h] = x_buffer_q[h][w]
# So x_lines[i][w*32 + h] = x_buffer_q[w][h] at shift i

# Parse X line into [w][h] array
def parse_x_line(vals):
    x = np.zeros((ARRAY_WIDTH, ARRAY_HEIGHT), dtype=np.uint16)
    for w in range(ARRAY_WIDTH):
        for h in range(ARRAY_HEIGHT):
            x[w][h] = vals[w * ARRAY_HEIGHT + h]
    return x

# The x_buffer cycles through depth (h_index_r: 0→31, buf_r_addr: 0→1)
# Over 32 h_shifts, the x_buffer reads addresses:
#   h_index 0→31 with buf_r_addr 0, then h_index 0→31 with buf_r_addr 1
# Wait - h_index_r cycles 0→31 per x_shift_cnt (32 shifts). buf_r_addr flips
# when h_index_r wraps. So in one x_shift_cnt pass (32 shifts):
#   Shift 0-31: h_index 0-31, buf_r_addr=0 (or 1, alternating)
# In two passes (64 shifts):
#   Pass 0: h_index 0-31, buf_r_addr=0
#   Pass 1: h_index 0-31, buf_r_addr=1

# So the x_buffer_q[h][w] at shift i represents X[w, depth_offset(pass)*32 + h_index]
# where pass alternates 0/1 based on buf_r_addr

# For x_buffer_q[w][h]: h is the N_OUTPUTS index (0..31)
# At shift i: h_index_r = i % 32, buf_r_addr toggles every 32 shifts
# x_buffer_q[h][w] = x_buf_scm[{buf_r_addr, h_index_r}][w]
# This means h in the dump corresponds to the w dimension (width of x_buffer)
# and the 32 consecutive lines correspond to cycling through h_index_r

# Actually, the dump format is: x_buffer_q[w_idx][h_idx] (w outer, h inner)
# x_buffer_q is [H-1:0][W-1:0][BITW-1:0] from the x_buf_scm
# H=32 (N_OUTPUTS), W=32 (WIDTH)
# The dump iterates w_idx 0..31, h_idx 0..31 → vals[w*32+h]

# x_buffer_o[w][h] = x_buffer_q[h][w] (line 331)
# Engine PE (row w, col h) gets x_buffer_o[w][h] = x_buffer_q[h][w]

# So from the dump: x_buffer_q[w_idx][h_idx]
# Engine PE (row w, col h) gets x_buffer_q[h][w] = vals[h*32 + w]

# For the first x_buffer load (M-tile 0, N-tile 0):
# x_pad stores X[m, n] for m=0..31, n=0..63
# x_buf reads from x_pad and provides to engine
# After FAST_FILL: x_buf[0] = x_pad[0:32] (first 32 depth values)
# At shift h_index_r: x_buffer_q[h][w] = x_pad[n_offset + h][w]
# Wait, x_pad[col][row] = X[row, col] (since x_pad has ROWS=W=32, COLS=TOT_DEPTH=64)

# x_pad_scm: write_addr = w_index (row), wdata = x_buffer_i (64 FP16 values per row)
# So x_pad[row][col] = X data word, where row = load index (0..31 = M-tile rows)
# and col = position within the 64 values of the bus beat

# x_buf_scm reads from x_pad at address pad_read_addr (cycles through 0..63)
# x_buf_scm stores x_pad[pad_read_addr][w] for all w
# x_buf_scm[{buf_r_addr, h_index_r}][w] = x_pad[read_addr][w]

# At shift h_index_r with buf_r_addr:
# The value stored at x_buf[{buf_r_addr, h_index_r}] was loaded from x_pad[some_addr]
# during the FAST_FILL / FILL phase.

# This is getting very complex. Let me just check if the FIRST non-zero X line values
# match any expected X values.

print(f"\n--- First X line analysis ---")
x0 = parse_x_line(x_lines[0])
nonzero = sum(1 for w in range(32) for h in range(32) if x0[w][h] != 0)
print(f"Non-zero values in first X line: {nonzero}/1024")

# The first X line should contain X data for M-tile 0.
# Check if x0[w][h] values appear in the quantized X matrix for row w
print(f"\nFirst X line, first few (w=0..3, h=0..7):")
for w in range(4):
    for h in range(8):
        v = x0[w][h]
        vf = fp16_to_float(v) if v != 0 else 0.0
        # Expected: X_q[m=w, n=?] for some n in the current depth slice
        print(f"  x[{w}][{h}] = 0x{v:04x} ({vf:8.4f})", end="")
        # Search in X_q row w
        found = [n for n in range(N) if x_q[w*N + n] == v] if v != 0 else []
        if found:
            print(f" → X_q[{w},{found}]", end="")
        print()

# Check first W line
print(f"\n--- First W line analysis ---")
w0 = w_lines[0]
nonzero_w = sum(1 for h in range(32) if w0[h] != 0)
print(f"Non-zero: {nonzero_w}/32")
for h in range(min(8, 32)):
    v = w0[h]
    vf = fp16_to_float(v) if v != 0 else 0.0
    found = [(n, k) for n in range(N) for k in range(K) if w_q[n*K + k] == v] if v != 0 else []
    if found and len(found) <= 5:
        print(f"  w[{h}] = 0x{v:04x} ({vf:8.4f}) → W_q{found}")
    else:
        print(f"  w[{h}] = 0x{v:04x} ({vf:8.4f}) → {len(found)} matches")

# Key test: compute Z from engine dumps and compare with RTL Z output
# Group engine shifts into passes of 32 X lines + 64 W lines
# Within each pass: X_data is constant (same x_buffer), W shifts 64 times
# The engine computes: Z_partial[w] += sum(x_buf[h] * w_buf[h], h=0..31) per cycle

# Build Z from engine inputs using outer product accumulation
# Each W line gives w_buffer_q[h] for h=0..31
# Each X line gives x_buffer_q[w][h] for w=0..31, h=0..31
# Engine output: x_buffer_o[w][h] = x_buffer_q[h][w]
# So PE(row=w, col=h) computes: x_buffer_q[h][w] * w_buffer_q[h]
# After H PEs: row w output = sum(x_buffer_q[h][w] * w_buffer_q[h], h=0..31)

# Total output per cycle: 32 partial sums (one per row w)
# Each cycle contributes one depth element to Z[w, ...]

# Wait - I need to understand what dimension the W shift corresponds to.
# W buffer shifts through el_addr and col_addr. Over 64 shifts:
#   el_addr: 0,1,0,1,...  (alternating)
#   col_addr: 0,0,1,1,...  (advances every 2 shifts)
# W_buffer_q[h] at shift s = W_scm[row=h, col=col_addr, elm=el_addr]
# The W buffer stores D=64 elements per row, organized as C=32 cols × ELMS=2
# Element index = col_addr * 2 + el_addr

# So W shift 0: el=0, col=0 → element 0
# W shift 1: el=1, col=0 → element 1
# W shift 2: el=0, col=1 → element 2
# ...
# W shift 63: el=1, col=31 → element 63

# Each W shift outputs H=32 values (one per row in the SCM)
# W_buffer_q[h] at shift s = W[h, element_s]

# For the X buffer: each h_shift reads one "column" of the x_buf
# At h_shift i: h_index_r = i % 32
# The x_buf outputs H=32 values: x_buffer_q[h][w] for all h, w
# But only h depends on the read address; w is always all 32 outputs

# Actually the x_buf_scm has N_OUTPUTS=H=32 read ports, each reading from
# the same column (WIDTH dimension) using its own row address? No...
# Let me just check from the SCM definition.

# x_buffer_scm: WIDTH=W=32, HEIGHT=2, N_OUTPUTS=H=32
# read_addr = {buf_r_addr, h_index_r} → selects row within HEIGHT
# But HEIGHT=2 and read_addr is {1-bit, 5-bit} = 6 bits...
# Wait, HEIGHT=2 means 2 "banks" or "pages". The actual storage is WIDTH × N_OUTPUTS.
# Each "height" level stores W × H_out values.

# I think the x_buf_scm stores WIDTH=32 independent columns.
# For each column (w), there are HEIGHT=2 pages, each with N_OUTPUTS=32 values.
# Read address {buf_r_addr, h_index_r} selects which of 2*32=64 values to read for each column.
# And all 32 outputs (h=0..31) are read simultaneously.

# No wait, N_OUTPUTS=H=32 means 32 simultaneous output ports.
# read_addr selects one value per output port.
# So at any time: x_buffer_q[h][w] = scm_data[h][w][{buf_r_addr, h_index_r}]

# Actually I think the storage is [N_OUTPUTS][WIDTH] × [HEIGHT*N_OUTPUTS entries per column]
# This is a register file with 32 read ports.

# Bottom line: x_buffer_q[h][w] changes with h_shift (which changes h_index_r and buf_r_addr)
# And the dump captures it at each h_shift event.

# Let me just do an empirical check. For each X dump line, check which slice of
# the X matrix it corresponds to, based on the non-zero pattern and values.

# For the FIRST x_shift_cnt pass (X lines 0-31):
# The x_buffer is loaded with N-tile 0 data (n=0..63) for M-tile 0 (m=0..31)
# At X line i (h_index = i, buf_r_addr = 0):
# x_buffer_q[h][w] should be X[w, f(h, h_index, buf_r_addr)]

# Let me check: does x_lines[0] (first shift, h_index=0, buf_r=0) contain
# data that matches X_q[m, n=0] for m=0..31?

# x_buffer_q[w][h] from dump → x_buffer_o[w][h] = x_buffer_q[h][w]
# The dump is x_buffer_q[w][h], so the engine sees x_buffer_o[w][h] = vals[h*32+w]

# At h_index_r=0, the first read from x_buf:
# For each width w, the value should correspond to X_pad at some depth index.

# Let me check: do the values in the first X line match X_q for specific n indices?
print(f"\n--- Matching X line 0 values to X_q ---")
match_map = {}
for w in range(32):
    for h in range(32):
        v = x0[w][h]
        if v == 0:
            continue
        matches = [n for n in range(N) if x_q[w*N + n] == v]
        if matches:
            if w not in match_map:
                match_map[w] = {}
            match_map[w][h] = matches

# Show a summary: for w=0, which n indices do the h=0..31 values correspond to?
if 0 in match_map:
    print(f"Row w=0 matches:")
    for h in sorted(match_map[0].keys())[:8]:
        print(f"  h={h}: n={match_map[0][h]}")

# Now let me check what pattern emerges
# For each w, check if the non-zero h values map to consecutive n indices
print(f"\n--- X line 0: n-index pattern for first 4 rows ---")
for w in range(4):
    n_indices = []
    for h in range(32):
        v = x0[w][h]
        if v != 0:
            matches = [n for n in range(N) if x_q[w*N + n] == v]
            if len(matches) == 1:
                n_indices.append((h, matches[0]))
            elif len(matches) > 1:
                n_indices.append((h, f"ambig:{matches[:3]}"))
    print(f"  w={w}: {n_indices[:8]}...")

# Also check second X line (h_index=1)
print(f"\n--- X line 1: n-index pattern for first 2 rows ---")
x1 = parse_x_line(x_lines[1])
for w in range(2):
    n_indices = []
    for h in range(32):
        v = x1[w][h]
        if v != 0:
            matches = [n for n in range(N) if x_q[w*N + n] == v]
            if len(matches) == 1:
                n_indices.append((h, matches[0]))
            elif len(matches) > 1:
                n_indices.append((h, f"ambig:{matches[:3]}"))
    print(f"  w={w}: {n_indices[:8]}...")

# Check W line pattern
print(f"\n--- W lines: which W row does each line correspond to? ---")
# W_buffer_q[h] at shift s corresponds to W[h, element_s]
# For the first 32 W rows loaded in one pass: W[n_start+h, k_start+element_s]
# W line 0: first shift (el=0, col=0 → element 0)
# W[h, k_start+0] for h=0..31

for line_idx in [0, 1, 2, 3]:
    w_line = w_lines[line_idx]
    # Try to find which W row and element this matches
    found_any = False
    for n_start in range(0, N, 32):
        for k_offset in range(min(K, 64)):
            matches = 0
            for h in range(32):
                n = n_start + h
                if n >= N: break
                expected = w_q[n*K + k_offset]
                if w_line[h] == expected:
                    matches += 1
            if matches >= 20:  # Good enough match
                print(f"  W line {line_idx}: matches W_q[n={n_start}:{n_start+32}, k={k_offset}] ({matches}/32)")
                found_any = True
                break
        if found_any: break
    if not found_any:
        print(f"  W line {line_idx}: no good match found (first values: {[hex(v) for v in w_line[:4]]})")
