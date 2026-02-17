#!/usr/bin/env python3
"""
Generate MX golden output by:
1. Reading MX-encoded X and W inputs (FP8 data + exponents) from C headers
2. Decoding to FP16
3. Performing bit-true GEMM
4. Encoding result back to MX format
5. Outputting both FP8 mantissas and exponents as C headers

This ensures the golden matches exactly what the RTL should produce,
including quantization effects from MX decode/encode.

Usage:
    python3 gen_mx_golden.py \
        --x-mx-header sw/inc/x_input_mx.h \
        --x-exp-header sw/inc/x_exp_mx.h \
        --w-mx-header sw/inc/w_input_mx.h \
        --w-exp-header sw/inc/w_exp_mx.h \
        --y-header sw/inc/y_input.h \
        --output-mx-header sw/inc/golden_mx.h \
        --output-exp-header sw/inc/golden_mx_exp.h \
        -M 12 -N 16 -K 16 \
        --block-size 32
"""

import argparse
import re
import sys
import os
import numpy as np

# Add path for local imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'common'))

from mx_fp_golden import mxfp8_decode_bits, encode_block_fp16_to_mx


def parse_c_header_array(filename, expected_type='uint16_t'):
    """Parse a C header file with array and return list of integers."""
    with open(filename, 'r') as f:
        text = f.read()

    # Find all hex values in the file
    values = re.findall(r'0x[0-9a-fA-F]+', text)
    return [int(x, 16) for x in values]


def unpack_fp8_from_16bit(packed_values):
    """Unpack FP8 values from 16-bit words (2 FP8 per word, little-endian)."""
    fp8_values = []
    for word in packed_values:
        low_fp8 = word & 0xFF
        high_fp8 = (word >> 8) & 0xFF
        fp8_values.append(low_fp8)
        fp8_values.append(high_fp8)
    return fp8_values


def unpack_exponents_8bit(packed_words):
    """Unpack 8-bit exponents from 32-bit words (4 exponents per word)."""
    exponents = []
    for word in packed_words:
        for i in range(4):
            exp = (word >> (i * 8)) & 0xFF
            exponents.append(exp)
    return exponents


def unpack_exponents_32bit(packed_words):
    """Unpack 32-bit exponent vectors - each word is one exponent (replicated)."""
    # For W format, each 32-bit word contains the same exponent replicated 4x
    # Just take the lowest byte as the actual exponent
    exponents = []
    for word in packed_words:
        exp = word & 0xFF
        exponents.append(exp)
    return exponents


def decode_mx_to_fp16(fp8_values, exponents, block_size=32):
    """
    Decode MX-encoded data to FP16 bit patterns.

    Args:
        fp8_values: List of FP8 (8-bit) values
        exponents: List of shared exponents (one per block)
        block_size: Number of FP8 values per MX block

    Returns:
        List of FP16 bit patterns (16-bit integers)
    """
    fp16_values = []
    num_blocks = (len(fp8_values) + block_size - 1) // block_size

    for block_idx in range(num_blocks):
        exp = exponents[block_idx] if block_idx < len(exponents) else 0x7F

        for lane in range(block_size):
            idx = block_idx * block_size + lane
            if idx < len(fp8_values):
                fp8 = fp8_values[idx]
                fp16 = mxfp8_decode_bits(fp8, exp)
                fp16_values.append(fp16)

    return fp16_values


def fp16_bits_to_float(bits):
    """Convert FP16 bit pattern to Python float."""
    arr = np.array([bits], dtype=np.uint16)
    return float(arr.view(np.float16)[0])


def float_to_fp16_bits(val):
    """Convert Python float to FP16 bit pattern."""
    arr = np.array([val], dtype=np.float16)
    return int(arr.view(np.uint16)[0])


def perform_gemm_fp16(x_bits, w_bits, y_bits, M, N, K):
    """
    Perform GEMM using bit-true FMA: Z = X @ W + Y

    Args:
        x_bits: List of FP16 bit patterns for X (M x N matrix, row-major)
        w_bits: List of FP16 bit patterns for W (N x K matrix, row-major)
        y_bits: List of FP16 bit patterns for Y (M x K matrix, row-major)
        M, N, K: Matrix dimensions

    Returns:
        List of FP16 bit patterns for Z (M x K matrix)
    """
    # Import the bit-true FMA
    from redmule_fma import bittrue_fma

    # Convert to numpy arrays
    X = np.array([fp16_bits_to_float(b) for b in x_bits[:M*N]], dtype=np.float16).reshape(M, N)
    W = np.array([fp16_bits_to_float(b) for b in w_bits[:N*K]], dtype=np.float16).reshape(N, K)
    Y = np.array([fp16_bits_to_float(b) for b in y_bits[:M*K]], dtype=np.float16).reshape(M, K)

    # Perform GEMM with bit-true FMA
    Z = np.zeros((M, K), dtype=np.float64)
    for m in range(M):
        for k in range(K):
            acc = float(Y[m, k])
            for n in range(N):
                acc = bittrue_fma(X[m, n], W[n, k], acc)
            Z[m, k] = acc

    Z = Z.astype(np.float16)

    # Convert back to bit patterns
    z_bits = [float_to_fp16_bits(float(z)) for z in Z.flatten()]
    return z_bits


