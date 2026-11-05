"""fp_common.py -- format descriptions and the ONE rounding routine.

Every operation model in this directory computes its exact intermediate result
as an integer `N` with a power-of-two scale, then hands it to `pack_from_int`,
which normalises it and calls `round_pack`.  `round_pack` is a line-for-line
mirror of rtl/fpu/rv64_fp_round.sv -- the same convention:

    sig = {implicit 1, fraction[FB-1:0], guard, round, sticky}      (FB+4 bits)
    value = sig * 2**(exp_in - (FB+3))

The RTL keeps that in one module for the same reason this file does: five
rounding modes are the easiest thing in an FPU to get subtly wrong, and a copy
per operation would be a copy per chance to disagree.

The models are exact rather than transcribed: `add`, `mul`, `div` and `sqrt`
below compute the mathematically exact result with Python integers, so the RTL
comparison is a real cross-check and not two copies of the same mistake.
"""

FFL_NV = 0x10
FFL_DZ = 0x08
FFL_OF = 0x04
FFL_UF = 0x02
FFL_NX = 0x01

RNE, RTZ, RDN, RUP, RMM = 0, 1, 2, 3, 4


class Fmt:
    """One binary interchange format."""

    __slots__ = ("name", "ebits", "fbits", "bias", "emax_field", "emin", "width")

    def __init__(self, name, ebits, fbits, bias, emax_field, emin, width):
        self.name = name
        self.ebits = ebits          # exponent field width
        self.fbits = fbits          # fraction width
        self.bias = bias
        self.emax_field = emax_field  # exponent field value meaning inf/NaN
        self.emin = emin            # unbiased exponent of the minimum normal
        self.width = width          # total bits

    # -- field extraction ---------------------------------------------------
    @property
    def frac_mask(self):
        return (1 << self.fbits) - 1

    @property
    def exp_mask(self):
        return (1 << self.ebits) - 1

    @property
    def sign_bit(self):
        return 1 << (self.width - 1)

    def fields(self, bits):
        bits &= (1 << self.width) - 1
        return (bits >> (self.width - 1),
                (bits >> self.fbits) & self.exp_mask,
                bits & self.frac_mask)

    def make(self, sign, efield, frac):
        return ((sign & 1) << (self.width - 1)) | \
               ((efield & self.exp_mask) << self.fbits) | (frac & self.frac_mask)

    def inf(self, sign=0):
        return self.make(sign, self.emax_field, 0)

    def qnan(self, sign=0):
        return self.make(sign, self.emax_field, 1 << (self.fbits - 1))

    def maxf(self):
        return self.make(0, self.emax_field - 1, self.frac_mask)

    def zero(self, sign=0):
        return self.make(sign, 0, 0)

    # -- classification -----------------------------------------------------
    def is_nan(self, bits):
        _, e, f = self.fields(bits)
        return e == self.emax_field and f != 0

    def is_snan(self, bits):
        _, e, f = self.fields(bits)
        return e == self.emax_field and f != 0 and not (f >> (self.fbits - 1)) & 1

    def is_inf(self, bits):
        _, e, f = self.fields(bits)
        return e == self.emax_field and f == 0

    def is_zero(self, bits):
        _, e, f = self.fields(bits)
        return e == 0 and f == 0

    def decompose(self, bits):
        """(sign, m, e) with value = (-1)**sign * m * 2**e, exactly.

        A subnormal keeps e fixed at 1-bias-fbits and m = fraction, so nothing
        about the value is lost.  Not meaningful for NaN/inf.
        """
        s, ef, f = self.fields(bits)
        if ef == 0:
            return s, f, 1 - self.bias - self.fbits
        return s, (1 << self.fbits) | f, ef - self.bias - self.fbits


F32 = Fmt("s", 8, 23, 127, 255, -126, 32)
F64 = Fmt("d", 11, 52, 1023, 2047, -1022, 64)

FMT = {0: F32, 1: F64}


def fmt_of(sel):
    """`sel` is 0 for binary32 and 1 for binary64, matching the RTL's fmt bit."""
    return F32 if not sel else F64


# ---------------------------------------------------------------------------
# the rounder -- mirror of rtl/fpu/rv64_fp_round.sv
# ---------------------------------------------------------------------------
def round_pack(sign, exp_in, sig, rm, F):
    """Round and pack. `sig` is an FB+4-bit integer whose top bit is set.

    Returns (bits, flags).  NV and DZ are never produced here; the callers own
    the special cases, exactly as in the RTL.
    """
    fb = F.fbits
    w = fb + 4
    sig &= (1 << w) - 1

    # ---- subnormal alignment ---------------------------------------------
    # shift = max(0, emin - exp_in), clamped at the significand width: a shift
    # of `w` already removes every bit and leaves only the sticky.
    shift = F.emin - exp_in
    shift = 0 if shift < 0 else min(shift, w)
    if shift:
        lost = sig & ((1 << shift) - 1)
        sig = (sig >> shift) | (1 if lost else 0)

    frac = (sig >> 3) & F.frac_mask
    g = (sig >> 2) & 1
    r = (sig >> 1) & 1
    s = sig & 1
    any_bits = g | r | s

    # ---- round decision ---------------------------------------------------
    if rm == RNE:
        up = g and (r or s or (frac & 1))
    elif rm == RTZ:
        up = 0
    elif rm == RDN:
        up = any_bits and sign
    elif rm == RUP:
        up = any_bits and not sign
    elif rm == RMM:
        up = g
    else:
        up = 0

    e_field = 0 if shift else exp_in + F.bias
    frac_r = frac + (1 if up else 0)
    if up and frac == F.frac_mask:
        frac_r = 0
        e_field += 1

    # ---- overflow result depends on the rounding mode ---------------------
    if e_field >= F.emax_field:
        if rm in (RNE, RMM):
            out = F.inf(sign)
        elif rm == RTZ:
            out = F.make(sign, F.emax_field - 1, F.frac_mask)
        elif rm == RDN:
            out = F.inf(1) if sign else F.make(0, F.emax_field - 1, F.frac_mask)
        else:  # RUP
            out = F.make(1, F.emax_field - 1, F.frac_mask) if sign else F.inf(0)
        return out, FFL_OF | FFL_NX

    out = F.make(sign, e_field, frac_r)
    flags = 0
    if any_bits:
        flags |= FFL_NX
        if e_field == 0:
            flags |= FFL_UF
    return out, flags


