"""Bit-exact model of the binary32/binary64 adder (fadd / fsub).

The model computes the sum EXACTLY with Python integers at a common scale and
only then rounds, so it is an independent oracle rather than a transcription of
the RTL's alignment/normalise stages.  That matters: the original version of
this file mirrored the RTL stage by stage and therefore reproduced the RTL's
three-ulp defect instead of catching it (see README.md).

History kept deliberately: the defect was an alignment sticky collapsed to one
bit at weight zero, while the low bit of `b` sat at exactly one ulp of the FINAL
result -- the result exponent drops during normalisation, so that bit is
representable and must not be turned into a sticky.  Computing the exact sum
first makes that class of bug impossible to write down.

The special-case order below mirrors rtl/fpu/rv64_fp_add.sv one for one, because
the RTL's override order is observable (inf + -inf is invalid, a NaN wins over
everything, x + 0 is exact).
"""

from fp_common import (FMT, FFL_NV, exact_add, fmt_of)


def fp_add(a, b, sub=0, rm=0, fmt=1):
    """Return (result_bits, flags) for a + b (sub=1: a - b)."""
    F = fmt_of(fmt)
    a &= (1 << F.width) - 1
    b &= (1 << F.width) - 1

    sa, ea, fa = F.fields(a)
    sb, eb, fb = F.fields(b)
    sb_eff = sb ^ (sub & 1)

    a_nan, b_nan = F.is_nan(a), F.is_nan(b)
    a_inf, b_inf = F.is_inf(a), F.is_inf(b)
    a_zero, b_zero = F.is_zero(a), F.is_zero(b)

    # ---- specials, in the RTL's override order ---------------------------
    if a_nan or b_nan:
        return F.qnan(), FFL_NV if (F.is_snan(a) or F.is_snan(b)) else 0
    if a_inf and b_inf and sa != sb_eff:
        return F.qnan(), FFL_NV                       # inf + -inf
    if a_inf:
        return F.inf(sa), 0
    if b_inf:
        return F.inf(sb_eff), 0
    if a_zero and b_zero:
        return F.zero(1 if (sa and sb_eff) else 0), 0
    if a_zero:
        return F.make(sb_eff, eb, fb), 0
    if b_zero:
        return a, 0

    # ---- exact sum -------------------------------------------------------
    _, ma, ea_v = F.decompose(a)
    _, mb, eb_v = F.decompose(b)
    return exact_add(sa, ma, ea_v, sb_eff, mb, eb_v, rm, F)


def fp_sub(a, b, rm=0, fmt=1):
    return fp_add(a, b, 1, rm, fmt)
