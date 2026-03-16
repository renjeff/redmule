#!/usr/bin/env python3
"""Verify MX decoded FP16 data against golden model.

Reads the decoder FP16 output dump and target labels, reconstructs X and W matrices,
then compares with the expected MX-decoded values from the golden model.
"""
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

# Parameters
M, N, K = 96, 96, 96
MX_NUM_LANES = 32
TILE = 64  # TOT_DEPTH
ARRAY_WIDTH = 32
ARRAY_HEIGHT = 32
CHUNKS_PER_KTILE = TILE // MX_NUM_LANES  # = 2

x_rows_iter = M // ARRAY_WIDTH  # 3
x_cols_iter = (N + TILE - 1) // TILE  # 2
w_cols_iter = (K + TILE - 1) // TILE  # 2

print(f"Tiling: x_rows={x_rows_iter}, x_cols={x_cols_iter}, w_cols={w_cols_iter}")
print(f"TILE={TILE}, CHUNKS_PER_KTILE={CHUNKS_PER_KTILE}")

# Load golden FP16 inputs and encode/decode through MX
x_fp16_orig = parse_c_header_array('sw/inc/x_input.h')
w_fp16_orig = parse_c_header_array('sw/inc/w_input.h')

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

x_quantized = encode_decode_mx(x_fp16_orig, MX_NUM_LANES)
w_quantized = encode_decode_mx(w_fp16_orig, MX_NUM_LANES)

print(f"X quantized: {len(x_quantized)} FP16 values")
print(f"W quantized: {len(w_quantized)} FP16 values")

# X is M×N row-major: x_quantized[m*N + n]
# W is N×K row-major: w_quantized[n*K + k]
X_golden = np.array([fp16_to_float(b) for b in x_quantized[:M*N]], dtype=np.float64).reshape(M, N)
W_golden = np.array([fp16_to_float(b) for b in w_quantized[:N*K]], dtype=np.float64).reshape(N, K)

# Read decoder FP16 outputs and targets
dec_fp16_file = 'target/sim/vsim/mx_decoder_fp16_outputs.txt'
dec_target_file = 'target/sim/vsim/mx_decoder_targets.txt'

dec_fp16_lines = []
with open(dec_fp16_file) as f:
    for line in f:
        vals = [int(x, 16) for x in line.strip().split()]
        dec_fp16_lines.append(vals)

dec_targets = []
with open(dec_target_file) as f:
    for line in f:
        dec_targets.append(line.strip())

print(f"\nDecoder outputs: {len(dec_fp16_lines)} lines")
print(f"Decoder targets: {len(dec_targets)} labels")

# Separate X and W decoder outputs
x_dec_chunks = []  # list of 32-element FP16 chunks
w_dec_chunks = []
for i, (vals, target) in enumerate(zip(dec_fp16_lines, dec_targets)):
    if target == 'X':
        x_dec_chunks.append(vals)
    elif target == 'W':
        w_dec_chunks.append(vals)

print(f"X decoder chunks: {len(x_dec_chunks)} (× {MX_NUM_LANES} = {len(x_dec_chunks)*MX_NUM_LANES} values)")
print(f"W decoder chunks: {len(w_dec_chunks)} (× {MX_NUM_LANES} = {len(w_dec_chunks)*MX_NUM_LANES} values)")

# Expected X chunks: per X memory read, each row has ceil(N/32) = 3 chunks per row
# X memory reads happen for each M-tile × K-tile pass × x_cols_iter
# But the streamer reads N values per row. With bus width 1024 bits = 128 FP8 values per beat,
# each row (96 FP8) fits in 1 beat = 4 slots (128/32). But only 3 slots have real data.
#
# Total X reads: x_rows_iter(3) × w_cols_iter(2) = 6 data passes
# Each pass: ARRAY_WIDTH(32) rows × 1 beat per row × 4 slots per beat = 128 slots
# But slot_buffer should only pop 3 valid slots per row (96/32=3), discarding the 4th (padding)
# Wait, the slot_buffer doesn't know about padding. Let me check.

