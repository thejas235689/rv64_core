"""
test_fpu_core.py -- the scalar FPU executed by the real CPU, compared against
the Python models in rtl/fpu/model/.

This is the end-to-end half of the FPU verification.  test_fpu_unit.py pushes
tens of thousands of vectors straight at the FPU blocks; this file proves that
software can actually reach them: it assembles RV64 programs, runs them on
riscv_core_top, and reads the architectural results out of the retirement trace.

Each vector becomes a short program fragment:

    csrrw x0, fflags, x0     # clear the sticky flags so this vector's are isolated
    li    x5, <a>            # build the bit pattern of the double
    fmv.d.x f1, x5
    li    x6, <b>
    fmv.d.x f2, x6
    fmul.d f3, f1, f2        # the operation under test
    fmv.x.d x7, f3           # result into an integer register we can observe
    csrrs x8, fflags, x0     # and the flags it raised

so every vector leaves exactly one write to x7 and one to x8 in the retirement
trace, in order.  The vector set covers NaN (quiet and signalling), +-infinity,
+-0 and subnormals, and every rounding mode; fflags is compared as well as the
result, because a right answer with the wrong flags is a bug.
"""

import os
import random
import sys

import cocotb

from rv64_asm import assemble

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..",
                                "rtl", "fpu", "model"))

from fp_cmp_model import fcmp                      # noqa: E402
from fp_cvt_model import fcvt_from_int, fcvt_to_int  # noqa: E402
from fp_div_model import fdiv                      # noqa: E402
from fp_mul_model import fmul                      # noqa: E402
from fp_sqrt_model import fsqrt                    # noqa: E402

from test_core import Harness                      # noqa: E402

QNAN = 0x7FF8000000000000
INF = 0x7FF0000000000000
SIGN = 1 << 63

SPECIALS = [
    0, SIGN, 1, SIGN | 1,
    0x000FFFFFFFFFFFFF, 0x8010000000000000,          # max subnormal, -min normal
    0x3FF0000000000000, 0xBFF0000000000000,          # +-1
    0x4000000000000000, 0xC000000000000000,          # +-2
    0x3FF8000000000000, 0x3FE0000000000000,          # 1.5, 0.5
    0x7FEFFFFFFFFFFFFF, 0xFFEFFFFFFFFFFFFF,          # +-max finite
    INF, SIGN | INF,
    0x7FF8000000000000, 0x7FF0000000000001,          # qNaN, sNaN
    0x0010000000000000, 0x0008000000000000,          # min normal, mid subnormal
]


def vectors(n=18, seed=3):
    rnd = random.Random(seed)
    v = list(SPECIALS)
    for _ in range(n):
        v.append(rnd.getrandbits(64))
    for _ in range(n // 2):
        v.append(rnd.getrandbits(52) | (rnd.getrandbits(1) << 63))
    return v


async def run_prog(dut, src, max_cycles=400000):
    """Assemble, load, run, and return {register: [writes in order]}."""
    words, _ = assemble(src)
    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=max_cycles, stop_on_ecall=True)
    causes = [c for (_, c) in h.traps]
    assert all(c != 2 for c in causes), \
        f"an FP instruction trapped as illegal: causes={[hex(c) for c in causes]}"
    writes = {}
    for t in h.trace:
        _, _, we, rd, wd = t
        if we and rd is not None:
            writes.setdefault(rd, []).append(wd)
    return writes, h


def check(cases, got_res, got_flg, want, tag):
    """Compare per-vector results and flags, reporting the first few misses."""
    assert len(got_res) == len(cases), (
        f"{tag}: retired {len(got_res)} results, expected {len(cases)}")
    assert len(got_flg) == len(cases), (
        f"{tag}: retired {len(got_flg)} flag reads, expected {len(cases)}")
    bad = 0
    for i, ((res, fl), (wres, wfl)) in enumerate(zip(zip(got_res, got_flg), want)):
        if res != wres or fl != wfl:
            bad += 1
            if bad <= 6:
                cocotb.log.error(
                    f"{tag}[{i}] a={cases[i]}: DUT {res:#018x}/{fl:#04x} "
                    f"model {wres:#018x}/{wfl:#04x}")
    return bad


def _binary_prog(cases, mn):
    """cases: list of (a, b, rm_suffix). Returns (src, cases)."""
    src = []
    for a, b, rm in cases:
        src += [
            "csrrw x0, fflags, x0",
            f"li    x5, {a}",
            "fmv.d.x f1, x5",
            f"li    x6, {b}",
            "fmv.d.x f2, x6",
            f"{mn} f3, f1, f2{rm}",
            "fmv.x.d x7, f3",
            "csrrs x8, fflags, x0",
        ]
    src.append("ecall")
    return "\n".join(src)


