"""
test_fpu_integration.py -- the SEAMS between the FPU blocks and riscv_core_top.

Why this file exists
--------------------
The scalar FPU blocks pass 106,192 block-level vectors with zero mismatches
(test_fpu_unit.py, --suite fpu) against the models in rtl/fpu/model/.  That
proves the adder, multiplier, divider, square root, converter, comparator and
rounder are individually right.  It proves nothing about the wiring: which
operand goes in, whether the fmt bit arrived, whether frm came from fcsr,
whether the flags were latched, whether the result was boxed on the way into
the register file, or whether a dependent instruction saw it.

Every test here therefore executes real code on riscv_core_top and checks the
ARCHITECTURAL result -- the value the ISA says must appear, and the fflags word
that must accompany it.  "It did not trap" is not an assertion in this file.

The observation idiom
---------------------
The FP registers are not directly readable, so a case observes one by storing
the whole 64-bit f-register with `fsd` and loading it back with `ld`.  That is
also the only way to see NaN-boxing: the box lives in the upper 32 bits, and a
consumer that unboxes correctly hides it.  Each case is

    csrrw x0, fflags, x0        # isolate this case's sticky flags
    <setup: build operands, usually li + fmv.*.x>
    <operation under test>
    fsd   f3, 0(x20) ; ld x7, 0(x20)     # raw f-register bits -> x7
    csrrs x8, fflags, x0                 # -> x8

so every case leaves exactly one write to x7 and one to x8, in order, and the
runner compares them against a per-case expectation.

The oracle
----------
Arithmetic values and flags come from rtl/fpu/model/ -- already cross-checked
against the RTL at block level, so a mismatch here is a wiring defect by
construction.  Seam-specific expectations (a box, the canonical NaN, a bit
pattern with no arithmetic in it) are written out literally, because those are
specification constants, not model outputs.

Rounding-mode and fmt expectations are always computed for the format the
instruction names, so a core that ignored funct7[0] would have to match the
wrong format's model to pass -- which it cannot.

Run:
    python3 sim/run.py --testcase test_s1_nanbox_read_write_paths
    python3 sim/run.py --testcase test_s1 --testcase test_s2 ...   (any subset)
"""

import os
import sys

import cocotb

from rv64_asm import assemble, li_value
from test_core import Harness

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "..", "..", "rtl", "fpu", "model"))

from fp_common import FFL_DZ, FFL_NV, FFL_NX, FFL_OF, FFL_UF   # noqa: E402
from fp_add_model import fp_add                                # noqa: E402
from fp_cmp_model import fcmp, FEQ, FLT, FLE                   # noqa: E402
from fp_cvt_model import fcvt_fp, fcvt_from_int, fcvt_to_int   # noqa: E402
from fp_div_model import fdiv                                  # noqa: E402
from fp_mul_model import fmul                                  # noqa: E402
from fp_sqrt_model import fsqrt                                # noqa: E402

M64 = (1 << 64) - 1
M32 = (1 << 32) - 1
BOX_HI = 0xFFFFFFFF00000000
CANON32 = 0x7FC00000            # canonical binary32 quiet NaN
QNAN64 = 0x7FF8000000000000     # canonical binary64 quiet NaN
INF64 = 0x7FF0000000000000
SIGN64 = 1 << 63

# Scratch memory.  The program is loaded at 0 and is a few KiB; everything below
# is clear of it.  x20 holds DATA_BASE, x21 is unused.
DATA_BASE = 0x3000
OBS = 0x000          # 8-byte slot used by `fsd`/`ld` to read an f-register
MEM = 0x100          # flw/fsw playground (offsets from x20)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def box32(v):
    """The NaN-boxed form of a binary32 bit pattern."""
    return BOX_HI | (v & M32)


def const_ops(rd, val, scratch="x31"):
    """Instructions that put the EXACT 64-bit pattern `val` into `rd`.

    `li` cannot express every 64-bit pattern: a literal in [2**31, 2**32) is
    taken as a 32-bit constant and sign-extended, which is correct assembler
    behaviour but not what a test that means 0x00000000_80000000 wants.  So
    build the high word, shift it up, and OR in a zero-extended low word.
    """
    v = val & M64
    if li_value(v) == v:
        return [f"li    {rd}, {v}"]
    hi, lo = (v >> 32) & M32, v & M32
    out = [f"li    {rd}, {hi}", f"slli  {rd}, {rd}, 32"]
    if lo:
        out += [f"li    {scratch}, {lo}",
                f"slli  {scratch}, {scratch}, 32",
                f"srli  {scratch}, {scratch}, 32",
                f"or    {rd}, {rd}, {scratch}"]
    return out


def ld_f(reg, bits, fmt):
    """Put the 64-bit pattern `bits` into f{reg} via fmv.<fmt>.x.

    fmt='s' uses fmv.w.x, which takes the low 32 bits and NaN-boxes them -- so
    the register ends up holding box32(bits).  fmt='d' uses fmv.d.x, which is a
    raw 64-bit move and leaves the pattern unboxed.
    """
    # the mnemonic for int->fp single is fmv.w.x (the "w" is the WIDTH of the
    # source, not the format of the destination)
    mn = "w" if fmt == "s" else "d"
    return const_ops("x5", bits) + [f"fmv.{mn}.x f{reg}, x5"]


def ld_i(reg, val):
    """Put `val` into integer register x{reg} exactly."""
    return const_ops(f"x{reg}", val)


def obs(reg=3, off=OBS):
    """Read the raw 64-bit contents of f{reg} into x7."""
    return [f"fsd   f{reg}, {off}(x20)", f"ld    x7, {off}(x20)"]


def case(name, pre, lines, want, want_flags=0):
    return dict(name=name, pre=pre, lines=lines,
                want=(want, want_flags))


RESULTS = {}


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------


async def run_prog(dut, src, max_cycles=200000, tag=""):
    """Assemble, load, run to ecall, and return {register: [writes in order]}."""
    words, _ = assemble(src)
    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=max_cycles, stop_on_ecall=True)
    causes = [c for (_, c) in h.traps]
    assert 2 not in causes, (
        f"{tag}: an FP instruction trapped as illegal (cause 2) at "
        f"{[hex(p) for p, c in h.traps if c == 2][:4]}; the decode arm rejected "
        f"an instruction the ISA requires to execute")
    writes = {}
    for (pc, insn, we, rd, wd) in h.trace:
        if we and rd is not None:
            writes.setdefault(rd, []).append(wd)
    return writes, h


async def run_cases(dut, cases, tag, max_cycles=200000):
    """Run every case in one program; compare value and flags; return misses."""
    src = [f"li    x20, {DATA_BASE}"]
    for c in cases:
        src.append("csrrw x0, fflags, x0")
        src += c["pre"]
        src += c["lines"]
        src.append("csrrs x8, fflags, x0")
    src.append("ecall")
    writes, h = await run_prog(dut, "\n".join(src), max_cycles, tag)
    got_v = writes.get(7, [])
    got_f = writes.get(8, [])
    assert len(got_v) == len(cases), (
        f"{tag}: retired {len(got_v)} results, expected {len(cases)} -- a case "
        f"did not complete")
    assert len(got_f) == len(cases), (
        f"{tag}: retired {len(got_f)} flag reads, expected {len(cases)}")
    bad = 0
    for i, c in enumerate(cases):
        wv, wf = c["want"]
        gv, gf = got_v[i], got_f[i]
        if gv != wv or (wf is not None and gf != wf):
            bad += 1
            if bad <= 8:
                cocotb.log.error(
                    f"{tag}[{i}] {c['name']}: DUT {gv:#018x}/{gf:#04x} "
                    f"want {wv:#018x}/"
                    f"{'any' if wf is None else format(wf, '#04x')}")
    RESULTS[tag] = (len(cases) - bad, len(cases))
    dut._log.info(f"{tag}: {len(cases) - bad}/{len(cases)} cases pass "
                  f"({len(h.trace)} retirements)")
    return bad, len(cases)


