#!/usr/bin/env python3
"""Cross-check the in-tree MX golden model against Gamze's FP9 model."""

from __future__ import annotations

import argparse
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Sequence, Tuple

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "mxfp-main-golden-Gamze"))

from MX import mx_fp_golden as legacy_mx
from golden.fp9 import FP9
from golden.utils import format_fp9_cvfpu


BIAS_FP16 = 15
BIAS_FP8_E4M3 = 7
FP16_MAX_FINITE = 0x7BFF


def fp16_bits_to_float(bits: int) -> float:
    """Convert an FP16 bit-pattern to a Python float."""
    arr = np.array([bits], dtype=np.uint16)
    return float(arr.view(np.float16)[0])


def encode_with_gamze(fp16_bits: int, shared_exp: int) -> int:
    """Reference encode using Gamze's FP9 helper for FP8 (E4M3)."""
    sign = (fp16_bits >> 15) & 0x1
    exponent = (fp16_bits >> 10) & 0x1F
    mantissa = fp16_bits & 0x3FF

    if exponent == 0:
        # Zero or subnormal -> signed zero regardless of scale
        return sign << 7

    if exponent == 0x1F:
        # Inf / NaN directly map to MX encodings
        if mantissa == 0:
            return (sign << 7) | (0xF << 3)
        return (sign << 7) | (0xF << 3) | 0x1

    base_value = np.float32(fp16_bits_to_float(fp16_bits))
    unscaled_value = np.float32(math.ldexp(float(base_value), 127 - shared_exp))

    fp9_obj = FP9.float_to_mx(value=float(unscaled_value), data_type="FP8ALT")
    return int(format_fp9_cvfpu(fp9_obj), 2)


def decode_reference(mx_val: int, shared_exp: int) -> int:
    """Reference decode derived from the MX specification."""
    sign = (mx_val >> 7) & 0x1
    exponent = (mx_val >> 3) & 0xF
    mantissa = mx_val & 0x7

    if exponent == 0:
        return sign << 15

    if exponent == 0xF:
        if mantissa == 0:
            return (sign << 15) | (0x1F << 10)
        return (sign << 15) | (0x1F << 10) | (1 << 9)

    e16 = exponent - BIAS_FP8_E4M3 + BIAS_FP16
    m16 = (mantissa << 7) & 0x3FF

    delta = shared_exp - 127
    new_e16 = e16 + delta

    if new_e16 <= 0:
        return sign << 15
    if new_e16 >= 31:
        return (sign << 15) | (FP16_MAX_FINITE & 0x7FFF)

    return (sign << 15) | ((new_e16 & 0x1F) << 10) | m16


@dataclass
class BlockResult:
    block_id: str
    shared_exp: int
    encode_mismatches: List[Tuple[int, int, int]]
    decode_mismatches: List[Tuple[int, int, int]]


def compare_block(block_bits: Sequence[int], block_id: str) -> BlockResult:
    shared_exp, legacy_encoded = legacy_mx.encode_block_fp16_to_mx(block_bits)

    encode_errors: List[Tuple[int, int, int]] = []
    decode_errors: List[Tuple[int, int, int]] = []

    for idx, (fp16_bits, mx_val) in enumerate(zip(block_bits, legacy_encoded)):
        expected_encode = encode_with_gamze(fp16_bits, shared_exp)
        if expected_encode != mx_val:
            encode_errors.append((idx, expected_encode, mx_val))

        expected_decode = decode_reference(mx_val, shared_exp)
        actual_decode = legacy_mx.mxfp8_decode_bits(mx_val, shared_exp)
        if expected_decode != actual_decode:
            decode_errors.append((idx, expected_decode, actual_decode))

    return BlockResult(block_id, shared_exp, encode_errors, decode_errors)


def generate_random_block(block_size: int, rng: np.random.Generator) -> List[int]:
    values = (rng.standard_normal(block_size) * 32.0).astype(np.float16)
    return values.view(np.uint16).tolist()


def generate_special_block(block_size: int) -> List[int]:
    specials = np.array(
        [
            0.0,
            -0.0,
            1.0,
            -1.0,
            0.5,
            -0.5,
            1e-4,
            -1e-4,
            65504.0,
            -65504.0,
            np.inf,
            -np.inf,
            np.nan,
        ],
        dtype=np.float16,
    )

    tiled = np.resize(specials, block_size)
    return tiled.view(np.uint16).tolist()


def run(block_count: int, block_size: int, seed: int):
    rng = np.random.default_rng(seed)
    results: List[BlockResult] = []

    for idx in range(block_count):
        block_bits = generate_random_block(block_size, rng)
        results.append(compare_block(block_bits, f"rand_{idx}"))

    results.append(compare_block(generate_special_block(block_size), "special"))
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare MX golden models")
    parser.add_argument("--blocks", type=int, default=200, help="Number of random blocks to test")
    parser.add_argument("--block-size", type=int, default=32, help="Number of FP16 values per MX block")
    parser.add_argument("--seed", type=int, default=1, help="Seed for the RNG")
    parser.add_argument("--verbose", action="store_true", help="Print every mismatch instead of summaries")
    args = parser.parse_args()

    results = run(args.blocks, args.block_size, args.seed)

    encode_errors = sum(len(res.encode_mismatches) for res in results)
    decode_errors = sum(len(res.decode_mismatches) for res in results)

    if encode_errors == 0 and decode_errors == 0:
        print(
            f"✅ All {args.blocks} random blocks plus one special block matched "
            f"(block size {args.block_size})."
        )
        return 0

    for res in results:
        if not (res.encode_mismatches or res.decode_mismatches):
            continue

        enc_count = len(res.encode_mismatches)
        dec_count = len(res.decode_mismatches)
        print(
            f"Block {res.block_id} (se={res.shared_exp}) mismatches: "
            f"encode={enc_count}, decode={dec_count}"
        )

        if args.verbose:
            for idx, expected, actual in res.encode_mismatches:
                print(
                    f"  idx {idx:02d}: expected 0x{expected:02x} from FP9 model, got 0x{actual:02x}"
                )
            for idx, expected, actual in res.decode_mismatches:
                print(
                    f"  idx {idx:02d}: expected FP16 0x{expected:04x} from spec, got 0x{actual:04x}"
                )

    return 1


if __name__ == "__main__":
    sys.exit(main())
