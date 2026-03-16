#!/usr/bin/env python3
"""Diagnose whether RTL Z output matches partial GEMM (wrong accumulation)."""
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
MX_BLOCK = 32
ARRAY_WIDTH = 32
TILE = 64

# Load and quantize
x_fp16 = parse_c_header_array('sw/inc/x_input.h')
w_fp16 = parse_c_header_array('sw/inc/w_input.h')
y_fp16 = parse_c_header_array('sw/inc/y_input.h')

x_q = encode_decode_mx(x_fp16, MX_BLOCK)
w_q = encode_decode_mx(w_fp16, MX_BLOCK)

X = np.array([fp16_to_float(b) for b in x_q[:M*N]], dtype=np.float16).reshape(M, N)
W = np.array([fp16_to_float(b) for b in w_q[:N*K]], dtype=np.float16).reshape(N, K)
Y = np.array([fp16_to_float(b) for b in y_fp16[:M*K]], dtype=np.float16).reshape(M, K)

def gemm_fp16_range(X, W, Y, n_start, n_end, accumulate_y=True):
    """Compute GEMM over N-range [n_start, n_end) with FP16 accumulation."""
    Z = np.zeros((M, K), dtype=np.float64)
    for m in range(M):
        for k in range(K):
            acc = float(np.float16(Y[m, k])) if accumulate_y else 0.0
            for n in range(n_start, n_end):
                acc = float(np.float16(float(np.float16(X[m, n]) * np.float16(W[n, k])) + np.float16(acc)))
            Z[m, k] = acc
    return Z.astype(np.float16)

# Read RTL encoder FP16 data
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