# ===========================================================================
# SEAM 1 -- NaN-boxing on every read and write path
# ===========================================================================
@cocotb.test()
async def test_fpu_integration_s1_nanbox_read_write_paths(dut):
    """NaN-boxing at the FP register file: every producer boxes, every consumer
    either unboxes (a .s operation) or takes the raw 64 bits (a .d operation).

    Expected architectural results:
      * fadd.s 1.0f+2.0f     -> f-register = 0xFFFFFFFF_40400000
        (the binary32 result 0x40400000 with the upper half set to ones -- the
        box is architectural: `fsd` of an f-register holding a single must show
        it, and fmv.x.d must return the whole thing).
      * fsub.s / fmul.s / fdiv.s / fsqrt.s / fmv.w.x / flw / fcvt.s.w /
        fcvt.s.d -- same rule, the value boxed with 0xFFFFFFFF in the high half.
      * a .d operation on a boxed single must see it as a NaN, because the box
        makes the 64-bit pattern a quiet NaN in binary64.  fadd.d of it with 1.0
        is therefore the canonical qNaN 0x7FF8000000000000 with NO flags (a
        quiet NaN is silent; only a signalling NaN raises invalid).
      * a .s operation on a value that was never boxed must substitute the
        canonical binary32 qNaN, so fadd.s of a raw double 1.0 with itself is
        0xFFFFFFFF_7FC00000.  (The F/D spec says a non-boxed operand "is
        treated as the canonical NaN"; it does not require invalid to be raised,
        so the flags checked here are that no OTHER flag appears.)
    """
    cases = []

    # ---- producers: each must leave a correctly boxed value ----------------
    cases += [
        case("fadd.s 1+2", ld_f(1, 0x3F800000, "s") + ld_f(2, 0x40000000, "s"),
             ["fadd.s f3, f1, f2"] + obs(), box32(0x40400000)),
        case("fsub.s 1-2", ld_f(1, 0x3F800000, "s") + ld_f(2, 0x40000000, "s"),
             ["fsub.s f3, f1, f2"] + obs(), box32(0xBF800000)),
        case("fmul.s 2*3", ld_f(1, 0x40000000, "s") + ld_f(2, 0x40400000, "s"),
             ["fmul.s f3, f1, f2"] + obs(), box32(0x40C00000)),
        case("fdiv.s 1/3", ld_f(1, 0x3F800000, "s") + ld_f(2, 0x40400000, "s"),
             ["fdiv.s f3, f1, f2"] + obs(),
             box32(fdiv(0x3F800000, 0x40400000, 0, 0)[0]), FFL_NX),
        case("fsqrt.s 2", ld_f(1, 0x40000000, "s"),
             ["fsqrt.s f3, f1"] + obs(),
             box32(fsqrt(0x40000000, 0, 0)[0]), FFL_NX),
        case("fmv.w.x 1.0f", const_ops("x5", 0x3F800000),
             ["fmv.w.x f3, x5"] + obs(), box32(0x3F800000)),
        case("flw", const_ops("x5", 0x40490FDB) + [f"sw    x5, {MEM}(x20)"],
             [f"flw   f3, {MEM}(x20)"] + obs(), box32(0x40490FDB)),
        case("fcvt.s.w 7", const_ops("x5", 7),
             ["fcvt.s.w f3, x5"] + obs(), box32(0x40E00000)),
        case("fcvt.s.d 1.5", ld_f(1, 0x3FF8000000000000, "d"),
             ["fcvt.s.d f3, f1"] + obs(), box32(0x3FC00000)),
        case("fcvt.s.l -1", const_ops("x5", M64),
             ["fcvt.s.l f3, x5"] + obs(), box32(0xBF800000)),
    ]

    # ---- a .d consumer must see the box as a NaN ---------------------------
    prod = ld_f(1, 0x3F800000, "s") + ld_f(2, 0x40000000, "s") + \
        ["fadd.s f3, f1, f2"]
    cases += [
        case("fadd.d(box,1.0)", prod + ld_f(4, 0x3FF0000000000000, "d"),
             ["fadd.d f5, f3, f4"] + obs(5), QNAN64, 0),
        case("fmul.d(box,1.0)", prod + ld_f(4, 0x3FF0000000000000, "d"),
             ["fmul.d f5, f3, f4"] + obs(5), QNAN64, 0),
        case("fsqrt.d(box)", prod, ["fsqrt.d f5, f3"] + obs(5), QNAN64, 0),
        case("fcvt.w.d(box)", prod, ["fcvt.w.d x7, f3"], 0x7FFFFFFF, FFL_NV),
        case("flt.d(box,1.0)", prod + ld_f(4, 0x3FF0000000000000, "d"),
             ["flt.d x7, f3, f4"], 0, 0),
    ]

    # ---- a .s consumer must substitute the canonical NaN for a bad box -----
    raw_double = ld_f(1, 0x3FF0000000000000, "d")
    cases += [
        case("fadd.s(unboxed,unboxed)", raw_double,
             ["fadd.s f3, f1, f1"] + obs(), box32(CANON32), 0),
        case("fmul.s(unboxed,unboxed)", raw_double,
             ["fmul.s f3, f1, f1"] + obs(), box32(CANON32), 0),
        case("fsqrt.s(unboxed)", raw_double,
             ["fsqrt.s f3, f1"] + obs(), box32(CANON32), 0),
        case("feq.s(unboxed,unboxed)", raw_double,
             ["feq.s x7, f1, f1"], 0, 0),
        case("fcvt.w.s(unboxed)", raw_double, ["fcvt.w.s x7, f1"],
             0x7FFFFFFF, FFL_NV),
        case("fcvt.d.s(unboxed)", ld_f(1, 0x3FF0000000000000, "d"),
             ["fcvt.d.s f3, f1"] + obs(), QNAN64, 0),
        case("fmv.x.w(raw double, bit move)", ld_f(1, 0x3FF0000000000000, "d"),
             ["fmv.x.w x7, f1"], 0x0000000000000000, 0),
        case("fcvt.s.s? no such op -- fadd.s of a box with hi=0x7FFFFFFF",
             ld_f(1, 0x7FFFFFFF3F800000, "d"),
             ["fadd.s f3, f1, f1"] + obs(), box32(CANON32), 0),
        # a box with the WRONG high half (0x00000000 rather than all ones) is
        # just as invalid as no box at all
        case("fadd.s(bad box)", ld_f(1, 0x0000000040400000, "d"),
             ["fadd.s f3, f1, f1"] + obs(), box32(CANON32), 0),
    ]

    bad, n = await run_cases(dut, cases, "s1_nanbox")
    assert bad == 0, f"NaN-boxing: {bad}/{n} cases wrong"


