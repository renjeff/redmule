# Minimal golden model for MX <-> FP16 encode/decode.
# Supports multiple MX formats: E4M3, E5M2, E3M2, E2M3, E2M1.

import numpy as np

# FP16 bias
BIAS_FP16 = 15

# Max finite FP16: 0 11110 1111111111
FP16_MAX_POS = 0x7BFF

# Format specifications: (exp_bits, mant_bits, bias)
MX_FORMAT_SPECS = {
    'e4m3': (4, 3, 7),
    'e5m2': (5, 2, 15),
    'e3m2': (3, 2, 3),
    'e2m3': (2, 3, 1),
    'e2m1': (2, 1, 1),
}

# Legacy aliases
BIAS_FP8_E4M3 = 7


# -------------------------------------------------------------------
# Generic MX element <-> FP16 bit patterns (format-parameterized)
# -------------------------------------------------------------------

def mx_elem_to_fp16_bits(x: int, exp_bits: int, mant_bits: int, bias: int) -> int:
    """
    Convert one MX element (up to 8-bit container) to FP16 (16-bit int).
    Format: [sign(1) | exponent(exp_bits) | mantissa(mant_bits)]

      - e == 0          -> signed zero
      - e == all-ones    -> +/-Inf (m=0) or +/-NaN (m!=0)
      - normal           -> exponent rebias, mantissa left-aligned to 10 bits
    """
    bitwidth = 1 + exp_bits + mant_bits
    x &= (1 << bitwidth) - 1

    s = (x >> (exp_bits + mant_bits)) & 0x1
    exp_mask = (1 << exp_bits) - 1
    mant_mask = (1 << mant_bits) - 1
    e = (x >> mant_bits) & exp_mask
    m = x & mant_mask

    # zero + subnormals -> signed zero
    if e == 0:
        return (s << 15)

    # Inf / NaN (all-ones exponent)
    if e == exp_mask:
        if m == 0:
            return (s << 15) | (0x1F << 10)             # Inf
        else:
            return (s << 15) | (0x1F << 10) | (1 << 9)  # NaN

    # normal: rebias exponent, left-align mantissa
    e16_int = int(e) - bias + BIAS_FP16
    e16 = e16_int & 0x1F
    m16 = (m << (10 - mant_bits)) & 0x3FF

    return (s << 15) | (e16 << 10) | m16


def mx_scale_fp16_bits(val_fp16: int, shared_exp: int) -> int:
    """
    Apply MX shared exponent E8M0 to a FP16 bit-pattern.
    Format-independent (operates only on FP16 + shared_exp).
    """
    val_fp16   = int(val_fp16) & 0xFFFF
    shared_exp = int(shared_exp) & 0xFF

    s   = (val_fp16 >> 15) & 0x1
    e16 = (val_fp16 >> 10) & 0x1F
    m16 = val_fp16 & 0x3FF

    if e16 == 0 or e16 == 0x1F:
        return val_fp16

    delta   = shared_exp - 127
    new_e16 = int(e16) + delta

    if new_e16 <= 0:
        return (s << 15)
    if new_e16 >= 31:
        return (s << 15) | (FP16_MAX_POS & 0x7FFF)

    e16_new = new_e16 & 0x1F
    return (s << 15) | (e16_new << 10) | m16


def mx_decode_bits(val: int, shared_exp: int, exp_bits: int, mant_bits: int, bias: int) -> int:
    """Generic MX element -> FP16 decode (bit patterns)."""
    base   = mx_elem_to_fp16_bits(val, exp_bits, mant_bits, bias)
    scaled = mx_scale_fp16_bits(base, shared_exp)
    return scaled


def fp16_to_mx_elem_unscaled(x: int, exp_bits: int, mant_bits: int, bias: int) -> int:
    """
    FP16 -> MX element WITHOUT MX scaling (generic, format-parameterized).
    Uses RNE rounding on mantissa truncation.
    """
    x &= 0xFFFF
    s   = (x >> 15) & 0x1
    e16 = (x >> 10) & 0x1F
    m16 = x & 0x3FF

    bitwidth = 1 + exp_bits + mant_bits
    exp_mask = (1 << exp_bits) - 1
    mant_mask = (1 << mant_bits) - 1
    max_finite_exp = exp_mask - 1  # all-ones minus 1

    # zero
    if e16 == 0:
        return s << (exp_bits + mant_bits)

    # Inf / NaN
    # Inf / NaN
    if e16 == 0x1F:
        if m16 == 0:
            return (s << (exp_bits + mant_bits)) | (exp_mask << mant_bits)
        else:
            return (s << (exp_bits + mant_bits)) | (exp_mask << mant_bits) | 0x1

    # normal: rebias
    e_unbiased = int(e16) - BIAS_FP16
    e_biased = e_unbiased + bias

    if e_biased <= 0:
        return s << (exp_bits + mant_bits)  # underflow to zero

    if e_biased > max_finite_exp:
        return (s << (exp_bits + mant_bits)) | (max_finite_exp << mant_bits) | mant_mask

    e_out = e_biased & exp_mask

    # RNE rounding: truncate 10-bit mantissa to mant_bits
    shift = 10 - mant_bits
    m_trunc = (m16 >> shift) & mant_mask
    round_bit = (m16 >> (shift - 1)) & 0x1 if shift > 0 else 0
    sticky = 1 if (m16 & ((1 << (shift - 1)) - 1)) != 0 else 0 if shift > 1 else 0

    if round_bit == 0:
        round_up = 0
    elif sticky == 1:
        round_up = 1
    else:
        round_up = (m_trunc & 0x1)  # tie-to-even

    m_round = m_trunc + round_up

    if m_round > mant_mask:  # mantissa overflow
        m_round = 0
        e_out += 1
        if e_out > max_finite_exp:
            return (s << (exp_bits + mant_bits)) | (max_finite_exp << mant_bits) | mant_mask

    return (s << (exp_bits + mant_bits)) | ((e_out & exp_mask) << mant_bits) | (m_round & mant_mask)


