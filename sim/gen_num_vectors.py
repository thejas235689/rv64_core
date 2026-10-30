#!/usr/bin/env python3
"""
gen_num_vectors.py -- reference model and vector generator for rv64_num_unit.

The model below mirrors the RTL operation by operation, including the exact
places where bits are dropped, so a mismatch means a real defect rather than a
rounding-convention difference. Sampling convention: the testbench samples the
combinational outputs (y, flags) and the *pre-edge* register state (err, quire)
before each clock edge, which is what the model records.

Files written to sim/num_vectors/:
    num_in.hex     5 words per vector: {fmt,op}, a, b, cfg, 0
    num_exp.hex    5 words per vector: y, flags, err, quire_lo, quire_hi
    num_count.hex  1 word: number of vectors
"""

import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "num_vectors")

M64 = (1 << 64) - 1
M65 = (1 << 65) - 1
M128 = (1 << 128) - 1

# operations (must match rv64_num_pkg)
QADD, QSUB, QMUL, QCLR, QACC, QGET, ADAPT, ERR = 0, 1, 2, 3, 4, 5, 6, 7
PADD, PSUB, PMUL, PDIV = 8, 9, 10, 11
LNMUL, LNDIV = 12, 13
RADD, RMUL = 14, 15
FADD, FMUL = 16, 17

LNS_ZERO = 0x8000_0000
POS_FRAC_BITS = 64
POS_LIM = (1 << 127) - 1


def posit_width(fmt):
    return {1: 8, 2: 32}.get(fmt, 16)
FP_QNAN = 0x7FC0_0000


def _s32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x8000_0000 else v


def rns_pack(r3, r5, r7, r11, r13=0, fmt=0):
    v = (r3 & 3) | ((r5 & 7) << 2) | ((r7 & 7) << 5)
    if fmt != 1:
        v |= (r11 & 15) << 8
    if fmt == 2:
        v |= (r13 & 15) << 12
    return v


def _sx(v, w):
    v &= (1 << w) - 1
    return v - (1 << w) if v & (1 << (w - 1)) else v


def lns_width(fmt):
    return {1: 16, 2: 64}.get(fmt, 32)


def lns_op(op, a, b, fmt=0):
    """LNS at the width selected by fmt; the zero code is 1<<(w-1)."""
    w = lns_width(fmt)
    mask = (1 << w) - 1
    zero = 1 << (w - 1)
    maxv, minv = zero - 1, -zero
    fa, fb = a & mask, b & mask
    sa, sb = _sx(fa, w), _sx(fb, w)
    a_zero, b_zero = fa == zero, fb == zero
    flags = 0
    if op == LNMUL:
        if a_zero or b_zero:
            return zero, 0
        t = sa + sb
    else:
        if b_zero:
            return maxv & mask, 1 << 4
        if a_zero:
            return zero, 0
        t = sa - sb
    if t > maxv:
        return maxv & mask, 1 << 0
    if t < minv:
        return zero, 1 << 0
    return t & mask, flags


def _f32_parts(v):
    return (v >> 31) & 1, (v >> 23) & 0xFF, v & 0x7FFFFF


def f32_mul(a, b):
    """binary32 multiply: RNE, inf/NaN handled, subnormals flushed to zero."""
    sa, ea, fa = _f32_parts(a)
    sb, eb, fb = _f32_parts(b)
    a_nan, b_nan = ea == 0xFF and fa != 0, eb == 0xFF and fb != 0
    a_inf, b_inf = ea == 0xFF and fa == 0, eb == 0xFF and fb == 0
    a_zero, b_zero = ea == 0, eb == 0
    if a_nan or b_nan:
        return FP_QNAN, 1 << 3
    if (a_inf and b_zero) or (b_inf and a_zero):
        return FP_QNAN, 1 << 3
    if a_inf or b_inf:
        return ((sa ^ sb) << 31) | (0xFF << 23), 0
    if a_zero or b_zero:
        return (sa ^ sb) << 31, 0
    prod = (0x800000 | fa) * (0x800000 | fb)
    exp = ea + eb - 127
    if not (prod >> 47) & 1:
        prod <<= 1                      # window shift only: exponent unchanged
    man = (prod >> 24) & 0xFFFFFF
    guard = (prod >> 23) & 1
    sticky = 1 if prod & 0x7FFFFF else 0
    if guard and (sticky or (man & 1)):
        man += 1
    if man >> 24:
        man >>= 1
        exp += 1
    if exp >= 255:
        return ((sa ^ sb) << 31) | (0xFF << 23), 1 << 0
    if exp <= 0:
        return (sa ^ sb) << 31, 1 << 1
    return ((sa ^ sb) << 31) | (exp << 23) | (man & 0x7FFFFF), 0


