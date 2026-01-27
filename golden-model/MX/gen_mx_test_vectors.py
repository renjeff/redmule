#!/usr/bin/env python3
"""
Generate MX-encoded test vectors (FP8 mantissas + shared exponents) from FP16 input matrices.

Usage:
    python3 gen_mx_test_vectors.py --input x_input.h --output-mx mx_x_data.txt --output-exp mx_x_exp.txt --num-lanes 12

This script reads a C header file with a uint16_t array (FP16 values),
converts blocks of NUM_LANES FP16 values to MX format (E4M3 mantissa, E8M0 shared exponent),
and writes the mantissas and exponents to separate files for use in RedMulE MX testbenches.
"""
import argparse
import re
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))
from mx_fp_golden import encode_block_fp16_to_mx

def parse_fp16_header(filename):
    """Parse a C header file with uint16_t array and return a list of FP16 ints."""
    with open(filename, 'r') as f:
        text = f.read()
    # Find the array initializer
    arr = re.findall(r'0x[0-9a-fA-F]+', text)
    return [int(x, 16) for x in arr]

def write_hex_lines(filename, values, width=0):
    with open(filename, 'w') as f:
        for v in values:
            if width > 0:
                f.write(f'{v:0{width}x}\n')
            else:
                f.write(f'{v:x}\n')

def pack_fp8_to_16bit_words(fp8_values):
    """Pack 2 FP8 values into each 16-bit word [high_fp8|low_fp8]."""
    packed = []
    for i in range(0, len(fp8_values), 2):
        low_fp8 = fp8_values[i] & 0xFF
        high_fp8 = (fp8_values[i+1] & 0xFF) if i+1 < len(fp8_values) else 0
        # Pack: [high_fp8][low_fp8] in 16 bits
        packed_word = (high_fp8 << 8) | low_fp8
        packed.append(packed_word)
    return packed

def pack_fp8_to_32bit_words(fp8_values):
    """Pack 4 FP8 values into each 32-bit word (byte0 = lowest FP8)."""
    packed = []
    for i in range(0, len(fp8_values), 4):
        word = 0
        for b in range(4):
            val = fp8_values[i+b] if i+b < len(fp8_values) else 0
            word |= (val & 0xFF) << (8 * b)
        packed.append(word)
    return packed

def pad_exponents_to_64_bytes(exp_blocks):
    """Pad exponents to match hardware memory layout: 2 exponents per 64-byte block.

    Hardware extracts 2 exponents per TCDM beat (64 bytes), so we pad:
    [exp0, exp1, 0x00...00 (62 bytes)], [exp2, exp3, 0x00...00 (62 bytes)], ...

    This creates proper rate matching: 1 TCDM beat = 2 exponents = 2 MX blocks.
    """
    padded = []
    for i in range(0, len(exp_blocks), 2):
        # Get 2 exponents (or pad if odd number)
        exp0 = exp_blocks[i] if i < len(exp_blocks) else 0
        exp1 = exp_blocks[i+1] if i+1 < len(exp_blocks) else 0

        # Create 64-byte block: [exp0, exp1, 62 bytes of padding]
        padded.append(exp0)
        padded.append(exp1)
        padded.extend([0] * 62)  # 62 bytes of padding

    return padded

def write_c_header(filename, array_name, values, elem_type='uint16_t', values_per_line=8):
    """Write values as a C header file."""
    with open(filename, 'w') as f:
        # Header guards
        guard = f"__{array_name.upper()}_H__"
        f.write(f"// Auto-generated MX-encoded data\n")
        f.write(f"#ifndef {guard}\n")
        f.write(f"#define {guard}\n\n")
        f.write(f"#include <stdint.h>\n\n")

        # Array declaration
        f.write(f"{elem_type} {array_name}[{len(values)}] = {{\n")

        # Write values
        for i, v in enumerate(values):
            if i % values_per_line == 0:
                f.write("  ")

            # Format based on type
            if elem_type == 'uint16_t':
                f.write(f"0x{v:04x}")
            elif elem_type == 'uint8_t':
                f.write(f"0x{v:02x}")
            else:
                f.write(f"0x{v:x}")

            if i < len(values) - 1:
                f.write(", ")
            if (i + 1) % values_per_line == 0 and i < len(values) - 1:
                f.write("\n")

        if len(values) % values_per_line != 0:
            f.write("\n")

        f.write("};\n\n")
        f.write(f"#endif // {guard}\n")

def encode_fp16_blocks_to_mx(fp16_vals, block_size):
    """Encode FP16 values into MX blocks and return (mx_blocks, exp_blocks)."""
    num_blocks = (len(fp16_vals) + block_size - 1) // block_size
    mx_per_block = []
    exp_blocks = []
    for b in range(num_blocks):
        block = fp16_vals[b*block_size:(b+1)*block_size]
        if len(block) < block_size:
            block += [0] * (block_size - len(block))
        exp, mx = encode_block_fp16_to_mx(block)
        mx_per_block.append(mx)
        exp_blocks.append(exp)
    return mx_per_block, exp_blocks

