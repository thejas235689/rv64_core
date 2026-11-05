"""
test_fpu_unit.py -- exhaustive unit-level comparison of the scalar FPU RTL
against the Python models in rtl/fpu/model/.

Every block is combinational, so a vector is applied to tb_fpu_top and the
result read back after one nanosecond; there is no pipeline to wait for.  That
is what makes thousands of vectors affordable here -- the end-to-end core test
(test_fpu_core.py) covers the same operations but can only afford tens.

The vector sets deliberately include NaN (quiet and signalling), +-infinity,
+-0 and subnormals, and every rounding mode, and the fflags word is compared as
well as the result value.  A block that computes the right answer with the wrong
flags fails here.
"""

import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..",
                                "rtl", "fpu", "model"))

from fp_add_model import fp_add                      # noqa: E402
from fp_cmp_model import fcmp, FEQ, FLT, FLE          # noqa: E402
from fp_cvt_model import fcvt_from_int, fcvt_to_int, fcvt_fp  # noqa: E402
from fp_div_model import fdiv                         # noqa: E402
from fp_mul_model import fmul                         # noqa: E402
from fp_sqrt_model import fsqrt                       # noqa: E402
from fp_common import FFL_NV, FFL_NX, F32, F64       # noqa: E402

QNAN = 0x7FF8000000000000
INF = 0x7FF0000000000000
SIGN = 1 << 63
MAXF = 0x7FEF_FFFF_FFFF_FFFF

# +-0, +-1, +-2, +-inf, qNaN, sNaN, min/max normal, min/max subnormal
SPECIALS = [
    0, SIGN, 1, SIGN | 1,
    0x000FFFFFFFFFFFFF, 0x800FFFFFFFFFFFFF,          # max subnormal
    0x0010000000000000, 0x8010000000000000,          # min normal
    0x3FF0000000000000, 0xBFF0000000000000,          # +-1
    0x4000000000000000, 0xC000000000000000,          # +-2
    0x3FF8000000000000, 0xBFF8000000000000,          # +-1.5
    0x3FE0000000000000, 0xBFE0000000000000,          # +-0.5
    0x7FEFFFFFFFFFFFFF, 0xFFEFFFFFFFFFFFFF,          # +-max finite
    INF, SIGN | INF,
    0x7FF8000000000000, 0xFFF8000000000000,          # quiet NaNs
    0x7FF0000000000001, 0x7FF4000000000000,          # signalling NaNs
]

ALL_RM = (0, 1, 2, 3, 4)


