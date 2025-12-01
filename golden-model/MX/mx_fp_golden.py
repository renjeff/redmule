# Minimal golden model for MX <-> FP16 encode/decode.

import numpy as np

# Biases
BIAS_FP8_E4M3 = 7
BIAS_FP16     = 15

# Max finite FP16: 0 11110 1111111111
FP16_MAX_POS = 0x7BFF


# -------------------------------------------------------------------
# Low-level helpers: FP8(E4M3) <-> FP16 bit patterns
# -------------------------------------------------------------------

def fp8_e4m3_to_fp16_bits(x: int) -> int:
    """
    Convert one FP8(E4M3) value (8-bit int) to FP16 (16-bit int):
      - e8 == 0000         -> signed zero
      - e8 == 1111, m=0    -> +/-Inf
      - e8 == 1111, m!=0   -> +/-NaN (quiet, mantissa bit 9 set)
      - normal             -> exponent rebias, mantissa << 7
    """
    x &= 0xFF # ensure 8-bit input
    s  = (x >> 7) & 0x1 # sign bit
    e8 = (x >> 3) & 0xF # exponent bits
    m8 = x & 0x7 # mantissa bits

    # zero + subnormals -> signed zero
    if e8 == 0:
        return (s << 15)

    # Inf / NaN
    if e8 == 0xF:
        if m8 == 0:
            # Inf
            return (s << 15) | (0x1F << 10)          # 0x7c00 / 0xfc00
        else:
            # NaN (quiet, mantissa bit 9 = 1)
            return (s << 15) | (0x1F << 10) | (1 << 9)  # 0x7e00 / 0xfe00

    # normal
    e16_int = int(e8) - BIAS_FP8_E4M3 + BIAS_FP16
    e16     = e16_int & 0x1F
    m16     = (m8 << 7) & 0x3FF  # pad mantissa

    return (s << 15) | (e16 << 10) | m16


def mx_scale_fp16_bits(val_fp16: int, shared_exp: int) -> int:
    """
    Apply MX shared exponent E8M0 to a FP16 bit-pattern.

      val_scaled = val * 2^(shared_exp - 127)

    Behaviour matches your SV mx_scale_fp16:

      - zero / Inf / NaN        -> returned as-is
      - underflow (new_e16 <=0) -> signed zero
      - overflow (new_e16 >=31) -> clamp to max finite (0x7bff) with sign
    """
    val_fp16   = int(val_fp16) & 0xFFFF
    shared_exp = int(shared_exp) & 0xFF

    s   = (val_fp16 >> 15) & 0x1
    e16 = (val_fp16 >> 10) & 0x1F
    m16 = val_fp16 & 0x3FF

    # zero, Inf, NaN: return as is
    if e16 == 0 or e16 == 0x1F:
        return val_fp16

    delta   = shared_exp - 127
    new_e16 = int(e16) + delta

    # underflow -> signed zero
    if new_e16 <= 0:
        return (s << 15)

    # overflow -> clamp to max finite magnitude
    if new_e16 >= 31:
        return (s << 15) | (FP16_MAX_POS & 0x7FFF)

    # normal scaled
    e16_new = new_e16 & 0x1F
    return (s << 15) | (e16_new << 10) | m16


# -------------------------------------------------------------------
# MXFP8 <-> FP16 element-wise encode / decode
# -------------------------------------------------------------------

def mxfp8_decode_bits(fp8_val: int, shared_exp: int) -> int:
    """
    Element-wise MXFP8 -> FP16 (bit patterns).

    First FP8(E4M3) -> FP16, then apply MX scaling with shared_exp.
    This is exactly what your decoder RTL does per element.
    """
    base   = fp8_e4m3_to_fp16_bits(fp8_val)
    scaled = mx_scale_fp16_bits(base, shared_exp)
    return scaled