# ===========================================================================
# SEAM 2 -- the fmt bit
# ===========================================================================
@cocotb.test()
async def test_fpu_integration_s2_fmt_bit_routing(dut):
    """funct7[0] is the format selector, and what it selects depends on the
    group.  The decoder keys on funct7[6:1] and takes funct7[0] as the format,
    so one wrong bit misroutes a whole opcode family.

    Expected architectural results, for every arithmetic op:
      the SAME 64-bit pattern is loaded twice -- once boxed via fmv.w.x (so the
      core sees a binary32) and once raw via fmv.d.x (so it sees a binary64) --
      and the result must equal the model for the format the instruction names.
      V = 0x00000000_40000000 is 2.0f as a single and 2**-1044 as a double, so
      the two answers cannot be confused: fadd.s gives 0xFFFFFFFF_40A00000
      (5.0f boxed) while fadd.d gives a subnormal 0x000000000000000A.

      fcmp: 1.0f vs -1.0f compares greater, but as doubles 0x000000003F800000
      is smaller than 0x00000000BF800000, so flt.s is 0 and flt.d is 1.

      fcvt: the fmt bit names the SOURCE for fp->int (fcvt.w.s reads a boxed
      single; fcvt.w.d on the same register reads a NaN), and the DESTINATION
      for int->fp and for fcvt.s.d / fcvt.d.s.

      fmv: funct7[0] is WIDTH, not format.  fmv.x.d of a boxed single must
      return the whole box 0xFFFFFFFF_40400000, while fmv.x.w of the same
      register must sign-extend the low 32 bits to 0x00000000_40400000.
    """
    cases = []
    # (label, op_mnemonic, fn(base, fmt), operands)
    WA, WB = 0x40000000, 0x40400000           # 2.0f, 3.0f
    VA, VB = WA, WB                           # same patterns, as doubles
    binops = [("fadd", lambda a, b, f: fp_add(a, b, 0, 0, f)),
              ("fsub", lambda a, b, f: fp_add(a, b, 1, 0, f)),
              ("fmul", lambda a, b, f: fmul(a, b, 0, f)),
              ("fdiv", lambda a, b, f: fdiv(a, b, 0, f))]
    for mn, fn in binops:
        for fmt in ("s", "d"):
            w, fl = fn(WA if fmt == "s" else VA, WB if fmt == "s" else VB,
                       0 if fmt == "s" else 1)
            pre = ld_f(1, WA, fmt) + ld_f(2, WB, fmt)
            cases.append(case(f"{mn}.{fmt}", pre,
                              [f"{mn}.{fmt} f3, f1, f2"] + obs(),
                              box32(w) if fmt == "s" else w, fl))
    # fsqrt, both formats
    for fmt in ("s", "d"):
        w, fl = fsqrt(WA if fmt == "s" else VA, 0, 0 if fmt == "s" else 1)
        cases.append(case(f"fsqrt.{fmt}", ld_f(1, WA, fmt),
                          [f"fsqrt.{fmt} f3, f1"] + obs(),
                          box32(w) if fmt == "s" else w, fl))
    # fcmp: funct3 is the selector here, not a rounding mode
    for fmt in ("s", "d"):
        a, b = (0x3F800000, 0xBF800000)
        A, B = (a, b) if fmt == "s" else (a, b)   # same patterns both ways
        for mn, f3 in (("feq", FEQ), ("flt", FLT), ("fle", FLE)):
            w, fl = fcmp(A, B, f3, 0 if fmt == "s" else 1)
            pre = ld_f(1, A, fmt) + ld_f(2, B, fmt)
            cases.append(case(f"{mn}.{fmt}", pre, [f"{mn}.{fmt} x7, f1, f2"], w, fl))
    # fp -> int: fmt names the SOURCE
    # the flags come from the model, not from a guess: 1.5 truncated to 1 IS
    # inexact, so fcvt.w.s of it raises NX.  (The first version of this test
    # asserted "no flags" here and was wrong -- see the seam report.)
    wv, wf = fcvt_to_int(0x3FC00000, 0, 32, 1, 0)
    cases += [
        case("fcvt.w.s(boxed 1.5f)", ld_f(1, 0x3FC00000, "s"),
             ["fcvt.w.s x7, f1, rtz"], wv, wf),
        case("fcvt.w.d(same reg)", ld_f(1, 0x3FC00000, "s"),
             ["fcvt.w.d x7, f1, rtz"], 0x7FFFFFFF, FFL_NV),
        case("fcvt.l.d(1.5)", ld_f(1, 0x3FF8000000000000, "d"),
             ["fcvt.l.d x7, f1, rtz"],
             *fcvt_to_int(0x3FF8000000000000, 0, 64, 1, 1)),
        case("fcvt.l.s(1.5f)", ld_f(1, 0x3FC00000, "s"),
             ["fcvt.l.s x7, f1, rtz"], *fcvt_to_int(0x3FC00000, 0, 64, 1, 0)),
        case("fcvt.w.s(2.5f, rne)", ld_f(1, 0x40200000, "s"),
             ["fcvt.w.s x7, f1, rne"], *fcvt_to_int(0x40200000, 0, 32, 0, 0)),
    ]
    # int -> fp: fmt names the DESTINATION
    cases += [
        case("fcvt.s.w(1)", const_ops("x5", 1), ["fcvt.s.w f3, x5"] + obs(),
             box32(0x3F800000), 0),
        case("fcvt.d.w(1)", const_ops("x5", 1), ["fcvt.d.w f3, x5"] + obs(),
             0x3FF0000000000000, 0),
        case("fcvt.s.lu(max)", const_ops("x5", M64),
             ["fcvt.s.lu f3, x5"] + obs(),
             box32(fcvt_from_int(M64, 1, 64, 0, 0)[0]),
             fcvt_from_int(M64, 1, 64, 0, 0)[1]),
        case("fcvt.d.lu(max)", const_ops("x5", M64),
             ["fcvt.d.lu f3, x5"] + obs(),
             fcvt_from_int(M64, 1, 64, 0, 1)[0],
             fcvt_from_int(M64, 1, 64, 0, 1)[1]),
    ]
    # fcvt.s.d / fcvt.d.s: fmt names the DESTINATION
    cases += [
        case("fcvt.s.d(1.5)", ld_f(1, 0x3FF8000000000000, "d"),
             ["fcvt.s.d f3, f1"] + obs(), box32(0x3FC00000), 0),
        case("fcvt.d.s(boxed 1.5f)", ld_f(1, 0x3FC00000, "s"),
             ["fcvt.d.s f3, f1"] + obs(), 0x3FF8000000000000, 0),
        case("fcvt.d.s(1/3f)", ld_f(1, 0x3EAAAAAB, "s"),
             ["fcvt.d.s f3, f1"] + obs(),
             fcvt_fp(0x3EAAAAAB, 0, 1, 0)[0], fcvt_fp(0x3EAAAAAB, 0, 1, 0)[1]),
    ]
    # fmv: funct7[0] is the WIDTH
    cases += [
        case("fmv.x.d(boxed single)", ld_f(1, 0x40400000, "s"),
             ["fmv.x.d x7, f1"], box32(0x40400000), 0),
        case("fmv.x.w(boxed single)", ld_f(1, 0x40400000, "s"),
             ["fmv.x.w x7, f1"], 0x0000000040400000, 0),
        case("fmv.x.w(-1.0f boxed)", ld_f(1, 0xBF800000, "s"),
             ["fmv.x.w x7, f1"], 0xFFFFFFFFBF800000, 0),
        case("fmv.d.x(no box)", const_ops("x5", 0x000000003F800000),
             ["fmv.d.x f3, x5"] + obs(), 0x000000003F800000, 0),
        case("fmv.w.x(boxes)", const_ops("x5", 0x3F800000),
             ["fmv.w.x f3, x5"] + obs(), box32(0x3F800000), 0),
    ]

    bad, n = await run_cases(dut, cases, "s2_fmt")
    assert bad == 0, f"fmt routing: {bad}/{n} cases wrong"