def make_vectors(n_random=260, seed=7):
    """Deterministic vector list: the specials plus random bit patterns, with a
    bias toward subnormal and near-overflow exponents because that is where a
    rounding bug hides."""
    rnd = random.Random(seed)
    v = list(SPECIALS)
    for _ in range(n_random):
        v.append(rnd.getrandbits(64))
    for _ in range(n_random // 2):
        v.append(rnd.getrandbits(52) | (rnd.getrandbits(1) << 63))
    for _ in range(n_random // 3):
        v.append((rnd.getrandbits(1) << 63) | (rnd.randrange(0x7C0, 0x7FF) << 52)
                 | rnd.getrandbits(52))
    for _ in range(n_random // 3):
        v.append((rnd.getrandbits(1) << 63) | (rnd.randrange(1, 0x40) << 52)
                 | rnd.getrandbits(52))
    return v


async def apply(dut, op, a, b, rm=0, fmt=1, cvt_op=0, cvt_unsigned=0, cvt_32=0,
                cmp_f3=0):
    dut.op.value = op
    dut.fmt.value = fmt
    dut.rm.value = rm
    dut.a.value = a & 0xFFFFFFFFFFFFFFFF
    dut.b.value = b & 0xFFFFFFFFFFFFFFFF
    dut.cvt_op.value = cvt_op
    dut.cvt_unsigned.value = cvt_unsigned
    dut.cvt_32.value = cvt_32
    dut.cmp_f3.value = cmp_f3
    await Timer(1, "ns")
    try:
        r = int(dut.result.value)
        f = int(dut.flags.value)
    except ValueError:
        return None, None
    return r, f


@cocotb.test()
async def test_fpu_unit(dut):
    """Compare every FPU block against its Python model, vector by vector."""
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    dut.op.value = 0
    dut.fmt.value = 1
    dut.rm.value = 0
    dut.cvt_op.value = 0
    dut.a.value = 0
    dut.b.value = 0
    dut.cvt_unsigned.value = 0
    dut.cvt_32.value = 0
    dut.cmp_f3.value = 0
    await RisingEdge(dut.clk)

    vecs = make_vectors()
    fails = []
    counts = {}

    def chk(tag, got, want, ctx=()):
        counts[tag] = counts.get(tag, 0) + 1
        if got != want:
            fails.append((tag, got, want, ctx))

    # Every sweep runs twice: fmt=1 (binary64) and fmt=0 (binary32).  Same
    # datapath, same rounder -- if single precision had been bolted on as a
    # second FPU, one of these two columns would disagree.
    for fmt in (1, 0):
        F = F64 if fmt else F32
        tag = "d" if fmt else "s"
        vv = [v & ((1 << F.width) - 1) for v in vecs]

        # ---- add / sub, every rounding mode -------------------------------
        n = 0
        for i, a in enumerate(vv):
            for b in (vv[i * 7 % len(vv)], vv[(i * 13 + 5) % len(vv)],
                      vv[(i * 3 + 1) % len(vv)]):
                for sub in (0, 1):
                    for rm in ALL_RM:
                        got, fl = await apply(dut, 1 if sub else 0, a, b,
                                              rm=rm, fmt=fmt)
                        chk(f"add.{tag}", (got, fl), fp_add(a, b, sub, rm, fmt),
                            (hex(a), hex(b), sub, rm))
                        n += 1
        dut._log.info(f"add/sub.{tag}: {n} vectors")

        # ---- multiply -----------------------------------------------------
        n = 0
        for i, a in enumerate(vv):
            for b in (vv[i * 5 % len(vv)], vv[(i * 11 + 3) % len(vv)]):
                for rm in ALL_RM:
                    got, fl = await apply(dut, 2, a, b, rm=rm, fmt=fmt)
                    chk(f"mul.{tag}", (got, fl), fmul(a, b, rm, fmt),
                        (hex(a), hex(b), rm))
                    n += 1
        dut._log.info(f"mul.{tag}: {n} vectors")

        # ---- divide -------------------------------------------------------
        n = 0
        for i, a in enumerate(vv):
            for b in (vv[i * 5 % len(vv)], vv[(i * 11 + 3) % len(vv)]):
                for rm in ALL_RM:
                    got, fl = await apply(dut, 3, a, b, rm=rm, fmt=fmt)
                    chk(f"div.{tag}", (got, fl), fdiv(a, b, rm, fmt),
                        (hex(a), hex(b), rm))
                    n += 1
        dut._log.info(f"div.{tag}: {n} vectors")

        # ---- square root --------------------------------------------------
        n = 0
        for a in vv:
            for rm in ALL_RM:
                got, fl = await apply(dut, 4, a, 0, rm=rm, fmt=fmt)
                chk(f"sqrt.{tag}", (got, fl), fsqrt(a, rm, fmt), (hex(a), rm))
                n += 1
        dut._log.info(f"sqrt.{tag}: {n} vectors")

        # ---- fcmp ---------------------------------------------------------
        n = 0
        for i, a in enumerate(vv):
            for b in (vv[i * 5 % len(vv)], vv[(i * 11 + 3) % len(vv)]):
                for f3 in (0, 1, 2):
                    got, fl = await apply(dut, 6, a, b, cmp_f3=f3, fmt=fmt)
                    chk(f"cmp.{tag}", (got, fl), fcmp(a, b, f3, fmt),
                        (hex(a), hex(b), f3))
                    n += 1
        dut._log.info(f"cmp.{tag}: {n} vectors")

        # ---- fcvt, both directions, every width and sign ------------------
        n = 0
        ints = [0, 1, 0xFFFFFFFF, 0x100000000, 0x7FFFFFFF, 0x80000000,
                0x7FFFFFFFFFFFFFFF, 0x8000000000000000, 0xFFFFFFFFFFFFFFFF,
                0x001FFFFFFFFFFFFF, 0x0020000000000000, 0x0020000000000001,
                0x01000000, 0x00FFFFFF, 0xFFFFFF0000000000]
        rnd = random.Random(11)
        ints += [rnd.getrandbits(64) for _ in range(120)]
        for x in ints:
            for is_u in (0, 1):
                for is32 in (0, 1):
                    for rm in ALL_RM:
                        got, fl = await apply(dut, 5, x, 0, rm=rm, fmt=fmt,
                                              cvt_op=1, cvt_unsigned=is_u,
                                              cvt_32=is32)
                        chk(f"cvt_from_int.{tag}", (got, fl),
                            fcvt_from_int(x, is_u, 32 if is32 else 64, rm, fmt))
                        n += 1
        for a in vv:
            for is_u in (0, 1):
                for is32 in (0, 1):
                    for rm in ALL_RM:
                        got, fl = await apply(dut, 5, a, 0, rm=rm, fmt=fmt,
                                              cvt_op=0, cvt_unsigned=is_u,
                                              cvt_32=is32)
                        chk(f"cvt_to_int.{tag}", (got, fl),
                            fcvt_to_int(a, is_u, 32 if is32 else 64, rm, fmt))
                        n += 1
        # fp -> fp is only meaningful across formats; the tb ties src_fmt and
        # dst_fmt to the same fmt input, so this is exercised end to end in
        # test_fpu_core_single instead.  Here it checks that a same-format
        # conversion is the identity on every vector.
        for a in vv:
            for rm in ALL_RM:
                got, fl = await apply(dut, 5, a, 0, rm=rm, fmt=fmt, cvt_op=2)
                chk(f"cvt_fp_ident.{tag}", (got, fl),
                    fcvt_fp(a, fmt, fmt, rm), (hex(a), rm))
                n += 1
        dut._log.info(f"cvt.{tag}: {n} vectors")

    # ---- report -----------------------------------------------------------
    total = sum(counts.values())
    for k in sorted(counts):
        bad = sum(1 for f in fails if f[0] == k)
        dut._log.info(f"  {k:14s} {counts[k]:6d} vectors, {bad} mismatches")
    if fails:
        for tag, got, want, ctx in fails[:16]:
            dut._log.error(f"MISMATCH {tag} ctx={ctx}: got {got} want {want}")
        raise AssertionError(
            f"{len(fails)} of {total} FPU vectors mismatched "
            f"({', '.join(sorted({f[0] for f in fails}))})")
    dut._log.info(f"FPU unit: {total} vectors, 0 mismatches")