def pack_from_int(sign, n, e, rm, F, sticky=0):
    """Round the exact value (-1)**sign * (n + sticky_frac) * 2**e to `F`.

    `n` is a non-negative integer; `sticky` says there are further nonzero bits
    below n's least significant bit (used by div and sqrt, whose results are not
    exact integers).  Returns (bits, flags).
    """
    if n == 0:
        if sticky:
            # a value strictly between 0 and one unit at this scale: round to 0
            # or to the smallest magnitude, depending on the mode
            if (rm == RUP and not sign) or (rm == RDN and sign):
                return F.make(sign, 0, 1), FFL_UF | FFL_NX
            return F.zero(sign), FFL_UF | FFL_NX
        return F.zero(sign), 0
    bl = n.bit_length()
    exp_in = e + bl - 1
    sh = bl - (F.fbits + 4)
    if sh > 0:
        lost = n & ((1 << sh) - 1)
        sig = (n >> sh) | (1 if (lost or sticky) else 0)
    else:
        sig = (n << -sh) | (1 if sticky else 0)
    return round_pack(sign, exp_in, sig, rm, F)


def scale_to_int(sign, n, e, e_common):
    """(-1)**sign * n * 2**e rewritten at scale 2**e_common (e_common <= e)."""
    return (-n if sign else n) << (e - e_common)


# ---------------------------------------------------------------------------
# exact operation cores
# ---------------------------------------------------------------------------
def exact_add(sign_a, ma, ea, sign_b, mb, eb, rm, F):
    e0 = min(ea, eb)
    s = scale_to_int(sign_a, ma, ea, e0) + scale_to_int(sign_b, mb, eb, e0)
    if s == 0:
        # an exact zero sum is +0 except under round-down, where it is -0
        return F.zero(1 if rm == RDN else 0), 0
    sign = 1 if s < 0 else 0
    return pack_from_int(sign, abs(s), e0, rm, F)


def exact_mul(sign_a, ma, ea, sign_b, mb, eb, rm, F):
    return pack_from_int(sign_a ^ sign_b, ma * mb, ea + eb, rm, F)


def exact_div(sign_a, ma, ea, sign_b, mb, eb, rm, F):
    # enough extra quotient bits that the sticky is decided correctly; the
    # quotient is normalised to the top before rounding, so 2*fbits+64 is
    # far more than the fbits+4 the rounder looks at
    k = 2 * F.fbits + 64
    n = (ma << k) // mb
    rem = (ma << k) - n * mb
    return pack_from_int(sign_a ^ sign_b, n, ea - eb - k, rm, F, sticky=1 if rem else 0)


def exact_sqrt(sign_a, ma, ea, rm, F):
    if ea & 1:
        ma <<= 1
        ea -= 1
    k = 2 * F.fbits + 64
    r = isqrt(ma << (2 * k))
    rem = (ma << (2 * k)) - r * r
    return pack_from_int(sign_a, r, (ea >> 1) - k, rm, F, sticky=1 if rem else 0)


def isqrt(n):
    import math
    return math.isqrt(n)


def round_to_int(sign, m, e, rm):
    """Round the exact value (-1)**sign * m * 2**e to an integer.

    Returns (magnitude, inexact).  The rounding decision is by magnitude, which
    is what makes RDN/RUP on a negative value come out right.
    """
    if m == 0:
        return 0, False
    if e >= 0:
        return m << e, False
    sh = -e
    if sh > m.bit_length() + 1:
        # |value| < 1/2: the integer part is 0, and only the direction of the
        # (nonzero) remainder decides between 0 and 1
        up = (rm == RUP and not sign) or (rm == RDN and sign)
        return (1 if up else 0), True
    q = m >> sh
    dropped = m & ((1 << sh) - 1)
    half = 1 << (sh - 1)
    if rm == RNE:
        up = dropped > half or (dropped == half and (q & 1))
    elif rm == RTZ:
        up = False
    elif rm == RDN:
        up = dropped != 0 and bool(sign)
    elif rm == RUP:
        up = dropped != 0 and not sign
    elif rm == RMM:
        up = dropped >= half
    else:
        up = False
    return q + (1 if up else 0), dropped != 0