# ===========================================================================
# SEAM 3 -- rounding mode propagation
# ===========================================================================
@cocotb.test()
async def test_fpu_integration_s3_rounding_mode_propagation(dut):
    """fcsr.frm must reach every FP operation through funct3 = 7 (DYN).

    Expected architectural results: with frm set to each of the five modes and
    the instruction's rm field left at DYN, the result must equal the model for
    THAT mode.  The operands are chosen so the modes disagree:

      1.0 + 2**-53   is an exact tie: RNE -> 1.0 (ties to even), RMM and RUP ->
                     1.0+2**-52, RTZ and RDN -> 1.0.
      1.0 / 3.0      is inexact and positive: RDN truncates, RUP increments.
      sqrt(2)        is inexact: RTZ, RNE and RUP give three different answers.
      (1+2**-52)**2  rounds up only under RUP.

    A core that drives the rounder from a stale pipeline register, or from a
    constant, fails at least one mode on every one of these -- and because the
    expectation is the model for the requested mode, it cannot pass by accident.
    The last four cases check the other direction: an explicit rm field must win
    over frm, so a core that always used frm would round wrongly there.
    """
    cases = []
    RMW = {"rne": 0, "rtz": 1, "rdn": 2, "rup": 3, "rmm": 4}
    # (label, mnemonic, a, b, model fn)
    dbin = [("fadd.d", 0x3FF0000000000000, 0x3CA0000000000000,
             lambda a, b, r: fp_add(a, b, 0, r, 1)),
            ("fmul.d", 0x3FF0000000000001, 0x3FF0000000000001,
             lambda a, b, r: fmul(a, b, r, 1)),
            ("fdiv.d", 0x3FF0000000000000, 0x4008000000000000,
             lambda a, b, r: fdiv(a, b, r, 1)),
            ("fsub.d", 0x3FF0000000000000, 0x3CA0000000000000,
             lambda a, b, r: fp_add(a, b, 1, r, 1))]
    for mn, a, b, fn in dbin:
        for name, rm in RMW.items():
            w, fl = fn(a, b, rm)
            pre = ld_i(9, rm) + ["csrrw x0, frm, x9"] + ld_f(1, a, "d") + \
                ld_f(2, b, "d")
            cases.append(case(f"{mn} frm={name}", pre,
                              [f"{mn} f3, f1, f2, dyn"] + obs(), w, fl))
    sbin = [("fadd.s", 0x3F800000, 0x33800000,
             lambda a, b, r: fp_add(a, b, 0, r, 0)),
            ("fdiv.s", 0x3F800000, 0x40400000,
             lambda a, b, r: fdiv(a, b, r, 0))]
    for mn, a, b, fn in sbin:
        for name, rm in RMW.items():
            w, fl = fn(a, b, rm)
            pre = ld_i(9, rm) + ["csrrw x0, frm, x9"] + ld_f(1, a, "s") + \
                ld_f(2, b, "s")
            cases.append(case(f"{mn} frm={name}", pre,
                              [f"{mn} f3, f1, f2, dyn"] + obs(),
                              box32(w), fl))
    for fmt, bits in (("d", 0x4000000000000000), ("s", 0x40000000)):
        for name, rm in RMW.items():
            w, fl = fsqrt(bits, rm, 1 if fmt == "d" else 0)
            pre = ld_i(9, rm) + ["csrrw x0, frm, x9"] + ld_f(1, bits, fmt)
            cases.append(case(f"fsqrt.{fmt} frm={name}", pre,
                              [f"fsqrt.{fmt} f3, f1, dyn"] + obs(),
                              w if fmt == "d" else box32(w), fl))
    # a bubble between the frm write and the operation must not lose it
    for name, rm in RMW.items():
        w, fl = fp_add(0x3FF0000000000000, 0x3CA0000000000000, 0, rm, 1)
        pre = ld_i(9, rm) + ["csrrw x0, frm, x9", "nop", "nop"] + \
            ld_f(1, 0x3FF0000000000000, "d") + ld_f(2, 0x3CA0000000000000, "d")
        cases.append(case(f"fadd.d frm={name} after bubble", pre,
                          ["fadd.d f3, f1, f2, dyn"] + obs(), w, fl))
    # the rounding mode must also reach the converter and the int->fp packer
    for name, rm in RMW.items():
        w, fl = fcvt_to_int(0x400C000000000000, 0, 64, rm, 1)   # 3.5 -> int
        pre = ld_i(9, rm) + ["csrrw x0, frm, x9"] + \
            ld_f(1, 0x400C000000000000, "d")
        cases.append(case(f"fcvt.l.d(3.5) frm={name}", pre,
                          ["fcvt.l.d x7, f1, dyn"], w, fl))
        w, fl = fcvt_from_int((1 << 53) + 1, 0, 64, rm, 1)      # needs rounding
        pre = ld_i(9, rm) + ["csrrw x0, frm, x9"] + \
            const_ops("x5", (1 << 53) + 1)
        cases.append(case(f"fcvt.d.l(2**53+1) frm={name}", pre,
                          ["fcvt.d.l f3, x5, dyn"] + obs(), w, fl))
    # csrw fcsr sets frm and fflags in one instruction; both must land
    for name, rm in RMW.items():
        w, fl = fp_add(0x3FF0000000000000, 0x3CA0000000000000, 0, rm, 1)
        pre = ld_i(9, rm | 0x1F) + ["csrrw x0, fcsr, x9"] + \
            ld_f(1, 0x3FF0000000000000, "d") + ld_f(2, 0x3CA0000000000000, "d")
        cases.append(case(f"csrw fcsr frm={name} fflags=0x1F", pre,
                          ["fadd.d f3, f1, f2, dyn"] + obs(), w, fl | 0x1F))
    # an explicit rm field must override frm
    for name, rm in RMW.items():
        w, fl = fp_add(0x3FF0000000000000, 0x3CA0000000000000, 0, 0, 1)
        pre = ld_i(9, rm) + ["csrrw x0, frm, x9"] + \
            ld_f(1, 0x3FF0000000000000, "d") + ld_f(2, 0x3CA0000000000000, "d")
        cases.append(case(f"fadd.d static rne under frm={name}", pre,
                          ["fadd.d f3, f1, f2, rne"] + obs(), w, fl))
    # leave frm at RNE and read it back: the write must land, and reading frm
    # must show what was written (a csrw that only reached fflags would fail)
    cases.append(case("restore frm and read it back", ld_i(9, 0),
                      ["csrrw x0, frm, x9", "csrrs x7, frm, x0"], 0, None))

    bad, n = await run_cases(dut, cases, "s3_frm")
    assert bad == 0, f"rounding mode: {bad}/{n} cases wrong"


