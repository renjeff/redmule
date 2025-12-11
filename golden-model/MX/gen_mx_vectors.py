# Unified MX vector generator: decoder + encoder.
# Uses mx_fp_golden.py as the golden model.
# Supports multiple MX formats: MXFP8, MXFP6, MXFP4

import random
import numpy as np

from mx_fp_golden import (
    mxfp8_decode_bits,
    encode_block_fp16_to_mx
)

NUM_BLOCKS = 50
NUM_ELEMS  = 32   # MX block = 256 bits

# Format specifications: {exp_bits, mantissa_bits, bias, bitwidth}
# Based on OCP MX v1.0 spec
MX_FORMATS = {
    # MXFP8 variants
    'mxfp8_e5m2': {'exp_bits': 5, 'mantissa_bits': 2, 'bias': 15, 'bitwidth': 8},
    'mxfp8_e4m3': {'exp_bits': 4, 'mantissa_bits': 3, 'bias': 7, 'bitwidth': 8},
    
    # MXFP6 variants
    'mxfp6_e3m2': {'exp_bits': 3, 'mantissa_bits': 2, 'bias': 3, 'bitwidth': 6},
    'mxfp6_e2m3': {'exp_bits': 2, 'mantissa_bits': 3, 'bias': 1, 'bitwidth': 6},
    
    # MXFP4 variant
    'mxfp4_e2m1': {'exp_bits': 2, 'mantissa_bits': 1, 'bias': 1, 'bitwidth': 4},
}


def gen_special_values_block(num_elems, fmt_spec):
    """
    Generate special FP values for edge case testing.
    Parameterized by format specification.
    """
    exp_bits = fmt_spec['exp_bits']
    mantissa_bits = fmt_spec['mantissa_bits']
    
    exp_mask = (1 << exp_bits) - 1
    mantissa_mask = (1 << mantissa_bits) - 1
    max_exp = exp_mask
    
    special = []
    
    # Zeros (both signs)
    special.append(0x0000)
    special.append(1 << (exp_bits + mantissa_bits))  # -0
    
    # Infinities (if exp_bits > 0)
    if exp_bits > 0:
        special.append(max_exp << mantissa_bits)  # +Inf
        special.append((1 << (exp_bits + mantissa_bits)) | (max_exp << mantissa_bits))  # -Inf
    
    # NaNs (if exp_bits > 0)
    if exp_bits > 0:
        special.append((max_exp << mantissa_bits) | 0x1)  # +NaN
        special.append((1 << (exp_bits + mantissa_bits)) | (max_exp << mantissa_bits) | 0x1)  # -NaN
    
    # Subnormals
    special.append(0x0001)
    special.append((1 << (exp_bits + mantissa_bits)) | 0x0001)
    
    # Max/min finite
    if max_exp > 1:
        max_finite_exp = (max_exp - 1) << mantissa_bits
        special.append(max_finite_exp | mantissa_mask)  # +max finite
        special.append((1 << (exp_bits + mantissa_bits)) | max_finite_exp | mantissa_mask)  # -max finite
    
    # Sweep exponents
    for exp in range(1, max(2, max_exp - 1)):
        special.append(exp << mantissa_bits)
        special.append((exp << mantissa_bits) | mantissa_mask)
        if len(special) >= num_elems:
            break
    
    # Pad with random
    while len(special) < num_elems:
        special.append(random.randrange(1 << (exp_bits + mantissa_bits + 1)))
    
    return special[:num_elems]


def gen_special_fp16_block(num_elems):
    """
    Generate FP16 special values for encoder testing.
    Always generates proper FP16 values regardless of target MX format.
    """
    special = []
    
    # Zeros
    special.append(0x0000)  # +0
    special.append(0x8000)  # -0
    
    # Infinities
    special.append(0x7C00)  # +Inf
    special.append(0xFC00)  # -Inf
    
    # NaNs
    special.append(0x7E00)  # +NaN
    special.append(0xFE00)  # -NaN
    
    # Subnormals
    special.append(0x0001)  # +tiny subnormal
    special.append(0x8001)  # -tiny subnormal
    special.append(0x03FF)  # +max subnormal
    special.append(0x83FF)  # -max subnormal
    
    # Max/min finite
    special.append(0x7BFF)  # +max finite
    special.append(0xFBFF)  # -max finite
    
    # Common values
    special.append(0x3C00)  # +1.0
    special.append(0xBC00)  # -1.0
    special.append(0x4000)  # +2.0
    special.append(0xC000)  # -2.0
    
    # Sweep different exponents
    for exp in range(1, 30):
        special.append((exp << 10))  # min mantissa
        special.append((exp << 10) | 0x3FF)  # max mantissa
        if len(special) >= num_elems:
            break
    
    # Pad with random FP16 values
    while len(special) < num_elems:
        special.append(random.randrange(0x10000))
    
    return special[:num_elems]


