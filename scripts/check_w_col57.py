#!/usr/bin/env python3
"""Check W decoded FP16 values at column 57 for all rows."""
import sys, os, re
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'golden-model', 'MX'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'golden-model', 'common'))
from mx_fp_golden import mxfp8_decode_bits

def parse_c_header_array(filename):
    with open(filename, 'r') as f:
        text = f.read()
    values = re.findall(r'0x[0-9a-fA-F]+', text)
    return [int(x, 16) for x in values]

def unpack_fp8_from_16bit(packed_values):
    fp8_values = []
    for word in packed_values:
        low_fp8 = word & 0xFF
        high_fp8 = (word >> 8) & 0xFF
        fp8_values.append(low_fp8)
        fp8_values.append(high_fp8)
    return fp8_values

def unpack_exponents_32bit(packed_words):
    exponents = []
    for word in packed_words:
        exp = word & 0xFF
        exponents.append(exp)
    return exponents

N = 64
K = 64
BLOCK_SIZE = 32

w_packed = parse_c_header_array('sw/inc/w_input_mx.h')
w_fp8 = unpack_fp8_from_16bit(w_packed)
w_exp_packed = parse_c_header_array('sw/inc/w_exp_mx.h')
w_exp = unpack_exponents_32bit(w_exp_packed)

print(f"W FP8: {len(w_fp8)} values, W exponents: {len(w_exp)} values")
print(f"Expected: {N*K} FP8 values, {N*K//BLOCK_SIZE} exponents")

# Decode all W to FP16
w_fp16 = []
num_blocks = (len(w_fp8) + BLOCK_SIZE - 1) // BLOCK_SIZE
for block_idx in range(num_blocks):
    exp = w_exp[block_idx] if block_idx < len(w_exp) else 0x7F
    for lane in range(BLOCK_SIZE):
        idx = block_idx * BLOCK_SIZE + lane
        if idx < len(w_fp8):
            fp8 = w_fp8[idx]
            fp16 = mxfp8_decode_bits(fp8, exp)
            w_fp16.append(fp16)

# Reshape to N×K
W = np.array(w_fp16[:N*K], dtype=np.uint16).reshape(N, K)

print(f"\n=== W column 57 (all N rows) ===")
print(f"{'Row':>4s}  {'FP16_hex':>8s}  {'Value':>10s}  {'Block':>5s}  {'Exp':>4s}  {'FP8':>4s}")
for n in range(N):
    val_bits = int(W[n, 57])
    val_float = float(np.array([val_bits], dtype=np.uint16).view(np.float16)[0])
    block_idx = n * (K // BLOCK_SIZE) + 57 // BLOCK_SIZE  # block for W[n,57]
    exp_val = w_exp[block_idx] if block_idx < len(w_exp) else 0
    fp8_idx = n * K + 57
    fp8_val = w_fp8[fp8_idx] if fp8_idx < len(w_fp8) else 0
    print(f"{n:4d}  0x{val_bits:04x}  {val_float:10.4f}  {block_idx:5d}  0x{exp_val:02x}  0x{fp8_val:02x}")

# Also print a few other columns for comparison
for col in [0, 25, 31, 32, 56, 58, 63]:
    vals = [int(W[0, col]) for _ in range(1)]
    val_bits = int(W[0, col])
    val_float = float(np.array([val_bits], dtype=np.uint16).view(np.float16)[0])
    print(f"\nW[0, {col}] = 0x{val_bits:04x} = {val_float:.4f}")

# Print expected packed 1024-bit beat for first W row load
# First W FIFO entry: 64 FP16 values for W row 0 (one complete row)
print(f"\n=== Expected W buffer data for row 0 (64 FP16 values) ===")
row0 = W[0, :]
for i in range(0, 64, 8):
    vals = [f"0x{int(row0[j]):04x}" for j in range(i, min(i+8, 64))]
    print(f"  [{i:2d}-{min(i+7,63):2d}]: {', '.join(vals)}")

# Check if any exponents differ for blocks in column 57's range
print(f"\n=== Exponents for all blocks containing K=57 ===")
for n in range(N):
    block_idx = n * (K // BLOCK_SIZE) + 57 // BLOCK_SIZE
    exp_val = w_exp[block_idx]
    if exp_val != 0x77:
        print(f"  W row {n}: block {block_idx}, exp=0x{exp_val:02x} (DIFFERENT from 0x77)")
