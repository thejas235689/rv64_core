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


def model(op, a, b, cfg, quire, err_q):
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

    if op in (QADD, QSUB):
        if op == QADD:
            ext = (ext65(opa) + ext65(opb)) & M65
        else:
            ext = (ext65(opa) - ext65(opb)) & M65
        ovf = ((ext >> 64) & 1) != ((ext >> 63) & 1)
        y = ext & M64
        if ovf and f["sat"]:
            # The rail comes from the OPERAND signs, not from the extended
            # result: on a positive overflow the wrapped result has its sign bit
            # set, so testing ext[63] saturates a too-large positive sum to
            # INT64_MIN. The RTL had the same defect and was fixed with it.
            a_neg = (opa >> 63) & 1
            b_neg = (opb >> 63) & 1
            neg = (a_neg and b_neg) if op == QADD else (a_neg and not b_neg)
            y = (1 << 63) if neg else (1 << 63) - 1
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

    # ---- reserved families must report invalid ------------------------------
    for op in (8, 9, 10, 11, 12, 13, 14, 15, 16, 17):
        vecs.append((op, 0, 0x1234, 0x5678, cfg()))

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
        y, flags, err_now, quire_next, err_next = model(op, a, b, cfg, quire, err_q)
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