def f32_add(a, b):
    """binary32 add: 28-bit accumulator, three guard bits, RNE."""
    sa, ea, fa = _f32_parts(a)
    sb, eb, fb = _f32_parts(b)
    a_nan, b_nan = ea == 0xFF and fa != 0, eb == 0xFF and fb != 0
    a_inf, b_inf = ea == 0xFF and fa == 0, eb == 0xFF and fb == 0
    a_zero, b_zero = ea == 0, eb == 0
    if a_nan or b_nan:
        return FP_QNAN, 1 << 3
    if a_inf and b_inf and sa != sb:
        return FP_QNAN, 1 << 3
    if a_inf:
        return (sa << 31) | (0xFF << 23), 0
    if b_inf:
        return (sb << 31) | (0xFF << 23), 0
    if a_zero and b_zero:
        return (sa & sb) << 31, 0
    if a_zero:
        return (sb << 31) | (eb << 23) | fb, 0
    if b_zero:
        return (sa << 31) | (ea << 23) | fa, 0
    if ea >= eb:
        ebig, esmall = ea, eb
        big, small = (0x800000 | fa) << 3, (0x800000 | fb) << 3
        sign = sa
    else:
        ebig, esmall = eb, ea
        big, small = (0x800000 | fb) << 3, (0x800000 | fa) << 3
        sign = sb
    shift = min(ebig - esmall, 26)
    shifted = small >> shift
    if ebig - esmall > 0:
        shifted |= 1 if (small & ((1 << shift) - 1)) else 0
    total = big + shifted if sa == sb else big - shifted
    exp = ebig
    if total == 0:
        return 0, 0
    if total >> 27:
        total >>= 1
        exp += 1
    else:
        for _ in range(27):
            if not (total >> 26) & 1 and total != 0:
                total <<= 1
                exp -= 1
    man = (total >> 3) & 0xFFFFFF
    guard = (total >> 2) & 1
    rnd = (total >> 1) & 1
    sticky = total & 1
    if guard and (rnd or sticky or (man & 1)):
        man += 1
    if man >> 24:
        man >>= 1
        exp += 1
    if exp >= 255:
        return (sign << 31) | (0xFF << 23), 1 << 0
    if exp <= 0:
        return sign << 31, 1 << 1
    return (sign << 31) | (exp << 23) | (man & 0x7FFFFF), 0


def posit_decode(p, n=16):
    """posit< n,1> -> signed Q63.64"""
    sgn = (p >> (n - 1)) & 1
    body = p & ((1 << (n - 1)) - 1)
    if body == 0:
        return 0
    i, k = n - 2, 0
    if (body >> (n - 2)) & 1:
        while i >= 0 and (body >> i) & 1:
            k += 1
            i -= 1
        k -= 1
    else:
        while i >= 0 and not ((body >> i) & 1):
            k -= 1
            i -= 1
    e, frac, nf = 0, 0, 0
    if i >= 1:
        e = (body >> (i - 1)) & 1
        frac = body & ((1 << (i - 1)) - 1)
        nf = i - 1
    mant = ((1 << (n - 2)) + frac) >> ((n - 2) - nf)
    shift = 2 * k + e + POS_FRAC_BITS - nf
    v = mant << shift if shift >= 0 else mant >> (-shift)
    return -v if sgn else v