# ===========================================================================
# SEAM 4 -- fflags accumulation, precision and clearing
# ===========================================================================
@cocotb.test()
async def test_fpu_integration_s4_fflags_accumulate_and_clear(dut):
    """Every FP operation must OR its exception flags into fcsr.fflags, the bits
    must stay set until software clears them, and a clear must clear.

    Expected architectural results (bit values: NV=0x10, DZ=0x08, OF=0x04,
    UF=0x02, NX=0x01):
      sqrt(-1.0)          -> NV only, result 0x7FF8000000000000
      sqrt(-1.0f)         -> NV only, result boxed 0xFFFFFFFF_7FC00000
      1.0/0.0             -> DZ only, result +inf
      1.0f/0.0f           -> DZ only, result boxed +inf
      inf - inf           -> NV only, canonical qNaN
      sNaN + 1.0          -> NV only, canonical qNaN (a qNaN operand is silent)
      maxdouble * 2.0     -> OF|NX (0x05), result +inf
      minsubnormal * 0.5  -> UF|NX (0x03), result +0
      1.0/3.0             -> NX only
      1.0+2.0             -> no flags at all
      fcvt.w.d(inf)       -> NV, result 0x7FFFFFFF
      feq.d(sNaN, 1.0)    -> NV, result 0

      accumulation: NX from one op then DZ from another, with no clear between,
      must read 0x09; `csrw fcsr, x0` must then read 0; and an op immediately
      after the clear must show only its own flags -- which is the ordering the
      core's EX-stage flag write exists to get right.
    """
    MINSUB = 0x0000000000000001
    MAXD = 0x7FEFFFFFFFFFFFFF
    SNaN = 0x7FF0000000000001

    def dcase(name, a, b, mn, want_flags, want=None, fmt="d", rm=0):
        """One single- or double-precision case.  `want` may be given outright
        for the specification constants (a canonical NaN, an infinity); the
        arithmetic default comes from the model for the format `mn` names."""
        f = 1 if fmt == "d" else 0
        pre = ld_f(1, a, fmt) + (ld_f(2, b, fmt) if b is not None else [])
        if want is None:
            base = mn.split(".")[0]
            w = {"fsqrt": lambda: fsqrt(a, rm, f),
                 "fadd": lambda: fp_add(a, b, 0, rm, f),
                 "fsub": lambda: fp_add(a, b, 1, rm, f),
                 "fmul": lambda: fmul(a, b, rm, f),
                 "fdiv": lambda: fdiv(a, b, rm, f)}[base]()[0]
            if fmt == "s":
                w = box32(w)
        else:
            w = want
        line = f"{mn} f3, f1" + (f", f2" if b is not None else "")
        return case(name, pre, [line] + obs(), w, want_flags)

    cases = [
        dcase("sqrt.d(-1)", 0xBFF0000000000000, None, "fsqrt.d", FFL_NV),
        dcase("sqrt.s(-1)", 0xBF800000, None, "fsqrt.s", FFL_NV, fmt="s",
              want=box32(CANON32)),
        dcase("1.0/0.0", 0x3FF0000000000000, 0, "fdiv.d", FFL_DZ, want=INF64),
        dcase("1.0f/0.0f", 0x3F800000, 0, "fdiv.s", FFL_DZ, fmt="s",
              want=box32(0x7F800000)),
        dcase("inf-inf", INF64, INF64, "fsub.d", FFL_NV, want=QNAN64),
        dcase("sNaN+1.0", SNaN, 0x3FF0000000000000, "fadd.d", FFL_NV,
              want=QNAN64),
        dcase("qNaN+1.0 (silent)", QNAN64, 0x3FF0000000000000, "fadd.d", 0,
              want=QNAN64),
        dcase("max*2", MAXD, 0x4000000000000000, "fmul.d", FFL_OF | FFL_NX,
              want=INF64),
        dcase("minsub*0.5", MINSUB, 0x3FE0000000000000, "fmul.d",
              FFL_UF | FFL_NX, want=0),
        dcase("1.0/3.0", 0x3FF0000000000000, 0x4008000000000000, "fdiv.d",
              FFL_NX),
        dcase("1.0+2.0", 0x3FF0000000000000, 0x4000000000000000, "fadd.d", 0),
        dcase("maxf*2 (single)", 0x7F7FFFFF, 0x40000000, "fmul.s",
              FFL_OF | FFL_NX, fmt="s", want=box32(0x7F800000)),
        case("fcvt.w.d(inf)", ld_f(1, INF64, "d"), ["fcvt.w.d x7, f1"],
             0x7FFFFFFF, FFL_NV),
        case("feq.d(sNaN,1.0)", ld_f(1, SNaN, "d") + ld_f(2, 0x3FF0000000000000, "d"),
             ["feq.d x7, f1, f2"], 0, FFL_NV),
        # flags are not a register write: fcvt into x0 must still set NV
        case("fcvt.w.d(inf) -> x0, flags still raised", ld_f(1, INF64, "d"),
             ["fcvt.w.d x0, f1", "addi  x7, x0, 0"], 0, FFL_NV),
        # single-precision underflow
        dcase("minsubf*0.5", 0x00000001, 0x3F000000, "fmul.s",
              FFL_UF | FFL_NX, fmt="s", want=box32(0)),
        case("fcvt.d.w(1) no flags", const_ops("x5", 1),
             ["fcvt.d.w f3, x5"] + obs(), 0x3FF0000000000000, 0),
    ]

    # accumulation and clearing, in one ordered program: these cases cannot be
    # isolated by the per-case clear, so they are checked here as a sequence.
    # fcsr packs frm[7:5] | fflags[4:0]; reading it must show both halves
    seq0 = [
        "csrrw x0, fcsr, x0",
        "li    x9, 3", "csrrw x0, frm, x9",
    ] + ld_f(1, 0x3FF0000000000000, "d") + ld_f(2, 0x4008000000000000, "d") + [
        "fdiv.d f3, f1, f2",            # 1.0/3.0 -> NX
        "csrrs x12, fcsr, x0",          # -> (3 << 5) | 1 = 0x61
        "ecall",
    ]
    w12 = (await run_prog(dut, "\n".join([f"li    x20, {DATA_BASE}"] + seq0),
                          tag="s4_fcsr"))[0].get(12, [])
    dut._log.info(f"s4 fcsr packing: {[hex(x) for x in w12]}")
    fcsr_bad = 0 if w12 == [0x61] else 1
    if fcsr_bad:
        cocotb.log.error(f"s4 fcsr: got {[hex(x) for x in w12]} want [0x61] "
                         f"(frm=3, fflags=NX)")

    seq = [
        "csrrw x0, fflags, x0",
        # 1.0/3.0 -> NX
    ] + ld_f(1, 0x3FF0000000000000, "d") + ld_f(2, 0x4008000000000000, "d") + [
        "fdiv.d f3, f1, f2",
        "csrrs x7, fflags, x0",                  # -> 0x01
    ] + ld_f(4, 0, "d") + [
        "fdiv.d f5, f1, f4",                     # 1.0/0.0 -> DZ
        "csrrs x8, fflags, x0",                  # -> 0x09 (accumulated)
        "csrrw x0, fcsr, x0",                    # clear both fields
        "csrrs x9, fflags, x0",                  # -> 0x00
        "fsqrt.d f6, f2",                        # sqrt(3.0) -> NX only
        "csrrs x10, fflags, x0",                 # -> 0x01, not 0x09
        "csrrw x0, fflags, x0",
        "csrrs x11, fflags, x0",                 # -> 0x00
        "ecall",
    ]
    writes, h = await run_prog(dut, "\n".join([f"li    x20, {DATA_BASE}"] + seq),
                               tag="s4_seq")
    w7, w8 = writes.get(7, []), writes.get(8, [])
    w9, w10 = writes.get(9, []), writes.get(10, [])
    w11 = writes.get(11, [])
    dut._log.info(f"s4 sticky: NX={w7} NX|DZ={w8} cleared={w9} "
                  f"after-op={w10} cleared={w11}")
    seq_bad = 0
    for got, want, what in ((w7, [FFL_NX], "1.0/3.0 raised NX"),
                            (w8, [FFL_NX | FFL_DZ], "flags accumulate"),
                            (w9, [0], "csrw fcsr cleared"),
                            (w10, [FFL_NX], "post-clear op shows only its own"),
                            (w11, [0], "csrw fflags cleared")):
        if got != want:
            seq_bad += 1
            cocotb.log.error(f"s4_seq {what}: got {[hex(x) for x in got]} "
                             f"want {[hex(x) for x in want]}")
    RESULTS["s4_seq"] = (5 - seq_bad, 5)
    RESULTS["s4_fcsr"] = (1 - fcsr_bad, 1)

    bad, n = await run_cases(dut, cases, "s4_fflags")
    total_bad, total = bad + seq_bad + fcsr_bad, n + 6
    assert total_bad == 0, f"fflags: {total_bad}/{total} cases wrong"


