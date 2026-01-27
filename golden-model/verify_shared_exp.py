#!/usr/bin/env python3
"""Cross-check MX shared-exponent computation against the spec formula."""

from __future__ import annotations

import argparse
import random
from typing import Iterable, List

import numpy as np

from MX import mx_fp_golden


BIAS_FP16 = 15
MX_MANTISSA_MAX_EXP = 7  # max unbiased exponent in FP8(E4M3)
BIAS_E8M0 = 127


def spec_shared_exp(fp16_block_bits: Iterable[int]) -> int:
    max_e16 = 0
    for value in fp16_block_bits:
        e16 = (int(value) >> 10) & 0x1F
        if e16 == 0 or e16 == 0x1F:
            continue  # skip zero/inf/nan per MX spec
        if e16 > max_e16:
            max_e16 = e16

    if max_e16 == 0:
        return 127  # neutral scale when block has no normals

    eM_unbiased = max_e16 - BIAS_FP16
    e_scale_unbiased = eM_unbiased - MX_MANTISSA_MAX_EXP
    e8m0 = e_scale_unbiased + BIAS_E8M0
    return max(0, min(255, e8m0)) & 0xFF


def _fp16_samples(count: int, rng: np.random.Generator) -> List[int]:
    values = (rng.standard_normal(count) * 32).astype(np.float16)
    return values.view(np.uint16).tolist()


def _directed_samples() -> List[List[int]]:
    blocks = []

    # only zeros -> neutral exponent
    blocks.append([0x0000] * 32)

    # mix zero, inf, NaN -> still neutral
    blocks.append([0x0000, 0x7C00, 0xFC00, 0x7E00, 0xFE00] + [0x0000] * 27)

    # smallest normal value (exp=1) should pick shared exp below bias
    blocks.append([0x0400] + [0x0000] * 31)

    # include max finite -> saturate to 255
    blocks.append([0x7BFF] * 32)

    # subnormals only -> neutral
    blocks.append([0x0001, 0x8001] + [0x0000] * 30)

    return blocks


def run(blocks: int, block_size: int, seed: int) -> int:
    rng = np.random.default_rng(seed)
    mismatches = 0

    for idx in range(blocks):
        block = _fp16_samples(block_size, rng)
        ref = spec_shared_exp(block)
        uut = mx_fp_golden.compute_shared_exp_from_block(block)
        if ref != uut:
            print(
                f"Random block {idx}: spec=0x{ref:02x} uut=0x{uut:02x} | "
                f"vals={block}"
            )
            mismatches += 1

    for idx, block in enumerate(_directed_samples()):
        ref = spec_shared_exp(block)
        uut = mx_fp_golden.compute_shared_exp_from_block(block)
        if ref != uut:
            print(
                f"Directed block {idx}: spec=0x{ref:02x} uut=0x{uut:02x} | "
                f"vals={block}"
            )
            mismatches += 1

    if mismatches == 0:
        print(
            f"✅ Shared exponent matches spec for {blocks} random blocks +"
            f" {len(_directed_samples())} directed cases"
        )

    return mismatches


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify MX shared exponent computation")
    parser.add_argument("--blocks", type=int, default=1000, help="Random blocks to test")
    parser.add_argument("--block-size", type=int, default=32, help="Elements per block")
    parser.add_argument("--seed", type=int, default=1, help="RNG seed")
    args = parser.parse_args()

    mismatches = run(args.blocks, args.block_size, args.seed)
    return 0 if mismatches == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
