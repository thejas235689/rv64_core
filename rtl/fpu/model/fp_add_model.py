"""Bit-exact model of the binary64 adder, to be transcribed to RTL line for line.

Working format, 57 bits:
    [56] carry out
    [55] implicit leading one
    [54:3] fraction (52 bits)
    [2]  round
    [1]  guard
    [0]  sticky

Three guard bits, not two: with {round, sticky} the normalisation shift pushes the
alignment sticky into the round position, so an EXACT result is read as needing a
round-up. That is the bug that cost six failed patches.
"""

M52 = (1 << 52) - 1
QNAN = 0x7FF8000000000000
INF = 0x7FF0000000000000


def fp_add(a: int, b: int, sub: int = 0):
    """Return (result_bits, invalid, inexact)."""
    sa, ea, fa = a >> 63, (a >> 52) & 0x7FF, a & M52
    sb, eb, fb = b >> 63, (b >> 52) & 0x7FF, b & M52

    a_nan = ea == 0x7FF and fa != 0
    b_nan = eb == 0x7FF and fb != 0
    a_inf = ea == 0x7FF and fa == 0
    b_inf = eb == 0x7FF and fb == 0
    a_zero = ea == 0 and fa == 0
    b_zero = eb == 0 and fb == 0
    sb_eff = sb ^ sub

    # ---- specials first, exactly as the RTL overrides at the end ----------
    if a_nan or b_nan:
        return QNAN, 0, 0
    if a_inf and b_inf and sa != sb_eff:
        return QNAN, 1, 0
    if a_inf:
        return (sa << 63) | INF, 0, 0
    if b_inf:
        return (sb_eff << 63) | INF, 0, 0
    if a_zero and b_zero:
        return (0x8000000000000000 if (sa and sb_eff) else 0), 0, 0
    if a_zero:
        return (sb_eff << 63) | (eb << 52) | fb, 0, 0
    if b_zero:
        return a, 0, 0

    # ---- order by magnitude ------------------------------------------------
    a_bigger = (ea > eb) or (ea == eb and fa >= fb)
    if a_bigger:
        e_big, f_big, s_big = ea, fa, sa
        e_sml, f_sml, s_sml = eb, fb, sb_eff
    else:
        e_big, f_big, s_big = eb, fb, sb_eff
        e_sml, f_sml, s_sml = ea, fa, sa

    sig_big = (1 << 52) | f_big          # implicit one included; denormals not
    sig_sml = (1 << 52) | f_sml          # handled below
    if e_big == 0:
        sig_big = f_big
    if e_sml == 0:
        sig_sml = f_sml

    diff = e_big - e_sml

    # Align into a field WIDER than the 53-bit significand so the low bits are
    # KEPT, not collapsed into a sticky. The result exponent can drop below e_big
    # during normalisation, which makes those low bits representable -- collapsing
    # them is what made vec140's exact sum look like it needed rounding.
    #   aligned = sig_sml * 2**ALIGN_EXT / 2**diff
    ALIGN_EXT = 3
    if diff > 53 + ALIGN_EXT:
        aligned = 0
        sticky = sig_sml != 0
    else:
        aligned = (sig_sml << ALIGN_EXT) >> diff
        lost = diff - ALIGN_EXT
        sticky = (sig_sml & ((1 << lost) - 1)) != 0 if lost > 0 else False

    # mag layout, 59 bits: [58]=carry [57]=implicit [56:5]=frac [4:3]=extra
    #                     [2]=round [1]=guard [0]=sticky
    mag_big = sig_big << 5
    mag_sml = (aligned << 2) | (1 if sticky else 0)

    if s_big == s_sml:
        mag = mag_big + mag_sml
        sign = s_big
    else:
        mag = mag_big - mag_sml
        sign = s_big

    exp = e_big
    inexact = 0

    # ---- normalise so the implicit one sits at bit 57 ---------------------
    if mag >> 58:
        inexact |= mag & 1
        mag >>= 1
        exp += 1
    else:
        while not (mag >> 57) and exp > 1:
            mag <<= 1
            exp -= 1
        if mag == 0:
            return 0, 0, 0

    frac = (mag >> 5) & M52
    rnd = (mag >> 4) & 1
    guard = (mag >> 3) & 1
    stk = 1 if (mag & 0x7) else 0

    up = rnd and (guard or stk or (frac & 1))
    inexact |= rnd | guard | stk
    if up:
        frac += 1
        if frac >> 52:
            frac = 0
            exp += 1

    if exp >= 0x7FF:
        return (sign << 63) | INF, 0, 1
    return (sign << 63) | (exp << 52) | (frac & M52), 0, inexact
