#!/usr/bin/env python3
"""Compare MX encoder FP16 inputs (from RTL sim) with golden FP16 Z output."""
import sys, re, os, struct
import numpy as np

def parse_c_header_array(filename):
    with open(filename, 'r') as f:
        text = f.read()
    return [int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]+', text)]

def fp16_to_float(bits):
    return float(np.array([bits], dtype=np.uint16).view(np.float16)[0])

def read_encoder_fp16_inputs(filename):
    """Read the RTL encoder FP16 input dump (hex string per line, 4 hex chars per FP16)."""
    values = []
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            # Each line is a hex string: groups of 4 hex chars = one FP16 value
            for i in range(0, len(line), 4):
                if i + 4 <= len(line):
                    values.append(int(line[i:i+4], 16))
    return values

# Load golden Z FP16 output
z_golden_fp16 = parse_c_header_array('sw/inc/z_output.h')
print(f"Golden Z FP16: {len(z_golden_fp16)} values")

# Load golden MX Z (decode from MX format)
sys.path.insert(0, 'golden-model/MX')
from mx_fp_golden import mxfp8_decode_bits
golden_mx_data = parse_c_header_array('sw/inc/golden_mx.h')
golden_mx_exp = parse_c_header_array('sw/inc/golden_mx_exp.h')

# Unpack golden MX
golden_fp8 = []
for word in golden_mx_data:
    for b in range(4):
        golden_fp8.append((word >> (b*8)) & 0xFF)

golden_exp = []
for word in golden_mx_exp:
    for b in range(4):
        golden_exp.append((word >> (b*8)) & 0xFF)

print(f"Golden MX: {len(golden_fp8)} FP8 values, {len(golden_exp)} exponents")

# Decode golden MX to FP16 for reference
golden_mx_fp16 = []
for i, fp8 in enumerate(golden_fp8):
    block_idx = i // 32
    exp = golden_exp[block_idx] if block_idx < len(golden_exp) else 0x7F
    golden_mx_fp16.append(mxfp8_decode_bits(fp8, exp))

# Load RTL encoder FP16 inputs
encoder_fp16 = read_encoder_fp16_inputs('target/sim/vsim/mx_encoder_fp16_inputs.txt')
print(f"RTL encoder FP16 inputs: {len(encoder_fp16)} values")

# Compare
M, K = 96, 96
total = M * K
print(f"\nExpected Z size: {M}x{K} = {total} values")

# Compare first tile
num_compare = min(len(encoder_fp16), total, 64)
print(f"\nFirst {num_compare} values comparison (golden FP16 vs RTL encoder input):")
mismatches = 0
for i in range(num_compare):
    g = z_golden_fp16[i] if i < len(z_golden_fp16) else 0
    r = encoder_fp16[i] if i < len(encoder_fp16) else 0
    gf = fp16_to_float(g)
    rf = fp16_to_float(r)
    match = "✓" if g == r else "✗"
    if g != r:
        mismatches += 1
    if i < 32 or g != r:
        print(f"  [{i:4d}] golden=0x{g:04x}({gf:10.4f}) rtl=0x{r:04x}({rf:10.4f}) {match}")

# Count total mismatches for all available values
total_mismatches = 0
for i in range(min(len(encoder_fp16), total)):
    g = z_golden_fp16[i] if i < len(z_golden_fp16) else 0
    r = encoder_fp16[i]
    if g != r:
        total_mismatches += 1

print(f"\nTotal FP16 mismatches (vs golden z_output.h): {total_mismatches}/{min(len(encoder_fp16), total)}")

# Also compare with MX-decoded golden (golden_mx decoded back to FP16)
# This shows the expected values AFTER MX quantization
mx_mismatches = 0
for i in range(min(len(encoder_fp16), len(golden_mx_fp16))):
    if encoder_fp16[i] != golden_mx_fp16[i]:
        mx_mismatches += 1

print(f"Total FP16 mismatches (vs MX-decoded golden): {mx_mismatches}/{min(len(encoder_fp16), len(golden_mx_fp16))}")