# Actually, the slot_buffer pops DATAW_ALIGN/256 = 1024/256 = 4 slots per beat.
# All 4 slots are sent to the decoder.
# The 4th slot has zeros (padding).
# After decoding, the input_mux filters by active chunk range.

# For X row of 96 elements:
# chunks_per_row = K/MX_NUM_LANES = 96/32 = 3 (BUG: should be N/32, but N=K=96 here)
# Beat has 4 slots (128/32). Slot_buffer sends all 4.
# But x_chunks_per_row_i = 3 (K/32, which equals N/32 for square)
# The input_mux counter wraps at chunk 3 (0,1,2), so chunk 3 is never in the active range.
# Wait, the input_mux counts chunks using x_chunk_in_row_q from 0 to x_chunks_per_row_i - 1.
# If chunks_per_row = 3, it counts 0,1,2, then wraps. But the slot_buffer sends 4 chunks per beat.
# So chunk 3 (the padding) is counted as chunk 0 of the NEXT row. This is WRONG!

# Actually wait, does the slot_buffer pop only valid slots? Let me check...
# From the summary: "[slot_buffer] X: data_in=1152 exp_in=1149 popped=1140"
# X memory beats: for 96 rows × 6 passes = 576 rows, but actually:
# x_rows_iter=3, w_cols_iter=2, ARRAY_WIDTH=32
# X reads = 3 × 2 = 6 passes, each 32 rows = 192 beats total
# But wait, each pass may involve x_cols_iter=2 N-tile reads? No...

# Let me just look at the data. Each X decoder chunk is 32 FP16 values.
# Let me compare them with expected MX-decoded X values.

# First, compute the expected order of X chunks from the memory layout.
# X is stored row-major: X[0,0..95], X[1,0..95], ... X[95,0..95]
# Each row has 96 FP8 values. In memory, stored as ceil(96/128)=1 beat per row.
# Each beat: X[row, 0..95] padded to 128 values (96 real, 32 zero).
# Slot_buffer unpacks: slot0 = X[row, 0..31], slot1 = X[row, 32..63], slot2 = X[row, 64..95], slot3 = zeros

# Expected MX-decoded X[row, 0..31]:
# Original FP16: x_fp16_orig[row*N : row*N + 32]
# MX encode/decode: encode_block_fp16_to_mx(x_fp16_orig[row*N:row*N+32]) → exp, fp8_vals
# Then decode each fp8 with exp → FP16

# Let me compare decoder X chunks with expected
print("\n--- X Decoder Data Verification ---")
print("Comparing first 10 X decoder chunks with expected MX-decoded X values:")

# The X chunks should come in the order: rows 0-31, chunks 0,1,2 per row
# Then repeated for subsequent K-tile passes (but K-tile is about W, X just replays)
# Actually, for each M-tile × K-tile combination:
#   X reads 32 rows, each with 3 data chunks + 1 padding chunk = 4 slots per row
# But I don't know if slot_buffer sends 3 or 4 slots per beat.

# Let me just compare the actual values and figure out the ordering.
for chunk_idx in range(min(12, len(x_dec_chunks))):
    vals = x_dec_chunks[chunk_idx]
    vals_float = [fp16_to_float(v) for v in vals]
    print(f"  X chunk {chunk_idx}: [{vals[0]:04x} {vals[1]:04x} {vals[2]:04x} ... {vals[31]:04x}]")
    print(f"    = [{vals_float[0]:.4f} {vals_float[1]:.4f} {vals_float[2]:.4f} ... {vals_float[31]:.4f}]")

