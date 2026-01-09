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

def main():
    parser = argparse.ArgumentParser(description='Generate MX test vectors from FP16 input header')
    parser.add_argument('--input', required=True, help='Input C header file (FP16 array)')
    parser.add_argument('--output-mx', required=True, help='Output file for MX mantissas (hex)')
    parser.add_argument('--output-exp', required=True, help='Output file for MX exponents (hex)')
    parser.add_argument('--num-lanes', type=int, default=12, help='Number of lanes (Width, default: 12)')
    parser.add_argument('--block-size', type=int, default=32, help='MX block size (default: 32)')
    args = parser.parse_args()

    fp16_vals = parse_fp16_header(args.input)
    num_blocks = (len(fp16_vals) + args.block_size - 1) // args.block_size
    mx_blocks = []
    exp_blocks = []

    for b in range(num_blocks):
        block = fp16_vals[b*args.block_size:(b+1)*args.block_size]
        # Pad with zeros if needed
        if len(block) < args.block_size:
            block += [0] * (args.block_size - len(block))
        exp, mx = encode_block_fp16_to_mx(block)
        # Pack MX mantissas into a single integer (LSB first)
        mx_word = 0
        for i, val in enumerate(mx):
            mx_word |= (val & 0xFF) << (8*i)
        mx_blocks.append(mx_word)
        exp_blocks.append(exp)

    write_hex_lines(args.output_mx, mx_blocks, width=args.block_size*2//8)
    write_hex_lines(args.output_exp, exp_blocks, width=2)
    print(f'Wrote {num_blocks} MX blocks to {args.output_mx} and {args.output_exp}')

if __name__ == '__main__':
    main()
