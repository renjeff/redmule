#!/usr/bin/env python3
"""Generate the expected FP16 Z values from MX-decoded X/W inputs.
This is what the RTL engine should compute (with MX quantization effects)."""
import sys, re, os
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'golden-model', 'MX'))
from mx_fp_golden import mxfp8_decode_bits, encode_block_fp16_to_mx

def parse_c_header_array(filename):
    with open(filename, 'r') as f:
        text = f.read()
    return [int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]+', text)]

def fp16_to_float(bits):
    return float(np.array([bits], dtype=np.uint16).view(np.float16)[0])

def float_to_fp16(val):
    return int(np.array([val], dtype=np.float16).view(np.uint16)[0])

# Load original FP16 inputs
x_fp16_orig = parse_c_header_array('sw/inc/x_input.h')
w_fp16_orig = parse_c_header_array('sw/inc/w_input.h')
y_fp16 = parse_c_header_array('sw/inc/y_input.h')

M, N, K = 96, 96, 96
print(f"GEMM: Z[{M}x{K}] = X[{M}x{N}] x W[{N}x{K}] + Y[{M}x{K}]")
print(f"X: {len(x_fp16_orig)} values, W: {len(w_fp16_orig)} values, Y: {len(y_fp16)} values")

# Encode X and W to MX, then decode back (simulating MX quantization)
block_size = 32

def encode_decode_mx(fp16_vals, bs=32):
    """Encode to MX then decode back, returning quantized FP16 values."""
    result = []
    for b in range(0, len(fp16_vals), bs):
        block = fp16_vals[b:b+bs]
        if len(block) < bs:
            block += [0] * (bs - len(block))
        exp, fp8_vals = encode_block_fp16_to_mx(block)
        for fp8 in fp8_vals:
            result.append(mxfp8_decode_bits(fp8, exp))
    return result

x_quantized = encode_decode_mx(x_fp16_orig, block_size)
w_quantized = encode_decode_mx(w_fp16_orig, block_size)

print(f"X quantized: {len(x_quantized)} FP16 values")
print(f"W quantized: {len(w_quantized)} FP16 values")

# Compute GEMM from quantized inputs
X = np.array([fp16_to_float(b) for b in x_quantized[:M*N]], dtype=np.float16).reshape(M, N)
W = np.array([fp16_to_float(b) for b in w_quantized[:N*K]], dtype=np.float16).reshape(N, K)
Y = np.array([fp16_to_float(b) for b in y_fp16[:M*K]], dtype=np.float16).reshape(M, K)

# Simple GEMM (not bit-true FMA, but close enough for comparison)
Z = np.zeros((M, K), dtype=np.float64)
for m in range(M):
    for k in range(K):
        acc = float(Y[m, k])
        for n in range(N):
            acc = float(np.float16(float(np.float16(X[m, n]) * np.float16(W[n, k])) + np.float16(acc)))
        Z[m, k] = acc

Z_fp16 = Z.astype(np.float16)
z_bits = [int(arr) for arr in Z_fp16.flatten().view(np.uint16)]
print(f"Z reference: {len(z_bits)} FP16 values")

# Now read RTL encoder inputs
def read_encoder_fp16_inputs(filename):
    values = []
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            for i in range(0, len(line), 4):
                if i + 4 <= len(line):
                    values.append(int(line[i:i+4], 16))
    return values

rtl_fp16 = read_encoder_fp16_inputs('target/sim/vsim/mx_encoder_fp16_inputs.txt')
print(f"RTL encoder inputs: {len(rtl_fp16)} FP16 values")

# Compare
print(f"\nFirst 32 values: ref (MX-quantized GEMM) vs RTL")
match_count = 0
for i in range(min(32, len(z_bits), len(rtl_fp16))):
    g = z_bits[i]
    r = rtl_fp16[i]
    gf = fp16_to_float(g)
    rf = fp16_to_float(r)
    diff = abs(gf - rf)
    close = diff < 0.5 * max(abs(gf), abs(rf), 0.01)
    mark = "≈" if close else "✗"
    if g == r:
        mark = "✓"
        match_count += 1
    print(f"  [{i:3d}] ref=0x{g:04x}({gf:8.3f}) rtl=0x{r:04x}({rf:8.3f}) diff={diff:.3f} {mark}")

# Summary
total = min(len(z_bits), len(rtl_fp16), M*K)
exact_match = sum(1 for i in range(total) if z_bits[i] == rtl_fp16[i])
close_match = sum(1 for i in range(total) if abs(fp16_to_float(z_bits[i]) - fp16_to_float(rtl_fp16[i])) < 1.0)
print(f"\nExact matches: {exact_match}/{total}")
print(f"Close matches (diff < 1.0): {close_match}/{total}")

# Check if RTL values match with an offset or permutation
# Try: is RTL[i] == ref[j] for some j?
ref_set = set(z_bits[:total])
rtl_in_ref = sum(1 for i in range(min(total, len(rtl_fp16))) if rtl_fp16[i] in ref_set)
print(f"RTL values found in reference set: {rtl_in_ref}/{total}")
