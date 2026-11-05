"""Bit-exact model of feq / flt / fle, both formats.

Only a SIGNALLING NaN raises invalid.  A quiet NaN compares false and is silent
-- the spec's rule, and the opposite of what a naive "any NaN is invalid" gets.
"""

from fp_common import FFL_NV, fmt_of

FEQ, FLT, FLE = 2, 1, 0


def fcmp(a, b, f3, fmt=1):
    """Return (0 or 1, flags).  f3: 0 fle, 1 flt, 2 feq."""
    F = fmt_of(fmt)
    a &= (1 << F.width) - 1
    b &= (1 << F.width) - 1

    if F.is_nan(a) or F.is_nan(b):
        return 0, FFL_NV if (F.is_snan(a) or F.is_snan(b)) else 0

    sa, ea, fa = F.fields(a)
    sb, eb, fb = F.fields(b)
    # -0 == +0: treat the two zero magnitude fields as equal
    both_zero = (ea == 0 and fa == 0) and (eb == 0 and fb == 0)
    if both_zero:
        eq, lt = True, False
    else:
        eq = a == b
        if sa != sb:
            lt = bool(sa)
        elif a == b:
            lt = False
        else:
            lt = ((b & ~F.sign_bit) < (a & ~F.sign_bit)) if sa else \
                 ((a & ~F.sign_bit) < (b & ~F.sign_bit))
    if f3 == FEQ:
        return int(eq), 0
    if f3 == FLT:
        return int(lt), 0
    return int(lt or eq), 0
