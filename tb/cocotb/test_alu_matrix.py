"""Directed ALU matrix: add/sub/and/or/xor/slt/sltu and their immediate forms.

Operand set: 0, 1, -1, 2, -2, INT32_MAX/MIN, INT64_MAX/MIN, 0x7FFFFFFF, 0x80000000,
0xFFFFFFFF, +/- powers of two, all-ones.

Expectations come from a Python model, not from the RTL and not from the in-repo ISS,
so an RTL bug cannot agree with itself.

Constants are built with rv64_asm's `li` pseudo-op, the one constant builder in this
tree that is checked against hardware (tb_li.py).  The operand list is passed through
li_value() -- li's own literal rules -- so the model is given exactly the value the
instruction loads.  The hand-rolled builder this replaced assumed ori zero-extends its
immediate; it sign-extends, so ori with 0xfff ORed in -1 and every constant whose low
word had bit 11 set came out all-ones.
"""
import cocotb
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from test_core import Harness
from rv64_asm import li_value

M64 = (1 << 64) - 1
INT32_MAX = 0x7FFFFFFF
INT32_MIN = 0x80000000
INT64_MAX = 0x7FFFFFFFFFFFFFFF
INT64_MIN = 0x8000000000000000

def s64(v):
    v &= M64
    return v - (1 << 64) if v >> 63 else v

REG_OPERANDS = [
    0, 1, -1, 2, -2,
    INT32_MAX, INT32_MIN, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF,
    INT64_MAX, INT64_MIN,
    1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 1 << 20, 1 << 32, 1 << 48,
    -1, -2, -4, -8, -16, -1024, -(1 << 20),
    M64,
]
# Every operand is what `li` actually loads, deduplicated on that value.  Two entries
# collapse and are removed rather than silently tested twice: 0xFFFFFFFF sign-extends
# to -1, and 0x80000000 sign-extends to 0xFFFFFFFF80000000, which is INT32_MIN.  The
# zero-extended words 0x00000000FFFFFFFF and 0x0000000080000000 have no 32-bit literal
# form, so li cannot build them and they are not in this matrix.
REG_OPERANDS = [li_value(v) for v in REG_OPERANDS]
_seen = set()
REG_OPERANDS = [v for v in REG_OPERANDS
                if not ((v & M64) in _seen or _seen.add(v & M64))]

IMM_OPERANDS = [0, 1, -1, 2, -2, 2047, -2048, 4, 8, -4, -8, 1024, -1024, 0x7FF, -0x800]

REG_OPS = ["add", "sub", "and", "or", "xor", "slt", "sltu"]
IMM_OPS = {"addi": "add", "andi": "and", "ori": "or", "xori": "xor",
           "slti": "slt", "sltiu": "sltu"}

def model(op, a, b):
    a &= M64; b &= M64
    if op == "add":  return (a + b) & M64
    if op == "sub":  return (a - b) & M64
    if op == "and":  return a & b
    if op == "or":   return a | b
    if op == "xor":  return a ^ b
    if op == "slt":  return 1 if s64(a) < s64(b) else 0
    if op == "sltu": return 1 if a < b else 0
    raise ValueError(op)


def build64(rd, val):
    """Instructions producing `val` in x{rd}, and the value they are expected to give.

    One `li` pseudo-op, expanded by rv64_asm.  The returned expectation comes from
    li_value(), which states what li leaves in the register, so the model is always
    given the value the sequence actually loads.  rv64_asm's li uses x31 as its scratch
    register for the low half of a 64-bit constant; nothing in these tests holds a live
    value in x31.
    """
    v = li_value(val)
    return [f"li x{rd}, {hex(v)}"], v


def check_sequence(h, expects, label, dut):
    result_regs = {r for r, _ in expects}
    writes = [(t[3], t[4]) for t in h.trace if t[2] == 1 and t[3] in result_regs]
    errors = 0
    for i, (reg, want) in enumerate(expects):
        if i >= len(writes):
            errors += 1
            if errors <= 5:
                dut._log.error(f"  {label}: retired {len(writes)}, expected {len(expects)}")
            break
        got = writes[i][1]
        if got != want:
            errors += 1
            if errors <= 5:
                dut._log.error(f"  {label}[{i}]: got {got:#x}, want {want:#x}")
    return errors


@cocotb.test()
async def test_alu_matrix_reg(dut):
    """All 7 register-register forms across every operand pair."""
    from rv64_asm import assemble
    h = Harness(dut)
    await h.startup()
    pairs = [(a, b) for a in REG_OPERANDS for b in REG_OPERANDS]
    dut._log.info(f"register matrix: {len(pairs)} pairs x {len(REG_OPS)} ops")

    BATCH = 20
    total = 0; errors = 0
    for start in range(0, len(pairs), BATCH):
        src = []; expects = []
        for a, b in pairs[start:start + BATCH]:
            sa, _ = build64(5, a)
            sb, _ = build64(6, b)
            src += sa + sb
            reg = 7
            for op in REG_OPS:
                src.append(f"{op} x{reg}, x5, x6")
                expects.append((reg, model(op, a, b)))
                reg += 1
        src.append("ecall")
        words, _ = assemble("\n".join(src))
        h.clear(); await h.load(words); await h.reset()
        await h.run(max_cycles=4000, stop_on_ecall=True)
        if 2 in [c for (_, c) in h.traps]:
            errors += 1
            dut._log.error(f"illegal trap in batch {start}")
            continue
        total += len(expects)
        errors += check_sequence(h, expects, f"reg@{start}", dut)
    dut._log.info(f"register matrix: {total} checks, {errors} mismatches")
    assert errors == 0, f"{errors} mismatches out of {total}"


@cocotb.test()
async def test_alu_matrix_imm(dut):
    """All 6 immediate forms across the representable immediate set."""
    from rv64_asm import assemble
    h = Harness(dut)
    await h.startup()
    src = []; expects = []
    for a in REG_OPERANDS:
        sa, _ = build64(5, a)
        src += sa
        for imm in IMM_OPERANDS:
            reg = 7
            for mn, op in IMM_OPS.items():
                src.append(f"{mn} x{reg}, x5, {imm}")
                expects.append((reg, model(op, a, imm)))
                reg += 1
    src.append("ecall")
    words, _ = assemble("\n".join(src))
    h.clear(); await h.load(words); await h.reset()
    await h.run(max_cycles=30000, stop_on_ecall=True)
    assert 2 not in [c for (_, c) in h.traps], "illegal trap"
    errors = check_sequence(h, expects, "imm", dut)
    dut._log.info(f"immediate matrix: {len(expects)} checks, {errors} mismatches")
    assert errors == 0, f"{errors} mismatches out of {len(expects)}"
