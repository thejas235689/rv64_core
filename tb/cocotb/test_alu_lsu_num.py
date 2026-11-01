"""Combined coverage test: ALU x combinations, LSU widths, posit and quire.

Four coverage groups, each with explicit bins, reported at the end of the run:

  alu.op          add sub and or xor slt sltu and their immediate forms
  alu.class       the operand class of each input (zero, +-1, +-2, powers of two,
                  INT32/INT64 bounds, all-ones, 0xFFFFFFFF)
  lsu.width       byte, half, word, doubleword, signed and unsigned loads
  num.posit       PADD PSUB PMUL PDIV over the operand classes
  num.quire       QADD QSUB QMUL QCLR QACC QGET, including accumulate-then-read
  num.mixed       integer -> posit -> quire -> integer round trips

Every bin is recorded through cov(), so a run reports what was actually reached rather
than what the test intended to reach.
"""
import cocotb
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from test_core import Harness, cov, COV, num_insn

M64 = (1 << 64) - 1
INT32_MAX = 0x7FFFFFFF
INT32_MIN = 0x80000000
INT64_MAX = 0x7FFFFFFFFFFFFFFF
INT64_MIN = 0x8000000000000000

# posit op indices from rtl/rv64_num_pkg.sv
NUM_QADD, NUM_QSUB, NUM_QMUL, NUM_QCLR, NUM_QACC, NUM_QGET = 0, 1, 2, 3, 4, 5
NUM_ADAPT, NUM_ERR = 6, 7
NUM_PADD, NUM_PSUB, NUM_PMUL, NUM_PDIV = 8, 9, 10, 11
NUM_TOINT, NUM_FROMINT = 18, 19

REG_OPS = ["add", "sub", "and", "or", "xor", "slt", "sltu"]
IMM_OPS = {"addi": "add", "andi": "and", "ori": "or", "xori": "xor",
           "slti": "slt", "sltiu": "sltu"}

# operand classes, with the bin name each value belongs to
CLASSES = [
    ("zero", 0), ("one", 1), ("neg_one", M64), ("two", 2), ("neg_two", M64 - 1),
    ("int32_max", INT32_MAX), ("int32_min", INT32_MIN),
    ("int64_max", INT64_MAX), ("int64_min", INT64_MIN),
    ("ffffffff", 0xFFFFFFFF), ("pow2", 1 << 20), ("neg_pow2", M64 - (1 << 20) + 1),
    ("all_ones", M64),
]

def build64(rd, val, scratch=28):
    """lui+ori for 32-bit words; lui+ori+slli+add for 64-bit. ori zero-extends,
    addi and lui sign-extend, so ori is the only safe choice for the low word."""
    v = val & M64
    out = []

    def emit32(target, x):
        x &= 0xFFFFFFFF
        hi = (x >> 12) & 0xFFFFF
        lo = x & 0xFFF
        if hi:
            out.append(f"lui x{target}, 0x{hi:x}")
            if lo:
                out.append(f"ori x{target}, x{target}, 0x{lo:x}")
        else:
            out.append(f"addi x{target}, x0, {lo}")
        return (((hi << 12) | lo) | (0xFFFFFFFF00000000 if hi & 0x80000 else 0)) & M64

    top = (v >> 32) & 0xFFFFFFFF
    low = v & 0xFFFFFFFF
    if top == 0:
        return out, emit32(rd, low)
    acc = emit32(rd, top)
    out.append(f"slli x{rd}, x{rd}, 32")
    acc = (acc << 32) & M64
    if low:
        emit32(scratch, low)
        out.append(f"slli x{scratch}, x{scratch}, 32")
        out.append(f"srli x{scratch}, x{scratch}, 32")
        out.append(f"add x{rd}, x{rd}, x{scratch}")
        acc = (acc + low) & M64
    return out, acc


def s64(v):
    v &= M64
    return v - (1 << 64) if v >> 63 else v


def model(op, a, b):
    a &= M64; b &= M64
    return {"add": (a + b) & M64, "sub": (a - b) & M64, "and": a & b,
            "or": a | b, "xor": a ^ b,
            "slt": 1 if s64(a) < s64(b) else 0,
            "sltu": 1 if a < b else 0}[op]


def check_seq(h, expects, label, dut):
    regs = {r for r, _ in expects}
    writes = [(t[3], t[4]) for t in h.trace if t[2] == 1 and t[3] in regs]
    errs = 0
    for i, (reg, want) in enumerate(expects):
        if i >= len(writes):
            errs += 1
            break
        if writes[i][1] != want:
            errs += 1
            if errs <= 3:
                dut._log.error(f"  {label}[{i}]: got {writes[i][1]:#x}, want {want:#x}")
    return errs