def posit_encode(v, n=16):
    """signed Q63.64 -> posit< n,1>, round to nearest even"""
    sgn = 1 if v < 0 else 0
    mag = -v if v < 0 else v
    if mag == 0:
        return 0
    lead = mag.bit_length() - 1
    e2 = lead - POS_FRAC_BITS
    k = (e2 >> 1) if e2 >= 0 else -(((-e2) + 1) >> 1)
    r = e2 - 2 * k
    if k >= 0:
        rlen, regime_val = k + 2, (1 << (k + 2)) - 2
    else:
        rlen, regime_val = (-k) + 1, 1
    nfrac = (n - 2) - rlen
    if nfrac < 0 or rlen > n - 1:
        return ((1 << (n - 1)) | 1) if sgn else ((1 << (n - 1)) - 1)
    below = ((mag << (127 - lead)) & ((1 << 128) - 1)) if lead >= 1 else 0
    fracbits = ((below >> (127 - nfrac)) & ((1 << nfrac) - 1)) if nfrac > 0 else 0
    disc = 127 - nfrac
    tail = (below & ((1 << disc) - 1)) if 0 < disc < 128 else 0
    if nfrac > 0 and disc >= 1:
        guard = (below >> (disc - 1)) & 1
        if guard and (tail != (1 << (disc - 1)) or (fracbits & 1)):
            fracbits += 1
            if fracbits >> nfrac:
                fracbits = 0
                r += 1
                if r > 1:
                    r = 0
                    k += 1
                    if k >= 0:
                        rlen, regime_val = k + 2, (1 << (k + 2)) - 2
                    else:
                        rlen, regime_val = (-k) + 1, 1
                    nfrac = max(0, (n - 2) - rlen)
                    if rlen > n - 1:
                        return ((1 << (n - 1)) | 1) if sgn else ((1 << (n - 1)) - 1)
    body = ((regime_val << ((n - 1) - rlen)) | (r << ((n - 2) - rlen)) |
            (fracbits & ((1 << nfrac) - 1)))
    return (sgn << (n - 1)) | (body & ((1 << (n - 1)) - 1))


def _trunc_div(a, b):
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def posit_op(op, a, b, fmt=0):
    n = posit_width(fmt)
    mask = (1 << n) - 1
    da, db = posit_decode(a & mask, n), posit_decode(b & mask, n)
    flags = 0
    if op == PADD:
        res = da + db
    elif op == PSUB:
        res = da - db
    elif op == PMUL:
        res = (da * db) >> POS_FRAC_BITS
    else:
        if db == 0:
            res = 0
            flags |= 1 << 4
            return posit_encode(res, n), flags
        res = _trunc_div(da << POS_FRAC_BITS, db)
    # mirror the RTL: the 128-bit internal range is the clamp point
    if res > POS_LIM:
        res = POS_LIM
        flags |= (1 << 5) | (1 << 0)
    elif res < -POS_LIM - 1:
        res = -POS_LIM - 1
        flags |= (1 << 5) | (1 << 0)
    return posit_encode(res, n), flags

# cfg field positions
CFG_ROUND, CFG_SAT, CFG_PREC, CFG_ES, CFG_ERREN, CFG_ADAPT = 0, 2, 8, 16, 20, 21


def u64(v):
    return v & M64


def s64(v):
    v &= M64
    return v - (1 << 64) if v >> 63 else v


def s128(v):
    v &= M128
    return v - (1 << 128) if v >> 127 else v


def ext65(v):
    """{v[63], v} -- sign-extend a 64-bit pattern to 65 bits."""
    v &= M64
    return v + (1 << 64) if v >> 63 else v


def adapt(v, prec, round_up):
    v &= M64
    if prec >= 64:
        return v, 0
    drop = 64 - prec
    mask = (1 << drop) - 1
    if round_up:
        q = (v + (1 << (drop - 1))) & M64 & ~mask & M64
    else:
        q = v & ~mask & M64
    lost = 1 if (v & mask) else 0
    return q, lost


def cfg_fields(cfg):
    return dict(round=cfg & 3,
                sat=(cfg >> CFG_SAT) & 1,
                prec=(cfg >> CFG_PREC) & 0x7F,
                adapt_en=(cfg >> CFG_ADAPT) & 1,
                err_en=(cfg >> CFG_ERREN) & 1)


