"""Bit-exact model of the binary32/binary64 multiplier (fmul).

The product of two significands is an exact integer, so no precision is lost
before rounding; the model hands that integer to the shared rounder.
"""

from fp_common import FFL_NV, exact_mul, fmt_of


def fmul(a, b, rm=0, fmt=1):
    """Return (result_bits, flags)."""
    F = fmt_of(fmt)
    a &= (1 << F.width) - 1
    b &= (1 << F.width) - 1

    sa, _, _ = F.fields(a)
    sb, _, _ = F.fields(b)
    a_nan, b_nan = F.is_nan(a), F.is_nan(b)
    a_inf, b_inf = F.is_inf(a), F.is_inf(b)
    a_zero, b_zero = F.is_zero(a), F.is_zero(b)
    sign = sa ^ sb

    if a_nan or b_nan:
        return F.qnan(), FFL_NV if (F.is_snan(a) or F.is_snan(b)) else 0
    if (a_inf and b_zero) or (a_zero and b_inf):
        return F.qnan(), FFL_NV                       # inf * 0
    if a_inf or b_inf:
        return F.inf(sign), 0
    if a_zero or b_zero:
        return F.zero(sign), 0

    _, ma, ea = F.decompose(a)
    _, mb, eb = F.decompose(b)
    return exact_mul(sa, ma, ea, sb, mb, eb, rm, F)
