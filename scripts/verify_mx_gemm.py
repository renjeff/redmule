#!/usr/bin/env python3
"""
Verify MX GEMM: Compare RTL MX output against golden model GEMM on MX inputs.

Reads:
  - mx_x_data.txt, mx_x_exp.txt (X matrix in MX format)
  - mx_w_data.txt, mx_w_exp.txt (W matrix in MX format)
  - mx_encoder_fp8_output.txt (RTL output)
  
Computes:
  1. Decode MX inputs to FP16
  2. Perform FP16 GEMM: Z = X @ W
  3. Encode result back to MX
  4. Compare with RTL output
"""

import argparse
import os
import re
import sys
from pathlib import Path
import numpy as np

# Add paths for imports
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GOLDEN_DIR = os.path.join(SCRIPT_DIR, "..", "golden-model")
sys.path.insert(0, os.path.join(GOLDEN_DIR, "MX"))
sys.path.insert(0, os.path.join(GOLDEN_DIR, "common"))

from mx_fp_golden import mxfp8_decode_bits, encode_block_fp16_to_mx
from redmule_fma import matrix_multiply_with_bittrue_fma


def load_mx_data(data_path, exp_path, lanes_per_block=32, exp_format='compact-32bit'):
    """Load MX data and exponent files, return decoded FP16 values and block count.

    exp_format:
      'compact-8bit'  -- X stream: 4 exponents packed per 32-bit word (8 hex chars/line).
                         Each line is unpacked as four individual 8-bit exponents.
      'compact-32bit' -- W stream: 1 exponent replicated into a 32-bit word per line.
                         Each line yields one exponent (low byte taken).
    """
    # Read FP8 data - each line is a packed 16-bit word (2 FP8 per word).
    # Packing: packed_word = (high_fp8 << 8) | low_fp8
    # So bytes are stored high-first in the hex string: "HH LL" → low_fp8=0xLL, high_fp8=0xHH.
    fp8_values = []
    with open(data_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('//'):
                # Each 4-char group is one packed 16-bit word: high byte then low byte.
                for i in range(0, len(line), 4):
                    chunk = line[i:i+4]
                    if len(chunk) == 4:
                        word = int(chunk, 16)
                        low_fp8  = word & 0xFF          # lane N+0 (first original FP8)
                        high_fp8 = (word >> 8) & 0xFF   # lane N+1 (second original FP8)
                        fp8_values.append(low_fp8)
                        fp8_values.append(high_fp8)
                    elif len(chunk) == 2:
                        fp8_values.append(int(chunk, 16))

    # Read exponents according to format
    exponents = []
    with open(exp_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            word = int(line, 16)
            if exp_format == 'compact-8bit':
                # 4 exponents packed in one 32-bit word, LSB first
                exponents.append((word >>  0) & 0xFF)
                exponents.append((word >>  8) & 0xFF)
                exponents.append((word >> 16) & 0xFF)
                exponents.append((word >> 24) & 0xFF)
            else:
                # compact-32bit: replicated exponent, take low byte
                exponents.append(word & 0xFF)

    # Decode to FP16
    fp16_values = []
    for block_idx, exp in enumerate(exponents):
        for lane in range(lanes_per_block):
            idx = block_idx * lanes_per_block + lane
            if idx < len(fp8_values):
                fp8 = fp8_values[idx]
                fp16 = mxfp8_decode_bits(fp8, exp)
                fp16_values.append(fp16)

    return fp16_values, len(exponents), len(fp8_values)


def fp16_bits_to_float(bits):
    """Convert FP16 bit pattern to Python float."""
    arr = np.array([bits], dtype=np.uint16)
    return float(arr.view(np.float16)[0])


def float_to_fp16_bits(val):
    """Convert Python float to FP16 bit pattern."""
    arr = np.array([val], dtype=np.float16)
    return int(arr.view(np.uint16)[0])


def perform_gemm_fp16(x_bits, w_bits, y_bits, M, N, K):
    """Perform GEMM using RedMulE FMA golden model."""
    # Convert to float
    X = np.array([fp16_bits_to_float(b) for b in x_bits], dtype=np.float16).reshape(M, N)
    W = np.array([fp16_bits_to_float(b) for b in w_bits], dtype=np.float16).reshape(N, K)
    Y = np.array([fp16_bits_to_float(b) for b in y_bits], dtype=np.float16).reshape(M, K)

    # Perform GEMM using RedMulE FMA
    Z = matrix_multiply_with_bittrue_fma(X, W, Y)
    
    # Convert back to bits
    Z_bits = [float_to_fp16_bits(float(z)) for z in Z.flatten()]
    
    return Z_bits


def encode_to_mx(fp16_values, lanes_per_block=32):
    """Encode FP16 values to MX format."""
    mx_values = []
    mx_exponents = []
    
    for i in range(0, len(fp16_values), lanes_per_block):
        block = fp16_values[i:i+lanes_per_block]
        # Pad if needed
        while len(block) < lanes_per_block:
            block.append(0)
        
        exp, fp8_vals = encode_block_fp16_to_mx(block)
        mx_values.extend(fp8_vals)
        mx_exponents.append(exp)
    
    return mx_values, mx_exponents


def load_rtl_output(output_path, lanes_per_block=32, num_blocks=None):
    """Load MX encoder output file - packed hex format like inputs."""
    all_lines = []
    with open(output_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('//') and not line.startswith('#'):
                all_lines.append(line)
    
    # If num_blocks specified, take the last N blocks (most recent output)
    if num_blocks is not None and len(all_lines) > num_blocks:
        print(f"   Note: File has {len(all_lines)} lines, using last {num_blocks} blocks")
        all_lines = all_lines[-num_blocks:]
    
    # Debug: check line lengths
    line_lengths = [len(line) for line in all_lines]
    values_per_line = [len(line)//2 for line in all_lines]
    print(f"   Debug: Line lengths (hex chars): min={min(line_lengths)}, max={max(line_lengths)}, avg={sum(line_lengths)/len(line_lengths):.1f}")
    print(f"   Debug: Values per line: min={min(values_per_line)}, max={max(values_per_line)}, avg={sum(values_per_line)/len(values_per_line):.1f}")
    
    fp8_values = []
    for line in all_lines:
        # Each line is hex string with FP8 values (2 hex chars per value)
        for i in range(0, len(line), 2):
            if i+1 < len(line):
                fp8 = int(line[i:i+2], 16)
                fp8_values.append(fp8)
    return fp8_values


def load_rtl_memory(memory_path, num_words):
    """Load RTL memory dump (32-bit words in hex format)."""
    fp8_values = []
    with open(memory_path) as f:
        for idx, line in enumerate(f):
            if idx >= num_words:
                break
            line = line.strip()
            if line:
                # Each line is a 32-bit word in hex (8 hex chars = 4 bytes = 4 FP8 values)
                word = int(line, 16)
                # Extract 4 bytes (little-endian)
                for byte_idx in range(4):
                    fp8 = (word >> (byte_idx * 8)) & 0xFF
                    fp8_values.append(fp8)
    return fp8_values


def parse_fp16_header(path):
    text = Path(path).read_text()
    return [int(val, 16) for val in re.findall(r'0x[0-9a-fA-F]+', text)]


def load_fp16_dump(path):
    """Parse a plain-text FP16 dump (hex values separated by whitespace)."""
    values = []
    with open(path) as f:
        for line in f:
            for token in line.strip().split():
                if len(token) >= 1:
                    values.append(int(token, 16))
    return values


def main():
    parser = argparse.ArgumentParser(description="Verify MX GEMM computation")
    parser.add_argument("--mx-dir", default="golden-model/MX", help="Directory with MX input files")
    parser.add_argument("--output-dir", default="target/sim/vsim", help="Directory with RTL output")
    parser.add_argument("--x-exp-format", default="compact-8bit",
                        choices=["compact-8bit", "compact-32bit"],
                        help="X exponent file format: compact-8bit packs 4 exponents per 32-bit word (default)")
    parser.add_argument("--w-exp-format", default="compact-32bit",
                        choices=["compact-8bit", "compact-32bit"],
                        help="W exponent file format: compact-32bit stores 1 replicated exponent per 32-bit word (default)")
    parser.add_argument("--output-file", default="mx_y_memory.txt", help="RTL MX memory dump file")
    parser.add_argument("--rtl-fp16-file", default=None, help="Optional FP16 dump (e.g. engine_z_outputs.txt)")
    parser.add_argument("-M", type=int, default=4, help="Matrix M dimension")
    parser.add_argument("-N", type=int, default=4, help="Matrix N dimension")
    parser.add_argument("-K", type=int, default=4, help="Matrix K dimension")
    parser.add_argument("--lanes", type=int, default=32, help="FP16 values per MX block")
    parser.add_argument("--output-width", type=int, default=128, help="FP8 values per output line")
    parser.add_argument("--max-errors", type=int, default=20, help="Maximum mismatches to print")
    parser.add_argument("--use-memory", action="store_true", default=True, help="Use memory dump instead of signal capture")
    parser.add_argument("--limit", type=int, default=None, help="Optional limit on number of output elements to compare (defaults to full M*K)")
    parser.add_argument("--x-fp16-header", type=str, default=None, help="Optional FP16 header for X (overrides MX inputs)")
    parser.add_argument("--w-fp16-header", type=str, default=None, help="Optional FP16 header for W (overrides MX inputs)")
    parser.add_argument("--y-fp16-header", type=str, default="sw/inc/y_input.h",
                        help="FP16 header for Y accumulator (default: sw/inc/y_input.h)")
    args = parser.parse_args()
    
    print(f"Verifying MX GEMM: {args.M}×{args.N} @ {args.N}×{args.K}")
    
    # Load MX inputs
    print(f"\n1. Loading inputs...")
    if args.x_fp16_header:
        x_path = args.x_fp16_header if os.path.isabs(args.x_fp16_header) else os.path.join(args.mx_dir, args.x_fp16_header)
        x_fp16 = parse_fp16_header(x_path)
        x_blocks = len(x_fp16) // args.lanes
        x_fp8_count = len(x_fp16)
        print(f"   X: {len(x_fp16)} FP16 values loaded from {x_path}")
    else:
        x_fp16, x_blocks, x_fp8_count = load_mx_data(
            os.path.join(args.mx_dir, "mx_x_data.txt"),
            os.path.join(args.mx_dir, "mx_x_exp.txt"),
            args.lanes,
            exp_format=args.x_exp_format
        )
        print(f"   X: {x_fp8_count} FP8 values, {x_blocks} blocks → {len(x_fp16)} FP16 values")

    if args.w_fp16_header:
        w_path = args.w_fp16_header if os.path.isabs(args.w_fp16_header) else os.path.join(args.mx_dir, args.w_fp16_header)
        w_fp16 = parse_fp16_header(w_path)
        w_blocks = len(w_fp16) // args.lanes
        w_fp8_count = len(w_fp16)
        print(f"   W: {len(w_fp16)} FP16 values loaded from {w_path}")
    else:
        w_fp16, w_blocks, w_fp8_count = load_mx_data(
            os.path.join(args.mx_dir, "mx_w_data.txt"),
            os.path.join(args.mx_dir, "mx_w_exp.txt"),
            args.lanes,
            exp_format=args.w_exp_format
        )
        print(f"   W: {w_fp8_count} FP8 values, {w_blocks} blocks → {len(w_fp16)} FP16 values")
    
    # Auto-detect dimensions if data doesn't match specified M,N,K
    if len(x_fp16) != args.M * args.N or len(w_fp16) != args.N * args.K:
        print(f"\n   WARNING: Data size mismatch!")
        print(f"   Expected: X={args.M}×{args.N}={args.M*args.N}, W={args.N}×{args.K}={args.N*args.K}")
        print(f"   Attempting auto-detection...")
        
        # Try to infer dimensions - assume square matrices for simplicity
        # For X (M×N): try to factor x_fp16 length
        # For W (N×K): try to factor w_fp16 length
        import math
        x_len = len(x_fp16)
        w_len = len(w_fp16)
        
        # Try common factors
        for n in range(1, min(x_len, w_len) + 1):
            if x_len % n == 0 and w_len % n == 0:
                m_test = x_len // n
                k_test = w_len // n
                if m_test > 0 and k_test > 0:
                    args.M, args.N, args.K = m_test, n, k_test
                    print(f"   Auto-detected: M={args.M}, N={args.N}, K={args.K}")
                    break
    
    # Load Y accumulator
    y_path = args.y_fp16_header if os.path.isabs(args.y_fp16_header) else args.y_fp16_header
    try:
        y_fp16 = parse_fp16_header(y_path)
        print(f"   Y: {len(y_fp16)} FP16 values loaded from {y_path}")
    except FileNotFoundError:
        print(f"   WARNING: Y header not found at {y_path}, using zeros")
        y_fp16 = [0] * (args.M * args.K)

    # Perform GEMM
    print(f"\n2. Performing FP16 GEMM...")
    z_fp16_golden = perform_gemm_fp16(x_fp16, w_fp16, y_fp16, args.M, args.N, args.K)
    print(f"   Z: {len(z_fp16_golden)} FP16 values")
    
    rtl_fp16 = None
    rtl_fp8 = None
    z_exp_golden = []

    # Encode to MX (for MX comparison fallback)
    print(f"\n3. Encoding result to MX format...")
    z_mx_golden, z_exp_golden = encode_to_mx(z_fp16_golden, args.lanes)
    print(f"   Z_MX: {len(z_mx_golden)} FP8 values ({len(z_exp_golden)} blocks)")

    # Load RTL output
    print(f"\n4. Loading RTL output from {args.output_dir}...")
    expected_values = args.M * args.K

    if args.rtl_fp16_file:
        fp16_path = args.rtl_fp16_file
        if not os.path.isabs(fp16_path):
            fp16_path = os.path.join(args.output_dir, fp16_path)
        rtl_fp16 = load_fp16_dump(fp16_path)
        print(f"   Loaded FP16 dump: {len(rtl_fp16)} values from {fp16_path}")
    else:
        output_path = os.path.join(args.output_dir, args.output_file)
        if args.use_memory or args.output_file.endswith('.txt') and 'memory' in args.output_file:
            num_words = (expected_values + 3) // 4
            rtl_fp8 = load_rtl_memory(output_path, num_words)[:expected_values]
            print(f"   Loaded from memory dump: {len(rtl_fp8)} FP8 values")
        else:
            rtl_fp8_all = load_rtl_output(output_path, args.lanes, num_blocks=None)
            if len(rtl_fp8_all) > expected_values:
                print(f"   Note: File has {len(rtl_fp8_all)} values, extracting last {expected_values} (Z output)")
                rtl_fp8 = rtl_fp8_all[-expected_values:]
            else:
                rtl_fp8 = rtl_fp8_all
        if rtl_fp8 is not None:
            print(f"   RTL Z: {len(rtl_fp8)} FP8 values ({len(rtl_fp8)//args.lanes} blocks)")
    
    # Load RTL exponents if available
    if rtl_fp16 is not None:
        print(f"\n5. Comparing FP16 outputs...")
        compare_limit = args.limit if args.limit is not None else len(z_fp16_golden)
        total = min(compare_limit, len(z_fp16_golden), len(rtl_fp16))
        errors = 0
        details = []
        for idx in range(total):
            if z_fp16_golden[idx] != rtl_fp16[idx]:
                errors += 1
                if len(details) < args.max_errors:
                    block = idx // args.lanes
                    lane = idx % args.lanes
                    details.append(
                        f"  [{idx:4d}] (block {block:2d}, lane {lane:2d}) "
                        f"Golden=0x{z_fp16_golden[idx]:04x}, RTL=0x{rtl_fp16[idx]:04x}"
                    )
        print(f"Compared {total} FP16 values. Mismatches: {errors}.")
        if errors == 0:
            print("✓ SUCCESS: Engine outputs match the GEMM golden model.")
            return 0
        print("✗ FAIL: Differences detected.")
        for line in details:
            print(line)
        if errors > args.max_errors:
            print(f"  ... and {errors - args.max_errors} more")
        return 1

    # Compare MX format as fallback
    print(f"\n5. Comparing MX outputs...")
    if rtl_fp8 is None:
        print("ERROR: No RTL FP8 data available for comparison")
        return 1

    compare_limit = args.limit if args.limit is not None else len(z_mx_golden)
    total = min(compare_limit, len(z_mx_golden), len(rtl_fp8))
    errors = 0
    error_details = []
    exact_matches = 0
    close_matches = 0  # Within 1-2 ULP

    for idx in range(total):
        golden_val = z_mx_golden[idx]
        rtl_val = rtl_fp8[idx]
        
        if golden_val == rtl_val:
            exact_matches += 1
        else:
            diff = abs(int(golden_val) - int(rtl_val))
            if diff <= 2:
                close_matches += 1
            
            errors += 1
            if len(error_details) < args.max_errors:
                block = idx // args.lanes
                lane = idx % args.lanes
                # Decode to see FP16 values
                golden_exp = z_exp_golden[block]
                # RTL exponents would need to be loaded separately
                error_details.append(
                    f"  [{idx:4d}] (block {block:2d}, lane {lane:2d}): "
                    f"Golden=0x{golden_val:02x}, RTL=0x{rtl_val:02x}, diff={diff}"
                )
    
    # Print results
    print(f"\n{'='*70}")
    print(f"RESULTS: Compared {total} FP8 values")
    print(f"{'='*70}")
    print(f"Exact matches: {exact_matches}/{total} ({100*exact_matches/total:.2f}%)")
    print(f"Close matches (diff≤2): {close_matches}/{total} ({100*close_matches/total:.2f}%)")
    print(f"Mismatches: {errors}/{total} ({100*errors/total:.2f}%)")
    
    if errors == 0:
        print("✓ SUCCESS: All values match!")
        return 0
    else:
        print(f"\nFirst {len(error_details)} mismatches:")
        for detail in error_details:
            print(detail)
        if errors > args.max_errors:
            print(f"  ... and {errors - args.max_errors} more")
        
        if close_matches > total * 0.5:
            print(f"\n⚠ Note: Many mismatches are small (diff≤2), suggesting rounding differences")
        
        return 1


if __name__ == "__main__":
    sys.exit(main())