def encode_fp16_to_mx(fp16_values, block_size=32):
    """
    Encode FP16 values to MX format.

    Args:
        fp16_values: List of FP16 bit patterns
        block_size: Number of values per MX block

    Returns:
        (fp8_values, exponents) - lists of FP8 mantissas and shared exponents
    """
    fp8_values = []
    exponents = []

    for i in range(0, len(fp16_values), block_size):
        block = fp16_values[i:i+block_size]
        # Pad if needed
        while len(block) < block_size:
            block.append(0)

        exp, fp8_block = encode_block_fp16_to_mx(block)
        fp8_values.extend(fp8_block)
        exponents.append(exp)

    return fp8_values, exponents


def pack_fp8_to_32bit_words(fp8_values):
    """Pack 4 FP8 values per 32-bit word (little-endian)."""
    packed = []
    for i in range(0, len(fp8_values), 4):
        word = 0
        for j in range(4):
            if i + j < len(fp8_values):
                word |= (fp8_values[i + j] & 0xFF) << (j * 8)
        packed.append(word)
    return packed


def pack_exponents_compact_8bit(exponents):
    """Pack 4 exponents per 32-bit word (little-endian)."""
    packed = []
    for i in range(0, len(exponents), 4):
        word = 0
        for j in range(4):
            if i + j < len(exponents):
                word |= (exponents[i + j] & 0xFF) << (j * 8)
        packed.append(word)
    return packed


def write_c_header(filename, array_name, values, elem_type='uint32_t', guard_name=None):
    """Write values to a C header file."""
    if guard_name is None:
        guard_name = f"__{array_name.upper()}_H__"

    with open(filename, 'w') as f:
        f.write("// Auto-generated MX golden output\n")
        f.write(f"#ifndef {guard_name}\n")
        f.write(f"#define {guard_name}\n\n")
        f.write("#include <stdint.h>\n\n")

        f.write(f"{elem_type} {array_name}[{len(values)}] = {{\n")

        # Write 8 values per line
        for i in range(0, len(values), 8):
            line_vals = values[i:i+8]
            hex_strs = [f"0x{v:08x}" for v in line_vals]
            f.write("  " + ", ".join(hex_strs))
            if i + 8 < len(values):
                f.write(",")
            f.write("\n")

        f.write("};\n\n")
        f.write(f"#endif // {guard_name}\n")


