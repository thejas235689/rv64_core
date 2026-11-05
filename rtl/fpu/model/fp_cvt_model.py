"""Bit-exact models of the fcvt family, both formats.

    fp <-> integer : fcvt.{w,wu,l,lu}.{s,d}   fcvt.{s,d}.{w,wu,l,lu}
    fp <-> fp      : fcvt.s.d  fcvt.d.s

Integer -> FP normalises the magnitude and rounds through the shared rounder, so
fcvt.d.l of a value wider than 2**53 rounds rather than truncating.

FP -> integer rounds the value to an integer and THEN range-checks the rounded
value.  The ordering matters: -0.5 under RTZ rounds to 0, which is representable,
so it must not raise invalid.  Out of range gives invalid plus the largest
positive or most negative value (NaN gives the largest positive), as the spec
asks, and a 32-bit result is sign- or zero-extended to XLEN.
"""

from fp_common import FFL_NV, FFL_NX, fmt_of, pack_from_int, round_to_int

MAXV = {0: 0xFFFFFFFF, 1: 0xFFFFFFFFFFFFFFFF}


def _limits(is_unsigned, bits):
    """(hi, lo) as 64-bit patterns, and the EXTENDED forms handed back to rd."""
    if is_unsigned:
        hi = MAXV[0] if bits == 32 else MAXV[1]
        lo = 0
        hi_ext = hi
        lo_ext = 0
    elif bits == 32:
        hi = 0x7FFFFFFF
        lo = 0x80000000
        hi_ext = 0x000000007FFFFFFF
        lo_ext = 0xFFFFFFFF80000000
    else:
        hi = 0x7FFFFFFFFFFFFFFF
        lo = 0x8000000000000000
        hi_ext = 0x7FFFFFFFFFFFFFFF
        lo_ext = 0x8000000000000000
    return hi, lo, hi_ext, lo_ext


def fcvt_to_int(a, is_unsigned, bits, rm, fmt=1):
    """FP -> integer.  Returns (result, flags)."""
    F = fmt_of(fmt)
    a &= (1 << F.width) - 1
    hi, lo, hi_ext, lo_ext = _limits(is_unsigned, bits)
    sa = F.fields(a)[0]

    if F.is_nan(a):
        return hi_ext, FFL_NV
    if F.is_inf(a):
        return (lo_ext if sa else hi_ext), FFL_NV

    _, m, e = F.decompose(a)
    mag, inexact = round_to_int(sa, m, e, rm)
    if not sa and mag > hi:
        return hi_ext, FFL_NV
    if sa and mag > lo:
        return lo_ext, FFL_NV

    iv = (-mag) & MAXV[1] if sa else mag
    if bits == 32:
        v = iv & 0xFFFFFFFF
        out = v if is_unsigned else ((v ^ 0x80000000) - 0x80000000) & MAXV[1]
    else:
        out = iv & MAXV[1]
    return out, (FFL_NX if inexact else 0)


def fcvt_from_int(x, is_unsigned, bits, rm, fmt=1):
    """integer -> FP.  Returns (result, flags)."""
    F = fmt_of(fmt)
    x &= MAXV[1]
    if bits == 32:
        v = x & 0xFFFFFFFF
        src = v if is_unsigned else ((v ^ 0x80000000) - 0x80000000) & MAXV[1]
    else:
        src = x
    neg = (not is_unsigned) and bool(src >> 63)
    mag = ((-src) & MAXV[1]) if neg else src
    if mag == 0:
        return F.zero(0), 0
    return pack_from_int(1 if neg else 0, mag, 0, rm, F)


def fcvt_fp(a, src_fmt, dst_fmt, rm):
    """FP -> FP (fcvt.s.d / fcvt.d.s).  Returns (result, flags).

    s -> d is exact; d -> s rounds.  A NaN becomes the destination's canonical
    quiet NaN, and only a signalling NaN raises invalid.
    """
    S = fmt_of(src_fmt)
    D = fmt_of(dst_fmt)
    a &= (1 << S.width) - 1
    if S.is_nan(a):
        return D.qnan(), FFL_NV if S.is_snan(a) else 0
    sa = S.fields(a)[0]
    if S.is_inf(a):
        return D.inf(sa), 0
    if S.is_zero(a):
        return D.zero(sa), 0
    _, m, e = S.decompose(a)
    return pack_from_int(sa, m, e, rm, D)