# ===========================================================================
# SEAM 5 -- register-file hazards and .s/.d consumption
# ===========================================================================
@cocotb.test()
async def test_fpu_integration_s5_regfile_hazards(dut):
    """An FP result consumed by the very next instruction must be the new value,
    and a .s result consumed by a .d operation must be the box (a NaN), not a
    reinterpretation of its low bits.

    Expected architectural results:
      fadd.d 1+2 -> f3 = 3.0; the next instruction fadd.d f4,f3,f3 -> 6.0.
      a four-deep dependent chain must equal the same expression evaluated
      directly.
      fadd.s 1.0f+2.0f (= 0x40400000 boxed) then fadd.d f4,f3,1.0 -> the box is
      a NaN in binary64, so 0x7FF8000000000000 with no flags.
      fadd.d 1.0+2.0 (= 0x4008000000000000) then fadd.s f4,f3,f3 -> not boxed,
      so canonical NaN: 0xFFFFFFFF_7FC00000.
      fcvt.d.s then a dependent .d op, flw then a dependent .d op, fadd.d then a
      dependent fsd (the store data path), and fadd.d then fmv.x.d (an integer
      consumer of an FP result) all have to see the fresh value.
    """
    cases = []
    # back-to-back and chained arithmetic
    cases.append(case(
        "back-to-back fadd.d",
        ld_f(1, 0x3FF0000000000000, "d") + ld_f(2, 0x4000000000000000, "d"),
        ["fadd.d f3, f1, f2", "fadd.d f4, f3, f3"] + obs(4),
        0x4018000000000000, 0))
    cases.append(case(
        "chain of 4",
        ld_f(1, 0x3FF0000000000000, "d") + ld_f(2, 0x3FF0000000000000, "d"),
        ["fadd.d f3, f1, f2", "fmul.d f4, f3, f2", "fadd.d f5, f4, f3",
         "fmul.d f6, f5, f4"] + obs(6),
        0x4020000000000000, 0))
    cases.append(case(
        "fadd.d -> fmv.x.d",
        ld_f(1, 0x3FF0000000000000, "d") + ld_f(2, 0x4000000000000000, "d"),
        ["fadd.d f3, f1, f2", "fmv.x.d x7, f3"], 0x4008000000000000, 0))
    cases.append(case(
        "fadd.d -> fsd",
        ld_f(1, 0x3FF0000000000000, "d") + ld_f(2, 0x4000000000000000, "d"),
        ["fadd.d f3, f1, f2", f"fsd   f3, {OBS}(x20)",
         f"ld    x7, {OBS}(x20)"], 0x4008000000000000, 0))
    cases.append(case(
        "flw -> fadd.d",
        const_ops("x5", 0x4000000000000000) + [f"sd    x5, {MEM}(x20)"] +
        ld_f(2, 0x3FF0000000000000, "d"),
        [f"fld   f3, {MEM}(x20)", "fadd.d f4, f3, f2"] + obs(4),
        0x4008000000000000, 0))
    cases.append(case(
        "fcvt.d.s -> fadd.d",
        ld_f(1, 0x3FC00000, "s") + ld_f(2, 0x3FF0000000000000, "d"),
        ["fcvt.d.s f3, f1", "fadd.d f4, f3, f2"] + obs(4),
        0x4004000000000000, 0))
    cases.append(case(
        "flw -> fsw (store data hazard)",
        const_ops("x5", 0x40490FDB) + [f"sw    x5, {MEM}(x20)",
                                       f"li    x6, -1",
                                       f"sd    x6, {MEM + 64:#x}(x20)"],
        [f"flw   f3, {MEM}(x20)", f"fsw   f3, {MEM + 64:#x}(x20)",
         f"ld    x7, {MEM + 64:#x}(x20)"], 0xFFFFFFFF40490FDB, 0))
    # the integer operand of fcvt.<fmt>.{w,wu,l,lu} and fmv.w.x arrives through
    # the integer forwarding network, which is a different path from the FP file
    cases += [
        case("addi -> fcvt.d.w (int forwarding)",
             [], ["addi  x5, x0, 7", "fcvt.d.w f3, x5"] + obs(),
             0x401C000000000000, 0),
        case("addi -> fmv.w.x (int forwarding)",
             [], ["li    x5, 0x3F800000", "fmv.w.x f3, x5"] + obs(),
             box32(0x3F800000), 0),
        case("lw -> fcvt.d.wu (load-use into FPU)",
             const_ops("x5", 42) + [f"sw    x5, {MEM + 80:#x}(x20)"],
             [f"lw    x5, {MEM + 80:#x}(x20)", "fcvt.d.wu f3, x5"] + obs(),
             0x4045000000000000, 0),
        case("ld -> fcvt.d.l (load-use into FPU)",
             const_ops("x5", (1 << 53) + 1) + [f"sd    x5, {MEM + 88:#x}(x20)"],
             [f"ld    x5, {MEM + 88:#x}(x20)", "fcvt.d.l f3, x5, rne"] + obs(),
             fcvt_from_int((1 << 53) + 1, 0, 64, 0, 1)[0],
             fcvt_from_int((1 << 53) + 1, 0, 64, 0, 1)[1]),
    ]
    # .s result consumed by a .d operation
    cases.append(case(
        ".s result consumed by .d",
        ld_f(1, 0x3F800000, "s") + ld_f(2, 0x40000000, "s") +
        ld_f(4, 0x3FF0000000000000, "d"),
        ["fadd.s f3, f1, f2", "fadd.d f5, f3, f4"] + obs(5), QNAN64, 0))
    # .d result consumed by a .s operation
    cases.append(case(
        ".d result consumed by .s",
        ld_f(1, 0x3FF0000000000000, "d") + ld_f(2, 0x4000000000000000, "d"),
        ["fadd.d f3, f1, f2", "fadd.s f4, f3, f3"] + obs(4),
        box32(CANON32), 0))
    # a .s chain must stay in single precision all the way down
    cases.append(case(
        ".s chain of 3",
        ld_f(1, 0x3F800000, "s") + ld_f(2, 0x40400000, "s"),
        ["fadd.s f3, f1, f2", "fmul.s f4, f3, f2", "fdiv.s f5, f4, f2"] +
        obs(5),
        box32(0x40800000), 0))

    bad, n = await run_cases(dut, cases, "s5_hazards")
    assert bad == 0, f"regfile hazards: {bad}/{n} cases wrong"