def main():
    parser = argparse.ArgumentParser(description="Generate MX golden from MX inputs")

    # Input files
    parser.add_argument('--x-mx-header', required=True, help='X matrix MX data header (packed FP8)')
    parser.add_argument('--x-exp-header', required=True, help='X matrix exponents header')
    parser.add_argument('--w-mx-header', required=True, help='W matrix MX data header (packed FP8)')
    parser.add_argument('--w-exp-header', required=True, help='W matrix exponents header')
    parser.add_argument('--y-header', required=True, help='Y matrix header (FP16 accumulator init)')

    # Output files
    parser.add_argument('--output-mx-header', required=True, help='Output golden MX data header')
    parser.add_argument('--output-exp-header', required=True, help='Output golden exponents header')

    # Matrix dimensions
    parser.add_argument('-M', type=int, required=True, help='Matrix M dimension')
    parser.add_argument('-N', type=int, required=True, help='Matrix N (K_in) dimension')
    parser.add_argument('-K', type=int, required=True, help='Matrix K (N_out) dimension')

    # MX parameters
    parser.add_argument('--block-size', type=int, default=32, help='MX block size (default: 32)')
    parser.add_argument('--x-exp-format', choices=['8bit', '32bit'], default='8bit',
                        help='X exponent format (default: 8bit)')
    parser.add_argument('--w-exp-format', choices=['8bit', '32bit'], default='32bit',
                        help='W exponent format (default: 32bit)')

    # Output array names
    parser.add_argument('--mx-array-name', default='golden_mx', help='Array name for MX data')
    parser.add_argument('--exp-array-name', default='golden_mx_exp', help='Array name for exponents')

    args = parser.parse_args()

    print(f"Generating MX golden for {args.M}x{args.N} @ {args.N}x{args.K} GEMM")

    # 1. Load MX inputs
    print(f"\n1. Loading MX inputs...")

    # X matrix
    x_packed = parse_c_header_array(args.x_mx_header)
    x_fp8 = unpack_fp8_from_16bit(x_packed)
    print(f"   X data: {len(x_packed)} packed words -> {len(x_fp8)} FP8 values")

    x_exp_packed = parse_c_header_array(args.x_exp_header)
    if args.x_exp_format == '8bit':
        x_exp = unpack_exponents_8bit(x_exp_packed)
    else:
        x_exp = unpack_exponents_32bit(x_exp_packed)
    print(f"   X exponents: {len(x_exp_packed)} words -> {len(x_exp)} exponents")

    # W matrix
    w_packed = parse_c_header_array(args.w_mx_header)
    w_fp8 = unpack_fp8_from_16bit(w_packed)
    print(f"   W data: {len(w_packed)} packed words -> {len(w_fp8)} FP8 values")

    w_exp_packed = parse_c_header_array(args.w_exp_header)
    if args.w_exp_format == '8bit':
        w_exp = unpack_exponents_8bit(w_exp_packed)
    else:
        w_exp = unpack_exponents_32bit(w_exp_packed)
    print(f"   W exponents: {len(w_exp_packed)} words -> {len(w_exp)} exponents")

    # Y matrix (FP16 accumulator initialization)
    y_fp16 = parse_c_header_array(args.y_header)
    print(f"   Y init: {len(y_fp16)} FP16 values")

    # 2. Decode MX to FP16
    print(f"\n2. Decoding MX to FP16...")

    x_fp16 = decode_mx_to_fp16(x_fp8, x_exp, args.block_size)
    w_fp16 = decode_mx_to_fp16(w_fp8, w_exp, args.block_size)

    print(f"   X FP16: {len(x_fp16)} values (need {args.M * args.N})")
    print(f"   W FP16: {len(w_fp16)} values (need {args.N * args.K})")

    # Verify we have enough data
    assert len(x_fp16) >= args.M * args.N, f"Not enough X data: {len(x_fp16)} < {args.M * args.N}"
    assert len(w_fp16) >= args.N * args.K, f"Not enough W data: {len(w_fp16)} < {args.N * args.K}"
    assert len(y_fp16) >= args.M * args.K, f"Not enough Y data: {len(y_fp16)} < {args.M * args.K}"

    # 3. Perform GEMM
    print(f"\n3. Performing bit-true GEMM...")
    z_fp16 = perform_gemm_fp16(x_fp16, w_fp16, y_fp16, args.M, args.N, args.K)
    print(f"   Z FP16: {len(z_fp16)} values")

    # Show some sample values for debugging
    print(f"   Sample Z values (first 8):")
    for i in range(min(8, len(z_fp16))):
        val = fp16_bits_to_float(z_fp16[i])
        print(f"     [{i}]: 0x{z_fp16[i]:04x} = {val:.6f}")

    # 4. Encode result to MX
    print(f"\n4. Encoding result to MX...")
    z_fp8, z_exp = encode_fp16_to_mx(z_fp16, args.block_size)
    print(f"   Z MX: {len(z_fp8)} FP8 values, {len(z_exp)} exponents")

    # Show sample encoded values
    print(f"   Sample Z exponents: {[f'0x{e:02x}' for e in z_exp[:4]]}")

    # 5. Pack and write output
    print(f"\n5. Writing output headers...")

    # Pack FP8 to 32-bit words
    z_packed = pack_fp8_to_32bit_words(z_fp8)
    write_c_header(args.output_mx_header, args.mx_array_name, z_packed,
                   elem_type='uint32_t', guard_name='__GOLDEN_MX_H__')
    print(f"   Wrote {len(z_packed)} uint32_t values to {args.output_mx_header}")

    # Pack exponents to 32-bit words
    z_exp_packed = pack_exponents_compact_8bit(z_exp)
    write_c_header(args.output_exp_header, args.exp_array_name, z_exp_packed,
                   elem_type='uint32_t', guard_name='__GOLDEN_MX_EXP_H__')
    print(f"   Wrote {len(z_exp_packed)} uint32_t values to {args.output_exp_header}")

    print(f"\nDone! Golden MX output generated successfully.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
