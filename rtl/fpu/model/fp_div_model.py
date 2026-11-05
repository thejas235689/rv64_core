"""Bit-exact model of the binary32/binary64 divider (fdiv).

The quotient is not exact in general, so the model computes it to 2*fbits+64
extra bits and folds the remainder into the sticky.  That is far more than the
guard/round/sticky bits the rounder looks at, which is what makes the model
usable as an oracle for all five rounding modes.
"""

from fp_common import FFL_DZ, FFL_NV, exact_div, fmt_of


def fdiv(a, b, rm=0, fmt=1):
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
    if a_inf and b_inf:
        return F.qnan(), FFL_NV                       # inf / inf
    if a_zero and b_zero:
        return F.qnan(), FFL_NV                       # 0 / 0
    if b_zero:
        return F.inf(sign), FFL_DZ                    # finite / 0
    if a_inf:
        return F.inf(sign), 0
    if b_inf or a_zero:
        return F.zero(sign), 0

    _, ma, ea = F.decompose(a)
    _, mb, eb = F.decompose(b)
    return exact_div(sa, ma, ea, sb, mb, eb, rm, F)