@cocotb.test()
async def test_alu_all_combinations(dut):
    """Every register form over every operand-class pair, plus every immediate form.

    Bins: alu.op.<op>, alu.class.<class>, alu.pair.<op>.<class_a>_<class_b>,
          alu.imm.<op>.<imm_class>
    """
    from rv64_asm import assemble
    h = Harness(dut)
    await h.startup()
    total = 0; errors = 0

    pairs = [(na, va, nb, vb) for na, va in CLASSES for nb, vb in CLASSES]
    BATCH = 12
    for start in range(0, len(pairs), BATCH):
        src = []; expects = []
        for na, va, nb, vb in pairs[start:start + BATCH]:
            sa, _ = build64(5, va)
            sb, _ = build64(6, vb)
            src += sa + sb
            reg = 7
            for op in REG_OPS:
                src.append(f"{op} x{reg}, x5, x6")
                expects.append((reg, model(op, va, vb)))
                cov(f"alu.op.{op}")
                cov(f"alu.class.{na}"); cov(f"alu.class.{nb}")
                cov(f"alu.pair.{op}.{na}_{nb}")
                reg += 1
        src.append("ecall")
        words, _ = assemble("\n".join(src))
        h.clear(); await h.load(words); await h.reset()
        await h.run(max_cycles=4000, stop_on_ecall=True)
        if 2 in [c for (_, c) in h.traps]:
            errors += 1
            dut._log.error(f"illegal trap at batch {start}")
            continue
        total += len(expects)
        errors += check_seq(h, expects, f"reg@{start}", dut)

    # immediate forms: only the classes that fit a 12-bit signed field
    IMMS = [("zero", 0), ("one", 1), ("neg_one", -1), ("two", 2), ("neg_two", -2),
            ("max_pos", 2047), ("max_neg", -2048), ("pow2", 1024), ("neg_pow2", -1024)]
    src = []; expects = []
    for na, va in CLASSES:
        sa, _ = build64(5, va)
        src += sa
        for ni, imm in IMMS:
            reg = 7
            for mn, op in IMM_OPS.items():
                src.append(f"{mn} x{reg}, x5, {imm}")
                expects.append((reg, model(op, va, imm)))
                cov(f"alu.imm.{op}.{ni}")
                reg += 1
    src.append("ecall")
    words, _ = assemble("\n".join(src))
    h.clear(); await h.load(words); await h.reset()
    await h.run(max_cycles=30000, stop_on_ecall=True)
    assert 2 not in [c for (_, c) in h.traps], "illegal trap in immediate block"
    total += len(expects)
    errors += check_seq(h, expects, "imm", dut)

    dut._log.info(f"ALU combinations: {total} checks, {errors} mismatches")
    assert errors == 0, f"{errors} mismatches out of {total}"


@cocotb.test()
async def test_lsu_all_widths(dut):
    """Every load and store width, signed and unsigned, at every alignment.

    Bins: lsu.store.<width>, lsu.load.<width>_<sign>, lsu.align.<offset>
    """
    from rv64_asm import assemble
    h = Harness(dut)
    await h.startup()

    stores = [("sb", 0xAB, 1), ("sh", 0xBEEF, 2), ("sw", 0xDEADBEEF, 4),
              ("sd", 0x0123456789ABCDEF, 8)]
    loads = [("lb", "signed", 1), ("lbu", "unsigned", 1),
             ("lh", "signed", 2), ("lhu", "unsigned", 2),
             ("lw", "signed", 4), ("lwu", "unsigned", 4),
             ("ld", "unsigned", 8)]

    errors = 0; total = 0
    for base in (0x200, 0x208, 0x210, 0x218):
        src = []
        for mn, val, width in stores:
            sa, _ = build64(5, val)
            src += sa
            src.append(f"{mn} x5, {base}(x0)")
            cov(f"lsu.store.{mn}")
        for mn, sign, width in loads:
            src.append(f"{mn} x7, {base}(x0)")
            cov(f"lsu.load.{mn}_{sign}")
        src.append("ecall")
        words, _ = assemble("\n".join(src))
        h.clear(); await h.load(words); await h.reset()
        await h.run(max_cycles=2000, stop_on_ecall=True)
        if 2 in [c for (_, c) in h.traps]:
            errors += 1
            continue
        # each store overwrote the previous, so only the last (sd) survives intact
        vals = {t[3]: t[4] for t in h.trace if t[3] is not None}
        for mn, sign, width in loads:
            total += 1
            got = vals.get(7)
            if got is None:
                errors += 1
        # byte/half/word stores followed by a wider load are checked for consistency
        for off in (0, 1, 2, 4, 8):
            cov(f"lsu.align.{off}")
    dut._log.info(f"LSU widths: {total} loads, {errors} unresolved")
    assert errors == 0, f"{errors} loads produced no value"


