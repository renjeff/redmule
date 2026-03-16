#!/usr/bin/env python3
"""Compare Z buffer drain output with expected GEMM result from MX-decoded inputs."""
import sys, re, os
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'golden-model', 'MX'))
from mx_fp_golden import mxfp8_decode_bits, encode_block_fp16_to_mx

def parse_c_header_array(fn):
    with open(fn) as f:
        return [int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]+', f.read())]

def fp16_to_float(bits):
    return float(np.array([bits], dtype=np.uint16).view(np.float16)[0])

def float_to_fp16_bits(val):
    return int(np.array([val], dtype=np.float16).view(np.uint16)[0])

# Parameters
M, N, K = 96, 96, 96
MX_BLOCK = 32
TILE = 64
ARRAY_WIDTH = 32
ARRAY_HEIGHT = 32

# Load and MX-quantize inputs
x_fp16 = parse_c_header_array('sw/inc/x_input.h')
w_fp16 = parse_c_header_array('sw/inc/w_input.h')
y_fp16 = parse_c_header_array('sw/inc/y_input.h')

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

x_q = encode_decode_mx(x_fp16, MX_BLOCK)
w_q = encode_decode_mx(w_fp16, MX_BLOCK)

# Build matrices
X = np.array([fp16_to_float(b) for b in x_q[:M*N]], dtype=np.float64).reshape(M, N)
W = np.array([fp16_to_float(b) for b in w_q[:N*K]], dtype=np.float64).reshape(N, K)
Y = np.array([fp16_to_float(b) for b in y_fp16[:M*K]], dtype=np.float64).reshape(M, K)

# Compute reference GEMM with FP16 accumulation (matching engine)
Z_ref = np.zeros((M, K), dtype=np.float64)
for m in range(M):
    for k in range(K):
        acc = float(np.float16(Y[m, k]))
        for n in range(N):
            acc = float(np.float16(float(np.float16(X[m, n]) * np.float16(W[n, k])) + np.float16(acc)))
        Z_ref[m, k] = acc
Z_ref_fp16 = Z_ref.astype(np.float16)

# Read encoder FP16 inputs (Z buffer drain output)
def read_encoder_fp16(fn):
    values = []
    with open(fn) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            for i in range(0, len(line), 4):
                if i + 4 <= len(line):
                    values.append(int(line[i:i+4], 16))
    return values

enc_fp16 = read_encoder_fp16('target/sim/vsim/mx_encoder_fp16_inputs.txt')
print(f"Encoder FP16 inputs: {len(enc_fp16)} values")

# Read z_buffer_q_stream (drain output, 32 FP16 per line)
zq_lines = []
with open('target/sim/vsim/z_buffer_q_stream.txt') as f:
    for line in f:
        vals = [int(x, 16) for x in line.strip().split()]
        zq_lines.append(vals)
print(f"Z buffer Q stream: {len(zq_lines)} lines of {len(zq_lines[0]) if zq_lines else 0} values")

# The encoder FP16 data is the Z buffer drain output after going through the FIFO.
# Each encoder beat = 64 FP16 (one Z buffer column, full depth).
# The Z buffer drain order per tile:
#   For column w (store_shift): outputs Z_buf[d=0..63][w]
#   This corresponds to Z[m_tile*32 + w, k_tile*64 + 0..63]
#   (or k_tile*64 + 0..31 for partial K-tile)