def model(op, a, b, cfg, quire, err_q, fmt=0):
    """Return (y, flags, err_now, quire_next, err_next) for one operation."""
    f = cfg_fields(cfg)
    rnd = f["round"] & 1
    y = 0
    flags = 0
    err_now = 0
    quire_next = quire
    err_next = err_q

    opa, opb = a & M64, b & M64
    lost_a = lost_b = 0
    if f["adapt_en"] and op in (QADD, QSUB, QMUL):
        opa, lost_a = adapt(a, f["prec"], rnd)
        opb, lost_b = adapt(b, f["prec"], rnd)

    if op in (PADD, PSUB, PMUL, PDIV):
        y, fl = posit_op(op, a, b, fmt)
        flags |= fl
        return y, flags, err_now, quire, err_next

    if op in (FADD, FMUL):
        y, fl = (f32_add(a & 0xFFFFFFFF, b & 0xFFFFFFFF) if op == FADD
                 else f32_mul(a & 0xFFFFFFFF, b & 0xFFFFFFFF))
        flags |= fl
        return y, flags, err_now, quire, err_next

    if op in (RADD, RMUL):
        a3, b3   = a & 3, b & 3
        a5, b5   = (a >> 2) & 7, (b >> 2) & 7
        a7, b7   = (a >> 5) & 7, (b >> 5) & 7
        a11, b11 = (a >> 8) & 15, (b >> 8) & 15
        a13, b13 = (a >> 12) & 15, (b >> 12) & 15
        if op == RADD:
            y = rns_pack((a3 + b3) % 3, (a5 + b5) % 5, (a7 + b7) % 7,
                         (a11 + b11) % 11, (a13 + b13) % 13, fmt)
        else:
            y = rns_pack((a3 * b3) % 3, (a5 * b5) % 5, (a7 * b7) % 7,
                         (a11 * b11) % 11, (a13 * b13) % 13, fmt)
        return y, flags, err_now, quire, err_next

    if op in (LNMUL, LNDIV):
        y, fl = lns_op(op, a, b, fmt)
        flags |= fl
        return y, flags, err_now, quire, err_next

    if op in (QADD, QSUB):
        if op == QADD:
            ext = (ext65(opa) + ext65(opb)) & M65
        else:
            ext = (ext65(opa) - ext65(opb)) & M65
        ovf = ((ext >> 64) & 1) != ((ext >> 63) & 1)
        y = ext & M64
        if ovf and f["sat"]:
            y = (1 << 63) if (ext >> 63) & 1 else (1 << 63) - 1
        if ovf:
            flags |= 1 << 0                      # FLAG_OVERFLOW
            if f["sat"]:
                flags |= 1 << 5                  # FLAG_SATURATE
        if lost_a or lost_b:
            flags |= 1 << 6                      # FLAG_PRECISION

    elif op == QMUL:
        prod = s64(opa) * s64(opb)
        unrounded = prod >> 32                   # arithmetic shift
        shifted = (prod + (1 << 31)) >> 32 if rnd else unrounded
        ovf = not (-(1 << 63) <= unrounded <= (1 << 63) - 1)
        y = u64(shifted)
        dropped = prod & 0xFFFFFFFF
        if dropped:
            flags |= 1 << 2                      # FLAG_INEXACT
        if ovf:
            flags |= 1 << 0
            if f["sat"]:
                flags |= 1 << 5
        if lost_a or lost_b:
            flags |= 1 << 6
        err_now = 1 if rnd else (dropped & M64)

    elif op == QACC:
        acc = s64(a) * s64(b)                    # exact Q64.64 product
        full = quire + (acc & M128)
        if full >> 128:
            flags |= 1 << 7                      # FLAG_QUIRE_OVF
        quire_next = full & M128
        y = 0

    elif op == QCLR:
        quire_next = 0
        y = 0

    elif op == QGET:
        q = s128(quire)
        if rnd:
            q += (1 << 31)
        y = u64(q >> 32)                         # arithmetic shift
        dropped = quire & 0xFFFFFFFF
        if dropped:
            flags |= 1 << 2
        err_now = 1 if rnd else dropped

    elif op == ADAPT:
        y, lost = adapt(a, f["prec"], rnd)
        if lost:
            flags |= 1 << 6
            flags |= 1 << 2
        err_now = 0 if f["prec"] >= 64 else (a & M64) & ((1 << (64 - f["prec"])) - 1)

    elif op == ERR:
        y = err_q

    else:
        y = 0
        flags = 1 << 3                           # FLAG_INVALID (reserved family)

    if f["err_en"]:
        err_next = err_now

    return y & M64, flags & 0xFF, err_now & M64, quire_next & M128, err_next & M64