# ===========================================================================
# SEAM 6 -- flw / fsw addressing, extension and boxing
# ===========================================================================
@cocotb.test()
async def test_fpu_integration_s6_flw_fsw_addressing(dut):
    """flw must zero-extend the 32 bits it reads and NaN-box them on the way
    into the f-register; fsw must store the low 32 bits of the f-register and
    nothing else.

    Expected architectural results:
      flw from an aligned word W        -> f-register = 0xFFFFFFFF_<W>
      flw from offset+2 of a stored 64-bit pattern 0x1122334455667788 ->
        the four bytes at +2 are 66 55 44 33 (little-endian), so W =
        0x33445566 and the f-register must be 0xFFFFFFFF_33445566.
      flw from offset+6 of the same pattern straddles a 64-bit memory beat:
        bytes 44 33 22 11 -> 0x11223344, boxed.
      fsw of a boxed single into a slot pre-filled with 0xFFFFFFFF_FFFFFFFF
        leaves 0xFFFFFFFF_40400000: the low 32 bits replaced, the high 32 bits
        untouched -- a store that wrote 8 bytes, or that stored the box instead
        of the value, fails here.
      fsw of a DOUBLE stores the low 32 bits of the double (1.5 ->
        0x00000000), not the whole thing.
      fsd then flw then fsd round-trips the box unchanged.

    The misaligned flw cases are architectural, not implementation detail: this
    core completes misaligned accesses in hardware rather than trapping
    (ex_misalign is tied low), so the value has to be right.  If the core were
    to trap instead, that would be a legitimate alternative -- but it does not,
    and a wrong VALUE is never acceptable.
    """
    PAT = 0x1122334455667788
    cases = []

    # aligned flw
    cases.append(case(
        "flw aligned", const_ops("x5", 0x40490FDB) + [f"sw    x5, {MEM}(x20)"],
        [f"flw   f3, {MEM}(x20)"] + obs(), box32(0x40490FDB), 0))
    # flw of a word with the sign bit set: zero-extend, then box.  (The box
    # overwrites the upper half, so what this checks is that the value is the
    # memory word and not something sign-extended into the box's place.)
    cases.append(case(
        "flw negative word", const_ops("x5", 0x80000000) +
        [f"sw    x5, {MEM + 8:#x}(x20)"],
        [f"flw   f3, {MEM + 8:#x}(x20)"] + obs(), box32(0x80000000), 0))
    # misaligned flw inside a stored 64-bit pattern
    cases.append(case(
        "flw at +2 (misaligned)", const_ops("x5", PAT) +
        [f"sd    x5, {MEM + 16:#x}(x20)"],
        [f"flw   f3, {MEM + 18:#x}(x20)"] + obs(), box32(0x33445566), 0))
    # misaligned flw straddling an 8-byte memory beat: the two halves come from
    # two different beats, so the LSU has to split the access
    cases.append(case(
        "flw at +6 (crosses beat)", const_ops("x5", PAT) +
        [f"sd    x5, {MEM + 16:#x}(x20)",
         f"li    x5, 0xAABBCCDD", f"sw    x5, {MEM + 24:#x}(x20)"],
        [f"flw   f3, {MEM + 22:#x}(x20)"] + obs(), box32(0xCCDD1122), 0))
    # fsw stores the low 32 bits only
    cases.append(case(
        "fsw boxed single", ld_f(1, 0x3F800000, "s") + ld_f(2, 0x40000000, "s") +
        [f"li    x5, -1", f"sd    x5, {MEM + 32:#x}(x20)"],
        ["fadd.s f3, f1, f2", f"fsw   f3, {MEM + 32:#x}(x20)",
         f"ld    x7, {MEM + 32:#x}(x20)"], 0xFFFFFFFF40400000, 0))
    # fsw of a double stores the low 32 bits of the double
    cases.append(case(
        "fsw double", ld_f(1, 0x3FF8000000000000, "d") +
        [f"li    x5, -1", f"sd    x5, {MEM + 40:#x}(x20)"],
        [f"fsw   f1, {MEM + 40:#x}(x20)",
         f"ld    x7, {MEM + 40:#x}(x20)"], 0xFFFFFFFF00000000, 0))
    # fsw at a misaligned address INSIDE one beat: bytes +2..+5 of the slot are
    # replaced, +0/+1 and +6/+7 keep the 0xFF they were pre-filled with
    cases.append(case(
        "fsw misaligned", ld_f(1, 0x3F800000, "s") +
        [f"li    x5, -1", f"sd    x5, {MEM + 48:#x}(x20)"],
        [f"fsw   f1, {MEM + 50:#x}(x20)",
         f"ld    x7, {MEM + 48:#x}(x20)"], 0xFFFF3F800000FFFF, 0))
    # fsw at +6 of a beat: the store crosses into the next beat, so both beats
    # must be written.  Two cases, one per beat, each repeating the setup.
    for lo_off, want in ((0x78, 0x0000FFFFFFFFFFFF), (0x80, 0xFFFFFFFFFFFF3F80)):
        cases.append(case(
            f"fsw crossing beat (observe {lo_off:#x})",
            ld_f(1, 0x3F800000, "s") +
            [f"li    x5, -1", f"sd    x5, {MEM + 0x78:#x}(x20)",
             f"sd    x5, {MEM + 0x80:#x}(x20)"],
            [f"fsw   f1, {MEM + 0x7E:#x}(x20)",
             f"ld    x7, {MEM + lo_off:#x}(x20)"], want, 0))
    # fld must NOT box: the 64-bit pattern lands in the register unchanged
    cases.append(case(
        "fld is not boxed", const_ops("x5", PAT) +
        [f"sd    x5, {MEM + 0x68:#x}(x20)"],
        [f"fld   f3, {MEM + 0x68:#x}(x20)"] + obs(), PAT, 0))
    # a misaligned fld spans two beats, like a misaligned flw
    cases.append(case(
        "fld at +4 (crosses beat)", const_ops("x5", PAT) +
        [f"sd    x5, {MEM + 0x60:#x}(x20)",
         f"li    x5, 0xAABBCCDD", f"sw    x5, {MEM + 0x68:#x}(x20)"],
        [f"fld   f3, {MEM + 0x64:#x}(x20)"] + obs(), 0xAABBCCDD11223344, 0))
    # fsd / flw / fsd round trip
    cases.append(case(
        "fsd->flw->fsd", ld_f(1, 0x40490FDB, "s"),
        [f"fsd   f1, {MEM + 56:#x}(x20)", f"flw   f3, {MEM + 56:#x}(x20)"] +
        obs(), box32(0x40490FDB), 0))

    bad, n = await run_cases(dut, cases, "s6_flwfsw")

    RESULTS["s6_flwfsw"] = (n - bad, n)
    assert bad == 0, f"flw/fsw: {bad}/{n} cases wrong"