def fp16_bits_to_fp8_e4m3_unscaled(x: int) -> int:
    """
    Reference quantiser FP16 -> FP8(E4M3) WITHOUT MX scaling.

    Policy:
      - zero          -> ±0
      - Inf / NaN     -> FP8 Inf / NaN
      - normals       -> rebias exponent, saturate to max finite E4M3,
                         flush tiny to zero, simple mantissa truncation
    This is a reasonable inverse of fp8_e4m3_to_fp16_bits.
    """
    x &= 0xFFFF
    s   = (x >> 15) & 0x1
    e16 = (x >> 10) & 0x1F
    m16 = x & 0x3FF

    # zero
    if e16 == 0:
        return s << 7

    # Inf / NaN
    if e16 == 0x1F:
        if m16 == 0:
            # Inf
            return (s << 7) | (0xF << 3)
        else:
            # NaN
            return (s << 7) | (0xF << 3) | 0x1

    # normal
    e_unbiased = int(e16) - BIAS_FP16
    e8_unbiased = e_unbiased + BIAS_FP8_E4M3

    # too small -> zero
    if e8_unbiased <= 0:
        return s << 7

    # too large -> max finite (e=1110, m=111)
    if e8_unbiased >= 0xF:
        return (s << 7) | (0xE << 3) | 0x7

    e8 = e8_unbiased & 0xF
    m8 = (m16 >> 7) & 0x7  # truncation; can add rounding later

    return (s << 7) | (e8 << 3) | m8


def mxfp8_encode_bits(val_fp16: int, shared_exp: int) -> int:
    """
    Element-wise FP16 -> MXFP8 (bit patterns).

    Assumes the decode side does:
      fp8 -> fp16_unscaled -> scale by 2^(shared_exp - 127).

    So to encode, we *undo* the MX scaling on the FP16 value first,
    then quantise that to FP8(E4M3).

    This gives a clean, invertible pair (up to quantisation) with
    mxfp8_decode_bits().
    """
    val_fp16   = int(val_fp16) & 0xFFFF
    shared_exp = int(shared_exp) & 0xFF

    s   = (val_fp16 >> 15) & 0x1
    e16 = (val_fp16 >> 10) & 0x1F
    m16 = val_fp16 & 0x3FF

    # zero / Inf / NaN: don't try to rescale, just map directly
    if e16 == 0 or e16 == 0x1F:
        return fp16_bits_to_fp8_e4m3_unscaled(val_fp16)

    # undo MX scaling in exponent domain:
    # decode did: e16_scaled = e16_unscaled + delta
    # so here:   e16_unscaled = e16_scaled - delta
    delta      = shared_exp - 127
    e_unbiased = int(e16) - BIAS_FP16
    e_unscaled = e_unbiased - delta
    e16_uns    = e_unscaled + BIAS_FP16

    if e16_uns <= 0:
        tmp = (s << 15)  # underflow to zero
    elif e16_uns >= 0x1F:
        # overflow before quantisation: clamp to max finite FP16
        tmp = (s << 15) | (0x1E << 10) | 0x3FF
    else:
        tmp = (s << 15) | ((e16_uns & 0x1F) << 10) | m16

    return fp16_bits_to_fp8_e4m3_unscaled(tmp)


# -------------------------------------------------------------------
# Small float16 wrappers
# -------------------------------------------------------------------

def mxfp8_decode(fp8_val: int, shared_exp: int) -> np.float16:
    """MXFP8 -> FP16 as a numpy.float16 scalar."""
    bits = np.uint16(mxfp8_decode_bits(fp8_val, shared_exp))
    return bits.view(np.float16)


def mxfp8_encode(val_fp16: np.float16, shared_exp: int) -> int:
    """FP16 (numpy.float16 scalar) -> MXFP8 8-bit value."""
    bits = np.uint16(np.array(val_fp16, dtype=np.float16).view(np.uint16))
    return mxfp8_encode_bits(int(bits), shared_exp)
