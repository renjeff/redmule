#!/usr/bin/env python3
"""
Compare engine dump files against golden GEMM for both FP16 and MX modes.

Reads:
  FP16 mode: x_input.h, w_input.h, y_input.h, golden.h
  MX mode:   x_input_mx.h, x_exp_mx.h, w_input_mx.h, w_exp_mx.h, y_input.h

  Engine dumps: engine_x_inputs.txt, engine_w_inputs.txt, engine_z_outputs.txt
  MX decoder:  mx_decoder_fp16_outputs.txt, mx_decoder_targets.txt (MX only)

Usage:
    # FP16 baseline
    python3 check_engine_vs_golden.py --mode fp16

    # MX mode
    python3 check_engine_vs_golden.py --mode mx

    # Custom paths / dimensions
    python3 check_engine_vs_golden.py --mode fp16 --dump-dir /path/to/vsim -M 32 -N 32 -K 32
"""

import argparse
import csv
import re
import sys
import os
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'common'))

from redmule_fma import bittrue_fma


# ── Parsing helpers ──────────────────────────────────────────────

def parse_c_header_array(filename):
    """Parse a C header and return list of integer values."""
    with open(filename, 'r') as f:
        text = f.read()
    values = re.findall(r'0x[0-9a-fA-F]+', text)
    return [int(x, 16) for x in values]


def unpack_fp16_from_32bit(packed_words):
    """Unpack FP16 values from 32-bit words (2 per word, little-endian)."""
    fp16_values = []
    for word in packed_words:
        fp16_values.append(word & 0xFFFF)
        fp16_values.append((word >> 16) & 0xFFFF)
    return fp16_values


def unpack_fp8_from_16bit(packed_values):
    """Unpack FP8 values from 16-bit words (2 per word, little-endian)."""
    fp8_values = []
    for word in packed_values:
        fp8_values.append(word & 0xFF)
        fp8_values.append((word >> 8) & 0xFF)
    return fp8_values


def unpack_exponents_8bit(packed_words):
    """Unpack 8-bit exponents from 32-bit words (4 per word)."""
    exps = []
    for word in packed_words:
        for i in range(4):
            exps.append((word >> (i * 8)) & 0xFF)
    return exps


def parse_engine_dump(filename):
    """Parse space-separated hex dump file. Returns list of lists of ints.
    Returns None if file doesn't exist or is empty."""
    if not os.path.exists(filename) or os.path.getsize(filename) == 0:
        return None
    lines = []
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            vals = [int(x, 16) for x in line.split()]
            lines.append(vals)
    return lines if lines else None


def parse_target_dump(filename):
    """Parse mx_decoder_targets.txt (one 'X' or 'W' per line)."""
    if not os.path.exists(filename) or os.path.getsize(filename) == 0:
        return None
    targets = []
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if line in ('X', 'W'):
                targets.append(line)
    return targets if targets else None


def parse_hex_scalar_lines(filename):
    """Parse one hex scalar per line."""
    if not os.path.exists(filename) or os.path.getsize(filename) == 0:
        return None
    values = []
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or line.startswith('//'):
                continue
            values.append(int(line, 16))
    return values if values else None


def parse_packed_hex_blocks(filename, elem_bits, elems_per_line=None):
    """Parse one packed hex word per line into little-endian element lists."""
    if not os.path.exists(filename) or os.path.getsize(filename) == 0:
        return None

    blocks = []
    elem_mask = (1 << elem_bits) - 1
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or line.startswith('//'):
                continue
            if elems_per_line is None:
                total_bits = len(line) * 4
                if total_bits % elem_bits != 0:
                    raise ValueError(f"{filename}: line width {total_bits} is not a multiple of {elem_bits}")
                count = total_bits // elem_bits
            else:
                count = elems_per_line
            word = int(line, 16)
            blocks.append([(word >> (elem_bits * i)) & elem_mask for i in range(count)])
    return blocks if blocks else None


def parse_engine_feed_trace(filename):
    """Parse engine_feed_trace.csv."""
    if not os.path.exists(filename) or os.path.getsize(filename) == 0:
        return None

    rows = []
    with open(filename, 'r') as f:
        reader = csv.DictReader(f)
        lane_cols = [c for c in reader.fieldnames if re.fullmatch(r'l\d+', c)] if reader.fieldnames else []
        lane_cols.sort(key=lambda x: int(x[1:]))
        for row in reader:
            rows.append({
                'time': int(row['time']),
                'event': row['event'],
                'line_idx': int(row['line_idx']),
                'mx_enable': int(row['mx_enable']),
                'target_x': int(row['target_x']),
                'target_w': int(row['target_w']),
                'pairdup': int(row['pairdup']),
                'lanes': [int(row[col], 16) for col in lane_cols],
            })
    return rows if rows else None


def chunk_values(values, chunk_size, pad=False):
    """Split a flat list into fixed-size chunks."""
    out = []
    for i in range(0, len(values), chunk_size):
        chunk = list(values[i:i + chunk_size])
        if pad and len(chunk) < chunk_size:
            chunk.extend([0] * (chunk_size - len(chunk)))
        out.append(chunk)
    return out


def expand_exp_words(exp_words, num_blocks):
    """Normalize packed exponent words into one exponent per MX block."""
    if len(exp_words) == num_blocks:
        return [(w & 0xFF) for w in exp_words]
    if len(exp_words) * 4 == num_blocks:
        exps = []
        for word in exp_words:
            for shift in range(0, 32, 8):
                exps.append((word >> shift) & 0xFF)
        return exps[:num_blocks]

    # Fallback: unpack all bytes and trim/pad.
    exps = []
    for word in exp_words:
        for shift in range(0, 32, 8):
            exps.append((word >> shift) & 0xFF)
    if len(exps) < num_blocks:
        exps.extend([0] * (num_blocks - len(exps)))
    return exps[:num_blocks]