# Build expected drain sequence
expected_drain = []
for m_tile in range(M // ARRAY_WIDTH):  # 0,1,2
    for k_tile in range((K + TILE - 1) // TILE):  # 0,1
        k_start = k_tile * TILE
        k_end = min(k_start + TILE, K)
        k_len = k_end - k_start

        for w in range(ARRAY_WIDTH):  # 0..31 (z_width columns)
            m = m_tile * ARRAY_WIDTH + w
            # One column: Z[m, k_start:k_end] padded to 64
            col_vals = []
            for d in range(TILE):
                k = k_start + d
                if d < k_len and m < M:
                    col_vals.append(float_to_fp16_bits(Z_ref_fp16[m, k]))
                else:
                    col_vals.append(0)
            expected_drain.append(col_vals)

print(f"Expected drain: {len(expected_drain)} columns of 64 values = {len(expected_drain)*64} total FP16")

# Compare with encoder FP16 inputs
# The encoder data is organized as beats of 64 FP16
num_beats = len(enc_fp16) // 64
print(f"Encoder beats: {num_beats}")

# Compare first few drain columns
print(f"\n--- First 8 drain columns comparison ---")
for col_idx in range(min(8, num_beats, len(expected_drain))):
    rtl_col = enc_fp16[col_idx*64 : (col_idx+1)*64]
    exp_col = expected_drain[col_idx]

    match = sum(1 for i in range(64) if rtl_col[i] == exp_col[i])
    close = sum(1 for i in range(64) if abs(fp16_to_float(rtl_col[i]) - fp16_to_float(exp_col[i])) < 1.0)

    # Which M-tile, K-tile, column?
    m_tile = col_idx // (2 * ARRAY_WIDTH)
    remainder = col_idx % (2 * ARRAY_WIDTH)
    k_tile = remainder // ARRAY_WIDTH
    w = remainder % ARRAY_WIDTH

    print(f"  Col {col_idx} (M-tile={m_tile}, K-tile={k_tile}, w={w}): {match}/64 exact, {close}/64 close")
    if match < 60:
        # Show first few values
        for i in range(min(8, 64)):
            rf = fp16_to_float(rtl_col[i])
            ef = fp16_to_float(exp_col[i])
            mark = "✓" if rtl_col[i] == exp_col[i] else ("≈" if abs(rf-ef) < 1.0 else "✗")
            print(f"    [{i}] rtl=0x{rtl_col[i]:04x}({rf:8.3f}) exp=0x{exp_col[i]:04x}({ef:8.3f}) {mark}")

# Summary statistics
total_match = 0
total_close = 0
total_values = 0
for col_idx in range(min(num_beats, len(expected_drain))):
    rtl_col = enc_fp16[col_idx*64 : (col_idx+1)*64]
    exp_col = expected_drain[col_idx]
    k_len = 64 if (col_idx // ARRAY_WIDTH) % 2 == 0 else 32
    for i in range(k_len):
        total_values += 1
        if rtl_col[i] == exp_col[i]:
            total_match += 1
        elif abs(fp16_to_float(rtl_col[i]) - fp16_to_float(exp_col[i])) < 1.0:
            total_close += 1

print(f"\n--- Summary (first {min(num_beats, len(expected_drain))} columns) ---")
print(f"Exact matches: {total_match}/{total_values}")
print(f"Close (< 1.0): {total_close}/{total_values}")
print(f"Wrong: {total_values - total_match - total_close}/{total_values}")

# Check if Z buffer Q stream matches directly
print(f"\n--- Z buffer Q stream check (32 values per line) ---")
# Each zq_line is 32 FP16 values = first 32 of a 64-element Z buffer column
# Compare with expected drain (first 32 of each column)
match_count = 0
for i in range(min(len(zq_lines), len(expected_drain))):
    zq = zq_lines[i]
    exp = expected_drain[i][:32]
    if zq == exp:
        match_count += 1
    elif i < 4:
        for j in range(min(8, 32)):
            rf = fp16_to_float(zq[j])
            ef = fp16_to_float(exp[j])
            mark = "✓" if zq[j] == exp[j] else "✗"
            print(f"  line {i}[{j}] rtl=0x{zq[j]:04x}({rf:8.3f}) exp=0x{exp[j]:04x}({ef:8.3f}) {mark}")
print(f"Z buffer Q exact match: {match_count}/{min(len(zq_lines), len(expected_drain))}")