def mx_encode_bits(val_fp16: int, shared_exp: int, exp_bits: int, mant_bits: int, bias: int) -> int:
    """
    FP16 -> MX element (bit patterns) with shared exponent scaling.
    Undoes MX scaling, then quantizes to target format.
    """
    val_fp16   = int(val_fp16) & 0xFFFF
    shared_exp = int(shared_exp) & 0xFF

    s   = (val_fp16 >> 15) & 0x1
    e16 = (val_fp16 >> 10) & 0x1F
    m16 = val_fp16 & 0x3FF

    if e16 == 0 or e16 == 0x1F:
        return fp16_to_mx_elem_unscaled(val_fp16, exp_bits, mant_bits, bias)

    delta = shared_exp - 127
    e16_unscaled = int(e16) - delta

    if e16_unscaled <= 0:
        tmp = (s << 15)
    elif e16_unscaled >= 0x1F:
        tmp = (s << 15) | (0x1E << 10) | 0x3FF
    else:
        tmp = (s << 15) | ((e16_unscaled & 0x1F) << 10) | m16

    return fp16_to_mx_elem_unscaled(tmp, exp_bits, mant_bits, bias)


def compute_shared_exp_from_block(fp16_block_bits, max_unbiased_exp=7):
    """
    Compute MX shared exponent from a block of FP16 values.
    max_unbiased_exp: max unbiased exponent for target format (E4M3=7, E5M2=15, etc.)
    """
    max_e16 = 0
    for x in fp16_block_bits:
        e16 = (int(x) >> 10) & 0x1F
        if e16 != 0 and e16 != 0x1F and e16 > max_e16:
            max_e16 = e16

    if max_e16 == 0:
        return 127

    eM_unbiased = max_e16 - BIAS_FP16
    e_scale_unbiased = eM_unbiased - max_unbiased_exp
    e8m0 = e_scale_unbiased + 127

    if e8m0 < 0:
        e8m0 = 0
    elif e8m0 > 255:
        e8m0 = 255
    return e8m0 & 0xFF


def encode_block_fp16_to_mx(fp16_block_bits, fmt='e4m3'):
    """
    Given a block of FP16 values, compute shared_exp and encode to MX format.
    fmt: format key from MX_FORMAT_SPECS (default 'e4m3')
    Returns (shared_exp, mx_vals)
    """
    exp_bits, mant_bits, bias = MX_FORMAT_SPECS[fmt]
    # Formats with Inf/NaN: max_finite_biased = 2^exp_bits - 2 (all-ones is special)
    # Formats without (E2M1, E2M3): max_finite_biased = 2^exp_bits - 1 (all normal)
    max_finite_biased = (1 << exp_bits) - 2
    max_ub = max_finite_biased - bias

    fp16_block_bits = [int(x) & 0xFFFF for x in fp16_block_bits]
    shared_exp = compute_shared_exp_from_block(fp16_block_bits, max_unbiased_exp=max_ub)

    elem_mask = (1 << (1 + exp_bits + mant_bits)) - 1
    mx_vals = [mx_encode_bits(v, shared_exp, exp_bits, mant_bits, bias) & elem_mask
               for v in fp16_block_bits]

    return shared_exp & 0xFF, mx_vals


# -------------------------------------------------------------------
# Backward-compatible wrappers (E4M3 default)
# -------------------------------------------------------------------

def fp8_e4m3_to_fp16_bits(x: int) -> int:
    return mx_elem_to_fp16_bits(x, 4, 3, 7)

def mxfp8_decode_bits(fp8_val: int, shared_exp: int) -> int:
    return mx_decode_bits(fp8_val, shared_exp, 4, 3, 7)

def fp16_bits_to_fp8_e4m3_unscaled(x: int) -> int:
    return fp16_to_mx_elem_unscaled(x, 4, 3, 7)

def mxfp8_encode_bits(val_fp16: int, shared_exp: int) -> int:
    return mx_encode_bits(val_fp16, shared_exp, 4, 3, 7)

def mxfp8_decode(fp8_val: int, shared_exp: int) -> np.float16:
    bits = np.uint16(mxfp8_decode_bits(fp8_val, shared_exp))
    return bits.view(np.float16)

def mxfp8_encode(val_fp16: np.float16, shared_exp: int) -> int:
    bits = np.uint16(np.array(val_fp16, dtype=np.float16).view(np.uint16))
    return mxfp8_encode_bits(int(bits), shared_exp)