def _build_int(rd, val, scratch="x30"):
    """Instructions that put the EXACT 64-bit pattern `val` into rd.

    `li` cannot express a positive 2**31.  Its expansion for a value that fits in
    32 bits is lui + addiw, and both sign-extend, so `li x5, 2147483648` builds
    0xFFFFFFFF80000000, not 0x0000000080000000.  That is correct assembler
    behaviour -- a compiler's li does the same, and test_scenario_8 relies on it --
    so this test builds the pattern explicitly instead of asking li for it.

    Measured on riscv_core_top, not assumed: with `li x5, 2147483648` the value
    arriving on the FPU's op_a (u_core.op_a while id_ex_fp_op == FP_CVT_D_L) was
    0xFFFFFFFF80000000, and fcvt.d.l returned 0xC1E0000000000000 (-2**31) and
    fcvt.d.lu 0x43EFFFFFFFF00000, both of which are exactly what
    fp_cvt_model.fcvt_from_int gives for that input.  The FPU was right; the
    constant was not what the test meant.

    Values below 2**31, and any value with a nonzero high word, expand correctly
    through li, so only the 2**31..2**32-1 range is built by hand.
    """
    v = val & ((1 << 64) - 1)
    if (v >> 32) == 0 and (v & 0x80000000):
        lo = v & 0x7FFFFFFF
        out = [f"addi  {rd}, x0, 1", f"slli  {rd}, {rd}, 31"]
        if lo:
            out += [f"li    {scratch}, {lo}", f"or    {rd}, {rd}, {scratch}"]
        return out
    return [f"li    {rd}, {v}"]


def _unary_prog(cases, mn):
    src = []
    for a, rm in cases:
        src += [
            "csrrw x0, fflags, x0",
            f"li    x5, {a}",
            "fmv.d.x f1, x5",
            f"{mn} f3, f1{rm}",
            "fmv.x.d x7, f3",
            "csrrs x8, fflags, x0",
        ]
    src.append("ecall")
    return "\n".join(src)


# ---------------------------------------------------------------------------
@cocotb.test()
async def test_fpu_core_mul(dut):
    """fmul.d end to end: result and fflags for every rounding mode."""
    vecs = vectors()
    cases, want = [], []
    for i, a in enumerate(vecs[:14]):
        b = vecs[(i * 5 + 1) % len(vecs)]
        for rm in ("", ", rtz", ", rdn", ", rup", ", rmm"):
            cases.append((a, b, rm))
            want.append(fmul(a, b, 0 if rm == "" else
                             {"rtz": 1, "rdn": 2, "rup": 3, "rmm": 4}[rm[2:]]))
    writes, h = await run_prog(dut, _binary_prog(cases, "fmul.d"))
    bad = check(cases, writes.get(7, []), writes.get(8, []), want, "fmul.d")
    dut._log.info(f"fmul.d: {len(cases)} vectors, {bad} mismatches, "
                  f"{len(h.trace)} retirements")
    assert bad == 0, f"fmul.d: {bad}/{len(cases)} mismatches"


@cocotb.test()
async def test_fpu_core_div(dut):
    """fdiv.d end to end, including x/0 (divide-by-zero flag) and 0/0 (invalid)."""
    vecs = vectors()
    cases, want = [], []
    for i, a in enumerate(vecs[:14]):
        b = vecs[(i * 7 + 2) % len(vecs)]
        for rm in ("", ", rtz", ", rdn", ", rup", ", rmm"):
            cases.append((a, b, rm))
            want.append(fdiv(a, b, 0 if rm == "" else
                             {"rtz": 1, "rdn": 2, "rup": 3, "rmm": 4}[rm[2:]]))
    writes, h = await run_prog(dut, _binary_prog(cases, "fdiv.d"))
    bad = check(cases, writes.get(7, []), writes.get(8, []), want, "fdiv.d")
    dut._log.info(f"fdiv.d: {len(cases)} vectors, {bad} mismatches, "
                  f"{len(h.trace)} retirements")
    assert bad == 0, f"fdiv.d: {bad}/{len(cases)} mismatches"


