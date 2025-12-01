# Generates MX decoder test vectors using mx_fp_golden.py.

from mx_fp_golden import mxfp8_decode_bits
import random

NUM_BLOCKS  = 50      # how many MX blocks to test
NUM_ELEMS   = 32      # elements per block

with open("mx_decoder_vectors.txt", "w") as f:
    for _ in range(NUM_BLOCKS):
        shared_exp = random.randrange(256)
        fp8_vals   = [random.randrange(256) for _ in range(NUM_ELEMS)]
        exp_vals   = [mxfp8_decode_bits(v, shared_exp) for v in fp8_vals]

        # Line format:
        #   <shared_exp> <32×fp8> <32×fp16>
        # all in hex
        f.write(f"{shared_exp:02x}")
        for v in fp8_vals:
            f.write(f" {v:02x}")
        for e in exp_vals:
            f.write(f" {e:04x}")
        f.write("\n")

print("Generated", NUM_BLOCKS, "blocks -> mx_decoder_vectors.txt")
