#!/usr/bin/env python3
"""
Verify MX encoder outputs from RedMulE simulation against golden model
"""

import sys
import numpy as np
from mx_fp_golden import encode_block_fp16_to_mx

def read_hex_file(filename):
    """Read hex values from file, one per line"""
    values = []
    try:
        with open(filename, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    values.append(int(line, 16))
    except FileNotFoundError:
        print(f"Warning: {filename} not found, skipping")
        return None
    return values

def unpack_fp16_block(hex_value, num_lanes=32):
    """
    Unpack hex value into FP16 bit array
    hex_value: integer representing packed FP16 values
    num_lanes: number of FP16 elements (32 for Width=32 config)
    Returns list of FP16 bit patterns
    """
    fp16_bits = []
    for i in range(num_lanes):
        # Extract 16 bits for this lane
        bits = (hex_value >> (i * 16)) & 0xFFFF
        fp16_bits.append(bits)
    return fp16_bits

def unpack_fp8_block(hex_value, num_elems=32):
    """Unpack hex value into FP8 bit array"""
    fp8_bits = []
    for i in range(num_elems):
        bits = (hex_value >> (i * 8)) & 0xFF
        fp8_bits.append(bits)
    return fp8_bits

def main():
    # Read captured simulation outputs
    print("Reading simulation outputs...")
    fp16_inputs = read_hex_file("mx_encoder_fp16_inputs.txt")
    fp8_outputs = read_hex_file("mx_encoder_fp8_outputs.txt")
    exp_outputs = read_hex_file("mx_encoder_exponents.txt")
    
    if not fp16_inputs or not fp8_outputs or not exp_outputs:
        print("ERROR: Missing simulation output files")
        print("Expected files in current directory:")
        print("  - mx_encoder_fp16_inputs.txt")
        print("  - mx_encoder_fp8_outputs.txt")
        print("  - mx_encoder_exponents.txt")
        sys.exit(1)
    
    num_blocks = min(len(fp16_inputs), len(fp8_outputs), len(exp_outputs))
    print(f"Found {num_blocks} MX blocks to verify")
    
    errors = 0
    max_errors_to_show = 5
    
    for block_idx in range(num_blocks):
        # Unpack FP16 inputs (as bit patterns)
        fp16_bits = unpack_fp16_block(fp16_inputs[block_idx])
        
        # Run golden model
        golden_exp, golden_fp8_bits = encode_block_fp16_to_mx(fp16_bits)
        
        # Unpack simulation outputs
        sim_fp8_bits = unpack_fp8_block(fp8_outputs[block_idx])
        sim_exp = exp_outputs[block_idx] & 0xFF
        
        # Compare exponent
        if golden_exp != sim_exp:
            if errors < max_errors_to_show:
                print(f"\nBlock {block_idx}: Exponent mismatch")
                print(f"  Golden: 0x{golden_exp:02x}")
                print(f"  Sim:    0x{sim_exp:02x}")
                print(f"  FP16 inputs: {[f'{x:04x}' for x in fp16_bits[:8]]}...")
            errors += 1
        
        # Compare FP8 mantissas
        for elem_idx in range(32):
            if golden_fp8_bits[elem_idx] != sim_fp8_bits[elem_idx]:
                if errors < max_errors_to_show:
                    print(f"\nBlock {block_idx}, Element {elem_idx}: FP8 mismatch")
                    print(f"  Golden: 0x{golden_fp8_bits[elem_idx]:02x}")
                    print(f"  Sim:    0x{sim_fp8_bits[elem_idx]:02x}")
                    print(f"  FP16 input: 0x{fp16_bits[elem_idx]:04x}")
                errors += 1
                break  # Only show first error per block
    
    print(f"\n{'='*60}")
    if errors == 0:
        print(f"✓ PASS: All {num_blocks} MX blocks match golden model")
    else:
        print(f"✗ FAIL: {errors} mismatches found in {num_blocks} blocks")
        if errors > max_errors_to_show:
            print(f"  (showing first {max_errors_to_show} errors)")
    print(f"{'='*60}")
    
    return 0 if errors == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