@cocotb.test()
async def test_fpu_core_sqrt(dut):
    """fsqrt.d end to end, including sqrt of a negative (invalid) and sqrt(-0)."""
    vecs = vectors()
    cases, want = [], []
    for a in vecs[:16]:
        for rm in ("", ", rtz", ", rdn", ", rup", ", rmm"):
            cases.append((a, rm))
            want.append(fsqrt(a, 0 if rm == "" else
                              {"rtz": 1, "rdn": 2, "rup": 3, "rmm": 4}[rm[2:]]))
    writes, h = await run_prog(dut, _unary_prog(cases, "fsqrt.d"))
    bad = check(cases, writes.get(7, []), writes.get(8, []), want, "fsqrt.d")
    dut._log.info(f"fsqrt.d: {len(cases)} vectors, {bad} mismatches, "
                  f"{len(h.trace)} retirements")
    assert bad == 0, f"fsqrt.d: {bad}/{len(cases)} mismatches"


@cocotb.test()
async def test_fpu_core_cvt(dut):
    """fcvt both ways: all four widths/sign combinations of each direction."""
    vecs = vectors()
    src, cases, want = [], [], []
    # double -> integer: the result lands directly in x7
    for a in vecs[:10]:
        for mn, is_u, bits in (("fcvt.w.d", 0, 32), ("fcvt.wu.d", 1, 32),
                               ("fcvt.l.d", 0, 64), ("fcvt.lu.d", 1, 64)):
            for rm, code in (("", 0), (", rtz", 1), (", rdn", 2)):
                src += ["csrrw x0, fflags, x0",
                        f"li    x5, {a}",
                        "fmv.d.x f1, x5",
                        f"{mn} x7, f1{rm}",
                        "csrrs x8, fflags, x0"]
                cases.append((mn, a))
                want.append(fcvt_to_int(a, is_u, bits, code))
    # integer -> double: the result comes back through the FP file
    # 0x80000000 is here as the positive value 2**31, and 0xFFFFFFFF80000000 as
    # the value li's sign-extension actually produces for that literal; both are
    # covered so the distinction cannot be lost again.
    ints = [0, 1, -1 & ((1 << 64) - 1), 0x7FFFFFFF, 0x80000000,
            0xFFFFFFFF80000000,
            0x7FFFFFFFFFFFFFFF, 0x8000000000000000, 0xFFFFFFFFFFFFFFFF,
            0x0020000000000001, 0x001FFFFFFFFFFFFF]
    for x in ints:
        for mn, is_u, bits in (("fcvt.d.w", 0, 32), ("fcvt.d.wu", 1, 32),
                               ("fcvt.d.l", 0, 64), ("fcvt.d.lu", 1, 64)):
            for rm, code in (("", 0), (", rtz", 1), (", rup", 3)):
                src += ["csrrw x0, fflags, x0"] + _build_int("x5", x) + [
                        f"{mn} f3, x5{rm}",
                        "fmv.x.d x7, f3",
                        "csrrs x8, fflags, x0"]
                cases.append((mn, x))
                want.append(fcvt_from_int(x, is_u, bits, code))
    src.append("ecall")
    writes, h = await run_prog(dut, "\n".join(src))
    bad = check(cases, writes.get(7, []), writes.get(8, []), want, "fcvt")
    dut._log.info(f"fcvt: {len(cases)} vectors, {bad} mismatches, "
                  f"{len(h.trace)} retirements")
    assert bad == 0, f"fcvt: {bad}/{len(cases)} mismatches"


@cocotb.test()
async def test_fpu_core_cmp(dut):
    """feq.d / flt.d / fle.d: the boolean result and the invalid flag on sNaN."""
    vecs = vectors()
    src, cases, want = [], [], []
    for i, a in enumerate(vecs[:12]):
        for b in (vecs[(i * 3 + 1) % len(vecs)], vecs[i % len(vecs)], 0, SIGN,
                  QNAN, INF):
            for mn, f3 in (("feq.d", 2), ("flt.d", 1), ("fle.d", 0)):
                src += ["csrrw x0, fflags, x0",
                        f"li    x5, {a}",
                        "fmv.d.x f1, x5",
                        f"li    x6, {b}",
                        "fmv.d.x f2, x6",
                        f"{mn} x7, f1, f2",
                        "csrrs x8, fflags, x0"]
                cases.append((mn, a, b))
                want.append(fcmp(a, b, f3))
    src.append("ecall")
    writes, h = await run_prog(dut, "\n".join(src))
    bad = check(cases, writes.get(7, []), writes.get(8, []), want, "fcmp")
    dut._log.info(f"fcmp: {len(cases)} vectors, {bad} mismatches, "
                  f"{len(h.trace)} retirements")
    assert bad == 0, f"fcmp: {bad}/{len(cases)} mismatches"