def compare_stage_dump(name, cur_dump, ref_dump, max_show=10):
    """Compare two stage dumps.

    1) Exact mode check (same shape + same ordered values)
    2) Fallback set-based check on unique vectors (timing-insensitive)
    """
    if cur_dump is None:
        print(f"   {name}: current dump missing")
        return False
    if ref_dump is None:
        print(f"   {name}: reference dump missing")
        return False

    cur_lines = len(cur_dump)
    ref_lines = len(ref_dump)
    if cur_lines == 0 or ref_lines == 0:
        print(f"   {name}: empty dump(s)")
        return False

    cur_w = len(cur_dump[0])
    ref_w = len(ref_dump[0])
    line_cnt = min(cur_lines, ref_lines)
    val_cnt = min(cur_w, ref_w)

    mism = 0
    shown = 0
    for i in range(line_cnt):
        a = cur_dump[i]
        b = ref_dump[i]
        for j in range(val_cnt):
            if a[j] != b[j]:
                mism += 1
                if shown < max_show:
                    print(f"     {name}[line={i},idx={j}]: got 0x{a[j]:04x} exp 0x{b[j]:04x}")
                    shown += 1

    same_shape = (cur_lines == ref_lines) and (cur_w == ref_w)
    if mism == 0 and same_shape:
        print(f"   {name}: PASS (exact ordered match to reference)")
        return True

    if not same_shape:
        print(f"   {name}: shape differs (cur={cur_lines}x{cur_w}, ref={ref_lines}x{ref_w})")

    # Timing-insensitive fallback: compare unique vectors (trim to common width)
    cur_set = {tuple(line[:val_cnt]) for line in cur_dump}
    ref_set = {tuple(line[:val_cnt]) for line in ref_dump}
    only_cur = cur_set - ref_set
    only_ref = ref_set - cur_set

    if not only_cur and not only_ref:
        print(f"   {name}: PASS (same unique vectors as reference; ordering/count differ)")
        return True

    inter = len(cur_set & ref_set)
    union = len(cur_set | ref_set)
    jacc = (100.0 * inter / union) if union else 100.0
    print(f"   {name}: FAIL (unique-vector mismatch, Jaccard={jacc:.2f}%)")
    print(f"     unique only in current: {len(only_cur)}")
    print(f"     unique only in ref    : {len(only_ref)}")
    return False