# Expected X row 0, chunk 0 (elements 0-31):
print("\nExpected X[row=0] MX-decoded chunks:")
for chunk in range(3):
    start = chunk * 32
    end = start + 32
    block = x_fp16_orig[start:end]
    exp, fp8_vals = encode_block_fp16_to_mx(block)
    decoded = [mxfp8_decode_bits(fp8, exp) for fp8 in fp8_vals]
    decoded_float = [fp16_to_float(v) for v in decoded]
    print(f"  Expected chunk {chunk} (exp={exp:02x}): [{decoded[0]:04x} {decoded[1]:04x} {decoded[2]:04x} ... {decoded[31]:04x}]")
    print(f"    = [{decoded_float[0]:.4f} {decoded_float[1]:.4f} {decoded_float[2]:.4f} ... {decoded_float[31]:.4f}]")

print("\n--- W Decoder Data Verification ---")
# Similarly for W chunks
print("Comparing first 10 W decoder chunks with expected MX-decoded W values:")
for chunk_idx in range(min(12, len(w_dec_chunks))):
    vals = w_dec_chunks[chunk_idx]
    vals_float = [fp16_to_float(v) for v in vals]
    print(f"  W chunk {chunk_idx}: [{vals[0]:04x} {vals[1]:04x} {vals[2]:04x} ... {vals[31]:04x}]")

# Expected W row 0, chunk 0 (elements 0-31):
print("\nExpected W[row=0] MX-decoded chunks:")
for chunk in range(3):
    start = chunk * 32
    end = start + 32
    block = w_fp16_orig[start:end]
    exp, fp8_vals = encode_block_fp16_to_mx(block)
    decoded = [mxfp8_decode_bits(fp8, exp) for fp8 in fp8_vals]
    decoded_float = [fp16_to_float(v) for v in decoded]
    print(f"  Expected chunk {chunk} (exp={exp:02x}): [{decoded[0]:04x} {decoded[1]:04x} {decoded[2]:04x} ... {decoded[31]:04x}]")
    print(f"    = [{decoded_float[0]:.4f} {decoded_float[1]:.4f} {decoded_float[2]:.4f} ... {decoded_float[31]:.4f}]")

# Now let's check if X decoder chunks match in sequence
print("\n--- X Chunk Matching ---")
# Build expected X chunks in memory order
expected_x_chunks = []
for row in range(M):
    for chunk in range(3):  # 96/32 = 3 chunks per row
        start = row * N + chunk * 32
        end = start + 32
        block = x_fp16_orig[start:end]
        exp, fp8_vals = encode_block_fp16_to_mx(block)
        decoded = tuple(mxfp8_decode_bits(fp8, exp) for fp8 in fp8_vals)
        expected_x_chunks.append(decoded)
    # 4th chunk (padding) - zeros decoded through MX
    expected_x_chunks.append(tuple([0]*32))

print(f"Expected X chunks (with padding): {len(expected_x_chunks)}")

# Check match for first pass
match_count = 0
mismatch_count = 0
for i in range(min(len(x_dec_chunks), len(expected_x_chunks), 40)):
    actual = tuple(x_dec_chunks[i])
    expected = expected_x_chunks[i]
    if actual == expected:
        match_count += 1
    else:
        mismatch_count += 1
        if mismatch_count <= 5:
            actual_f = [fp16_to_float(v) for v in actual[:4]]
            expected_f = [fp16_to_float(v) for v in expected[:4]]
            print(f"  MISMATCH at chunk {i}: actual=[{actual[0]:04x},{actual[1]:04x},...] expected=[{expected[0]:04x},{expected[1]:04x},...]")
            print(f"    actual_f={actual_f}, expected_f={expected_f}")

print(f"First 40 X chunks: {match_count} match, {mismatch_count} mismatch")