@cocotb.test()
async def test_fpu_core_frm(dut):
    """The dynamic rounding mode: funct3 = 7 must take frm out of fcsr.

    This is the path a compiler actually uses -- `fmul.d` with no explicit rm
    field encodes 7, and the mode then comes from the frm CSR.  A core that
    ignored frm would still pass every test that writes the mode in the
    instruction, so this is checked separately: the same operands are run under
    all five frm settings and the results must differ where they should.
    """
    a = 0x3FF0000000000001          # 1.0 + 1 ulp
    b = 0x3FF0000000000001
    src = []
    cases, want = [], []
    for frm in range(5):
        src += ["csrrw x0, fflags, x0",
                f"li    x9, {frm}",
                "csrrw x0, frm, x9",
                f"li    x5, {a}",
                "fmv.d.x f1, x5",
                f"li    x6, {b}",
                "fmv.d.x f2, x6",
                "fmul.d f3, f1, f2, dyn",     # funct3 = 7 -> use frm
                "fmv.x.d x7, f3",
                "csrrs x8, fflags, x0"]
        cases.append((frm,))
        want.append(fmul(a, b, frm))
    src += ["li    x9, 0", "csrrw x0, frm, x9", "ecall"]
    writes, h = await run_prog(dut, "\n".join(src))
    bad = check(cases, writes.get(7, []), writes.get(8, []), want, "frm")
    dut._log.info(f"frm: {len(cases)} modes, {bad} mismatches, "
                  f"results={[hex(x) for x in writes.get(7, [])]}")
    assert bad == 0, f"frm: {bad}/{len(cases)} mismatches"


@cocotb.test()
async def test_fpu_core_flags_sticky(dut):
    """fflags is sticky and accumulates across operations until software clears it."""
    src = [
        "csrrw x0, fflags, x0",
        f"li    x5, {0x3FF0000000000000}",      # 1.0
        "fmv.d.x f1, x5",
        f"li    x6, {0x4000000000000000}",      # 2.0
        "fmv.d.x f2, x6",
        "fdiv.d f3, f1, f2",                    # 0.5: exact, no flags
        "csrrs x7, fflags, x0",                 # -> 0
        "fsqrt.d f3, f2",                       # sqrt(2): inexact
        "csrrs x8, fflags, x0",                 # -> NX
        "fdiv.d f3, f1, x0",                    # placeholder replaced below
    ]
    # 1.0 / 0.0 -> infinity with divide-by-zero; build the zero in f4
    src[-1] = "fdiv.d f3, f1, f4"
    src.insert(-1, f"li    x10, 0")
    src.insert(-1, "fmv.d.x f4, x10")
    src += ["csrrs x9, fflags, x0",             # -> NX | DZ, still sticky
            "csrrw x0, fflags, x0",
            "csrrs x11, fflags, x0",            # -> 0 after the clear
            "ecall"]
    writes, h = await run_prog(dut, "\n".join(src))
    w7 = writes.get(7, [])
    w8 = writes.get(8, [])
    w9 = writes.get(9, [])
    w11 = writes.get(11, [])
    dut._log.info(f"sticky flags: after exact div={w7}, after sqrt={w8}, "
                  f"after div-by-zero={w9}, after clear={w11}")
    assert w7 == [0], f"an exact division raised flags: {w7}"
    assert w8 == [0x1], f"sqrt(2) should raise only inexact, got {w8}"
    assert w9 == [0x9], f"expected NX|DZ (0x9) after 1.0/0.0, got {w9}"
    assert w11 == [0], f"fflags did not clear: {w11}"


@cocotb.test()
async def test_fpu_core_single_precision_traps(dut):
    """Single-precision and the unimplemented OP-FP forms must still trap.

    The decoder is what decides this, and widening it to the whole double
    encoding is exactly the change that could accidentally start accepting
    fadd.s (funct7 0x00) as fadd.d.  misa advertises F, not D-only-plus-noise, so
    a silent wrong answer here would be worse than a trap.
    """
    from test_core import Harness as H
    words = [0x00000053,          # fadd.s f0, f0, f0  (funct7 = 0x00)
             0x00000073]          # ecall
    h = H(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=400, stop_on_ecall=False)
    causes = [c for (_, c) in h.traps]
    assert 2 in causes, f"fadd.s did not trap: causes={causes}"
