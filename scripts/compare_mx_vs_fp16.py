#!/usr/bin/env python3
"""Compare MX encoder output against FP16 golden Z buffer."""
import argparse
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MX_PY = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "golden-model", "MX"))
sys.path.insert(0, MX_PY)

from mx_fp_golden import mxfp8_decode_bits


def load_fp16_golden(path):
    values = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if (not line) or line.startswith("/*") or line.startswith("uint16_t"):
                continue
            if line.endswith(","):
                line = line[:-1]
            for token in line.split(','):
                token = token.strip()
                if token and token not in {'};'}:
                    try:
                        values.append(int(token, 16))
                    except ValueError:
                        pass
    return values


def load_hex_words(path):
    words = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                words.append(int(line, 16))
    return words


def main():
    parser = argparse.ArgumentParser(description="Compare MX encoder output against FP16 golden data")
    parser.add_argument("--golden", default="sw/inc/z_output.h", help="Path to FP16 golden header")
    parser.add_argument("--mx-dir", default="target/sim/vsim", help="Directory containing mx_encoder_* files")
    parser.add_argument("--num-lanes", type=int, default=32, help="Number of FP16 values per MX block")
    parser.add_argument("--max-errors", type=int, default=20, help="Maximum mismatches to print")
    args = parser.parse_args()

    golden = load_fp16_golden(args.golden)
    mx_vals = load_hex_words(os.path.join(args.mx_dir, "mx_encoder_fp8_outputs_filtered.txt"))
    mx_exps = load_hex_words(os.path.join(args.mx_dir, "mx_encoder_exponents_filtered.txt"))

    if len(mx_vals) != len(mx_exps):
        print(f"ERROR: value count {len(mx_vals)} != exponent count {len(mx_exps)}")
        return 1

    decoded = []
    for val, exp in zip(mx_vals, mx_exps):
        shared = exp & 0xFF
        for lane in range(args.num_lanes):
            fp8 = (val >> (lane * 8)) & 0xFF
            decoded.append(mxfp8_decode_bits(fp8, shared))

    total = min(len(decoded), len(golden))
    errors = 0
    for idx in range(total):
        if decoded[idx] != golden[idx]:
            if errors < args.max_errors:
                print(f"Mismatch @ {idx}: MX=0x{decoded[idx]:04x}, golden=0x{golden[idx]:04x}")
            errors += 1

    print(f"Compared {total} elements; mismatches={errors}")
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