# Do same for W
print("\n--- W Chunk Matching ---")
expected_w_chunks = []
for row in range(N):  # W is N×K
    for chunk in range(3):  # K/32 = 3 chunks per row
        start = row * K + chunk * 32
        end = start + 32
        block = w_fp16_orig[start:end]
        exp, fp8_vals = encode_block_fp16_to_mx(block)
        decoded = tuple(mxfp8_decode_bits(fp8, exp) for fp8 in fp8_vals)
        expected_w_chunks.append(decoded)
    # 4th chunk (padding)
    expected_w_chunks.append(tuple([0]*32))

print(f"Expected W chunks (with padding): {len(expected_w_chunks)}")

match_count = 0
mismatch_count = 0
for i in range(min(len(w_dec_chunks), len(expected_w_chunks), 40)):
    actual = tuple(w_dec_chunks[i])
    expected = expected_w_chunks[i]
    if actual == expected:
        match_count += 1
    else:
        mismatch_count += 1
        if mismatch_count <= 5:
            print(f"  MISMATCH at chunk {i}: actual=[{actual[0]:04x},{actual[1]:04x},...] expected=[{expected[0]:04x},{expected[1]:04x},...]")

print(f"First 40 W chunks: {match_count} match, {mismatch_count} mismatch")

# Try without padding chunks (maybe slot_buffer doesn't send padding)
print("\n--- W Chunk Matching (no padding) ---")
expected_w_chunks_np = []
for row in range(N):
    for chunk in range(3):
        start = row * K + chunk * 32
        end = start + 32
        block = w_fp16_orig[start:end]
        exp, fp8_vals = encode_block_fp16_to_mx(block)
        decoded = tuple(mxfp8_decode_bits(fp8, exp) for fp8 in fp8_vals)
        expected_w_chunks_np.append(decoded)

match_count = 0
mismatch_count = 0
for i in range(min(len(w_dec_chunks), len(expected_w_chunks_np), 40)):
    actual = tuple(w_dec_chunks[i])
    expected = expected_w_chunks_np[i]
    if actual == expected:
        match_count += 1
    else:
        mismatch_count += 1
        if mismatch_count <= 5:
            actual_f = [fp16_to_float(v) for v in actual[:4]]
            expected_f = [fp16_to_float(v) for v in expected[:4]]
            print(f"  MISMATCH at chunk {i}: actual=[{actual[0]:04x},{actual[1]:04x},{actual[2]:04x},{actual[3]:04x}] expected=[{expected[0]:04x},{expected[1]:04x},{expected[2]:04x},{expected[3]:04x}]")
            print(f"    actual={actual_f}, expected={expected_f}")

print(f"First 40 W chunks (no padding): {match_count} match, {mismatch_count} mismatch")

print("\n--- X Chunk Matching (no padding) ---")
expected_x_chunks_np = []
for row in range(M):
    for chunk in range(3):
        start = row * N + chunk * 32
        end = start + 32
        block = x_fp16_orig[start:end]
        exp, fp8_vals = encode_block_fp16_to_mx(block)
        decoded = tuple(mxfp8_decode_bits(fp8, exp) for fp8 in fp8_vals)
        expected_x_chunks_np.append(decoded)

match_count = 0
mismatch_count = 0
for i in range(min(len(x_dec_chunks), len(expected_x_chunks_np), 40)):
    actual = tuple(x_dec_chunks[i])
    expected = expected_x_chunks_np[i]
    if actual == expected:
        match_count += 1
    else:
        mismatch_count += 1
        if mismatch_count <= 5:
            actual_f = [fp16_to_float(v) for v in actual[:4]]
            expected_f = [fp16_to_float(v) for v in expected[:4]]
            print(f"  MISMATCH at chunk {i}: actual=[{actual[0]:04x},{actual[1]:04x},{actual[2]:04x},{actual[3]:04x}] expected=[{expected[0]:04x},{expected[1]:04x},{expected[2]:04x},{expected[3]:04x}]")
            print(f"    actual={actual_f}, expected={expected_f}")

print(f"First 40 X chunks (no padding): {match_count} match, {mismatch_count} mismatch")
