#!/usr/bin/env python3
"""Check golden FP16 values at column 57 to see if they're at FP8 quantization boundaries."""
import sys, os, re
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'golden-model', 'MX'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'golden-model', 'common'))
from mx_fp_golden import encode_block_fp16_to_mx, mxfp8_decode_bits, compute_shared_exp_from_block

def parse_c_header_array(filename):
    with open(filename, 'r') as f:
        text = f.read()
    values = re.findall(r'0x[0-9a-fA-F]+', text)
    return [int(x, 16) for x in values]

def fp16_to_float(bits):
    return float(np.array([bits], dtype=np.uint16).view(np.float16)[0])

def float_to_fp16(val):
    return int(np.array([val], dtype=np.float16).view(np.uint16)[0])

# Load golden FP16 tiled output
golden_fp16_file = 'sw/inc/golden_z_fp16_tiled.txt'
fp16_vals = []
with open(golden_fp16_file, 'r') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        for i in range(0, len(line), 4):
            fp16_vals.append(int(line[i:i+4], 16))

print(f"Loaded {len(fp16_vals)} FP16 values from golden tiled output")

# M=96, K=64: 96 rows * 64 cols = 6144 values
M, K = 96, 64
BLOCK_SIZE = 32

# Golden is row-major (no tile reordering for K=64, tile_cols=64)
# So fp16_vals[row * K + col] = Z[row, col]

# Check column 57 values for M-tile 0 (rows 0-31)
print(f"\n=== Column 57 FP16 values for M-tile 0 (rows 0-31) ===")
print(f"{'Row':>4} {'FP16 hex':>10} {'FP16 float':>12} {'Block':>6} {'Pos':>4}")

# Collect block 1 (cols 32-63) for each row to compute shared exponent
for row in range(32):
    col = 57
    idx = row * K + col
    fp16_val = fp16_vals[idx]
    fval = fp16_to_float(fp16_val)
    # Which MX block? Row in the output has K=64 cols -> 2 blocks of 32
    block_idx = col // BLOCK_SIZE  # = 1
    pos_in_block = col % BLOCK_SIZE  # = 25
    print(f"{row:4d} 0x{fp16_val:04x} {fval:12.6f} {block_idx:6d} {pos_in_block:4d}")

# Check the MX encoding for block containing column 57
# Block 1 = cols 32-63 of each row
print(f"\n=== MX encoding for block 1 (cols 32-63) of each row ===")
print(f"{'Row':>4} {'SharedExp':>10} {'col57 FP8':>10} {'Decoded':>12} {'Original':>12} {'Match':>6}")

# Load golden MX output
golden_mx = parse_c_header_array('sw/inc/golden_mx.h')
golden_exp = parse_c_header_array('sw/inc/golden_mx_exp.h')

for row in range(32):
    # Get FP16 values for block 1 of this row
    block_fp16 = [fp16_vals[row * K + c] for c in range(32, 64)]

    # Compute shared exponent
    shared_exp, fp8_block = encode_block_fp16_to_mx(block_fp16)

    # Get the FP8 value at position 25 (col 57 - 32)
    fp8_val = fp8_block[25]

    # Decode back
    decoded_fp16 = mxfp8_decode_bits(fp8_val, shared_exp)
    original_fp16 = fp16_vals[row * K + 57]

    orig_float = fp16_to_float(original_fp16)
    decoded_float = fp16_to_float(decoded_fp16)

    match = "OK" if decoded_fp16 == original_fp16 else f"DIFF({decoded_float:.6f})"

    print(f"{row:4d} 0x{shared_exp:02x} 0x{fp8_val:02x} {decoded_float:12.6f} {orig_float:12.6f} {match}")

# Now check what the golden_mx.h actually has at column 57
print(f"\n=== Golden MX header values at column 57 ===")
print(f"{'Row':>4} {'Word idx':>10} {'Byte pos':>10} {'Golden FP8':>12} {'Computed FP8':>14} {'Match':>6}")

for row in range(32):
    # Each row has 64 FP8 bytes = 16 words of 4 bytes
    # Column 57 = word 14, byte 1
    word_idx = row * 16 + 14  # 16 words per row
    if word_idx >= len(golden_mx):
        print(f"  word_idx {word_idx} out of range")
        continue
    word = golden_mx[word_idx]
    byte_val = (word >> 8) & 0xFF  # byte 1

    # Compute expected FP8
    block_fp16 = [fp16_vals[row * K + c] for c in range(32, 64)]
    shared_exp, fp8_block = encode_block_fp16_to_mx(block_fp16)
    expected_fp8 = fp8_block[25]

    match = "OK" if byte_val == expected_fp8 else f"DIFF"
    print(f"{row:4d} {word_idx:10d} {'byte1':>10} 0x{byte_val:02x} 0x{expected_fp8:02x} {match:>14}")

# Check sensitivity: try ±1 ULP in FP16 at col 57
print(f"\n=== FP16 ±1 ULP sensitivity at column 57 ===")
print(f"{'Row':>4} {'FP16':>8} {'FP8(orig)':>10} {'FP8(-1ulp)':>12} {'FP8(+1ulp)':>12} {'Sensitive':>10}")

for row in range(32):
    block_fp16 = [fp16_vals[row * K + c] for c in range(32, 64)]
    shared_exp, fp8_orig = encode_block_fp16_to_mx(block_fp16)
    fp8_at_25 = fp8_orig[25]

    # Try ±1 ULP at position 25 (col 57)
    orig_fp16 = block_fp16[25]

    # -1 ULP
    block_m1 = list(block_fp16)
    block_m1[25] = max(0, orig_fp16 - 1)
    shared_exp_m1, fp8_m1 = encode_block_fp16_to_mx(block_m1)
    fp8_m1_at25 = fp8_m1[25]

    # +1 ULP
    block_p1 = list(block_fp16)
    block_p1[25] = min(0x7BFF, orig_fp16 + 1)
    shared_exp_p1, fp8_p1 = encode_block_fp16_to_mx(block_p1)
    fp8_p1_at25 = fp8_p1[25]

    sensitive = "YES" if fp8_m1_at25 != fp8_at_25 or fp8_p1_at25 != fp8_at_25 else "no"
    print(f"{row:4d} 0x{orig_fp16:04x} 0x{fp8_at_25:02x} 0x{fp8_m1_at25:02x} 0x{fp8_p1_at25:02x} {sensitive:>10}")
