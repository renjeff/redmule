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
    e8 = e8_unbiased & 0xF

    # --- RNE rounding of mantissa: 10 bits -> 3 bits ---
    m8_trunc = (m16 >> 7) & 0x7              # m16[9:7]
    round_bit = (m16 >> 6) & 0x1             # m16[6]
    sticky = 1 if (m16 & 0x3F) != 0 else 0   # OR m16[5:0]

    # round-to-nearest, ties-to-even:
    # RS=00/01 -> down
    # RS=10 -> tie -> up iff LSB==1
    # RS=11 -> up
    if round_bit == 0:
        round_up = 0
    else:
        # round_bit == 1
        if sticky == 1:
            round_up = 1
        else:
            # exact half-way tie
            round_up = (m8_trunc & 0x1)

    m8_round = m8_trunc + round_up

    # handle mantissa carry into exponent
    if m8_round == 0x8:  # overflowed past 3 bits (1000)
        m8_round = 0x0
        e8 += 1
        # clamp if exponent would become 0xF (Inf/NaN encoding in FP8)
        if e8 >= 0xF:
            return (s << 7) | (0xE << 3) | 0x7

    return (s << 7) | ((e8 & 0xF) << 3) | (m8_round & 0x7)

def mxfp8_encode_bits(val_fp16: int, shared_exp: int) -> int:
    """
    Element-wise FP16 -> MXFP8 (bit patterns).

    Decode side does:
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
    delta      = shared_exp - 127  #signed
    e16_unscaled   = int(e16) - delta # back to pre-scaled exponent

    if e16_unscaled <= 0:
        tmp = (s << 15)  # underflow to zero
    elif e16_unscaled >= 0x1F:
        # overflow before quantisation: clamp to max finite FP16
        tmp = (s << 15) | (0x1E << 10) | 0x3FF
    else:
        tmp = (s << 15) | ((e16_unscaled & 0x1F) << 10) | m16

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

def compute_shared_exp_from_block(fp16_block_bits):
    """
    Compute MX shared exponent from a block of FP16 values.

    currently: zero-extended max_16 to 8 bits

    fp16_block_bits: list[int] of FP16 bit patterns
    """
    fp16_blocks_bits = [int(x) & 0xFFFF for x in fp16_block_bits]

    max_e16 = 0
    for x in fp16_block_bits:
        e16 = (x >> 10) & 0x1F
        if e16 != 0 and e16 != 0x1F and e16 > max_e16: # ignore zero/Inf/NaN
            max_e16 = e16
    
    # no normal values in block -> neutral scale
    if max_e16 == 0:
        return 127
    
    eM_unbiased = max_e16 - BIAS_FP16 # exponent of max |V|
    e_scale_unbiased = eM_unbiased - 7 # max pow2 exp in E4M3 = 7
    e8m0 = e_scale_unbiased + 127 # E8M0 bias

    if e8m0 < 0:
        e8m0 = 0
    elif e8m0 > 255:
        e8m0 = 255
    return e8m0 & 0xFF

def encode_block_fp16_to_mx(fp16_block_bits):
    """
    Given a block of FP16 values, compute:
    - shared_exp (8-bit)
    - mx_vals (list of MXFP8 values)

    using:

    - shared_exp = compute_sahred_exp_from_block(...)
    - fp8_i = mxfp8_encode_bits(fp16_i, shared_exp)

    returns (shared_exp, mx_vals)
    """

    fp16_block_bits = [int(x) & 0xFFFF for x in fp16_block_bits]

    shared_exp = compute_shared_exp_from_block(fp16_block_bits)

    mx_vals = [mxfp8_encode_bits(v, shared_exp) & 0xFF for v in fp16_block_bits]

    return shared_exp & 0xFF, mx_vals