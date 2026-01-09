#!/usr/bin/env python3
"""
Verify MX encoder outputs from RedMulE integrated simulation against golden model.

This script reads the filtered output files from the simulation and compares
them against the Python golden model for MX encoding.

Usage:
    cd /path/to/redmule/target/sim/vsim
    python3 /path/to/golden-model/MX/verify_mx_encoder_integrated.py

Expected input files (in current directory):
    - mx_encoder_fp16_inputs_filtered.txt  : FP16 inputs to encoder (hex, one per line)
    - mx_encoder_fp8_outputs_filtered.txt  : FP8 encoded outputs (hex, one per line)
    - mx_encoder_exponents_filtered.txt    : E8M0 shared exponents (hex, one per line)
"""

import sys
import os

# Add the MX golden model directory to path
script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, script_dir)

from mx_fp_golden import encode_block_fp16_to_mx


def read_hex_file(filename):
    """Read hex values from file, one per line."""
    values = []
    try:
        with open(filename, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    values.append(int(line, 16))
    except FileNotFoundError:
        return None
    return values


def unpack_fp16_block(hex_value, num_lanes):
    """
    Unpack a hex value into individual FP16 bit patterns.
    
    Args:
        hex_value: Integer representing packed FP16 values (LSB first)
        num_lanes: Number of FP16 elements to extract
    
    Returns:
        List of FP16 bit patterns (16-bit integers)
    """
    fp16_bits = []
    for i in range(num_lanes):
        bits = (hex_value >> (i * 16)) & 0xFFFF
        fp16_bits.append(bits)
    return fp16_bits


def unpack_fp8_block(hex_value, num_elems):
    """
    Unpack a hex value into individual FP8 bit patterns.
    
    Args:
        hex_value: Integer representing packed FP8 values (LSB first)
        num_elems: Number of FP8 elements to extract
    
    Returns:
        List of FP8 bit patterns (8-bit integers)
    """
    fp8_bits = []
    for i in range(num_elems):
        bits = (hex_value >> (i * 8)) & 0xFF
        fp8_bits.append(bits)
    return fp8_bits


def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Verify MX encoder outputs against golden model'
    )
    parser.add_argument(
        '--num-lanes', type=int, default=12,
        help='Number of lanes (Width parameter, default: 12)'
    )
    parser.add_argument(
        '--input-dir', type=str, default='.',
        help='Directory containing simulation output files (default: current dir)'
    )
    parser.add_argument(
        '--verbose', '-v', action='store_true',
        help='Show detailed output for each block'
    )
    parser.add_argument(
        '--max-errors', type=int, default=10,
        help='Maximum number of errors to display (default: 10)'
    )
    
    args = parser.parse_args()
    
    NUM_LANES = args.num_lanes
    input_dir = args.input_dir
    
    # Read filtered simulation output files
    print("Reading simulation outputs...")
    fp16_file = os.path.join(input_dir, 'mx_encoder_fp16_inputs_filtered.txt')
    fp8_file = os.path.join(input_dir, 'mx_encoder_fp8_outputs_filtered.txt')
    exp_file = os.path.join(input_dir, 'mx_encoder_exponents_filtered.txt')
    
    fp16_inputs = read_hex_file(fp16_file)
    fp8_outputs = read_hex_file(fp8_file)
    exp_outputs = read_hex_file(exp_file)
    
    if fp16_inputs is None:
        print(f"ERROR: Could not read {fp16_file}")
        return 1
    if fp8_outputs is None:
        print(f"ERROR: Could not read {fp8_file}")
        return 1
    if exp_outputs is None:
        print(f"ERROR: Could not read {exp_file}")
        return 1
    
    print(f"  FP16 inputs:  {len(fp16_inputs)} entries")
    print(f"  FP8 outputs:  {len(fp8_outputs)} entries")
    print(f"  Exponents:    {len(exp_outputs)} entries")
    
    num_blocks = min(len(fp16_inputs), len(fp8_outputs), len(exp_outputs))
    if num_blocks == 0:
        print("ERROR: No data to verify")
        return 1
    
    print(f"\nVerifying {num_blocks} MX blocks (NUM_LANES={NUM_LANES})...")
    
    exp_errors = 0
    fp8_errors = 0
    error_details = []
    
    for block_idx in range(num_blocks):
        # Unpack FP16 inputs
        fp16_bits = unpack_fp16_block(fp16_inputs[block_idx], NUM_LANES)
        
        # Run golden model
        golden_exp, golden_fp8 = encode_block_fp16_to_mx(fp16_bits)
        
        # Get simulation outputs
        sim_exp = exp_outputs[block_idx] & 0xFF
        sim_fp8 = unpack_fp8_block(fp8_outputs[block_idx], NUM_LANES)
        
        block_has_error = False
        
        # Compare exponent
        if golden_exp != sim_exp:
            exp_errors += 1
            block_has_error = True
            if len(error_details) < args.max_errors:
                error_details.append(
                    f"Block {block_idx}: Exponent mismatch\n"
                    f"  Golden: 0x{golden_exp:02x}, Sim: 0x{sim_exp:02x}"
                )
        
        # Compare FP8 values
        for i in range(NUM_LANES):
            if golden_fp8[i] != sim_fp8[i]:
                fp8_errors += 1
                block_has_error = True
                if len(error_details) < args.max_errors:
                    error_details.append(
                        f"Block {block_idx}, Lane {i}: FP8 mismatch\n"
                        f"  Golden: 0x{golden_fp8[i]:02x}, Sim: 0x{sim_fp8[i]:02x}\n"
                        f"  FP16 input: 0x{fp16_bits[i]:04x}"
                    )
        
        if args.verbose and not block_has_error:
            print(f"  Block {block_idx}: OK (exp=0x{sim_exp:02x})")
    
    # Print results
    print(f"\n{'='*60}")
    
    if exp_errors == 0 and fp8_errors == 0:
        print(f"✓ PASS: All {num_blocks} blocks match golden model")
        print(f"{'='*60}")
        return 0
    else:
        print(f"✗ FAIL: {exp_errors} exponent errors, {fp8_errors} FP8 errors")
        print(f"{'='*60}")
        
        if error_details:
            print("\nError details:")
            for detail in error_details:
                print(f"\n{detail}")
            
            total_errors = exp_errors + fp8_errors
            if total_errors > args.max_errors:
                print(f"\n... and {total_errors - args.max_errors} more errors")
        
        return 1


if __name__ == "__main__":
    sys.exit(main())