def build_vectors():
    rnd = random.Random(1234)
    vecs = []

    def cfg(round_=0, sat=0, prec=32, adapt_en=0, err_en=1):
        return ((round_ & 3) << CFG_ROUND) | ((sat & 1) << CFG_SAT) | \
               ((prec & 0x7F) << CFG_PREC) | ((adapt_en & 1) << CFG_ADAPT) | \
               ((err_en & 1) << CFG_ERREN)

    edge = [0, 1, 2, 0xFFFFFFFF, 0x1_0000_0000, 0x7FFF_FFFF_FFFF_FFFF,
            0x8000_0000_0000_0000, M64, 0x0000_0001_8000_0000, 0xFFFF_FFFF_0000_0001]

    # ---- directed: fixed-Q add/sub across the interesting boundaries --------
    for c in (cfg(), cfg(sat=1), cfg(round_=1), cfg(sat=1, round_=1)):
        for a in edge:
            for b in (edge[0], edge[1], edge[2], edge[5], edge[6], edge[7]):
                vecs.append((QADD, 0, a, b, c))
                vecs.append((QSUB, 0, a, b, c))

    # ---- directed: multiply, including rounding and inexact ------------------
    for c in (cfg(), cfg(round_=1), cfg(sat=1, round_=1)):
        for a in edge:
            for b in (edge[1], edge[2], edge[3], edge[5], edge[6]):
                vecs.append((QMUL, 0, a, b, c))

    # ---- quire: clear, accumulate a chain, read back -------------------------
    qcfg = cfg(round_=1)
    vecs.append((QCLR, 0, 0, 0, qcfg))
    acc_vals = [(0x0000_0002_0000_0000, 0x0000_0003_0000_0000),   # 2.0 * 3.0
                (0x0000_0001_8000_0000, 0x0000_0002_8000_0000),   # 1.5 * 2.5
                (0xFFFF_FFFF_0000_0000, 0x0000_0004_0000_0000),   # -1.0 * 4.0
                (0x0000_0000_8000_0000, 0x0000_0000_8000_0000)]   # 0.5 * 0.5
    for a, b in acc_vals:
        vecs.append((QACC, 0, a, b, qcfg))
    vecs.append((QGET, 0, 0, 0, qcfg))
    vecs.append((QGET, 0, 0, 0, cfg(round_=0)))
    vecs.append((QCLR, 0, 0, 0, qcfg))
    vecs.append((QGET, 0, 0, 0, qcfg))

    # ---- adaptive precision -------------------------------------------------
    for prec in (8, 16, 24, 32, 48, 63, 64):
        for a in (0x1234_5678_9ABC_DEF0, 0xFFFF_FFFF_FFFF_FFFF, 0x0000_0001_2345_6789):
            vecs.append((ADAPT, 0, a, 0, cfg(prec=prec)))
            vecs.append((ADAPT, 0, a, 0, cfg(prec=prec, round_=1)))
            vecs.append((QADD, 0, a, 0x0000_0000_1000_0000, cfg(prec=prec, adapt_en=1)))
            vecs.append((QMUL, 0, a, 0x0000_0002_0000_0000, cfg(prec=prec, adapt_en=1)))

    # ---- error reporting ----------------------------------------------------
    vecs.append((QMUL, 0, 0x0000_0001_8000_0000, 0x0000_0001_4000_0000, cfg()))
    vecs.append((ERR, 0, 0, 0, cfg()))
    vecs.append((ERR, 0, 0, 0, cfg(err_en=0)))
    vecs.append((QGET, 0, 0, 0, cfg()))

    # ---- residue number system ---------------------------------------------
    for a, b in ((rns_pack(0, 0, 0, 0), rns_pack(0, 0, 0, 0)),
                 (rns_pack(2, 4, 6, 10), rns_pack(2, 4, 6, 10)),
                 (rns_pack(1, 3, 5, 7), rns_pack(2, 2, 2, 2)),
                 (rns_pack(2, 1, 3, 4), rns_pack(2, 4, 6, 10)),
                 (0xFFF, 0xABC), (0x123, 0x456)):
        vecs.append((RADD, 0, a, b, cfg()))
        vecs.append((RMUL, 0, a, b, cfg()))

    # ---- logarithmic number system -----------------------------------------
    for a, b in ((0x0001_0000, 0x0002_0000), (0x0002_0000, 0x0002_0000),
                 (0xFFFF_0000, 0x0001_0000), (LNS_ZERO, 0x0002_0000),
                 (0x0002_0000, LNS_ZERO), (0x7FFF_FFFF, 0x0001_0000),
                 (0x0000_8000, 0x0000_8000)):
        vecs.append((LNMUL, 0, a, b, cfg()))
        vecs.append((LNDIV, 0, a, b, cfg()))

    # ---- IEEE binary32 ------------------------------------------------------
    f32 = [0x3F800000, 0x40000000, 0x40400000, 0x3FC00000,
           0x41200000, 0xC0000000, 0x00000000, 0x80000000,
           0x7F800000, 0xFF800000, 0x7FC00000, 0x00000001,
           0x7F7FFFFF, 0x00800000, 0x33800000, 0x4B000000]
    for x in f32:
        for yv in f32:
            vecs.append((FADD, 0, x, yv, cfg()))
            vecs.append((FMUL, 0, x, yv, cfg()))

    # ---- posit<16,1> --------------------------------------------------------
    pos = [0x0000, 0x4000, 0x5000, 0x6000, 0x7000, 0x4800, 0x5400, 0x3000,
           0x2000, 0x1000, 0x0800, 0x7FFF, 0xC000, 0xD000, 0x3800, 0x4400]
    for x in pos:
        for yv in pos:
            for op in (PADD, PSUB, PMUL, PDIV):
                vecs.append((op, 0, x, yv, cfg()))
    # the same sweep at 8 and 32 bits, so fmt is exercised
    pos8  = [0x00, 0x40, 0x50, 0x60, 0x70, 0x48, 0x30, 0x20, 0xC0, 0x7F, 0x10, 0x08]
    pos32 = [0x0000_0000, 0x4000_0000, 0x5000_0000, 0x6000_0000, 0x7000_0000,
             0x4800_0000, 0x3000_0000, 0x2000_0000, 0xC000_0000, 0x7FFF_FFFF,
             0x1000_0000, 0x0800_0000]
    for fmt_sel, pool in ((1, pos8), (2, pos32)):
        for x in pool:
            for yv in pool:
                for op in (PADD, PSUB, PMUL, PDIV):
                    vecs.append((op, fmt_sel, x, yv, cfg()))

    # ---- random -------------------------------------------------------------
    ops_impl = [QADD, QSUB, QMUL, ADAPT]
    for _ in range(400):
        op = rnd.choice(ops_impl)
        a = rnd.getrandbits(64)
        b = rnd.getrandbits(64)
        c = cfg(round_=rnd.randint(0, 1), sat=rnd.randint(0, 1),
                prec=rnd.randint(8, 64), adapt_en=rnd.randint(0, 1),
                err_en=rnd.randint(0, 1))
        vecs.append((op, 0, a, b, c))

    return vecs


