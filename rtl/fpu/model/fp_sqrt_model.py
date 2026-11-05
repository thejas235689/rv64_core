"""Bit-exact model of the binary32/binary64 square root (fsqrt).

sqrt is required to be correctly rounded, so the model computes
floor(sqrt(m * 2**(2k))) for a large k with the remainder folded into the
sticky -- an exact integer square root, not an approximation.
"""

from fp_common import FFL_NV, exact_sqrt, fmt_of


def fsqrt(a, rm=0, fmt=1):
    """Return (result_bits, flags)."""
    F = fmt_of(fmt)
    a &= (1 << F.width) - 1
    sa, _, _ = F.fields(a)
    a_nan = F.is_nan(a)
    a_zero = F.is_zero(a)
    a_inf = F.is_inf(a)

    if a_nan:
        return F.qnan(), FFL_NV if F.is_snan(a) else 0
    if a_zero:
        return a, 0                                   # sqrt(+-0) = +-0
    if sa:
        return F.qnan(), FFL_NV                       # sqrt of a negative
    if a_inf:
        return F.inf(0), 0

    _, ma, ea = F.decompose(a)
    return exact_sqrt(sa, ma, ea, rm, F)