# ===========================================================================
# SEAM 7 -- f0 is an ordinary FP register (found while testing seam 1 and 5)
# ===========================================================================
@cocotb.test()
async def test_fpu_integration_s7_f0_is_a_real_register(dut):
    """The RISC-V F/D register file has no architecturally dead register: all 32
    f-registers hold values, unlike x0 on the integer side.

    Expected architectural results:
      fadd.d f0, f1(1.0), f2(2.0) then fmv.x.d x7, f0 -> 3.0
        (0x4008000000000000).  A register file that inherited the integer
        file's "never write register 0" rule returns the stale f0 instead.
      fadd.s f0, f1, f2 then fsd/ld -> 0xFFFFFFFF_40400000: the box applies to
      f0 exactly as to any other register.
      flw f0, ... then fmv.x.d x7, f0 -> the boxed word.
      fmv.d.x f0, x5 then fmv.x.d x7, f0 -> the raw 64-bit pattern.
      fadd.s f0, f1, f2 then fsw f0 -> the low 32 bits reach memory.
      fadd.d f0, f1, f2 followed IMMEDIATELY by fadd.d f4, f0, f2 -> 5.0
        (0x4014000000000000): the hazard interlock must not skip a producer
        whose rd field is 0, or the consumer reads the stale f0.
      fcvt.d.s f0, f1(1.5f) then fadd.d f4, f0, f2 -> 2.5.
    """
    cases = []
    D1 = 0x3FF0000000000000        # 1.0
    D2 = 0x4000000000000000        # 2.0
    S1, S2 = 0x3F800000, 0x40000000
    cases += [
        case("fadd.d -> f0 -> fmv.x.d",
             ld_f(1, D1, "d") + ld_f(2, D2, "d"),
             ["fadd.d f0, f1, f2", "fmv.x.d x7, f0"], 0x4008000000000000, 0),
        case("fadd.s -> f0 (boxing)",
             ld_f(1, S1, "s") + ld_f(2, S2, "s"),
             ["fadd.s f0, f1, f2"] + obs(0), box32(0x40400000), 0),
        case("flw -> f0",
             const_ops("x5", 0x40490FDB) + [f"sw    x5, {MEM}(x20)"],
             [f"flw   f0, {MEM}(x20)", "fmv.x.d x7, f0"],
             box32(0x40490FDB), 0),
        case("fmv.d.x -> f0",
             const_ops("x5", 0x3FF8000000000000),
             ["fmv.d.x f0, x5", "fmv.x.d x7, f0"], 0x3FF8000000000000, 0),
        case("fadd.s -> f0 -> fsw",
             ld_f(1, S1, "s") + ld_f(2, S2, "s") +
             [f"li    x6, -1", f"sd    x6, {MEM + 72:#x}(x20)"],
             ["fadd.s f0, f1, f2", f"fsw   f0, {MEM + 72:#x}(x20)",
              f"ld    x7, {MEM + 72:#x}(x20)"], 0xFFFFFFFF40400000, 0),
        case("f0 producer -> f0 consumer (hazard)",
             ld_f(1, D1, "d") + ld_f(2, D2, "d"),
             ["fadd.d f0, f1, f2", "fadd.d f4, f0, f2"] + obs(4),
             0x4014000000000000, 0),
        case("fcvt.d.s -> f0 -> fadd.d",
             ld_f(1, 0x3FC00000, "s") + ld_f(2, D1, "d"),
             ["fcvt.d.s f0, f1", "fadd.d f4, f0, f2"] + obs(4),
             0x4004000000000000, 0),
        case("fdiv.d -> f0 -> f0 (self hazard)",
             ld_f(1, D1, "d") + ld_f(2, D2, "d"),
             ["fdiv.d f0, f1, f2", "fadd.d f0, f0, f0"] + obs(0),
             0x3FF0000000000000, 0),
    ]
    bad, n = await run_cases(dut, cases, "s7_f0")
    assert bad == 0, f"f0 as a real register: {bad}/{n} cases wrong"


# ===========================================================================
# SEAM 8 -- a reserved dynamic rounding mode must trap
# ===========================================================================
async def run_expect_illegal(dut, src, label, tag):
    """Run `src` and return the first trap (pc, cause), without the usual
    "no illegal trap" assertion -- this program is SUPPOSED to trap."""
    words, labels = assemble(src)
    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=400, stop_on_ecall=True)
    return (labels[label] if labels else None), h.traps


@cocotb.test()
async def test_fpu_integration_s8_reserved_frm_traps(dut):
    """fcsr.frm values 5 and 6 are reserved.  An instruction with rm = DYN (7)
    therefore has no legal rounding mode when frm holds 5 or 6, and the spec
    requires an illegal-instruction exception -- not a silent default.

    Expected architectural result: the FP instruction raises cause 2
    (illegal instruction) at its own pc.  Measured before the fix: it executed
    and returned 3.0, i.e. a reserved mode was accepted, and the decoder could
    not have caught it because it never sees the CSR.

    The control cases -- frm = 0..4 with the same instruction -- must NOT trap;
    that is what distinguishes "the check is right" from "the check always
    fires".
    """
    pre = ["li    x20, 0x3000",
           "li    x5, 0x3ff0000000000000", "fmv.d.x f1, x5",
           "li    x5, 0x4000000000000000", "fmv.d.x f2, x5"]
    bad = 0
    checks = 0
    # reserved: must trap
    for frm in (5, 6):
        for mn in ("fadd.d f3, f1, f2, dyn", "fsqrt.d f3, f1, dyn",
                   "fcvt.w.d x7, f1, dyn", "fcvt.d.s f3, f1, dyn"):
            src = pre + [f"li    x9, {frm}", "csrrw x0, frm, x9",
                         "op:", mn, "ecall"]
            want_pc, traps = await run_expect_illegal(dut, "\n".join(src),
                                                     "op", "s8_reserved")
            checks += 1
            if not traps or traps[0][0] != want_pc or traps[0][1] != 2:
                bad += 1
                cocotb.log.error(
                    f"s8: frm={frm} `{mn}` should raise cause 2 at "
                    f"{want_pc:#x}; traps={[(hex(p), hex(c)) for p, c in traps][:2]}")
    # legal: must not trap
    for frm in range(5):
        src = pre + [f"li    x9, {frm}", "csrrw x0, frm, x9",
                     "op:", "fadd.d f3, f1, f2, dyn", "ecall"]
        want_pc, traps = await run_expect_illegal(dut, "\n".join(src),
                                                 "op", "s8_legal")
        checks += 1
        if any(c == 2 for _, c in traps):
            bad += 1
            cocotb.log.error(f"s8: frm={frm} is legal but the instruction "
                             f"trapped as illegal")
    RESULTS["s8_frm_trap"] = (checks - bad, checks)
    dut._log.info(f"s8_frm_trap: {checks - bad}/{checks} cases pass")
    assert bad == 0, f"reserved frm: {bad}/{checks} cases wrong"


# ===========================================================================
# summary
# ===========================================================================
@cocotb.test()
async def test_fpu_integration_s9_summary(dut):
    """Print the exact per-seam counts recorded by the tests above."""
    total_p = total_n = 0
    for k in sorted(RESULTS):
        p, n = RESULTS[k]
        total_p += p
        total_n += n
        dut._log.info(f"  {k:14s} {p:4d}/{n:<4d} cases pass")
    dut._log.info(f"  {'TOTAL':14s} {total_p:4d}/{total_n:<4d} cases pass")
    missing = [t for t in ("s1_nanbox", "s2_fmt", "s3_frm", "s4_fflags",
                           "s4_seq", "s5_hazards", "s6_flwfsw", "s7_f0", "s8_frm_trap")
               if t not in RESULTS]
    if missing:
        dut._log.info(f"  (not run in this invocation: {missing})")