def main():
    os.makedirs(OUT, exist_ok=True)
    vecs = build_vectors()

    quire = 0
    err_q = 0
    fin, fexp = [], []
    for op, fmt, a, b, cfg in vecs:
        y, flags, err_now, quire_next, err_next = model(op, a, b, cfg, quire, err_q, fmt)
        fin.append(f"{(fmt << 5) | (op & 0x1F):016x}")
        fin.append(f"{a & M64:016x}")
        fin.append(f"{b & M64:016x}")
        fin.append(f"{cfg & M64:016x}")
        fin.append(f"{0:016x}")
        fexp.append(f"{y:016x}")
        fexp.append(f"{flags:016x}")
        fexp.append(f"{err_q:016x}")          # pre-edge register state
        fexp.append(f"{quire & M64:016x}")
        fexp.append(f"{(quire >> 64) & M64:016x}")
        quire = quire_next
        err_q = err_next

    open(os.path.join(OUT, "num_in.hex"), "w").write("\n".join(fin) + "\n")
    open(os.path.join(OUT, "num_exp.hex"), "w").write("\n".join(fexp) + "\n")
    open(os.path.join(OUT, "num_count.hex"), "w").write(f"{len(vecs):x}\n")
    print(f"wrote {len(vecs)} vectors to {OUT}")


if __name__ == "__main__":
    main()
