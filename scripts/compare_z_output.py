#!/usr/bin/env python3
"""Compare hardware Z store output (muxed stream) against golden_mx."""
import re, sys

def read_fp8_outputs(path):
    """Read mx_encoder_fp8_outputs.txt — each line is 32 FP8 bytes as hex string."""
    all_bytes = []
    with open(path) as f:
        for line in f:
            hex_str = line.strip()
            for i in range(0, len(hex_str), 2):
                all_bytes.append(int(hex_str[i:i+2], 16))
    return all_bytes

def read_golden_mx(path):
    """Read golden_mx.h — uint32_t array packed with 4 FP8 values per word."""
    with open(path) as f:
        text = f.read()
    values = re.findall(r'0x[0-9a-fA-F]+', text)
    all_bytes = []
    for v in values:
        word = int(v, 16)
        all_bytes.append(word & 0xFF)
        all_bytes.append((word >> 8) & 0xFF)
        all_bytes.append((word >> 16) & 0xFF)
        all_bytes.append((word >> 24) & 0xFF)
    return all_bytes

def main():
    fp8_path = "target/sim/vsim/mx_encoder_fp8_outputs.txt"
    golden_path = "sw/inc/golden_mx.h"

    hw = read_fp8_outputs(fp8_path)
    golden = read_golden_mx(golden_path)

    print(f"Hardware bytes: {len(hw)}")
    print(f"Golden bytes:   {len(golden)}")

    min_len = min(len(hw), len(golden))
    errors = 0
    first_err = None
    err_by_region = {}

    # MX96 tile regions
    ARRAY_WIDTH = 32
    TILE = 64
    M, K = 96, 96
    regions = []
    offset = 0
    for m_start in range(0, M, ARRAY_WIDTH):
        m_end = min(m_start + ARRAY_WIDTH, M)
        for k_start in range(0, K, TILE):
            k_end = min(k_start + TILE, K)
            n_rows = m_end - m_start
            n_cols = k_end - k_start
            size = n_rows * n_cols  # FP8 bytes
            regions.append((f"m={m_start}-{m_end-1},k={k_start}-{k_end-1}", offset, offset+size))
            offset += size

    for i in range(min_len):
        if hw[i] != golden[i]:
            errors += 1
            if first_err is None:
                first_err = i
            # Find region
            for name, start, end in regions:
                if start <= i < end:
                    err_by_region[name] = err_by_region.get(name, 0) + 1
                    break

    print(f"\nTotal byte mismatches: {errors} / {min_len}")
    if first_err is not None:
        print(f"First error at byte {first_err} (0x{first_err:x})")
        print(f"  Golden: 0x{golden[first_err]:02x}  Actual: 0x{hw[first_err]:02x}")
        # Show context
        print(f"\n  Context around first error (byte {first_err}):")
        for j in range(max(0, first_err-4), min(min_len, first_err+8)):
            match = "✓" if hw[j] == golden[j] else "✗"
            print(f"    [{j}] golden=0x{golden[j]:02x} actual=0x{hw[j]:02x} {match}")

    print(f"\nErrors by tile region:")
    for name, start, end in regions:
        size = end - start
        e = err_by_region.get(name, 0)
        print(f"  {name}: {e}/{size} errors ({100*e/size:.1f}%)")

    # Check first 16 bytes of each region
    print(f"\nFirst 8 bytes of each tile (golden vs actual):")
    for name, start, end in regions:
        g = ' '.join(f'{golden[start+j]:02x}' for j in range(min(8, end-start)))
        h = ' '.join(f'{hw[start+j]:02x}' for j in range(min(8, end-start)))
        match = "✓" if g == h else "✗"
        print(f"  {name}: golden={g}")
        print(f"  {' '*len(name)}  actual={h} {match}")

if __name__ == '__main__':
    main()