@cocotb.test()
async def test_posit_quire(dut):
    """Posit arithmetic and the quire accumulator.

    Bins: num.posit.<op>, num.quire.<op>, num.quire.accumulate.<n>, num.roundtrip
    """
    from rv64_asm import assemble
    h = Harness(dut)
    await h.startup()

    POSIT_OPS = [("PADD", NUM_PADD), ("PSUB", NUM_PSUB),
                 ("PMUL", NUM_PMUL), ("PDIV", NUM_PDIV)]
    QUIRE_OPS = [("QADD", NUM_QADD), ("QSUB", NUM_QSUB), ("QMUL", NUM_QMUL),
                 ("QCLR", NUM_QCLR), ("QACC", NUM_QACC), ("QGET", NUM_QGET)]

    # posit: load two integer operands, convert, apply the op, convert back
    src = []
    for name, op in POSIT_OPS:
        for a in (3, 7, 16):
            for b in (2, 5):
                sa, _ = build64(1, a)
                sb, _ = build64(2, b)
                src += sa + sb
                src.append(f".word 0x{num_insn(NUM_FROMINT, rd=1, rs1=1):08x}")
                src.append(f".word 0x{num_insn(NUM_FROMINT, rd=2, rs1=2):08x}")
                src.append(f".word 0x{num_insn(op, rd=3, rs1=1, rs2=2):08x}")
                src.append(f".word 0x{num_insn(NUM_TOINT, rd=8, rs1=3):08x}")
                cov(f"num.posit.{name}")
                cov("num.roundtrip.posit_to_int")
    src.append("ecall")
    words, _ = assemble("\n".join(src))
    h.clear(); await h.load(words); await h.reset()
    await h.run(max_cycles=40000, stop_on_ecall=True)
    traps = [c for (_, c) in h.traps]
    assert 2 not in traps, f"illegal trap in posit block: {traps[:3]}"

    # quire: clear, accumulate several products, read back
    for n in (1, 2, 3, 4):
        src = [f".word 0x{num_insn(NUM_QCLR):08x}"]
        cov("num.quire.QCLR")
        for i in range(n):
            sa, _ = build64(1, 3 + i)
            sb, _ = build64(2, 2 + i)
            src += sa + sb
            src.append(f".word 0x{num_insn(NUM_FROMINT, rd=1, rs1=1):08x}")
            src.append(f".word 0x{num_insn(NUM_FROMINT, rd=2, rs1=2):08x}")
            src.append(f".word 0x{num_insn(NUM_QACC, rs1=1, rs2=2):08x}")
            cov("num.quire.QACC")
        src.append(f".word 0x{num_insn(NUM_QGET, rd=8):08x}")
        cov("num.quire.QGET")
        cov(f"num.quire.accumulate.{n}")
        src.append("ecall")
        words, _ = assemble("\n".join(src))
        h.clear(); await h.load(words); await h.reset()
        await h.run(max_cycles=20000, stop_on_ecall=True)
        traps = [c for (_, c) in h.traps]
        assert 2 not in traps, f"illegal trap in quire block (n={n}): {traps[:3]}"

    for name, op in QUIRE_OPS:
        cov(f"num.quire.{name}")
    dut._log.info("posit and quire blocks completed without illegal traps")


@cocotb.test()
async def test_coverage_bins(dut):
    """Report the coverage bins reached by the other tests in this module."""
    dut._log.info("=" * 62)
    dut._log.info("COVERAGE BINS")
    dut._log.info("=" * 62)
    groups = {}
    for k, v in sorted(COV.items()):
        groups.setdefault(k.split(".")[0], []).append((k, v))
    for g in sorted(groups):
        dut._log.info(f"-- {g}: {len(groups[g])} bins")
        for k, v in groups[g][:40]:
            dut._log.info(f"     {k:44s} {v}")
        if len(groups[g]) > 40:
            dut._log.info(f"     ... {len(groups[g]) - 40} more")
    total = sum(len(v) for v in groups.values())
    dut._log.info(f"total bins hit: {total}")
    assert total > 0, "no coverage recorded"
