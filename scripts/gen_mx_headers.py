#!/usr/bin/env python3
"""
Generate C header files for MX input data from golden model txt files
Each line in the txt file is 128 hex chars = 512 bits = 64 bytes = 32 uint16 values
For a 32x32 FP8 matrix: 32 lines × 32 values/line = 1024 values total = 512 uint16 words
"""

import sys

def hex_to_uint16_array(hex_file, output_h, array_name):
    """Convert hex file to flat C uint16_t array"""
    with open(hex_file, 'r') as f:
        hex_lines = [line.strip() for line in f if line.strip()]
    
    values = []
    for hex_line in hex_lines:
        # Each line is 128 hex chars, split into 4-char (16-bit) chunks
        for i in range(0, len(hex_line), 4):
            chunk = hex_line[i:i+4]
            if len(chunk) == 4:
                # Reverse byte order for little-endian
                val = '0x' + chunk[2:4] + chunk[0:2]
                values.append(val)
    
    with open(output_h, 'w') as f:
        f.write(f'/* MX-encoded data generated from {hex_file} */\n')
        f.write(f'uint16_t {array_name} [{len(values)}] = {{\n')
        
        # Write 8 values per line for readability
        for i in range(0, len(values), 8):
            line_vals = values[i:i+8]
            f.write('  ' + ', '.join(line_vals) + ',\n')
        
        f.write('};\n')
    
    print(f"Generated {output_h} with {len(values)} uint16 values")

# Generate x_input_mx.h from mx_x_data.txt
hex_to_uint16_array(
    'golden-model/MX/mx_x_data.txt',
    'inc/x_input_mx.h',
    'x_inp'
)

# Generate w_input_mx.h from mx_w_data.txt
hex_to_uint16_array(
    'golden-model/MX/mx_w_data.txt',
    'inc/w_input_mx.h',
    'w_inp'
)

print("Done!")