def compare_ordered_blocks(name, actual, expected, elem_bits=16, max_show=8):
    """Exact ordered compare of 2D blocks, trimming only for reporting mismatches."""
    if actual is None:
        print(f"   {name}: current dump missing")
        return False
    if expected is None:
        print(f"   {name}: expected data missing")
        return False
    if not actual or not expected:
        print(f"   {name}: empty data")
        return False

    actual_rows = len(actual)
    expected_rows = len(expected)
    actual_w = len(actual[0])
    expected_w = len(expected[0])
    row_cnt = min(actual_rows, expected_rows)
    col_cnt = min(actual_w, expected_w)
    fmt_w = max(2, elem_bits // 4)

    mismatches = 0
    shown = 0
    for i in range(row_cnt):
        for j in range(col_cnt):
            if actual[i][j] != expected[i][j]:
                mismatches += 1
                if shown < max_show:
                    print(
                        f"     {name}[row={i},idx={j}]: got 0x{actual[i][j]:0{fmt_w}x} "
                        f"exp 0x{expected[i][j]:0{fmt_w}x}"
                    )
                    shown += 1

    same_shape = (actual_rows == expected_rows) and (actual_w == expected_w)
    if mismatches == 0 and same_shape:
        print(f"   {name}: PASS ({actual_rows}x{actual_w} exact match)")
        return True

    print(f"   {name}: FAIL")
    if not same_shape:
        print(f"     shape differs (cur={actual_rows}x{actual_w}, exp={expected_rows}x{expected_w})")
    print(f"     mismatches (common region): {mismatches}")
    return False


def compare_scalar_sequence(name, actual, expected, elem_bits=8, max_show=8):
    """Exact ordered compare of scalar sequences."""
    if actual is None:
        print(f"   {name}: current dump missing")
        return False
    if expected is None:
        print(f"   {name}: expected data missing")
        return False
    if not actual or not expected:
        print(f"   {name}: empty data")
        return False

    count = min(len(actual), len(expected))
    fmt_w = max(2, elem_bits // 4)
    mismatches = 0
    shown = 0
    for i in range(count):
        if actual[i] != expected[i]:
            mismatches += 1
            if shown < max_show:
                print(
                    f"     {name}[{i}]: got 0x{actual[i]:0{fmt_w}x} "
                    f"exp 0x{expected[i]:0{fmt_w}x}"
                )
                shown += 1

    same_len = len(actual) == len(expected)
    if mismatches == 0 and same_len:
        print(f"   {name}: PASS ({len(actual)} exact match)")
        return True

    print(f"   {name}: FAIL")
    if not same_len:
        print(f"     length differs (cur={len(actual)}, exp={len(expected)})")
    print(f"     mismatches (common region): {mismatches}")
    return False


def is_reference_stale(input_files, ref_files):
    """Return (stale, reason) if any input file is newer than any reference file."""
    existing_inputs = [p for p in input_files if os.path.exists(p)]
    existing_refs = [p for p in ref_files if os.path.exists(p)]
    if not existing_inputs or not existing_refs:
        return False, ""

    newest_input = max(existing_inputs, key=os.path.getmtime)
    oldest_ref = min(existing_refs, key=os.path.getmtime)
    if os.path.getmtime(newest_input) > os.path.getmtime(oldest_ref):
        return True, f"newer inputs detected (latest input: {os.path.basename(newest_input)}, oldest ref: {os.path.basename(oldest_ref)})"
    return False, ""


def fp16_to_float(bits):
    return float(np.array([bits & 0xFFFF], dtype=np.uint16).view(np.float16)[0])


def float_to_fp16(val):
    return int(np.array([val], dtype=np.float16).view(np.uint16)[0])


# ── Data loading ─────────────────────────────────────────────────

def load_fp16_inputs(header_dir, M, N, K):
    """Load FP16 baseline inputs. Returns (x_fp16, w_fp16, y_fp16) as 2D lists."""
    x_flat = parse_c_header_array(os.path.join(header_dir, 'x_input.h'))
    w_flat = parse_c_header_array(os.path.join(header_dir, 'w_input.h'))
    y_flat = parse_c_header_array(os.path.join(header_dir, 'y_input.h'))

    print(f"   X: {len(x_flat)} uint16 values (need {M*N})")
    print(f"   W: {len(w_flat)} uint16 values (need {N*K})")
    print(f"   Y: {len(y_flat)} uint16 values (need {M*K})")

    x_fp16 = [x_flat[r*N:(r+1)*N] for r in range(M)]
    w_fp16 = [w_flat[r*K:(r+1)*K] for r in range(N)]
    y_fp16 = [y_flat[r*K:(r+1)*K] for r in range(M)]
    return x_fp16, w_fp16, y_fp16


def load_fp16_golden(header_dir, M, K):
    """Load pre-computed FP16 golden from golden.h (uint32_t packed pairs)."""
    packed = parse_c_header_array(os.path.join(header_dir, 'golden.h'))
    fp16_flat = unpack_fp16_from_32bit(packed)
    print(f"   Golden: {len(fp16_flat)} FP16 values (need {M*K})")
    return [fp16_flat[r*K:(r+1)*K] for r in range(M)]


def load_mx_inputs(header_dir, M, N, K, block_size):
    """Load MX inputs, decode to FP16. Returns (x_fp16, w_fp16, y_fp16) as 2D lists."""
    from mx_fp_golden import mxfp8_decode_bits

    x_packed = parse_c_header_array(os.path.join(header_dir, 'x_input_mx.h'))
    x_fp8 = unpack_fp8_from_16bit(x_packed)
    x_exp_packed = parse_c_header_array(os.path.join(header_dir, 'x_exp_mx.h'))
    x_exp = unpack_exponents_8bit(x_exp_packed)
    print(f"   X: {len(x_fp8)} FP8 values, {len(x_exp)} exponents")

    w_packed = parse_c_header_array(os.path.join(header_dir, 'w_input_mx.h'))
    w_fp8 = unpack_fp8_from_16bit(w_packed)
    w_exp_packed = parse_c_header_array(os.path.join(header_dir, 'w_exp_mx.h'))
    w_exp = unpack_exponents_8bit(w_exp_packed)
    print(f"   W: {len(w_fp8)} FP8 values, {len(w_exp)} exponents")

    y_flat = parse_c_header_array(os.path.join(header_dir, 'y_input.h'))
    print(f"   Y: {len(y_flat)} FP16 values")

    def decode_matrix(fp8_values, exponents, rows, cols):
        total = rows * cols
        fp16_flat = []
        num_blocks = (total + block_size - 1) // block_size
        for blk in range(num_blocks):
            exp = exponents[blk] if blk < len(exponents) else 0x7F
            for lane in range(block_size):
                idx = blk * block_size + lane
                if idx < total:
                    fp16_flat.append(mxfp8_decode_bits(fp8_values[idx], exp))
        return [fp16_flat[r*cols:(r+1)*cols] for r in range(rows)]

    print("   Decoding MX to FP16...")
    x_fp16 = decode_matrix(x_fp8, x_exp, M, N)
    w_fp16 = decode_matrix(w_fp8, w_exp, N, K)
    y_fp16 = [y_flat[r*K:(r+1)*K] for r in range(M)]
    return x_fp16, w_fp16, y_fp16


def load_expected_mx_blocks(header_dir, M, N, K, block_size):
    """Load MX headers as expected block streams for decoder ingress."""
    x_words = parse_c_header_array(os.path.join(header_dir, 'x_input_mx.h'))
    x_fp8 = unpack_fp8_from_16bit(x_words)
    x_blocks = chunk_values(x_fp8[:M * N], block_size, pad=True)
    x_exp_words = parse_c_header_array(os.path.join(header_dir, 'x_exp_mx.h'))
    x_exps = expand_exp_words(x_exp_words, len(x_blocks))

    w_words = parse_c_header_array(os.path.join(header_dir, 'w_input_mx.h'))
    w_fp8 = unpack_fp8_from_16bit(w_words)
    w_blocks = chunk_values(w_fp8[:N * K], block_size, pad=True)
    w_exp_words = parse_c_header_array(os.path.join(header_dir, 'w_exp_mx.h'))
    w_exps = expand_exp_words(w_exp_words, len(w_blocks))

    return {
        'X': {'blocks': x_blocks, 'exps': x_exps},
        'W': {'blocks': w_blocks, 'exps': w_exps},
    }


def build_expected_decoder_sequence(targets, expected_inputs):
    """Interleave X/W MX blocks to match the actual decoder target log."""
    x_idx = 0
    w_idx = 0
    seq = []
    for target in targets:
        if target == 'X':
            seq.append({
                'target': 'X',
                'fp8': expected_inputs['X']['blocks'][x_idx],
                'exp': expected_inputs['X']['exps'][x_idx],
            })
            x_idx += 1
        elif target == 'W':
            seq.append({
                'target': 'W',
                'fp8': expected_inputs['W']['blocks'][w_idx],
                'exp': expected_inputs['W']['exps'][w_idx],
            })
            w_idx += 1
    return seq


# ── Golden GEMM ──────────────────────────────────────────────────

def golden_gemm_fp16(x_bits, w_bits, y_bits, M, N, K):
    """
    Compute Z = X*W + Y using bittrue FMA.
    All inputs are 2D lists of FP16 bit patterns.
    Returns [M][K] FP16 bit patterns.
    """
    z = []
    for m in range(M):
        z_row = []
        for k in range(K):
            acc = fp16_to_float(y_bits[m][k])
            for n in range(N):
                acc = bittrue_fma(
                    fp16_to_float(x_bits[m][n]),
                    fp16_to_float(w_bits[n][k]),
                    acc
                )
            z_row.append(float_to_fp16(acc))
        z.append(z_row)
        if (m + 1) % 8 == 0:
            print(f"  GEMM row {m+1}/{M} done")
    return z


# ── Comparison ───────────────────────────────────────────────────

def compare_z_output(z_dump, z_golden, M, K, AW, max_show=30):
    """Compare Z engine dump against golden, trying both interpretations."""
    num_lines = len(z_dump)
    vals_per_line = len(z_dump[0])
    got_values = num_lines * vals_per_line
    exp_a_values = min(num_lines, K) * min(vals_per_line, M)
    exp_b_values = min(num_lines, M) * min(vals_per_line, K)
    print(f"\n5. Comparing Z engine output ({num_lines} lines x {vals_per_line} values)")
    print(f"   Full GEMM matrix shape: {M}x{K} = {M*K} values")
    print(f"   Stream dump values: {got_values}")
    print(f"   Comparable values: A={exp_a_values}, B={exp_b_values}")

    # Check for duplicate lines
    dup_groups = {}
    for i, line in enumerate(z_dump):
        key = tuple(line)
        dup_groups.setdefault(key, []).append(i)
    for key, indices in dup_groups.items():
        if len(indices) > 1:
            print(f"   WARNING: Z output lines {indices} are IDENTICAL")

    # Interpretation A: each line = one K-column (vals_per_line M-rows)
    print(f"\n   [A] Each line = one K-column, {vals_per_line} M-rows:")
    err_a = 0
    for k_idx, z_line in enumerate(z_dump):
        for m_idx, z_val in enumerate(z_line):
            if m_idx < M and k_idx < K:
                expected = z_golden[m_idx][k_idx]
                if z_val != expected:
                    err_a += 1
                    if err_a <= max_show:
                        print(f"     Z[m={m_idx},k={k_idx}]: got 0x{z_val:04x} ({fp16_to_float(z_val):10.4f})"
                              f"  exp 0x{expected:04x} ({fp16_to_float(expected):10.4f})")
    if err_a > max_show:
        print(f"     ... and {err_a - max_show} more")
    print(f"   [A] {'PASS' if err_a == 0 else f'FAIL ({err_a} mismatches)'}")

    # Interpretation B: each line = one M-row (vals_per_line K-columns)
    print(f"\n   [B] Each line = one M-row, {vals_per_line} K-columns:")
    err_b = 0
    for m_idx, z_line in enumerate(z_dump):
        for k_idx, z_val in enumerate(z_line):
            if m_idx < M and k_idx < K:
                expected = z_golden[m_idx][k_idx]
                if z_val != expected:
                    err_b += 1
                    if err_b <= max_show:
                        print(f"     Z[m={m_idx},k={k_idx}]: got 0x{z_val:04x} ({fp16_to_float(z_val):10.4f})"
                              f"  exp 0x{expected:04x} ({fp16_to_float(expected):10.4f})")
    if err_b > max_show:
        print(f"     ... and {err_b - max_show} more")
    print(f"   [B] {'PASS' if err_b == 0 else f'FAIL ({err_b} mismatches)'}")

    return err_a, err_b, min(err_a, err_b)


def analyze_x_buffer(x_dump, x_fp16, AW, AH, N):
    """Analyze X buffer dumps against golden X matrix."""
    print(f"\n6. X buffer analysis ({len(x_dump)} snapshots)")
    vals_per_line = len(x_dump[0])
    print(f"   Values per snapshot: {vals_per_line} ({AW} rows x {AH} cols = {AW*AH})")

    if len(x_dump) < AH:
        print(f"   Not enough snapshots for steady-state analysis")
        return

    steady_idx = AH - 1
    steady_line = x_dump[steady_idx]
    nz = sum(1 for v in steady_line if v != 0)
    print(f"   First steady-state at snapshot {steady_idx}: {nz}/{vals_per_line} non-zero")

    x_buf = []
    for w in range(AW):
        row = steady_line[w * AH:(w + 1) * AH]
        x_buf.append(row)

    print(f"   X_buf[0][0:8] = {['0x%04x' % v for v in x_buf[0][:8]]}")
    print(f"   X golden[0][0:8] = {['0x%04x' % v for v in x_fp16[0][:8]]}")

    # Compare forward order
    errors = 0
    for h in range(min(AH, N)):
        if x_buf[0][h] != x_fp16[0][h]:
            errors += 1
    if errors == 0:
        print(f"   X buffer row 0 vs golden X[0][0:{AH}]: PASS")
    else:
        print(f"   X buffer row 0 vs golden X[0][0:{AH}]: {errors}/{min(AH,N)} mismatches")
        for h in range(min(AH, N)):
            buf_val = x_buf[0][h]
            golden_val = x_fp16[0][h]
            if buf_val != golden_val:
                print(f"     h={h:2d}: buf=0x{buf_val:04x} golden=0x{golden_val:04x}")
                if h > 10:
                    print(f"     ...")
                    break


def analyze_w_buffer(w_dump, w_fp16, AH, N, K):
    """Analyze W buffer dumps against golden W matrix."""
    print(f"\n7. W buffer analysis ({len(w_dump)} snapshots)")
    vals_per_line = len(w_dump[0])
    print(f"   Values per snapshot: {vals_per_line}")

    if len(w_dump) < AH:
        print(f"   Not enough snapshots for steady-state analysis")
        return

    steady_idx = AH - 1
    w_buf = w_dump[steady_idx]
    nz = sum(1 for v in w_buf if v != 0)
    print(f"   First steady-state at snapshot {steady_idx}: {nz}/{vals_per_line} non-zero")
    print(f"   W_buf[0:8] = {['0x%04x' % v for v in w_buf[:8]]}")

    # Try W column 0: W[n][0] for n=0..AH-1
    w_col0 = [w_fp16[n][0] for n in range(min(AH, N))]
    col_errors = sum(1 for h in range(min(AH, len(w_buf))) if w_buf[h] != (w_col0[h] if h < len(w_col0) else 0))
    print(f"   W buf vs golden W[:,0] (column 0): {col_errors} mismatches")

    # Try W row 0: W[0][k] for k=0..AH-1
    row_errors = sum(1 for h in range(min(AH, K)) if w_buf[h] != (w_fp16[0][h] if h < len(w_fp16[0]) else 0))
    print(f"   W buf vs golden W[0,:] (row 0): {row_errors} mismatches")

    # Show best match details
    best = min(col_errors, row_errors)
    if best > 0:
        label, ref = ("W[:,0]", w_col0) if col_errors <= row_errors else ("W[0,:]", w_fp16[0][:AH])
        print(f"\n   Detailed W buf vs {label}:")
        shown = 0
        for h in range(min(AH, len(w_buf))):
            golden_val = ref[h] if h < len(ref) else 0
            if w_buf[h] != golden_val and shown < 10:
                print(f"     h={h:2d}: buf=0x{w_buf[h]:04x} golden=0x{golden_val:04x}")
                shown += 1


def analyze_w_sequence_mapping(w_dump, w_fp16, AH, N, K, max_show=12):
    """Infer which W coordinates best explain each dumped W vector.

    Tries several hypotheses:
      - col:      vec[h] = W[row_base+h][k]
      - col_rev:  vec[h] = W[row_base+(AH-1-h)][k]
      - row:      vec[h] = W[k][row_base+h]
      - row_rev:  vec[h] = W[k][row_base+(AH-1-h)]
    """
    print(f"\n8. W sequence mapping analysis ({len(w_dump)} snapshots)")
    row_bases = list(range(0, N, AH))
    if not row_bases:
        row_bases = [0]

    def expected_vec(mode, row_base, k):
        out = []
        for h in range(AH):
            if mode == 'col':
                r = row_base + h
                c = k
            elif mode == 'col_rev':
                r = row_base + (AH - 1 - h)
                c = k
            elif mode == 'row':
                r = k
                c = row_base + h
            else:  # row_rev
                r = k
                c = row_base + (AH - 1 - h)

            if 0 <= r < N and 0 <= c < K:
                out.append(w_fp16[r][c])
            else:
                out.append(0)
        return out

    modes = ['col', 'col_rev', 'row', 'row_rev']
    best = []
    mode_hist = {m: 0 for m in modes}
    perfect = 0

    for s_idx, vec in enumerate(w_dump):
        best_item = None
        for mode in modes:
            k_max = K if mode.startswith('col') else min(N, K)
            for row_base in row_bases:
                for k in range(k_max):
                    exp = expected_vec(mode, row_base, k)
                    mism = sum(1 for a, b in zip(vec, exp) if a != b)
                    if best_item is None or mism < best_item[0]:
                        best_item = (mism, mode, row_base, k)
                        if mism == 0:
                            break
                if best_item[0] == 0:
                    break
            if best_item[0] == 0:
                break

        best.append(best_item)
        mode_hist[best_item[1]] += 1
        if best_item[0] == 0:
            perfect += 1

    print(f"   Perfect snapshot matches: {perfect}/{len(w_dump)}")
    print("   Best-mode histogram: " + ", ".join(f"{m}={mode_hist[m]}" for m in modes))

    avg_mism = sum(x[0] for x in best) / max(1, len(best))
    print(f"   Average mismatches/snapshot (best hypothesis): {avg_mism:.2f} / {AH}")

    # Show first few inferred mappings
    print("   First inferred mappings (snapshot -> mode,row_base,k,mism):")
    for i, (mism, mode, row_base, k) in enumerate(best[:max_show]):
        print(f"     s{i:03d}: {mode:7s} base={row_base:2d} k={k:2d} mism={mism:2d}")

    # Check k progression on dominant mode only
    dom_mode = max(mode_hist, key=mode_hist.get)
    dom = [(idx, item) for idx, item in enumerate(best) if item[1] == dom_mode]
    if len(dom) >= 2:
        non_inc = 0
        jumps = 0
        prev_k = dom[0][1][3]
        for _, item in dom[1:]:
            k = item[3]
            if k == prev_k:
                non_inc += 1
            elif k != (prev_k + 1) % K:
                jumps += 1
            prev_k = k
        print(f"   Dominant mode '{dom_mode}' progression: repeats={non_inc}, non-seq-jumps={jumps}, samples={len(dom)}")


def analyze_mx_decoder(dec_fp16, dec_targets, x_fp16, w_fp16, M=None, N=None, K=None, block_size=32):
    """Analyze MX decoder output against golden decoded values."""
    print(f"\n8. MX Decoder analysis ({len(dec_fp16)} lines, {len(dec_targets)} targets)")

    x_dec_lines = [(i, fp16) for i, (fp16, t) in enumerate(zip(dec_fp16, dec_targets)) if t == 'X']
    w_dec_lines = [(i, fp16) for i, (fp16, t) in enumerate(zip(dec_fp16, dec_targets)) if t == 'W']
    print(f"   X decoder outputs: {len(x_dec_lines)} lines")
    print(f"   W decoder outputs: {len(w_dec_lines)} lines")

    if M is not None and N is not None and K is not None:
        exp_x_blocks = (M * N + block_size - 1) // block_size
        exp_w_blocks = (N * K + block_size - 1) // block_size
        x_ok = len(x_dec_lines) == exp_x_blocks
        w_ok = len(w_dec_lines) == exp_w_blocks
        print(f"   X decoder blocks: got {len(x_dec_lines)}, expected {exp_x_blocks} -> {'PASS' if x_ok else 'FAIL'}")
        print(f"   W decoder blocks: got {len(w_dec_lines)}, expected {exp_w_blocks} -> {'PASS' if w_ok else 'FAIL'}")

    if not x_dec_lines:
        return

    num_lanes = len(x_dec_lines[0][1])
    print(f"   Decoder lanes per output: {num_lanes}")

    # Check X decoder
    x_fp16_flat = [v for row in x_fp16 for v in row]
    x_errors = 0
    for blk_idx, (line_num, dec_vals) in enumerate(x_dec_lines):
        for lane, dec_val in enumerate(dec_vals):
            golden_idx = blk_idx * num_lanes + lane
            if golden_idx < len(x_fp16_flat) and dec_val != x_fp16_flat[golden_idx]:
                x_errors += 1
    print(f"   X decoder vs golden: {'PASS' if x_errors == 0 else f'{x_errors} mismatches'}")

    # Check W decoder
    w_fp16_flat = [v for row in w_fp16 for v in row]
    w_errors = 0
    for blk_idx, (line_num, dec_vals) in enumerate(w_dec_lines):
        for lane, dec_val in enumerate(dec_vals):
            golden_idx = blk_idx * num_lanes + lane
            if golden_idx < len(w_fp16_flat) and dec_val != w_fp16_flat[golden_idx]:
                w_errors += 1
    print(f"   W decoder vs golden: {'PASS' if w_errors == 0 else f'{w_errors} mismatches'}")


def analyze_mx_decoder_stages(dec_fp16, dec_targets, dec_exps, header_dir, M, N, K,
                              block_size=32, max_show=8):
    """Stage-level MX decoder ingress and egress checks."""
    from mx_fp_golden import mxfp8_decode_bits

    print(f"\n9. MX Decoder stage-by-stage")
    if dec_targets is None:
        print("   Decoder targets missing")
        return

    expected_inputs = load_expected_mx_blocks(header_dir, M, N, K, block_size)
    expected_target_count = len(expected_inputs['X']['blocks']) + len(expected_inputs['W']['blocks'])
    if len(dec_targets) != expected_target_count:
        print(f"   DECODER_TARGETS: FAIL (got {len(dec_targets)}, expected {expected_target_count})")
        return

    x_count = sum(1 for t in dec_targets if t == 'X')
    w_count = sum(1 for t in dec_targets if t == 'W')
    print(f"   DECODER_TARGETS: X={x_count} (exp {len(expected_inputs['X']['blocks'])}), "
          f"W={w_count} (exp {len(expected_inputs['W']['blocks'])})")

    expected_seq = build_expected_decoder_sequence(dec_targets, expected_inputs)
    expected_exps = [item['exp'] for item in expected_seq]
    compare_scalar_sequence("DECODER_EXPS", dec_exps, expected_exps, elem_bits=8, max_show=max_show)

    expected_decoded = []
    for item in expected_seq:
        expected_decoded.append([mxfp8_decode_bits(fp8, item['exp']) for fp8 in item['fp8']])
    compare_ordered_blocks("DECODER_FP16", dec_fp16, expected_decoded, elem_bits=16, max_show=max_show)


def analyze_z_encoder_boundary(z_dump, enc_in_rows, z_golden, max_show=8):
    """Compare the engine/Z-buffer boundary against golden and encoder input."""
    print(f"\n10. Z / Encoder boundary")

    if z_dump is not None:
        expected_z = [row[:len(z_dump[0])] for row in z_golden[:len(z_dump)]]
        compare_ordered_blocks("ENGINE_Z_LOW", z_dump, expected_z, elem_bits=16, max_show=max_show)
    else:
        print("   ENGINE_Z_LOW: current dump missing")

    if enc_in_rows is not None:
        expected_rows = [row[:len(enc_in_rows[0])] for row in z_golden[:len(enc_in_rows)]]
        compare_ordered_blocks("ENCODER_IN_FP16", enc_in_rows, expected_rows, elem_bits=16, max_show=max_show)
    else:
        print("   ENCODER_IN_FP16: current dump missing")

    if z_dump is not None and enc_in_rows is not None:
        enc_low = [row[:len(z_dump[0])] for row in enc_in_rows[:len(z_dump)]]
        compare_ordered_blocks("Z_TO_ENCODER_LOW", z_dump, enc_low, elem_bits=16, max_show=max_show)


def _build_transposed_square_tiles(rows, tile_dim):
    """Build complete tile_dim x tile_dim tiles and their column-major transposes."""
    if rows is None:
        return None

    out = []
    for base in range(0, len(rows), tile_dim):
        tile = rows[base:base + tile_dim]
        if len(tile) < tile_dim:
            break
        if any(len(row) < tile_dim for row in tile):
            break
        out.append({
            'base': base,
            'rows': tile,
            'cols': [[tile[row][col] for row in range(tile_dim)] for col in range(tile_dim)],
        })
    return out if out else None


def analyze_z_source_to_buffer(z_src_rows, z_q_rows, array_width, max_show=8):
    """Compare row-major engine source tiles against column-major Z-buffer output."""
    print(f"\n11. Engine -> Z-buffer transpose")

    if z_src_rows is None:
        print("   Z_ENGINE_SOURCE: current dump missing")
        return
    if z_q_rows is None:
        print("   Z_BUFFER_Q: current dump missing")
        return

    src_tiles = _build_transposed_square_tiles(z_src_rows, array_width)
    if src_tiles is None:
        print("   Z_ENGINE_TO_Z_BUFFER: unable to build complete transposed tiles")
        return

    zq_tiles = [z_q_rows[base:base + array_width]
                for base in range(0, len(z_q_rows), array_width)
                if len(z_q_rows[base:base + array_width]) == array_width]
    if not zq_tiles:
        print("   Z_ENGINE_TO_Z_BUFFER: incomplete Z-buffer tiles")
        return

    next_src_tile = 0
    tile_matches = []
    mismatch = None
    for zq_tile_idx, zq_tile in enumerate(zq_tiles):
        matched_src_tile = None
        for src_tile_idx in range(next_src_tile, len(src_tiles)):
            if zq_tile == src_tiles[src_tile_idx]['cols']:
                matched_src_tile = src_tile_idx
                tile_matches.append((zq_tile_idx, src_tile_idx))
                next_src_tile = src_tile_idx + 1
                break
        if matched_src_tile is None:
            mismatch = zq_tile_idx
            break

    if mismatch is None:
        print(f"   Z_ENGINE_TO_Z_BUFFER: PASS ({len(zq_tiles)} tiles matched by exact transpose)")
        for zq_tile_idx, src_tile_idx in tile_matches:
            src_base = src_tiles[src_tile_idx]['base']
            print(f"     z_buffer_q tile {zq_tile_idx} <- z_engine_source rows "
                  f"{src_base}:{src_base + array_width} (source tile {src_tile_idx})")
    else:
        print(f"   Z_ENGINE_TO_Z_BUFFER: FAIL (z_buffer_q tile {mismatch} has no exact source-tile match)")
        zq_tile = zq_tiles[mismatch]
        if next_src_tile < len(src_tiles):
            exp_tile = src_tiles[next_src_tile]['cols']
            shown = 0
            for row_idx, (got_row, exp_row) in enumerate(zip(zq_tile, exp_tile)):
                for col_idx, (got_val, exp_val) in enumerate(zip(got_row, exp_row)):
                    if got_val != exp_val:
                        print(f"     Z_ENGINE_TO_Z_BUFFER[tile={mismatch},row={row_idx},idx={col_idx}]: "
                              f"got 0x{got_val:04x} exp 0x{exp_val:04x}")
                        shown += 1
                        if shown >= max_show:
                            break
                if shown >= max_show:
                    break

    first_dup_pair = None
    for idx in range(len(z_src_rows) - 1):
        if z_src_rows[idx] == z_src_rows[idx + 1]:
            first_dup_pair = idx
            break

    if first_dup_pair is None:
        print("   Z_ENGINE_ROW_DUP: no identical adjacent source rows")
        return

    tile_idx = first_dup_pair // array_width
    row_in_tile = first_dup_pair % array_width
    zq_base = tile_idx * array_width
    print("   Z_ENGINE_ROW_DUP: first identical adjacent source rows")
    print(f"     rows {first_dup_pair}/{first_dup_pair + 1} "
          f"(tile {tile_idx}, row {row_in_tile}/{row_in_tile + 1})")
    print(f"     z_engine_source[{first_dup_pair}][0:8] = "
          f"{[f'0x{v:04x}' for v in z_src_rows[first_dup_pair][:8]]}")
    if zq_base < len(z_q_rows):
        print(f"     z_buffer_q_stream[{zq_base}][0:8] = "
              f"{[f'0x{v:04x}' for v in z_q_rows[zq_base][:8]]}")


def _encode_rows_to_blocks(rows, block_size):
    """Convert FP16 rows into block_size chunks for MX encoder checks."""
    from mx_fp_golden import encode_block_fp16_to_mx

    exp_out = []
    fp8_out = []
    for row in rows:
        for start in range(0, len(row), block_size):
            block = list(row[start:start + block_size])
            if len(block) < block_size:
                block.extend([0] * (block_size - len(block)))
            exp_val, fp8_vals = encode_block_fp16_to_mx(block)
            exp_out.append(exp_val)
            fp8_out.append(fp8_vals)
    return exp_out, fp8_out


def analyze_mx_encoder_stages(enc_in_rows, enc_fp8_blocks, enc_exps, z_golden,
                              block_size=32, max_show=8):
    """Stage-level MX encoder checks using golden rows and actual encoder inputs."""
    print(f"\n12. MX Encoder stage-by-stage")
    if enc_in_rows is None:
        print("   Encoder input dump missing")
        return

    golden_rows = [row[:len(enc_in_rows[0])] for row in z_golden[:len(enc_in_rows)]]
    golden_exp, golden_fp8 = _encode_rows_to_blocks(golden_rows, block_size)
    self_exp, self_fp8 = _encode_rows_to_blocks(enc_in_rows, block_size)

    compare_scalar_sequence("ENCODER_EXP_GOLDEN", enc_exps, golden_exp, elem_bits=8, max_show=max_show)
    compare_ordered_blocks("ENCODER_FP8_GOLDEN", enc_fp8_blocks, golden_fp8, elem_bits=8, max_show=max_show)
    compare_scalar_sequence("ENCODER_EXP_SELFCHK", enc_exps, self_exp, elem_bits=8, max_show=max_show)
    compare_ordered_blocks("ENCODER_FP8_SELFCHK", enc_fp8_blocks, self_fp8, elem_bits=8, max_show=max_show)


def analyze_engine_feed_trace(trace_rows, x_dump, w_dump, z_dump, enc_in_rows,
                              z_golden, array_width, max_show=8):
    """Correlate engine_feed_trace.csv with the heavier text dumps."""
    print(f"\n13. Engine feed trace correlation")
    if trace_rows is None:
        print("   Engine feed trace missing")
        return

    trace_x = [row['lanes'] for row in trace_rows if row['event'] == 'XBUFQ']
    trace_w = [row['lanes'] for row in trace_rows if row['event'] == 'WBUFQ']
    trace_z = [row['lanes'] for row in trace_rows if row['event'] == 'ZPOP']

    if x_dump is not None:
        x_summary = [[line[i * array_width] for i in range(min(8, len(line) // max(1, array_width)))]
                     for line in x_dump]
        compare_ordered_blocks("TRACE_XBUFQ", trace_x, x_summary, elem_bits=16, max_show=max_show)
    else:
        print("   TRACE_XBUFQ: current dump missing")

    if w_dump is not None:
        w_summary = [line[:8] for line in w_dump]
        compare_ordered_blocks("TRACE_WBUFQ", trace_w, w_summary, elem_bits=16, max_show=max_show)
    else:
        print("   TRACE_WBUFQ: current dump missing")

    if z_dump is not None:
        z_summary = [line[:8] for line in z_dump]
        compare_ordered_blocks("TRACE_ZPOP", trace_z, z_summary, elem_bits=16, max_show=max_show)
    else:
        print("   TRACE_ZPOP: current dump missing")

    first_pairdup = None
    for row in trace_rows:
        if row['event'] == 'ZPOP' and row['pairdup'] == 1:
            first_pairdup = row
            break

    if first_pairdup is None:
        print("   ZPOP_DUPLICATION: no pairdup-marked ZPOP rows")
        return

    print("   ZPOP_DUPLICATION: first pairdup-marked ZPOP row")
    print(f"     time={first_pairdup['time']} line_idx={first_pairdup['line_idx']} "
          f"mx_enable={first_pairdup['mx_enable']} pairdup={first_pairdup['pairdup']}")
    print(f"     trace lanes[0:8] = {[f'0x{v:04x}' for v in first_pairdup['lanes'][:8]]}")

    dup_pair = None
    lanes = first_pairdup['lanes']
    for i in range(0, len(lanes) - 1, 2):
        if lanes[i] == lanes[i + 1]:
            dup_pair = i
            break

    if dup_pair is not None:
        print(f"     first duplicated lane pair in trace: "
              f"lane{dup_pair}/lane{dup_pair + 1} = 0x{lanes[dup_pair]:04x}")
    else:
        print("     no duplicated adjacent pair found in the 8-lane trace summary")

    row_idx = first_pairdup['line_idx']
    if z_dump is not None and row_idx < len(z_dump):
        print(f"     engine_z_outputs[{row_idx}][0:8] = "
              f"{[f'0x{v:04x}' for v in z_dump[row_idx][:8]]}")
        dup_pair_dump = None
        for i in range(0, min(len(z_dump[row_idx]), 8) - 1, 2):
            if z_dump[row_idx][i] == z_dump[row_idx][i + 1]:
                dup_pair_dump = i
                break
        if dup_pair_dump is not None:
            print(f"     first duplicated lane pair in engine_z_outputs[0:8]: "
                  f"lane{dup_pair_dump}/lane{dup_pair_dump + 1} = 0x{z_dump[row_idx][dup_pair_dump]:04x}")

    if enc_in_rows is not None and row_idx < len(enc_in_rows):
        print(f"     mx_encoder_fp16_inputs[{row_idx}][0:8] = "
              f"{[f'0x{v:04x}' for v in enc_in_rows[row_idx][:8]]}")
        print(f"     mx_encoder_fp16_inputs[{row_idx}][32:40] = "
              f"{[f'0x{v:04x}' for v in enc_in_rows[row_idx][32:40]]}")

    if z_golden is not None and row_idx < len(z_golden):
        print(f"     golden_z[{row_idx}][0:8] = "
              f"{[f'0x{v:04x}' for v in z_golden[row_idx][:8]]}")
        print(f"     golden_z[{row_idx}][32:40] = "
              f"{[f'0x{v:04x}' for v in z_golden[row_idx][32:40]]}")


# ── Main ─────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Check engine dumps vs golden (FP16 or MX)")
    parser.add_argument('--mode', choices=['fp16', 'mx'], default='fp16',
                        help='fp16 = baseline FP16, mx = MX FP8+exponent path')
    parser.add_argument('--dump-dir', default='../../target/sim/vsim',
                        help='Directory with engine dump files')
    parser.add_argument('--header-dir', default='../../sw/inc',
                        help='Directory with C header files')
    parser.add_argument('-M', type=int, default=64)
    parser.add_argument('-N', type=int, default=64)
    parser.add_argument('-K', type=int, default=64)
    parser.add_argument('--block-size', type=int, default=32, help='MX block size (MX mode only)')
    parser.add_argument('--array-width', type=int, default=32, help='ARRAY_WIDTH (M tile)')
    parser.add_argument('--array-height', type=int, default=32, help='ARRAY_HEIGHT (shift depth)')
    parser.add_argument('--skip-gemm', action='store_true',
                        help='Skip GEMM computation, use pre-computed golden.h (FP16 mode only)')
    parser.add_argument('--analyze-internals', action='store_true',
                        help='Run verbose X/W/MX-internal diagnostics (can be noisy and order-dependent)')
    parser.add_argument('--stage-reference-dir', default=None,
                        help='Directory containing reference stage dumps (engine_x_inputs.txt / engine_w_inputs.txt). '
                             'If omitted, tries <dump-dir>/*_baseline.txt automatically.')
    parser.add_argument('--legacy-stage-mapping-check', action='store_true',
                        help='Also run legacy matrix-mapping checks for X/W internals (may report false mismatches for W ordering).')
    parser.add_argument('--max-stage-errors', type=int, default=8,
                        help='Maximum mismatches to print per detailed stage check')
    args = parser.parse_args()

    M, N, K = args.M, args.N, args.K
    AW, AH = args.array_width, args.array_height

    print(f"=== Engine vs Golden Check: {M}x{N} @ {N}x{K} GEMM ({args.mode.upper()} mode) ===")
    print(f"    ARRAY_WIDTH={AW}, ARRAY_HEIGHT={AH}")
    print()

    # ── 1. Load inputs ──
    print(f"1. Loading {args.mode.upper()} input data...")
    if args.mode == 'mx':
        x_fp16, w_fp16, y_fp16 = load_mx_inputs(args.header_dir, M, N, K, args.block_size)
    else:
        x_fp16, w_fp16, y_fp16 = load_fp16_inputs(args.header_dir, M, N, K)

    print(f"   X[0][0:4] = {['0x%04x' % v for v in x_fp16[0][:4]]}")
    print(f"   W[0][0:4] = {['0x%04x' % v for v in w_fp16[0][:4]]}")
    print(f"   Y[0][0:4] = {['0x%04x' % v for v in y_fp16[0][:4]]}")

    # ── 2. Get golden Z ──
    z_golden = None
    if args.mode == 'fp16' and args.skip_gemm:
        print(f"\n2. Loading pre-computed golden from golden.h...")
        z_golden = load_fp16_golden(args.header_dir, M, K)
    else:
        print(f"\n2. Computing golden GEMM ({M}x{N} @ {N}x{K})...")
        z_golden = golden_gemm_fp16(x_fp16, w_fp16, y_fp16, M, N, K)

    print(f"   Z[0][0:4] = {['0x%04x' % v for v in z_golden[0][:4]]}")

    # ── 3. Load engine dumps ──
    print(f"\n3. Loading engine dump files from {args.dump_dir}...")
    z_dump = parse_engine_dump(os.path.join(args.dump_dir, 'engine_z_outputs.txt'))
    x_dump = parse_engine_dump(os.path.join(args.dump_dir, 'engine_x_inputs.txt'))
    w_dump = parse_engine_dump(os.path.join(args.dump_dir, 'engine_w_inputs.txt'))

    found = []
    for name, data in [('engine_z_outputs', z_dump), ('engine_x_inputs', x_dump), ('engine_w_inputs', w_dump)]:
        status = f"{len(data)} lines" if data else "EMPTY/MISSING"
        found.append(f"{name}: {status}")
    print(f"   {', '.join(found)}")

    # ── 4. Compare Z ──
    z_best_err = None
    if z_dump:
        err_a, err_b, z_best_err = compare_z_output(z_dump, z_golden, M, K, AW)
        if z_best_err == 0:
            print("\n4. Z RESULT: PASS (at least one stream interpretation matches golden exactly)")
        else:
            print(f"\n4. Z RESULT: FAIL (best interpretation has {z_best_err} mismatches)")
    else:
        print(f"\n4. No Z output data to compare (file empty or missing)")

    # ── 5. X buffer ──
    if args.analyze_internals:
        print("\n5. Stage checks (X/W)")
        ref_dir = args.stage_reference_dir
        if ref_dir is None:
            ref_x_path = os.path.join(args.dump_dir, 'engine_x_inputs_baseline.txt')
            ref_w_path = os.path.join(args.dump_dir, 'engine_w_inputs_baseline.txt')
        else:
            ref_x_path = os.path.join(ref_dir, 'engine_x_inputs.txt')
            ref_w_path = os.path.join(ref_dir, 'engine_w_inputs.txt')

        ref_x_dump = parse_engine_dump(ref_x_path)
        ref_w_dump = parse_engine_dump(ref_w_path)

        input_files = [
            os.path.join(args.header_dir, 'x_input.h'),
            os.path.join(args.header_dir, 'w_input.h'),
            os.path.join(args.header_dir, 'y_input.h'),
            os.path.join(args.header_dir, 'x_input_mx.h'),
            os.path.join(args.header_dir, 'w_input_mx.h'),
            os.path.join(args.header_dir, 'x_exp_mx.h'),
            os.path.join(args.header_dir, 'w_exp_mx.h'),
        ]
        stale_ref, stale_reason = is_reference_stale(input_files, [ref_x_path, ref_w_path])

        if ref_x_dump is not None or ref_w_dump is not None:
            print(f"   Using reference dumps:")
            print(f"     X ref: {ref_x_path}")
            print(f"     W ref: {ref_w_path}")
            if stale_ref:
                print(f"   Stage reference appears stale: {stale_reason}")
                print("   X_STAGE: INCONCLUSIVE (refresh baseline reference dumps)")
                print("   W_STAGE: INCONCLUSIVE (refresh baseline reference dumps)")
            else:
                compare_stage_dump("X_STAGE", x_dump, ref_x_dump)
                compare_stage_dump("W_STAGE", w_dump, ref_w_dump)
        else:
            print("   No reference stage dumps found; falling back to structural checks only.")

        if args.legacy_stage_mapping_check:
            if x_dump:
                analyze_x_buffer(x_dump, x_fp16, AW, AH, N)
            else:
                print(f"\n5. No X buffer data to compare")

    # ── 6. W buffer ──
    if args.analyze_internals and args.legacy_stage_mapping_check:
        if w_dump:
            analyze_w_buffer(w_dump, w_fp16, AH, N, K)
            analyze_w_sequence_mapping(w_dump, w_fp16, AH, N, K)
        else:
            print(f"\n6. No W buffer data to compare")

    # ── 7. MX decoder (MX mode only) ──
    if args.mode == 'mx' and args.analyze_internals:
        dec_fp16 = parse_engine_dump(os.path.join(args.dump_dir, 'mx_decoder_fp16_outputs.txt'))
        dec_targets = parse_target_dump(os.path.join(args.dump_dir, 'mx_decoder_targets.txt'))
        dec_exps = parse_hex_scalar_lines(os.path.join(args.dump_dir, 'mx_decoder_exponents.txt'))
        z_src_rows = parse_engine_dump(os.path.join(args.dump_dir, 'z_engine_source.txt'))
        z_q_rows = parse_engine_dump(os.path.join(args.dump_dir, 'z_buffer_q_stream.txt'))
        enc_in_rows = parse_packed_hex_blocks(os.path.join(args.dump_dir, 'mx_encoder_fp16_inputs.txt'), 16)
        enc_fp8_blocks = parse_packed_hex_blocks(os.path.join(args.dump_dir, 'mx_encoder_fp8_outputs.txt'), 8)
        enc_exps = parse_hex_scalar_lines(os.path.join(args.dump_dir, 'mx_encoder_exponents.txt'))
        feed_trace = parse_engine_feed_trace(os.path.join(args.dump_dir, 'engine_feed_trace.csv'))

        if dec_fp16 and dec_targets:
            analyze_mx_decoder(dec_fp16, dec_targets, x_fp16, w_fp16,
                              M=M, N=N, K=K, block_size=args.block_size)
            analyze_mx_decoder_stages(dec_fp16, dec_targets, dec_exps, args.header_dir,
                                      M, N, K, block_size=args.block_size,
                                      max_show=args.max_stage_errors)
        else:
            print(f"\n7. No MX decoder data to compare")

        analyze_z_encoder_boundary(z_dump, enc_in_rows, z_golden, max_show=args.max_stage_errors)
        analyze_z_source_to_buffer(z_src_rows, z_q_rows, AW, max_show=args.max_stage_errors)
        analyze_mx_encoder_stages(enc_in_rows, enc_fp8_blocks, enc_exps, z_golden,
                                  block_size=args.block_size, max_show=args.max_stage_errors)
        analyze_engine_feed_trace(feed_trace, x_dump, w_dump, z_dump, enc_in_rows, z_golden, AW,
                                  max_show=args.max_stage_errors)

    if not args.analyze_internals:
        print("\n   Note: internal X/W/decoder checks are skipped by default.")
        print("         Use --analyze-internals for deep diagnostics.")
    else:
        print("\n   Note: W stage is checked against reference dumps by default.")
        print("         Use --legacy-stage-mapping-check only for exploratory matrix-order debugging.")

    print(f"\n=== Done ===")
    return 0 if (z_best_err == 0) else 1


if __name__ == '__main__':
    sys.exit(main())