def main():
    parser = argparse.ArgumentParser(description='Generate MX test vectors from FP16 input header')
    parser.add_argument('--input', required=True, help='Input C header file (FP16 array)')
    parser.add_argument('--output-mx', help='Output file for MX mantissas (hex format)')
    parser.add_argument('--output-exp', help='Output file for MX exponents (hex format)')
    parser.add_argument('--output-mx-header', help='Output C header file for MX mantissas')
    parser.add_argument('--output-exp-header', help='Output C header file for MX exponents')
    parser.add_argument('--mx-array-name', default='mx_data', help='Array name for MX data in C header (default: mx_data)')
    parser.add_argument('--exp-array-name', default='mx_exp', help='Array name for exponents in C header (default: mx_exp)')
    parser.add_argument('--num-lanes', type=int, default=12, help='Number of lanes (Width, default: 12)')
    parser.add_argument('--block-size', type=int, default=32, help='MX block size (default: 32)')
    parser.add_argument('--pack-fp8', action='store_true', help='Pack 2 FP8 values per 16-bit word for bandwidth savings')
    parser.add_argument('--golden-input', help='Optional FP16 golden result header to encode to MX')
    parser.add_argument('--golden-output-header', help='Output C header for MX golden result (requires --golden-input)')
    parser.add_argument('--golden-array-name', default='golden_mx', help='Array name for MX golden header')
    args = parser.parse_args()

    # Validate: need at least one output format
    if not (args.output_mx or args.output_mx_header):
        parser.error('Must specify at least one of --output-mx or --output-mx-header')
    if not (args.output_exp or args.output_exp_header):
        parser.error('Must specify at least one of --output-exp or --output-exp-header')

    fp16_vals = parse_fp16_header(args.input)
    mx_per_block, exp_blocks = encode_fp16_blocks_to_mx(fp16_vals, args.block_size)
    num_blocks = len(exp_blocks)

    # Output MX data
    if args.pack_fp8:
        # Pack 2 FP8 values per 16-bit word
        all_fp8_values = [val for block in mx_per_block for val in block]
        packed_words = pack_fp8_to_16bit_words(all_fp8_values)

        # Write hex format if requested
        if args.output_mx:
            write_hex_lines(args.output_mx, packed_words, width=4)  # 16-bit words
            print(f'Wrote {len(packed_words)} packed 16-bit words (2 FP8 per word) to {args.output_mx}')

        # Write C header if requested
        if args.output_mx_header:
            write_c_header(args.output_mx_header, args.mx_array_name, packed_words, elem_type='uint16_t')
            print(f'Wrote C header with {len(packed_words)} uint16_t values to {args.output_mx_header}')
    else:
        # Unpacked format
        mx_blocks = []
        for mx in mx_per_block:
            mx_word = 0
            for i, val in enumerate(mx):
                mx_word |= (val & 0xFF) << (8*i)
            mx_blocks.append(mx_word)
        if args.output_mx:
            write_hex_lines(args.output_mx, mx_blocks, width=args.block_size*2//8)
            print(f'Wrote {num_blocks} MX blocks to {args.output_mx}')

        if args.output_mx_header:
            # For unpacked, we'd need to decide on representation - not commonly used
            print('Warning: C header output for unpacked format not implemented')

    # Output exponents with padding (2 exponents per 64-byte block)
    padded_exp = pad_exponents_to_64_bytes(exp_blocks)

    if args.output_exp:
        write_hex_lines(args.output_exp, padded_exp, width=2)
        print(f'Wrote {num_blocks} exponents ({len(padded_exp)} bytes with padding) to {args.output_exp}')

    if args.output_exp_header:
        write_c_header(args.output_exp_header, args.exp_array_name, padded_exp, elem_type='uint8_t')
        print(f'Wrote C header with {len(padded_exp)} uint8_t values ({num_blocks} exponents with padding) to {args.output_exp_header}')

    if args.golden_output_header or args.golden_input:
        if not args.golden_input or not args.golden_output_header:
            parser.error('--golden-input and --golden-output-header must be provided together')
        if not args.pack_fp8:
            parser.error('Golden MX output requires --pack-fp8 to be enabled')
        golden_vals = parse_fp16_header(args.golden_input)
        golden_mx_blocks, _ = encode_fp16_blocks_to_mx(golden_vals, args.block_size)
        golden_fp8 = [val for block in golden_mx_blocks for val in block]
        golden_packed = pack_fp8_to_32bit_words(golden_fp8)
        write_c_header(args.golden_output_header, args.golden_array_name,
                       golden_packed, elem_type='uint32_t')
        print(f'Wrote MX golden header with {len(golden_packed)} uint32_t values to {args.golden_output_header}')

if __name__ == '__main__':
    main()