# ------------------------------------------------------------
# Generate DECODER vectors  
# Format per line:
#   <shared_exp> <32×values> <32×fp16_expected>
# ------------------------------------------------------------
def gen_decoder_vectors(fmt_name, filename=None):
    """Generate decoder vectors for a specific format."""
    if fmt_name not in MX_FORMATS:
        print(f"Unknown format: {fmt_name}")
        return
    
    if filename is None:
        filename = f"mx_decoder_vectors_{fmt_name}.txt"
    
    fmt = MX_FORMATS[fmt_name]
    
    with open(filename, "w") as f:
        # Random blocks
        for _ in range(NUM_BLOCKS):
            shared_exp = random.randrange(256)
            vals = [random.randrange(1 << fmt['bitwidth']) for _ in range(NUM_ELEMS)]
            # TODO: Use parameterized decode for different formats
            fp16_vals = [mxfp8_decode_bits(v, shared_exp) for v in vals]
            
            f.write(f"{shared_exp:02x}")
            for v in vals:
                f.write(f" {v:02x}")
            for x in fp16_vals:
                f.write(f" {x:04x}")
            f.write("\n")
        
        # Special values block
        special = gen_special_values_block(NUM_ELEMS, fmt)
        shared_exp = random.randrange(256)
        fp16_vals = [mxfp8_decode_bits(v, shared_exp) for v in special]
        
        f.write(f"{shared_exp:02x}")
        for v in special:
            f.write(f" {v:02x}")
        for x in fp16_vals:
            f.write(f" {x:04x}")
        f.write("\n")
    
    print(f"Generated decoder vectors -> {filename}")


# ------------------------------------------------------------
# Generate ENCODER vectors  
# Format per line:
#   <32×fp16_vals> <shared_exp> <32×encoded_vals>
# ------------------------------------------------------------
def gen_encoder_vectors(fmt_name, filename=None):
    """Generate encoder vectors for a specific format."""
    if fmt_name not in MX_FORMATS:
        print(f"Unknown format: {fmt_name}")
        return
    
    if filename is None:
        filename = f"mx_encoder_vectors_{fmt_name}.txt"
    
    fmt = MX_FORMATS[fmt_name]
    
    with open(filename, "w") as f:
        # Random blocks
        for _ in range(NUM_BLOCKS):
            fp16_vals = [
                np.float16(random.uniform(-10.0, 10.0))
                for _ in range(NUM_ELEMS)
            ]
            
            fp16_bits = [
                int(np.uint16(np.array(v, dtype=np.float16).view(np.uint16)))
                for v in fp16_vals
            ]
            
            # TODO: Use parameterized encode for different formats
            shared_exp, mx_vals = encode_block_fp16_to_mx(fp16_bits)
            
            for i, b in enumerate(fp16_bits):
                f.write(f"{b:04x}" if i == 0 else f" {b:04x}")
            f.write(f" {shared_exp:02x}")
            for v in mx_vals:
                f.write(f" {v:02x}")
            f.write("\n")
        
        # Special values block
        special = gen_special_fp16_block(NUM_ELEMS)
        shared_exp, mx_vals = encode_block_fp16_to_mx(special)
        
        for i, b in enumerate(special):
            f.write(f"{b:04x}" if i == 0 else f" {b:04x}")
        f.write(f" {shared_exp:02x}")
        for v in mx_vals:
            f.write(f" {v:02x}")
        f.write("\n")
    
    print(f"Generated encoder vectors -> {filename}")


# ------------------------------------------------------------
# Run for all formats
# ------------------------------------------------------------
if __name__ == "__main__":
    for fmt_name in MX_FORMATS:
        gen_encoder_vectors(fmt_name)
        gen_decoder_vectors(fmt_name)