# Get RTL Z as a matrix (from encoder FP16, drain order: M-tile × K-tile × column)
rtl_z = np.zeros((M, K), dtype=np.float16)
beat_idx = 0
for m_tile in range(M // ARRAY_WIDTH):  # 0,1,2
    for k_tile in range((K + TILE - 1) // TILE):  # 0,1
        k_start = k_tile * TILE
        k_end = min(k_start + TILE, K)
        for w in range(ARRAY_WIDTH):  # 0..31 columns
            m = m_tile * ARRAY_WIDTH + w
            if beat_idx < len(enc_fp16) // 64:
                col = enc_fp16[beat_idx * 64: (beat_idx + 1) * 64]
                for d in range(k_end - k_start):
                    if m < M:
                        rtl_z[m, k_start + d] = np.float16(fp16_to_float(col[d]))
                beat_idx += 1

print(f"RTL Z reconstructed: {beat_idx} beats used (expected 192)")

# Compute various reference Z variants
print("\nComparing RTL Z with different GEMM computations:")
print("=" * 80)

# Full GEMM (n=0..95)
Z_full = gemm_fp16_range(X, W, Y, 0, N)
exact_full = np.sum(np.array([float_to_fp16_bits(v) for v in rtl_z.flat]) ==
                     np.array([float_to_fp16_bits(v) for v in Z_full.flat]))
print(f"Full GEMM (n=0..95): {exact_full}/{M*K} exact matches")

# Only N-tile 0 (n=0..63)
Z_ntile0 = gemm_fp16_range(X, W, Y, 0, 64)
exact_ntile0 = np.sum(np.array([float_to_fp16_bits(v) for v in rtl_z.flat]) ==
                       np.array([float_to_fp16_bits(v) for v in Z_ntile0.flat]))
print(f"N-tile 0 only (n=0..63): {exact_ntile0}/{M*K} exact matches")

# Only N-tile 1 (n=64..95)
Z_ntile1 = gemm_fp16_range(X, W, Y, 64, N)
exact_ntile1 = np.sum(np.array([float_to_fp16_bits(v) for v in rtl_z.flat]) ==
                       np.array([float_to_fp16_bits(v) for v in Z_ntile1.flat]))
print(f"N-tile 1 only (n=64..95): {exact_ntile1}/{M*K} exact matches")

# First 32 W rows only (n=0..31)
Z_wrows0 = gemm_fp16_range(X, W, Y, 0, 32)
exact_wr0 = np.sum(np.array([float_to_fp16_bits(v) for v in rtl_z.flat]) ==
                    np.array([float_to_fp16_bits(v) for v in Z_wrows0.flat]))
print(f"W rows 0-31 only (n=0..31): {exact_wr0}/{M*K} exact matches")

# Second 32 W rows only (n=32..63)
Z_wrows1 = gemm_fp16_range(X, W, Y, 32, 64)
exact_wr1 = np.sum(np.array([float_to_fp16_bits(v) for v in rtl_z.flat]) ==
                    np.array([float_to_fp16_bits(v) for v in Z_wrows1.flat]))
print(f"W rows 32-63 only (n=32..63): {exact_wr1}/{M*K} exact matches")

# Try: double-counting certain ranges
# Maybe the engine processes N-tile 0 twice (same X with W rows 0-63 twice)
Z_double_ntile0 = gemm_fp16_range(X, W, Y, 0, 64)
# Add another pass of n=0..63 ON TOP of the first
for m in range(M):
    for k in range(K):
        acc = float(np.float16(Z_double_ntile0[m, k]))
        for n in range(64):
            acc = float(np.float16(float(np.float16(X[m, n]) * np.float16(W[n, k])) + np.float16(acc)))
        Z_double_ntile0[m, k] = np.float16(acc)
exact_double = np.sum(np.array([float_to_fp16_bits(v) for v in rtl_z.flat]) ==
                       np.array([float_to_fp16_bits(v) for v in Z_double_ntile0.flat]))
print(f"N-tile 0 twice: {exact_double}/{M*K} exact matches")

# Try: X N-tile 0 with all W rows (X is stuck on n=0..63 but W processes all 96 rows)
Z_x_stuck_ntile0 = np.zeros((M, K), dtype=np.float64)
for m in range(M):
    for k in range(K):
        acc = float(np.float16(Y[m, k]))
        for n in range(N):
            x_n = min(n, 63)  # X clips to N-tile 0
            acc = float(np.float16(float(np.float16(X[m, x_n]) * np.float16(W[n, k])) + np.float16(acc)))
        Z_x_stuck_ntile0[m, k] = acc
Z_x_stuck_ntile0 = Z_x_stuck_ntile0.astype(np.float16)
exact_xstuck = np.sum(np.array([float_to_fp16_bits(v) for v in rtl_z.flat]) ==
                       np.array([float_to_fp16_bits(v) for v in Z_x_stuck_ntile0.flat]))
print(f"X stuck on N-tile 0 (W all rows): {exact_xstuck}/{M*K} exact matches")

# Try: W rows and X N-tiles misaligned
# X N-tile 0 with W rows 0-63, then X N-tile 0 (again!) with W rows 64-95
Z_x_ntile0_all = np.zeros((M, K), dtype=np.float64)
for m in range(M):
    for k in range(K):
        acc = float(np.float16(Y[m, k]))
        for n in range(N):
            x_val = X[m, n % 64]  # X wraps around N-tile 0
            acc = float(np.float16(float(np.float16(x_val) * np.float16(W[n, k])) + np.float16(acc)))
        Z_x_ntile0_all[m, k] = acc
Z_x_ntile0_all = Z_x_ntile0_all.astype(np.float16)
exact_xwrap = np.sum(np.array([float_to_fp16_bits(v) for v in rtl_z.flat]) ==
                      np.array([float_to_fp16_bits(v) for v in Z_x_ntile0_all.flat]))
print(f"X wraps N-tile 0 for all W: {exact_xwrap}/{M*K} exact matches")

# Try: misaligned N-tiles
# Pass 1: X N-tile 0 × W[0:64] (correct)
# Pass 2: X N-tile 1 × W[0:32] (WRONG: should be W[64:96])
# Pass 3: X N-tile 0 × W[32:64] (WRONG: misaligned)
# This would happen if x_cols_iter doesn't reset with w_rows_iter
Z_misaligned = np.zeros((M, K), dtype=np.float64)
for m in range(M):
    for k in range(K):
        acc = float(np.float16(Y[m, k]))
        # Pass 0: X[m, 0:32] × W[0:32, k] (first 32 of N-tile 0, first 32 W rows)
        for n in range(32):
            acc = float(np.float16(float(np.float16(X[m, n]) * np.float16(W[n, k])) + np.float16(acc)))
        # After 32 W rows, x_shift_cnt has done one full cycle (32)
        # buf_r_addr hasn't changed yet, so we're still on the first "page"
        # The X buffer reads the same 32 values again... or moves to next page?
        # Pass 1: X[m, 32:64] × W[32:64, k] (second 32 of N-tile 0, next 32 W rows)
        for n in range(32, 64):
            acc = float(np.float16(float(np.float16(X[m, n]) * np.float16(W[n, k])) + np.float16(acc)))
        # Now x_buffer empties, x_cols_iter advances to 1 (N-tile 1)
        # X reloads with N-tile 1 data (n=64..95)
        # Pass 2: X[m, 64:96] × W[64:96, k] (N-tile 1, remaining W rows)
        for n in range(64, 96):
            acc = float(np.float16(float(np.float16(X[m, n]) * np.float16(W[n, k])) + np.float16(acc)))
        Z_misaligned[m, k] = acc
Z_misaligned = Z_misaligned.astype(np.float16)
exact_mis = np.sum(np.array([float_to_fp16_bits(v) for v in rtl_z.flat]) ==
                    np.array([float_to_fp16_bits(v) for v in Z_misaligned.flat]))
print(f"Aligned: X ntile 0→W[0:64], X ntile 1→W[64:96]: {exact_mis}/{M*K} exact matches")

# The above IS the correct GEMM. Let me try actual misalignment patterns:

# Hypothesis: x_buffer empties after 64 h_shifts, not after 32.
# So x_cols_iter changes every 2 sets of 32 W rows (= 64 W rows).
# Meanwhile w_rows_iter wraps at 96.
# Timeline (all for K-tile 0):
#   W rows 0-31 (pass 0): x_cols_iter=0, x_data = N-tile 0
#   W rows 32-63 (pass 1): x_cols_iter=0, x_data = N-tile 0 (same! not reloaded yet)
#   x_buffer empties → x_cols_iter: 0→1, reload X with N-tile 1
#   W rows 64-95 (pass 2): x_cols_iter=1, x_data = N-tile 1
#   At W row 95: w_rows_iter wraps, w_cols_iter: 0→1
#   But x_buffer has only done 32 shifts of N-tile 1 (needs 64 for empty)
#   W rows 0-31 (pass 3): x_cols_iter=1 still (N-tile 1!), K-tile now 1
#   x_buffer empties → x_cols_iter: 1→0, reload X with N-tile 0
#   W rows 32-63 (pass 4): x_cols_iter=0, N-tile 0, K-tile 1
#   W rows 64-95 (pass 5): x_cols_iter=0 still! N-tile 0, K-tile 1
#   x_buffer empties → x_cols_iter: 0→1
# This means for K-tile 1, pass 3 uses N-tile 1 and pass 4-5 use N-tile 0!

# Let me model this: for each M-tile, the computation is:
# Z[m, k] = Y[m,k] + sum_passes(X[m, n_tile_of_pass] * W[n_of_pass, k])

# For K-tile 0 (k=0..63):
#   Pass 0: W rows 0-31, X N-tile 0 → sum(X[m,0:32]*W[0:32,k])  (using first 32 of X ntile 0)
#   Pass 1: W rows 32-63, X N-tile 0 → sum(X[m,0:32]*W[32:64,k])  (using SECOND 32 of X ntile 0)
# Wait, the X buffer doesn't change within a pass. The same x_buffer data is used
# for 32 consecutive W rows. But the x_buffer provides 32 values at a time
# (one per h), and h_index_r cycles through them.
#
# Actually, x_buffer_q changes EVERY cycle (h_shift fires each LOAD_W cycle).
# h_index_r cycles 0→31, buf_r_addr flips. So over 64 shifts:
#   Shifts 0-31: h_index 0-31, buf_r_addr 0 → reads first 32 of 64 depth values
#   Shifts 32-63: h_index 0-31, buf_r_addr 1 → reads second 32 of 64 depth values
#
# BUT h_shift (x_shift_cnt_en) fires in LOAD_W only. And LOAD_W is one cycle per
# (LOAD_W, WAIT) pair. So 32 h_shifts happen over 64 clock cycles.
#
# buf_r_addr flips when h_index_r wraps (at h=31 → h=0).
# With 32 h_shifts per x_shift_cnt pass: h goes 0→31, then wraps. buf_r_addr flips.
# So WITHIN a single x_shift_cnt pass (32 shifts), buf_r_addr stays constant!
# It only flips at the START of the next pass.
#
# This means:
#   x_shift_cnt pass 0 (shifts 0-31): buf_r_addr=0, h_index 0→31
#   x_shift_cnt pass 1 (shifts 32-63): buf_r_addr=1, h_index 0→31
#   Total: 64 h_shifts = 64 LOAD_W cycles = 64 W rows processed
#
# In each pass, the engine sees 32 different x_buffer_q states (one per h_index).
# Each state provides 32×32 values: x_buffer_q[h][w].
# The W buffer shifts through its 64 elements in 64 total shift cycles
# (32 LOAD_W + 32 WAIT).
#
# So each x_shift_cnt pass (32 shifts = 32 W rows loaded):
# The engine does 32 multiply-accumulates of:
#   z[w] += x_buf[h][w] * w_buf[h]  for each shift
# After 64 total shifts (2 x_shift_cnt passes), one complete W-buffer traversal.
#
# But wait - new W rows are loaded every LOAD_W cycle. So the W buffer data
# changes every cycle! The engine computes with fresh W data each LOAD_W cycle.
#
# This is NOT a simple matmul. Let me model what the systolic array actually computes.

# After extensive analysis, let me just empirically check: for M-tile 0, K-tile 0,
# what does the RTL produce for Z[0, 0:64]?
# And what does each partial GEMM scenario predict?

# Let me just compute different scenarios and compare with the first few RTL values.
# RTL first column (Col 0): Z[0, 0:64]
# From encoder FP16 inputs:
rtl_col0 = enc_fp16[0:64]  # First 64 values = first column
rtl_col0_f = [fp16_to_float(v) for v in rtl_col0]

print(f"\n--- Detailed comparison for Z[0, 0:7] ---")
print(f"RTL:        {[f'{v:.3f}' for v in rtl_col0_f[:8]]}")
print(f"Full GEMM:  {[f'{float(Z_full[0,k]):.3f}' for k in range(8)]}")
print(f"N-tile 0:   {[f'{float(Z_ntile0[0,k]):.3f}' for k in range(8)]}")
print(f"N-tile 1:   {[f'{float(Z_ntile1[0,k]):.3f}' for k in range(8)]}")
print(f"W rows 0-31:{[f'{float(Z_wrows0[0,k]):.3f}' for k in range(8)]}")
print(f"W rows 32-63:{[f'{float(Z_wrows1[0,k]):.3f}' for k in range(8)]}")
print(f"Y bias:     {[f'{float(Y[0,k]):.3f}' for k in range(8)]}")

# Try more patterns: X N-tile 0 with W[0:64], then X N-tile 1 with W[0:32]
# (misaligned: after w_rows_iter wraps at 96, x_cols_iter is still on N-tile 1)
# K-tile 0: X_ntile0 × W[0:64] + X_ntile1 × W[64:96] → this IS correct
# K-tile 0 WRONG: X_ntile0 × W[0:64] + X_ntile1 × W[0:32]

# Actually let me test the hypothesis from my earlier analysis:
# x_buffer empties after ctrl_i.slots pad reads.
# slots = D (=64 in scheduler context, which is TOT_DEPTH) for non-last N-tile
# slots = X_SLOTS for last N-tile
# With slots=64, x_buffer empties after 64 pad reads.
# pad_read_cnt increments each buf_write_en (FAST_FILL or FILL+h_shift).
# Each h_shift = one LOAD_W cycle = one W row.
# So x_buffer empties after 64 W rows → x_cols_iter advances.
# But N=96, so after 64 W rows, w_rows_iter is at 64.
# Then x_cols_iter advances, x_buffer reloads. Next 32 W rows (64-95)
# use N-tile 1. Then w_rows_iter wraps, w_cols_iter advances.
# x_buffer has had 32 pad reads of N-tile 1, needs 32 more (for slots=32, last N-tile).
# Wait — for last N-tile, slots = X_SLOTS.
# What is X_SLOTS set to?

# Let me check the register file to see what X_SLOTS is for MX96.
# From the scheduler: slots = x_cols_iter_q == X_ITERS[15:0]-1 ? X_SLOTS : D
# For x_cols_iter_q=1 (last N-tile), slots = X_SLOTS
# For x_cols_iter_q=0 (first N-tile), slots = D = 64

# X_SLOTS for 96-element N: last N-tile has 32 elements.
# The x_buffer needs 32 pad reads for 32 elements.
# But x_buf has HEIGHT=2, so it fills in 2 passes of 32.
# slots probably = 32 (depth of last N-tile).

# So:
# First N-tile: slots=64 → empties after 64 pad reads (= 64 W rows)
# Second N-tile: slots=32 → empties after 32 pad reads (= 32 W rows)
# Total: 64 + 32 = 96 W rows = exactly N.

# For K-tile 0:
#   W rows 0-63: x_cols_iter=0 (N-tile 0, slots=64)
#     x_buffer provides X[m, 0:64] → 64 pad reads
#   W rows 64-95: x_cols_iter=1 (N-tile 1, slots=32)
#     x_buffer provides X[m, 64:96] → 32 pad reads
# For K-tile 1:
#   W rows 0-63: x_cols_iter=0 (N-tile 0, slots=64)
#   W rows 64-95: x_cols_iter=1 (N-tile 1, slots=32)

# This looks correct! But then why are the results wrong?
# Maybe the issue is in HOW the x_buffer maps to the engine computation.

# Let me model the EXACT computation based on x_buffer mechanics.
# With DEPTH=2 (D=DW/(H*BITW)=1024/(32*16)=2):
#   x_buf_scm has HEIGHT=2, N_OUTPUTS=H=32, WIDTH=W=32
#   Read address = {buf_r_addr(1 bit), h_index_r(5 bits)}
#   buf_r_addr flips when h_index_r wraps (every 32 h_shifts)

# With slots=64:
#   64 pad reads → x_buf fills 2 pages (32 reads per page)
#   Engine reads 2 pages: buf_r_addr 0 (32 shifts), then buf_r_addr 1 (32 shifts)
#   Total: 64 h_shifts → 64 W rows

# The x_buf data:
#   Page 0: x_pad[0..31] → first 32 columns of X tile
#   Page 1: x_pad[32..63] → second 32 columns of X tile

# At h_shift i (0..31) with buf_r_addr=0:
#   x_buffer_q[h][w] = x_pad[i][w] = X[w, i] (for first 32 depth)
# Wait, x_pad read address is pad_r_addr_d (which cycles 0..slots-1).
# x_buf stores data at write address {buf_w_addr, h_index_w}.
# h_index_w cycles 0..31, buf_w_addr flips when h_index_w wraps.

# So x_buf[{0, 0}] = x_pad[0], x_buf[{0, 1}] = x_pad[1], ..., x_buf[{0, 31}] = x_pad[31]
# x_buf[{1, 0}] = x_pad[32], ..., x_buf[{1, 31}] = x_pad[63]

# Read at h_shift i with buf_r_addr=0: x_buffer_q[h_index_r=i][w] = x_pad[i][w]
# But x_pad[col][row] stores data as: x_pad stores at write_addr=w_index (row=load index),
# with full row of TOT_DEPTH=64 values per write. So x_pad[row=m_in_tile][col=n_in_tile].

# Hmm, actually x_pad_scm has ROWS=W=32 and COLS=TOT_DEPTH=64.
# write_addr = w_index (0..31) = the M-tile row index
# wdata = x_buffer_i = 64 FP16 from bus = one row of X tile (all N columns in tile)
# So x_pad[w_index][0..63] = X[m_tile*32 + w_index, n_tile*64 + 0..63]

# Read: read_addr = pad_read_addr (0..63)
# x_pad_q[w] = x_pad[w][pad_read_addr] for all w=0..31
# This reads one N-column from all M-rows simultaneously!
# So pad_read_addr selects which N-element is read.

# x_buf stores these reads:
# x_buf[{buf_w_addr, h_index_w}][w] = x_pad[w][pad_r_addr_at_write_time]

# The x_buf is read with {buf_r_addr, h_index_r}:
# x_buffer_q[h][w] = x_buf[{buf_r_addr, h_index_r}][w]
# where h = the output port index (0..H-1=31)

# Wait, the x_buf_scm has N_OUTPUTS=H=32 read ports. Read address selects the
# "row" within each "column", and all N_OUTPUTS are returned.
# Actually, I think N_OUTPUTS means each read returns H=32 values from the stored
# data. The x_buf_scm stores WIDTH × HEIGHT × WORD_SIZE. But it has N_OUTPUTS
# simultaneous read ports, each addressed independently? Or it returns N_OUTPUTS
# values from a single read?

# Looking at the instantiation:
# read_addr_i = {buf_r_addr, h_index_r} — single read address
# rdata_o = x_buffer_q = [H-1:0][W-1:0][BITW-1:0] — H×W output

# So one read address returns H=32 outputs, each W=32 elements wide.
# Total output = 32 × 32 = 1024 FP16 per read.

# The storage is HEIGHT=2 deep. Each "height" level stores N_OUTPUTS=32 slices,
# each W=32 wide. So total storage = 2 × 32 × 32 = 2048 values.
# But we need to store 32 M-rows × 64 N-columns = 2048 values. Perfect match!

# Write: write_addr = {buf_w_addr, h_index_w} (6-bit, selects one of 64 entries)
# wdata = x_pad_q (W=32 values)
# Each write stores one W=32 vector at one of the 64 entries.

# Read: read_addr = {buf_r_addr, h_index_r}
# Returns: x_buffer_q[h][w] for all h=0..31, w=0..31
# This means 32 of the 64 stored vectors are read simultaneously!
# Each output port h reads from a different entry: the entry at address h_index_r
# from height bank buf_r_addr.

# Actually, I think the N_OUTPUTS ports read from addresses that are relative
# to the base read address. Like: port h reads from address base + h.
# So: x_buffer_q[h][w] = stored_data[{buf_r_addr, h_index_r} + offset(h)][w]

# Hmm, this is the critical part I need to understand. Let me look at the SCM.
print(f"\nNeed to check x_buffer_scm implementation to understand exact mapping.")
print(f"Running empirical check instead...\n")

# Empirical: for each scenario, compute Z and check match rate
print("Scenario comparison for Z[0:32, 0:32] (first M-tile, first K-tile half):")
rtl_sub = np.array([[fp16_to_float(rtl_col0[k]) for k in range(32)] if rtl_col0 else [] ])

# Just output the raw numbers for manual analysis
print(f"\nRTL Z[0,0:8]: {[f'{fp16_to_float(v):.3f}' for v in rtl_col0[:8]]}")

# Compare with N-tile computations
for n_start, n_end, label in [
    (0, 96, "Full"),
    (0, 64, "n=0:64"),
    (0, 32, "n=0:32"),
    (32, 64, "n=32:64"),
    (64, 96, "n=64:96"),
    (0, 48, "n=0:48"),
]:
    z = gemm_fp16_range(X, W, Y, n_start, n_end)
    print(f"Z_{label}[0,0:8]: {[f'{float(z[0,k]):.3f}' for k in range(8)]}")

# Check if RTL Z matches Y + X[0:32]*W[0:32] (only first 32×32 block)
# This would mean the engine only processes the first x_buf page (one pass of h_index)
z_32 = gemm_fp16_range(X, W, Y, 0, 32)
# RTL value for Z[0,0] = 22.422, z_32[0,0] = ?
print(f"\nz_32[0,0] = {float(z_32[0,0]):.3f}, RTL Z[0,0] = {fp16_to_float(rtl_col0[0]):.3f}")

# Maybe the engine uses x_buffer with only h=0..31 and ignores the second page?
# In that case: inner product over 32 W-row values with x_buf[page0]
# For each W row n (0..95): engine accumulates x[m, n%32] * w[n, k]
# (because x_buf page stays on page 0, repeating every 32 W rows)
Z_repeat32 = np.zeros((M, K), dtype=np.float64)
for m in range(M):
    for k in range(K):
        acc = float(np.float16(Y[m, k]))
        for n in range(N):
            x_val = X[m, n % 32]  # x repeats with period 32
            acc = float(np.float16(float(np.float16(x_val) * np.float16(W[n, k])) + np.float16(acc)))
        Z_repeat32[m, k] = acc
Z_repeat32 = Z_repeat32.astype(np.float16)
exact_rep32 = np.sum(np.array([float_to_fp16_bits(v) for v in rtl_z.flat]) ==
                      np.array([float_to_fp16_bits(v) for v in Z_repeat32.flat]))
print(f"X repeats period 32 (n%32): {exact_rep32}/{M*K} exact matches")
print(f"Z_repeat32[0,0:8]: {[f'{float(Z_repeat32[0,k]):.3f}' for k in range(8)]}")
