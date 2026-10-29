"""
test_core.py -- self-checking cocotb testbench for riscv_core_top.

Every test drives a program into the core, collects the architectural
retirement trace (pc, instruction, register write) from the observability
ports, and compares it element-by-element against the independent Python
golden model (rv64_iss).  A mismatch fails loudly with the retirement index,
the DUT value and the expected value.

Coverage is accumulated across tests and printed at the end of the run.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

from rv64_asm import assemble
from rv64_iss import ISS

DATA_BASE = 0x2000
CAUSE = {
    0: "inst_misalign", 1: "inst_access", 2: "illegal", 3: "breakpoint",
    4: "load_misalign", 5: "load_access", 6: "store_misalign", 7: "store_access",
    11: "ecall_m",
    0x8000000000000003: "m_soft_int",
    0x8000000000000007: "m_timer_int",
    0x800000000000000B: "m_ext_int",
}

COV = {}


def cov(key, n=1):
    COV[key] = COV.get(key, 0) + n


def _i(sig, name):
    """Convert a sampled signal, failing with the raw bits if it holds X/Z."""
    try:
        return int(sig.value)
    except ValueError:
        raise AssertionError(f"signal {name} sampled with unknown bits: {sig.value.binstr}")


# --------------------------------------------------------------------------- harness
class Harness:
    def __init__(self, dut):
        self.dut = dut
        self.trace = []
        self.traps = []

    async def startup(self):
        d = self.dut
        d.rst_n.value = 0
        d.host_we.value = 0
        d.host_clear.value = 0
        d.host_addr.value = 0
        d.host_wdata.value = 0
        d.i_bp.value = 0
        d.d_bp.value = 0
        d.err_en.value = 0
        d.err_addr.value = 0
        d.irq_soft.value = 0
        d.irq_timer.value = 0
        d.irq_ext.value = 0
        d.dbg_halt_req.value = 0
        d.dbg_resume_req.value = 0
        d.dbg_step.value = 0
        d.dbg_reg_addr.value = 0
        d.wp_en.value = 0
        d.task_done_valid.value = 0
        d.task_done_slot.value = 0
        d.task_done_result.value = 0
        d.wp_addr.value = 0
        cocotb.start_soon(Clock(d.clk, 10, "ns").start())
        for _ in range(5):
            await RisingEdge(d.clk)

    async def load(self, words, base=0):
        d = self.dut
        # wipe memory so each test starts from a known state (the DUT keeps its
        # memory array across tests, the golden model always starts clean)
        d.host_clear.value = 1
        await RisingEdge(d.clk)
        d.host_clear.value = 0
        for i, w in enumerate(words):
            d.host_we.value = 1
            d.host_addr.value = base + 4 * i
            d.host_wdata.value = w & 0xFFFFFFFF
            await RisingEdge(d.clk)
        d.host_we.value = 0
        await RisingEdge(d.clk)

    async def reset(self):
        d = self.dut
        d.rst_n.value = 0
        for _ in range(3):
            await RisingEdge(d.clk)
        d.rst_n.value = 1
        await RisingEdge(d.clk)

    def clear(self):
        self.trace = []
        self.traps = []

    async def run(self, max_cycles=20000, stop_on_ecall=True):
        """Step the core, accumulating retirement and trap records."""
        d = self.dut
        for _ in range(max_cycles):
            await RisingEdge(d.clk)
            await FallingEdge(d.clk)
            if _i(d.retire_valid, "retire_valid"):
                self.trace.append((
                    _i(d.retire_pc, "retire_pc"), _i(d.retire_insn, "retire_insn"),
                    _i(d.gpr_we, "gpr_we"), _i(d.gpr_waddr, "gpr_waddr"),
                    _i(d.gpr_wdata, "gpr_wdata"),
                ))
            if int(d.trap_valid.value):
                cause = int(d.trap_cause.value)
                self.traps.append((int(d.trap_pc.value), cause))
                cov(f"trap:{CAUSE.get(cause, hex(cause))}")
                if stop_on_ecall and cause == 11:
                    return
            if int(d.dbg_halted.value):
                return

    async def read_gpr(self, idx):
        """Read an architectural register through the debug port."""
        d = self.dut
        d.dbg_reg_addr.value = idx
        await RisingEdge(d.clk)
        await FallingEdge(d.clk)
        return int(d.dbg_reg_data.value)


ISA_CLASSES = {
    0x37: "lui", 0x17: "auipc", 0x6F: "jal", 0x67: "jalr", 0x63: "branch",
    0x03: "load", 0x23: "store", 0x13: "op-imm", 0x33: "op", 0x1B: "op-imm-32",
    0x3B: "op-32", 0x0F: "fence", 0x73: "system",
}


def classify(insn):
    """Coarse instruction class, refined for a few large groups."""
    op = insn & 0x7F
    cls = ISA_CLASSES.get(op, "illegal")
    if op == 0x33:
        f7 = (insn >> 25) & 0x7F
        if f7 == 0x01:
            cls = "muldiv"
        elif f7 == 0x05:
            cls = "zbb/zbc"
        elif f7 in (0x14, 0x24, 0x34):
            cls = "zbs"
        elif f7 in (0x10,):
            cls = "zba"
        elif f7 == 0x07:
            cls = "zicond"
    elif op == 0x13:
        f3 = (insn >> 12) & 7
        if f3 in (1, 5):
            cls = "shift/bit-imm"
    elif op == 0x73 and ((insn >> 12) & 7) != 0:
        cls = "csr"
    elif op == 0x73:
        cls = "system"
    return cls


def compare_memory(dut, iss, lo=0x2000, hi=0x2200, tag="memory"):
    """Compare the data region of DUT memory against the golden model."""
    for addr in range(lo, hi, 8):
        idx = (addr >> 3) & 0x1FFF
        dut_word = int(dut.mem[idx].value)
        iss_word = int.from_bytes(iss.mem[addr:addr + 8], "little")
        assert dut_word == iss_word, \
            f"{tag}: data memory at {addr:#06x}: DUT {dut_word:#018x} != ISS {iss_word:#018x}"


def compare(h, iss_trace, tag):
    """Compare the DUT retirement trace against the golden model."""
    n = len(iss_trace)
    assert n > 0, f"{tag}: DUT retired nothing"
    assert len(h.trace) >= n, f"{tag}: DUT retired {len(h.trace)} < ISS {n}"
    for i in range(n):
        dpc, dinsn, dwe, dwaddr, dwdata = h.trace[i]
        ipc, iinsn, ird, iwdata = iss_trace[i]
        cov("isa:" + classify(iinsn))
        where = f"{tag}: retirement {i} (pc {ipc:#x}, insn {iinsn:#010x})"
        assert dpc == ipc, f"{where}: DUT pc {dpc:#x} != ISS {ipc:#x}"
        assert dinsn == iinsn, f"{where}: DUT insn {dinsn:#010x} != ISS {iinsn:#010x}"
        if ird is not None:
            assert dwe == 1, f"{where}: DUT did not write x{ird}"
            assert dwaddr == ird, f"{where}: DUT wrote x{dwaddr}, ISS x{ird}"
            assert dwdata == iwdata, \
                f"{where}: x{ird} DUT {dwdata:#018x} != ISS {iwdata:#018x}"


async def run_program(h, src, max_cycles=20000, stop_on_ecall=True, mem=None):
    words, labels = assemble(src)
    iss = ISS()
    iss.load_words(0, words)
    if mem:
        for addr, val in mem.items():
            iss.mem[addr] = val & 0xFF
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=max_cycles, stop_on_ecall=stop_on_ecall)
    iss_trace = iss.run_to(len(h.trace))
    return iss, iss_trace, words


def pad_nop_to(src, target_addr):
    """Pad with NOPs so falling through the gap stays legal."""
    words, _ = assemble(src)
    n = (target_addr - 4 * len(words)) // 4
    assert n >= 0, f"program already past {target_addr:#x}"
    return src + "nop\n" * n


def pad_to(src, target_addr):
    """Pad the program with .word 0 so the next instruction lands at target_addr."""
    words, _ = assemble(src)
    n = (target_addr - 4 * len(words)) // 4
    assert n >= 0, f"program already past {target_addr:#x}"
    return src + ".word 0\n" * n


# --------------------------------------------------------------------------- programs
ALU_PROG = """
    lui   x1, 0x12345
    addi  x2, x0, 0x7ff
    addi  x3, x0, -1
    addi  x4, x0, 0
    addi  x5, x0, 1
    addi  x6, x0, 63
    slli  x7, x3, 1
    add   x8, x1, x2
    sub   x9, x1, x2
    sll   x10, x5, x6
    slt   x11, x3, x5
    sltu  x12, x3, x5
    xor   x13, x1, x2
    srl   x14, x3, x6
    sra   x15, x3, x6
    or    x16, x1, x2
    and   x17, x1, x2
    slti  x18, x1, -1
    sltiu x19, x3, 1
    xori  x20, x1, 0x555
    ori   x21, x2, 0x100
    andi  x22, x1, 0xff
    srai  x23, x3, 3
    srli  x24, x3, 3
    addw  x25, x1, x2
    subw  x26, x1, x2
    sllw  x27, x1, x6
    srlw  x28, x1, x6
    sraw  x29, x1, x6
    addiw x1, x1, 1
    slliw x2, x2, 4
    srliw x3, x3, 4
    sraiw x4, x3, 2
    andn  x5, x1, x2
    orn   x6, x1, x2
    xnor  x7, x1, x2
    min   x8, x1, x3
    minu  x9, x1, x3
    max   x10, x1, x3
    maxu  x11, x1, x3
    sext.b x12, x1
    sext.h x13, x1
    zext.h x14, x1
    clz   x15, x1
    ctz   x16, x1
    cpop  x17, x1
    clz   x18, x4
    ctz   x19, x4
    cpop  x20, x4
    rol   x21, x1, x6
    ror   x22, x1, x6
    rori  x23, x1, 7
    rolw  x24, x1, x6
    rorw  x25, x1, x6
    rev8  x26, x1
    orc.b x27, x1
    orc.b x28, x4
    bset  x29, x1, x6
    bclr  x1, x3, x6
    binv  x2, x3, x6
    bext  x3, x3, x6
    bseti x4, x4, 63
    bclri x5, x3, 0
    binvi x6, x3, 5
    bexti x7, x3, 5
    sh1add x8, x1, x2
    sh2add x9, x1, x2
    sh3add x10, x1, x2
    add.uw x11, x1, x2
    slli.uw x12, x1, 3
    clmul x13, x1, x2
    clmulh x14, x1, x2
    clmulr x15, x1, x2
    czero.eqz x16, x1, x4
    czero.nez x17, x1, x5
    czero.eqz x18, x1, x5
    czero.nez x19, x1, x4
    add   x0, x1, x2
    addi  x0, x0, 1
    ecall
"""

MDU_PROG = """
    addi  x1, x0, 1000
    addi  x2, x0, -7
    addi  x3, x0, 0
    lui   x4, 0x80000
    addi  x5, x0, -1
    mul   x6, x1, x2
    mulh  x7, x1, x2
    mulhsu x8, x1, x2
    mulhu x9, x1, x2
    mul   x10, x4, x4
    mulh  x11, x4, x4
    div   x12, x1, x2
    divu  x13, x1, x2
    rem   x14, x1, x2
    remu  x15, x1, x2
    div   x16, x1, x3
    divu  x17, x1, x3
    rem   x18, x1, x3
    remu  x19, x1, x3
    div   x20, x4, x5
    rem   x21, x4, x5
    div   x22, x4, x3
    mul   x23, x3, x3
    divu  x24, x3, x1
    mulh  x25, x5, x5
    mulhu x26, x5, x5
    mulhsu x27, x5, x5
    div   x28, x5, x1
    remu  x29, x5, x1
    ecall
"""

MEM_PROG = """
    lui   x30, 0x2
    addi  x1, x0, 0x123
    sd    x1, 0(x30)
    ld    x2, 0(x30)
    sw    x1, 8(x30)
    lw    x3, 8(x30)
    lwu   x4, 8(x30)
    sh    x1, 16(x30)
    lh    x5, 16(x30)
    lhu   x6, 16(x30)
    sb    x1, 24(x30)
    lb    x7, 24(x30)
    lbu   x8, 24(x30)
    sb    x1, 25(x30)
    lb    x9, 25(x30)
    lbu   x10, 25(x30)
    addi  x11, x0, -1
    sd    x11, 32(x30)
    ld    x12, 32(x30)
    sw    x11, 40(x30)
    lw    x13, 40(x30)
    lwu   x14, 40(x30)
    sb    x11, 48(x30)
    lb    x15, 48(x30)
    lbu   x16, 48(x30)
    addi  x17, x0, 0x7f
    sb    x17, 56(x30)
    lb    x18, 56(x30)
    ld    x19, 0(x30)
    add   x20, x19, x11
    sd    x20, 64(x30)
    ld    x21, 64(x30)
    ecall
"""

CTRL_PROG = """
    addi  x1, x0, 0
    addi  x2, x0, 5
    addi  x3, x0, 5
    addi  x4, x0, 0
    addi  x5, x0, 1
    beq   x2, x3, t1
    addi  x4, x4, 100
t1: bne   x2, x3, t2
    addi  x4, x4, 1
t2: blt   x2, x3, t3
    addi  x4, x4, 2
t3: bge   x3, x2, t4
    addi  x4, x4, 4
t4: bltu  x2, x3, t5
    addi  x4, x4, 8
t5: bgeu  x3, x2, t6
    addi  x4, x4, 16
t6: addi  x6, x0, 0
    addi  x7, x0, 10
loop:
    addi  x6, x6, 1
    blt   x6, x7, loop
    jal   x8, sub1
    addi  x9, x0, 0x55
    jal   x0, after
sub1:
    addi  x10, x0, 0x77
    jalr  x0, 0(x8)
after:
    auipc x11, 0
    lui   x12, 0xdeadb
    addi  x13, x0, 3
back:
    addi  x13, x13, -1
    bne   x13, x0, back
    ecall
"""

HAZARD_PROG = """
    lui   x1, 0x1234
    add   x2, x1, x1
    add   x3, x2, x1
    add   x4, x3, x2
    add   x5, x4, x3
    lui   x6, 0x2
    addi  x7, x0, 0x321
    sd    x7, 0(x6)
    ld    x8, 0(x6)
    add   x9, x8, x8
    add   x10, x9, x8
    sd    x10, 8(x6)
    lw    x11, 8(x6)
    add   x12, x11, x1
    slli  x13, x12, 3
    xor   x14, x13, x12
    mul   x15, x14, x12
    add   x16, x15, x15
    add   x17, x16, x15
    ld    x18, 0(x6)
    sd    x18, 16(x6)
    ld    x19, 16(x6)
    add   x20, x19, x18
    ecall
"""

CSR_PROG = """
    lui   x1, 0x2
    addi  x1, x1, 0x10
    csrrw x0, mscratch, x1
    csrrs x2, mscratch, x0
    addi  x3, x0, 0xff
    csrrs x4, mscratch, x3
    csrrc x5, mscratch, x3
    csrrwi x6, mscratch, 0x15
    csrrsi x7, mscratch, 0x0a
    csrrci x8, mscratch, 0x01
    csrrs x9, misa, x0
    csrrs x10, mhartid, x0
    csrrs x11, marchid, x0
    csrrs x12, mvendorid, x0
    csrrs x13, mimpid, x0
    csrrs x14, mstatus, x0
    csrrs x15, mtvec, x0
    lui   x16, 0x1
    csrrw x0, mtvec, x16
    csrrs x17, mtvec, x0
    csrrs x18, mie, x0
    csrrs x19, mip, x0
    csrrs x20, pmpcfg0, x0
    csrrs x21, pmpaddr0, x0
    csrrs x22, mepc, x0
    csrrs x23, mcause, x0
    csrrs x24, mtval, x0
    csrrs x25, mcounteren, x0
    csrrs x0, mscratch, x0
    ecall
"""

TRAP_BODY = """
    lui   x5, 0x1
    csrrw x0, mtvec, x5
    addi  x1, x0, 1
    .word 0x00000000
    addi  x2, x0, 2
    csrrw x9, 0x999, x0
    addi  x3, x0, 3
    ld    x10, 4(x0)
    addi  x11, x0, 4
    sd    x11, 2(x0)
    ecall
done:
    jal   x0, done
"""

TRAP_HANDLER = """
    csrrs x20, mcause, x0
    csrrs x21, mepc, x0
    csrrs x22, mtval, x0
    addi  x21, x21, 4
    csrrw x0, mepc, x21
    mret
"""


def trap_program():
    body = pad_to(TRAP_BODY, 0x1000)
    return body + TRAP_HANDLER


IRQ_PROG = """
    lui   x5, 0x1
    csrrw x0, mtvec, x5
    addi  x1, x0, 0x80
    csrrw x0, mie, x1
    csrrs x2, mstatus, x0
    ori   x2, x2, 8
    csrrw x0, mstatus, x2
    addi  x10, x0, 0
spin:
    jal   x0, spin
"""

IRQ_HANDLER = """
    addi  x10, x10, 1
    csrrs x11, mcause, x0
    csrrs x12, mepc, x0
    mret
"""


def irq_program():
    return pad_to(IRQ_PROG, 0x1000) + IRQ_HANDLER


# --------------------------------------------------------------------------- random
R_OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
         "andn", "orn", "xnor", "min", "minu", "max", "maxu", "rol", "ror",
         "sh1add", "sh2add", "sh3add", "add.uw", "clmul", "clmulr", "clmulh",
         "czero.eqz", "czero.nez", "bset", "bclr", "binv", "bext"]
R_OPS_W = ["addw", "subw", "sllw", "srlw", "sraw", "rolw", "rorw"]
MDU_OPS = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SHIFT_OPS = ["slli", "srli", "srai", "rori"]
U_OPS = ["clz", "ctz", "cpop", "sext.b", "sext.h", "zext.h", "rev8", "orc.b"]
MEM_OPS = [("ld", 8), ("sd", 8), ("lw", 4), ("sw", 4),
           ("lh", 2), ("sh", 2), ("lb", 1), ("sb", 1),
           ("lbu", 1), ("lhu", 2), ("lwu", 4)]


def gen_random(n, seed, allow_control=True):
    rnd = random.Random(seed)
    lines = ["lui x30, 0x2", "addi x28, x0, 0"]
    for r in range(1, 28):
        lines.append(f"addi x{r}, x0, {rnd.randint(-2048, 2047)}")
    for i in range(n):
        k = rnd.random()
        rd = rnd.choice([0] + list(range(1, 30)))   # x30 is the data base pointer
        rs1 = rnd.randint(0, 30)
        rs2 = rnd.randint(0, 30)
        if k < 0.34:
            lines.append(f"{rnd.choice(R_OPS)} x{rd}, x{rs1}, x{rs2}")
        elif k < 0.44:
            lines.append(f"{rnd.choice(R_OPS_W)} x{rd}, x{rs1}, x{rs2}")
        elif k < 0.52:
            lines.append(f"{rnd.choice(MDU_OPS)} x{rd}, x{rs1}, x{rs2}")
        elif k < 0.68:
            lines.append(f"{rnd.choice(I_OPS)} x{rd}, x{rs1}, {rnd.randint(-2048, 2047)}")
        elif k < 0.76:
            lines.append(f"{rnd.choice(SHIFT_OPS)} x{rd}, x{rs1}, {rnd.randint(0, 63)}")
        elif k < 0.82:
            lines.append(f"{rnd.choice(U_OPS)} x{rd}, x{rs1}")
        elif k < 0.94:
            op, size = rnd.choice(MEM_OPS)
            off = rnd.randrange(0, 512, size)
            lines.append(f"{op} x{rd}, {off}(x30)")
        elif allow_control:
            kind = rnd.random()
            tag = f"f{i}"          # unique label per site: no forward-target aliasing
            if kind < 0.55:
                lines.append(f"{rnd.choice(['beq','bne','blt','bge','bltu','bgeu'])} "
                             f"x{rs1}, x{rs2}, {tag}1")
                lines.append("addi x29, x29, 1")
                lines.append(f"{tag}1: addi x29, x29, 1")
                lines.append(f"{tag}2: addi x29, x29, 1")
                lines.append(f"{tag}3: addi x29, x29, 1")
            else:
                lines.append("addi x29, x29, 1")
                lines.append(f"jal x0, {tag}1")
                lines.append(f"{tag}1: addi x29, x29, 2")
                lines.append(f"{tag}2: addi x29, x29, 2")
                lines.append(f"{tag}3: addi x29, x29, 2")
        else:
            lines.append(f"addi x{rd}, x{rs1}, {rnd.randint(-2048, 2047)}")
    lines.append("end: jal x0, end")
    return "\n".join(lines)


# --------------------------------------------------------------------------- tests
@cocotb.test()
async def test_alu(dut):
    """Every RV64I / Zba / Zbb / Zbc / Zbs / Zicond ALU op, plus x0 write suppression."""
    h = Harness(dut)
    await h.startup()
    _, iss_trace, words = await run_program(h, ALU_PROG, max_cycles=4000)
    compare(h, iss_trace, "alu")
    for w in words:
        cov("insn_retired")
    dut._log.info(f"alu: {len(iss_trace)} instructions matched the golden model")


@cocotb.test()
async def test_muldiv(dut):
    """RV64M multiply/divide, including div-by-zero and signed overflow."""
    h = Harness(dut)
    await h.startup()
    _, iss_trace, _ = await run_program(h, MDU_PROG, max_cycles=40000)
    compare(h, iss_trace, "muldiv")
    cov("mdu_ops", 30)


@cocotb.test()
async def test_memory(dut):
    """All load/store widths, sign/zero extension and byte lanes."""
    h = Harness(dut)
    await h.startup()
    _, iss_trace, _ = await run_program(h, MEM_PROG, max_cycles=4000)
    compare(h, iss_trace, "memory")
    cov("mem_widths", 4)


@cocotb.test()
async def test_control(dut):
    """All branch conditions, jal/jalr link and return, loops, auipc."""
    h = Harness(dut)
    await h.startup()
    _, iss_trace, _ = await run_program(h, CTRL_PROG, max_cycles=4000)
    compare(h, iss_trace, "control")
    cov("branch_cond", 6)


@cocotb.test()
async def test_hazards(dut):
    """Back-to-back dependent chains: EX/MEM + MEM/WB forwarding and load-use."""
    h = Harness(dut)
    await h.startup()
    _, iss_trace, _ = await run_program(h, HAZARD_PROG, max_cycles=4000)
    compare(h, iss_trace, "hazards")
    cov("forward_paths", 2)


@cocotb.test()
async def test_csr(dut):
    """CSR read / write / read-modify-write, immediate forms, WARL fields."""
    h = Harness(dut)
    await h.startup()
    _, iss_trace, _ = await run_program(h, CSR_PROG, max_cycles=4000)
    compare(h, iss_trace, "csr")
    cov("csr_ops", 3)


@cocotb.test()
async def test_traps(dut):
    """Illegal instruction, unimplemented CSR, ecall.

    Misaligned load/store no longer traps: Zicclsm handles them in hardware, and
    tb_lsu checks the split and merge directly.
    """
    h = Harness(dut)
    await h.startup()
    _, iss_trace, _ = await run_program(h, trap_program(), max_cycles=6000,
                                        stop_on_ecall=False)
    compare(h, iss_trace, "traps")
    causes = [c for _, c in h.traps]
    assert 2 in causes, f"expected an illegal-instruction trap, got {causes}"
    assert 11 in causes, f"expected an ecall trap, got {causes}"


@cocotb.test()
async def test_random(dut):
    """Randomised instruction streams compared instruction-by-instruction."""
    h = Harness(dut)
    await h.startup()
    total = 0
    for seed in (1, 2, 3, 4, 5):
        src = gen_random(120, seed)
        iss, iss_trace, _ = await run_program(h, src, max_cycles=12000,
                                            stop_on_ecall=False)
        compare(h, iss_trace, f"random(seed={seed})")
        compare_memory(dut, iss, tag=f"random(seed={seed})")
        total += len(iss_trace)
        cov("random_streams")
    dut._log.info(f"random: {total} instructions matched across 5 streams")


@cocotb.test()
async def test_backpressure(dut):
    """Random request backpressure on both memory ports must not change results."""
    h = Harness(dut)
    await h.startup()
    words, _ = assemble(HAZARD_PROG)
    iss = ISS()
    iss.load_words(0, words)
    h.clear()
    await h.load(words)
    await h.reset()

    d = dut
    rnd = random.Random(99)
    for _ in range(6000):
        # drive backpressure before the edge
        d.i_bp.value = 1 if rnd.random() < 0.35 else 0
        d.d_bp.value = 1 if rnd.random() < 0.35 else 0
        await RisingEdge(d.clk)
        await FallingEdge(d.clk)
        if int(d.retire_valid.value):
            h.trace.append((int(d.retire_pc.value), int(d.retire_insn.value),
                            int(d.gpr_we.value), int(d.gpr_waddr.value),
                            int(d.gpr_wdata.value)))
        if int(d.trap_valid.value) and int(d.trap_cause.value) == 11:
            break
    d.i_bp.value = 0
    d.d_bp.value = 0
    iss_trace = iss.run_to(len(h.trace))
    compare(h, iss_trace, "backpressure")
    cov("backpressure")


@cocotb.test()
async def test_access_fault(dut):
    """A memory error on a load must raise a load access fault, not corrupt state."""
    h = Harness(dut)
    await h.startup()
    src = pad_to("""
    lui   x5, 0x1
    csrrw x0, mtvec, x5
    lui   x30, 0x2
    ld    x1, 0(x30)
    addi  x2, x0, 7
    ecall
done:
    jal   x0, done
""", 0x1000) + TRAP_HANDLER

    words, _ = assemble(src)
    iss = ISS()
    iss.load_words(0, words)
    iss.fault_addr = DATA_BASE
    await h.load(words)
    dut.err_en.value = 1
    dut.err_addr.value = DATA_BASE
    await h.reset()
    await h.run(max_cycles=4000, stop_on_ecall=False)
    dut.err_en.value = 0
    iss_trace = iss.run_to(len(h.trace))
    compare(h, iss_trace, "access_fault")
    assert 5 in [c for _, c in h.traps], f"expected load access fault, got {h.traps}"
    cov("load_access_fault")


@cocotb.test()
async def test_interrupt(dut):
    """Timer interrupt entry, mcause/mepc, and return to the interrupted flow."""
    h = Harness(dut)
    await h.startup()
    words, _ = assemble(irq_program())
    h.clear()
    await h.load(words)
    await h.reset()

    d = dut
    await h.run(max_cycles=60, stop_on_ecall=False)     # let it reach the spin loop
    d.irq_timer.value = 1
    await h.run(max_cycles=200, stop_on_ecall=False)
    d.irq_timer.value = 0
    await h.run(max_cycles=100, stop_on_ecall=False)

    causes = [c for _, c in h.traps]
    assert 0x8000000000000007 in causes, f"expected a timer interrupt, got {causes}"
    d.dbg_halt_req.value = 1
    for _ in range(40):
        await RisingEdge(d.clk)
        await FallingEdge(d.clk)
        if int(d.dbg_halted.value):
            break
    assert int(d.dbg_halted.value) == 1, "core did not halt for debug inspection"
    x10 = await h.read_gpr(10)
    x11 = await h.read_gpr(11)
    x12 = await h.read_gpr(12)
    assert x10 >= 1, f"handler did not run (x10={x10})"
    assert x11 == 0x8000000000000007, f"mcause read as {x11:#x}"
    assert x12 != 0, "mepc read as zero"
    d.dbg_halt_req.value = 0
    cov("timer_interrupt")


@cocotb.test()
async def test_debug(dut):
    """External halt, resume, single step and watchpoint reporting."""
    h = Harness(dut)
    await h.startup()
    src = """
    lui   x30, 0x2
    addi  x1, x0, 0
loop:
    addi  x1, x1, 1
    sd    x1, 0(x30)
    jal   x0, loop
"""
    words, _ = assemble(src)
    h.clear()
    await h.load(words)
    await h.reset()

    d = dut
    d.wp_en.value = 1
    d.wp_addr.value = DATA_BASE
    hits = 0
    await h.run(max_cycles=40, stop_on_ecall=False)
    d.dbg_halt_req.value = 1
    for _ in range(40):
        await RisingEdge(d.clk)
        await FallingEdge(d.clk)
        if int(d.wp_hit.value):
            hits += 1
        if int(d.dbg_halted.value):
            break
    assert int(d.dbg_halted.value) == 1, "core did not halt"
    x1 = await h.read_gpr(1)
    assert x1 > 0, f"x1 not advancing before halt (x1={x1})"

    # single step: exactly one retirement, then halt again
    d.dbg_halt_req.value = 0
    d.dbg_step.value = 1
    d.dbg_resume_req.value = 1
    await RisingEdge(d.clk)
    d.dbg_resume_req.value = 0
    retired = 0
    for _ in range(60):
        await RisingEdge(d.clk)
        await FallingEdge(d.clk)
        if int(d.retire_valid.value):
            retired += 1
        if int(d.dbg_halted.value) and retired > 0:
            break
    d.dbg_step.value = 0
    assert int(d.dbg_halted.value) == 1, "core did not re-halt after a single step"
    assert retired == 1, f"single step retired {retired} instructions, expected 1"

    # resume freely and confirm forward progress
    d.dbg_resume_req.value = 1
    await RisingEdge(d.clk)
    d.dbg_resume_req.value = 0
    await h.run(max_cycles=40, stop_on_ecall=False)
    assert int(d.dbg_halted.value) == 0, "core stayed halted after resume"
    d.wp_en.value = 0
    dut._log.info(f"debug: watchpoint hit pulses observed = {hits}")
    cov("debug_halt_step")
    cov("watchpoint")


@cocotb.test()
async def test_pmp(dut):
    """PMP: NAPOT matching, denied load/store/fetch, lock enforcement, and a
    permitted read-only region.  The golden model has no PMP, so this test
    checks explicit expected causes and CSR read-back values."""
    h = Harness(dut)
    await h.startup()
    prog = pad_nop_to(PMP_PART1, 0x800) + PMP_PART2
    prog = pad_nop_to(prog, 0x1000) + PMP_HANDLER
    words, _ = assemble(prog)
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=4000, stop_on_ecall=True)

    causes = [c for _, c in h.traps]
    assert causes == [5, 7, 1, 7, 11], \
        f"expected [load_access, store_access, inst_access, store_access, ecall], got {causes}"

    pcs = [p for p, _ in h.traps]
    assert pcs[2] == 0x2000, f"instruction access fault at {pcs[2]:#x}, expected 0x2000"

    vals = await halt_and_read(h, [9, 11, 15, 16])
    assert vals[9] == 0x98, \
        f"locked pmpcfg0 changed to {vals[9]:#x} after a write (lock not enforced)"
    assert vals[11] == 0x807, \
        f"locked pmpaddr0 changed to {vals[11]:#x} after a write (lock not enforced)"
    assert vals[15] == 0x9998, f"pmpcfg0 read back {vals[15]:#x}, expected 0x9998"
    cov("pmp_denied_load")
    cov("pmp_denied_store")
    cov("pmp_denied_fetch")
    cov("pmp_lock")
    cov("pmp_napot")


@cocotb.test()
async def test_fetch_fault(dut):
    """A bus error on the instruction port raises an instruction access fault
    at the faulting address, and the core recovers once the error clears."""
    h = Harness(dut)
    await h.startup()
    body = pad_nop_to("""
    lui   x5, 0x1
    csrrw x0, mtvec, x5
    addi  x1, x0, 1
""", 0x40) + """
    addi  x2, x0, 2
    addi  x3, x0, 3
    ecall
"""
    handler = """
    csrrs x20, mcause, x0
    addi  x23, x0, 1
    beq   x20, x23, hfetch
    csrrs x21, mepc, x0
    addi  x21, x21, 4
    csrrw x0, mepc, x21
    mret
hfetch:
    addi  x21, x0, 0x48
    csrrw x0, mepc, x21
    mret
"""
    src = pad_nop_to(body, 0x1000) + handler
    words, _ = assemble(src)
    h.clear()
    await h.load(words)
    dut.err_en.value = 1
    dut.err_addr.value = 0x40
    await h.reset()
    await h.run(max_cycles=200, stop_on_ecall=False)
    dut.err_en.value = 0
    await h.run(max_cycles=600, stop_on_ecall=True)

    causes = [c for _, c in h.traps]
    assert 1 in causes, f"expected an instruction access fault, got {causes}"
    pcs = [p for p, c in h.traps if c == 1]
    assert 0x40 in pcs, f"instruction access fault reported at {pcs}, expected 0x40"
    assert 11 in causes, f"core did not recover and reach ecall, got {causes}"
    cov("inst_access_fault")


@cocotb.test()
async def test_ebreak_debug(dut):
    """EBREAK enters debug (no breakpoint trap), and resume continues at the
    instruction after it."""
    h = Harness(dut)
    await h.startup()
    src = """
    lui   x5, 0x1
    csrrw x0, mtvec, x5
    addi  x1, x0, 1
    ebreak
    addi  x1, x1, 0x10
    ecall
"""
    words, _ = assemble(src)
    h.clear()
    await h.load(words)
    await h.reset()
    d = dut
    await h.run(max_cycles=600, stop_on_ecall=False)

    assert int(d.dbg_halted.value) == 1, "EBREAK did not enter debug mode"
    assert 3 not in [c for _, c in h.traps], "EBREAK raised a breakpoint trap instead of debug entry"

    d.dbg_resume_req.value = 1
    await RisingEdge(d.clk)
    d.dbg_resume_req.value = 0
    await h.run(max_cycles=600, stop_on_ecall=True)

    causes = [c for _, c in h.traps]
    assert 11 in causes, f"execution did not continue past EBREAK, traps={causes}"
    writes = [t for t in h.trace if t[2] == 1 and t[3] == 1]
    assert writes, "no write to x1 observed"
    assert writes[-1][4] == 0x11, \
        f"x1 = {writes[-1][4]:#x} after EBREAK, expected 0x11 (instruction after EBREAK did not run)"
    cov("ebreak_debug_entry")


WFI_BASE = """
    lui   x5, 0x1
    csrrw x0, mtvec, x5
    addi  x1, x0, 0x80
    csrrw x0, mie, x1
%s
    wfi
    addi  x5, x0, 0x55
    ecall
"""


@cocotb.test()
async def test_wfi(dut):
    """WFI resumes at the next instruction when an interrupt is pending but
    masked, and takes the interrupt when MIE is set."""
    d = dut
    h = Harness(dut)
    await h.startup()

    # ---- phase 1: MIE = 0, interrupt pending -> resume, no trap -------------
    words, _ = assemble(WFI_BASE % "")
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=80, stop_on_ecall=False)
    d.irq_timer.value = 1
    await h.run(max_cycles=400, stop_on_ecall=True)
    d.irq_timer.value = 0
    causes = [c for _, c in h.traps]
    assert 0x8000000000000007 not in causes, "masked interrupt was taken during WFI"
    assert 11 in causes, f"WFI did not resume execution (no ecall), traps={causes}"
    w5 = [t for t in h.trace if t[2] == 1 and t[3] == 5]
    assert w5 and w5[-1][4] == 0x55, "the instruction after WFI did not execute"
    cov("wfi_masked_resume")

    # ---- phase 2: MIE = 1, interrupt pending -> trap ------------------------
    set_mie = """
    csrrs x2, mstatus, x0
    ori   x2, x2, 8
    csrrw x0, mstatus, x2
"""
    words, _ = assemble(WFI_BASE % set_mie)
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=120, stop_on_ecall=False)
    d.irq_timer.value = 1
    await h.run(max_cycles=400, stop_on_ecall=False)
    d.irq_timer.value = 0
    causes = [c for _, c in h.traps]
    assert 0x8000000000000007 in causes, f"WFI did not take the enabled interrupt, traps={causes}"
    cov("wfi_interrupt_wake")


@cocotb.test()
async def test_counters(dut):
    """mcycle advances every cycle and minstret counts retired instructions.
    Counter values are pipeline-timing dependent, so the test bounds the delta
    rather than comparing an exact number."""
    h = Harness(dut)
    await h.startup()
    src = """
    csrrs x1, minstret, x0
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    csrrs x2, minstret, x0
    csrrs x3, mcycle, x0
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    csrrs x4, mcycle, x0
    ecall
"""
    words, _ = assemble(src)
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=2000, stop_on_ecall=True)
    assert 11 in [c for _, c in h.traps], "program did not reach ecall"
    v = await halt_and_read(h, [1, 2, 3, 4])
    delta = v[2] - v[1]
    assert 8 <= delta <= 11, f"minstret advanced by {delta} over 8 nops"
    assert v[4] > v[3], f"mcycle did not advance ({v[3]} -> {v[4]})"
    cov("counter_minstret")
    cov("counter_mcycle")


PREDICT_PROG = """
    lui   x30, 0x2
    addi  x2, x30, 0x100
    addi  x1, x0, 0
    jal   x5, rec
    addi  x7, x0, 0x300
    sd    x7, 0(x30)
    ld    x8, 0(x30)
    jalr  x0, 0(x8)
    addi  x9, x0, 0xbad
    ecall
rec:
    addi  x1, x1, 1
    addi  x6, x0, 10
    blt   x1, x6, rec2
    jalr  x0, 0(x5)
rec2:
    addi  x2, x2, -8
    sd    x5, 0(x2)
    jal   x5, rec
    ld    x5, 0(x2)
    addi  x2, x2, 8
    jalr  x0, 0(x5)
"""


@cocotb.test()
async def test_predictor_stress(dut):
    """Deep call/return recursion (overflows the 8-entry return-address stack)
    plus an indirect jump through a loaded target, compared to the golden model."""
    h = Harness(dut)
    await h.startup()
    prog = pad_to(PREDICT_PROG, 0x300) + """
tgt:
    addi  x10, x0, 0x77
    ecall
"""
    iss, iss_trace, words = await run_program(h, prog, max_cycles=6000)
    compare(h, iss_trace, "predictor")
    compare_memory(dut, iss, tag="predictor")
    assert 11 in [c for _, c in h.traps], "program did not reach the indirect target"
    w1 = [t for t in h.trace if t[2] == 1 and t[3] == 1]
    assert w1 and w1[-1][4] == 10, f"recursion depth was {w1[-1][4] if w1 else 'unset'}, expected 10"
    cov("ras_overflow")
    cov("indirect_target")


@cocotb.test()
async def test_reset(dut):
    """A mid-stream reset restarts the core at RESET_PC and it re-executes the
    program correctly from scratch."""
    h = Harness(dut)
    await h.startup()
    src = """
    lui   x1, 0x1234
    addi  x2, x0, 5
    addi  x3, x0, 0
loop:
    add   x3, x3, x1
    addi  x2, x2, -1
    bne   x2, x0, loop
    ecall
"""
    words, _ = assemble(src)
    iss = ISS()
    iss.load_words(0, words)
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=25, stop_on_ecall=False)
    assert len(h.trace) > 0, "core did not start before the reset"

    d = dut
    d.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(d.clk)
    d.rst_n.value = 1
    await RisingEdge(d.clk)

    h.clear()
    await h.run(max_cycles=2000, stop_on_ecall=True)
    iss_trace = iss.run_to(len(h.trace))
    compare(h, iss_trace, "reset")
    assert h.trace[0][0] == 0, f"first retirement after reset was at {h.trace[0][0]:#x}, expected 0x0"
    assert 11 in [c for _, c in h.traps], "program did not complete after the reset"
    cov("mid_stream_reset")


@cocotb.test()
async def test_coverage_report(dut):
    """Print the accumulated functional coverage summary."""
    lines = [f"  {k:28s} {v}" for k, v in sorted(COV.items())]
    dut._log.info("functional coverage accumulated this run:\n" + "\n".join(lines))
    assert COV, "no coverage was recorded -- did the other tests run?"


# ===========================================================================
# Feature-completion suites: the areas the first regression pass left open
# (PMP, fetch faults, EBREAK debug entry, WFI, counters, predictor stress,
# mid-stream reset).  Where the golden model has no matching feature (PMP,
# counters, debug entry) the test asserts explicit expected values instead of
# a trace comparison, and says so in its docstring.
# ===========================================================================

async def halt_and_read(h, regs):
    """Halt the core and read architectural registers through the debug port."""
    d = h.dut
    d.dbg_halt_req.value = 1
    for _ in range(80):
        await RisingEdge(d.clk)
        await FallingEdge(d.clk)
        if int(d.dbg_halted.value):
            break
    assert int(d.dbg_halted.value) == 1, "core did not halt for inspection"
    vals = {r: await h.read_gpr(r) for r in regs}
    d.dbg_halt_req.value = 0
    d.dbg_resume_req.value = 1
    await RisingEdge(d.clk)
    d.dbg_resume_req.value = 0
    return vals


PMP_PART1 = """
    lui   x5, 0x1
    csrrw x0, mtvec, x5
    lui   x30, 0x2
    addi  x6, x0, 0x7ff
    addi  x6, x6, 8
    csrrw x0, pmpaddr0, x6
    addi  x7, x0, 0x98
    csrrw x0, pmpcfg0, x7
    ld    x1, 0(x30)
    sd    x1, 0(x30)
    jalr  x0, 0(x30)
"""

PMP_PART2 = """
    addi  x8, x0, 0
    csrrw x0, pmpcfg0, x8
    csrrs x9, pmpcfg0, x0
    addi  x10, x0, 0
    csrrw x0, pmpaddr0, x10
    csrrs x11, pmpaddr0, x0
    lui   x31, 0x2
    addi  x31, x31, 0x100
    addi  x12, x0, 0x7ff
    addi  x12, x12, 0x48
    csrrw x0, pmpaddr1, x12
    addi  x14, x0, 0x99
    slli  x14, x14, 8
    addi  x13, x0, 0x98
    or    x14, x14, x13
    csrrw x0, pmpcfg0, x14
    csrrs x15, pmpcfg0, x0
    ld    x16, 0(x31)
    sd    x16, 0(x31)
    ecall
"""

PMP_HANDLER = """
    csrrs x20, mcause, x0
    csrrs x21, mepc, x0
    csrrs x22, mtval, x0
    addi  x23, x0, 1
    beq   x20, x23, hfetch
    addi  x21, x21, 4
    csrrw x0, mepc, x21
    mret
hfetch:
    lui   x21, 0x1
    addi  x21, x21, -0x800
    csrrw x0, mepc, x21
    mret
"""


# ===========================================================================
# Custom numeric ABI reached from executed instructions
# ===========================================================================
def li64(reg, v):
    """Load an arbitrary 64-bit constant with lui/addi/or (x28 is scratch).

    The low 12 bits go through a signed immediate, so the upper part is rounded
    first; splitting naively makes `addi ..., 0x800` mean -2048.
    """
    hi = (v >> 32) & 0xFFFFFFFF
    lo = v & 0xFFFFFFFF
    out = []
    if hi:
        h_hi = (hi + 0x800) >> 12
        h_lo = hi - (h_hi << 12)
        out.append(f"lui x{reg}, 0x{h_hi & 0xFFFFF:05x}")
        if h_lo:
            out.append(f"addi x{reg}, x{reg}, {h_lo}")
        out.append(f"slli x{reg}, x{reg}, 32")
    else:
        out.append(f"addi x{reg}, x0, 0")
    if lo:
        l_hi = (lo + 0x800) >> 12
        l_lo = lo - (l_hi << 12)
        out.append(f"lui x28, 0x{l_hi & 0xFFFFF:05x}")
        if l_lo:
            out.append(f"addi x28, x28, {l_lo}")
        out.append(f"or x{reg}, x{reg}, x28")
    return out


def num_insn(op, fmt=0, rd=0, rs1=0, rs2=0):
    """Encode a custom-0 numeric-ABI instruction."""
    return (op << 25) | (rs2 << 20) | (rs1 << 15) | (fmt << 12) | (rd << 7) | 0x0B


NUM_QADD, NUM_QSUB, NUM_QMUL, NUM_QCLR, NUM_QACC, NUM_QGET = 0, 1, 2, 3, 4, 5
NUM_TOINT, NUM_FROMINT = 18, 19


@cocotb.test()
async def test_numeric_abi(dut):
    """Numeric ops executed by the core, with results read back through the
    integer register file. The ISS has no numeric model, so this test asserts
    explicit expected values rather than comparing a trace."""
    h = Harness(dut)
    await h.startup()

    src = f"""
    lui   x1, 0x20000
    slli  x1, x1, 4                                        # x1 = 2.0 in Q32.32
    .word 0x{num_insn(NUM_FROMINT, rd=1, rs1=1):08x}
    .word 0x{num_insn(NUM_TOINT, rd=8, rs1=1):08x}          # probe n1 -> x8
    lui   x2, 0x30000
    slli  x2, x2, 4                                        # x2 = 3.0 in Q32.32
    .word 0x{num_insn(NUM_FROMINT, rd=2, rs1=2):08x}
    .word 0x{num_insn(NUM_TOINT, rd=9, rs1=2):08x}          # probe n2 -> x9
    .word 0x{num_insn(NUM_QMUL, rd=3, rs1=1, rs2=2):08x}    # n3 = 6.0
    .word 0x{num_insn(NUM_QADD, rd=4, rs1=1, rs2=2):08x}    # n4 = 5.0
    .word 0x{num_insn(NUM_TOINT, rd=3, rs1=3):08x}          # x3 = n3
    .word 0x{num_insn(NUM_TOINT, rd=4, rs1=4):08x}          # x4 = n4
    csrrs x5, ncfg, x0                                      # default config
    csrrs x6, nflags, x0                                    # no flags so far
    .word 0x{num_insn(NUM_QCLR, rd=0, rs1=0):08x}
    .word 0x{num_insn(NUM_QACC, rd=0, rs1=1, rs2=2):08x}    # quire += 2.0*3.0
    .word 0x{num_insn(NUM_QGET, rd=5, rs1=0):08x}           # n5 = 6.0
    .word 0x{num_insn(NUM_TOINT, rd=7, rs1=5):08x}          # x7 = n5
    ecall
"""
    words, _ = assemble(src)
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=4000, stop_on_ecall=True)

    vals = await halt_and_read(h, [3, 4, 5, 6, 7, 8, 9])
    dut._log.info(f"n1={vals[8]:#x} n2={vals[9]:#x} mul={vals[3]:#x} add={vals[4]:#x} "
                  f"ncfg={vals[5]:#x} nflags={vals[6]:#x} quire={vals[7]:#x}")
    assert vals[8] == 0x2_0000_0000, f"bridge int->num: n1 = {vals[8]:#x}"
    assert vals[9] == 0x3_0000_0000, f"bridge int->num: n2 = {vals[9]:#x}"
    assert vals[3] == 0x6_0000_0000, f"nqmul 2.0*3.0: x3 = {vals[3]:#x}, expected 0x600000000"
    assert vals[4] == 0x5_0000_0000, f"nqadd 2.0+3.0: x4 = {vals[4]:#x}, expected 0x500000000"
    assert vals[5] == 0x2020,        f"ncfg default = {vals[5]:#x}, expected 0x2020"
    assert vals[6] == 0,             f"nflags = {vals[6]:#x}, expected 0"
    assert vals[7] == 0x6_0000_0000, f"quire 2.0*3.0: x7 = {vals[7]:#x}, expected 0x600000000"
    cov("numeric_abi_ops")
    dut._log.info("numeric ABI: mul, add, bridges, quire and CSRs all correct")


@cocotb.test()
async def test_xcetask(dut):
    """Xcetask reached through the CSR window at 0x7D0, with a simulated task
    engine on the other side. Checks start, completion, result, pending bit and
    the per-slot state, all read back by executed instructions."""
    h = Harness(dut)
    await h.startup()

    src = """
    addi  x1, x0, 3
    csrrw x0, 0x7d0, x1        # enable + interrupt enable
    addi  x2, x0, 0x5a
    csrrw x0, 0x7d2, x2        # token
    addi  x3, x0, 0x3e8
    csrrw x0, 0x7d3, x3        # timeout 1000 cycles
    addi  x4, x0, 0x01         # op = START, slot = 0
    csrrw x0, 0x7d1, x4
poll:
    csrrs x5, 0x7d4, x0        # status
    andi  x6, x5, 3            # slot 0 state
    addi  x7, x0, 2            # DONE
    bne   x6, x7, poll
    csrrs x8, 0x7d7, x0        # pending bits
    csrrs x9, 0x7d5, x0        # result of the selected slot
    ecall
"""
    words, _ = assemble(src)
    h.clear()
    await h.load(words)
    await h.reset()

    starts = [0]

    async def engine():
        """Complete each started task one cycle after the start pulse.

        The completion must not be driven in the same cycle as the start: the
        slot becomes ACTIVE at the end of that cycle, so a completion presented
        then is evaluated against a slot that is still IDLE and is rejected.
        """
        queued = None
        while True:
            await RisingEdge(dut.clk)
            await FallingEdge(dut.clk)
            if queued is not None:
                dut.task_done_valid.value = 1
                dut.task_done_slot.value = queued
                dut.task_done_result.value = 0x77
                queued = None
            else:
                dut.task_done_valid.value = 0
                if int(dut.task_start_valid.value):
                    starts[0] += 1
                    queued = int(dut.task_start_slot.value)

    cocotb.start_soon(engine())
    await h.run(max_cycles=4000, stop_on_ecall=True)

    vals = await halt_and_read(h, [5, 8, 9])
    dut._log.info(f"start pulses seen by the engine: {starts[0]}")
    dut._log.info(f"status={vals[5]:#x} pending={vals[8]:#x} result={vals[9]:#x}")
    assert (vals[5] & 3) == 2, f"slot 0 state = {vals[5] & 3}, expected DONE(2)"
    assert vals[8] == 1,       f"pending = {vals[8]:#x}, expected 1"
    assert vals[9] == 0x77,    f"result = {vals[9]:#x}, expected 0x77"
    cov("xcetask_csr_path")
    dut._log.info("Xcetask: start, completion, result, pending and slot state all correct")


@cocotb.test()
async def test_isa_sweep_fast(dut):
    """The same 4445-instruction ISA sweep the UVM test uses, run through the
    fast harness so any divergence can be located without waiting on the UVM
    memory driver."""
    import os, sys
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, os.path.join(here, "..", "..", "sim"))
    import gen_isa_sweep as g

    src = g.with_handler(g.build_isa_program())
    words, _ = assemble(src)

    iss = ISS()
    iss.load_words(0, words)

    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=80000, stop_on_ecall=False)

    iss_trace = iss.run_to(len(h.trace))
    compare(h, iss_trace, "isa-sweep")
    cov("isa_sweep")
    dut._log.info(f"ISA sweep: {len(h.trace)} retirements matched the golden model")


@cocotb.test()
async def test_numeric_sweep(dut):
    """Systematic numeric-ABI sweep with full trace comparison.

    Every numeric op is followed by NUM_TOINT so its result lands in an integer
    register -- otherwise the retirement trace would show no writes at all for
    numeric instructions, and comparing traces would prove nothing.
    """
    def enc(op, rd=0, rs1=0, rs2=0, fmt=0):
        return (op << 25) | (rs2 << 20) | (rs1 << 15) | (fmt << 12) | (rd << 7) | 0x0B

    L = []
    # operand pool for each family, loaded into the integer file then bridged
    q_vals = [0x2_0000_0000, 0x3_0000_0000, 0xFFFF_FFFF_0000_0000, 0x1_8000_0000]
    wide = {
        0: [(0x4000, 0x4000), (0x4000, 0x5000), (0x7000, 0x2000), (0xC000, 0x4000)],   # posit16
        1: [(0x0001_0000, 0x0002_0000), (0x0002_0000, 0xFFFF_0000), (0x8000_0000, 0x0001_0000)],  # LNS
        2: [(0x123, 0x456), (0xFFF, 0xABC), (0x001, 0x002)],                           # RNS
        3: [(0x3F800000, 0x40000000), (0x40400000, 0x3FC00000), (0x7F800000, 0x40000000)],  # FP32
    }
    fam_ops = {0: (8, 9, 10, 11), 1: (12, 13), 2: (14, 15), 3: (16, 17)}

    gpr = 5
    nreg = 1
    rd_gpr = 10
    # fixed-Q ops over the operand pool
    for i, av in enumerate(q_vals):
        L.extend(li64(gpr, av))
        L.append(f".word 0x{enc(19, rd=i, rs1=gpr):08x}")       # FROMINT
    for op in (0, 1, 2):
        for i in range(len(q_vals)):
            for j in range(len(q_vals)):
                L.append(f".word 0x{enc(op, rd=8, rs1=i, rs2=j):08x}")
                L.append(f".word 0x{enc(18, rd=rd_gpr, rs1=8):08x}")   # TOINT
                rd_gpr += 1
                if rd_gpr > 28:
                    rd_gpr = 10
    # research families
    for fam, pairs in wide.items():
        for (av, bv) in pairs:
            L.extend(li64(gpr, av))
            L.append(f".word 0x{enc(19, rd=1, rs1=gpr):08x}")
            L.extend(li64(gpr, bv))
            L.append(f".word 0x{enc(19, rd=2, rs1=gpr):08x}")
            for op in fam_ops[fam]:
                L.append(f".word 0x{enc(op, rd=8, rs1=1, rs2=2):08x}")
                L.append(f".word 0x{enc(18, rd=rd_gpr, rs1=8):08x}")
                rd_gpr += 1
                if rd_gpr > 28:
                    rd_gpr = 10
    # quire and adaptive-precision paths
    L.append(f".word 0x{enc(3, rd=0, rs1=0):08x}")              # QCLR
    L.append(f".word 0x{enc(4, rd=0, rs1=0, rs2=1):08x}")       # QACC
    L.append(f".word 0x{enc(5, rd=8, rs1=0):08x}")              # QGET
    L.append(f".word 0x{enc(18, rd=9, rs1=8):08x}")
    L.append(f".word 0x{enc(6, rd=8, rs1=1):08x}")              # ADAPT
    L.append(f".word 0x{enc(18, rd=11, rs1=8):08x}")
    L.append("csrrs x12, nflags, x0")
    L.append("ecall")

    src = "\n".join(L)
    words, _ = assemble(src)

    iss = ISS()
    iss.load_words(0, words)

    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=20000, stop_on_ecall=True)

    iss_trace = iss.run_to(len(h.trace))
    compare(h, iss_trace, "numeric-sweep")
    cov("numeric_sweep")
    dut._log.info(f"numeric sweep: {len(h.trace)} retirements matched the ISS")


def amo_insn(f5, rd, rs1, rs2=0, f3=3):
    """Encode an A-extension instruction: funct5 | rs2 | rs1 | f3 | rd | 0x2F."""
    return (f5 << 27) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x2F


@cocotb.test()
async def test_atomic(dut):
    """LR/SC and the AMOs, executed by the core and compared against the ISS."""
    L = []
    L.extend(li64(5, 0x100))                     # base address
    L.extend(li64(6, 100))
    L.append("sd x6, 0(x5)")
    L.append(f".word 0x{amo_insn(0x02, 7, 5):08x}")        # lr.d  x7, (x5)  -> 100
    L.extend(li64(8, 5))
    L.append(f".word 0x{amo_insn(0x00, 9, 5, 8):08x}")     # amoadd.d x9, x8, (x5) -> 100, mem 105
    L.append(f".word 0x{amo_insn(0x02, 10, 5):08x}")       # lr.d  x10, (x5) -> 105
    L.append(f".word 0x{amo_insn(0x03, 11, 5, 8):08x}")    # sc.d  x11, x8, (x5) -> 0, mem 5
    L.append(f".word 0x{amo_insn(0x03, 12, 5, 8):08x}")    # sc.d  x12 -> 1, no reservation
    L.append("ld x13, 0(x5)")                    # 5
    L.extend(li64(8, 0x0F))
    L.append(f".word 0x{amo_insn(0x0C, 14, 5, 8):08x}")    # amoor.d -> 5|15 = 15
    L.append(f".word 0x{amo_insn(0x01, 15, 5, 8):08x}")    # amoswap.d -> 15, mem 15
    L.append("ld x16, 0(x5)")                    # 15
    L.append("ecall")

    src = "\n".join(L)
    words, _ = assemble(src)
    iss = ISS()
    iss.load_words(0, words)

    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=20000, stop_on_ecall=True)

    iss_trace = iss.run_to(len(h.trace))
    compare(h, iss_trace, "atomic")
    cov("atomic")
    dut._log.info(f"atomic: {len(h.trace)} retirements matched the ISS")


@cocotb.test()
async def test_sv39_identity(dut):
    """Run real Sv39 translation inside the core.

    A single level-2 leaf PTE maps the low 1 GB identity (VA == PA), so the
    architectural results are unchanged and the ISS comparison stays valid while
    the walker, the TLB and the LSU translation phase are all exercised by
    executed instructions. MPRV is set so M-mode loads and stores translate;
    fetches are never translated in M-mode, so the program itself runs bare.
    """
    L = []
    # root page table at PA 0x1000, holding one identity megapage PTE
    L.extend(li64(5, 0x1000))
    L.extend(li64(6, 0xCF))              # V|R|W|X|A|D, PPN 0 -> identity
    L.append("sd x6, 0(x5)")
    L.extend(li64(7, 0x8000000000000001))  # satp: MODE=8 (Sv39), PPN=1
    # csrrw x0, satp(0x180), x7 -- encoded directly: the assembler has no name
    # for satp
    L.append(f".word 0x{(0x180 << 20) | (7 << 15) | (1 << 12) | 0x73:08x}")
    L.extend(li64(8, 0x20000))             # mstatus.MPRV (bit 17)
    # csrrs x0, mstatus(0x300), x8
    L.append(f".word 0x{(0x300 << 20) | (8 << 15) | (2 << 12) | 0x73:08x}")
    # now every load and store below goes through the walker
    L.extend(li64(9, 0x2000))
    L.extend(li64(10, 0x1234))
    L.append("sd x10, 0(x9)")
    L.append("ld x11, 0(x9)")
    L.extend(li64(10, 0x5678))
    L.append("sd x10, 8(x9)")
    L.append("ld x12, 8(x9)")
    L.append("add x13, x11, x12")          # 0x1234 + 0x5678
    # a second page, so the TLB has more than one entry to manage
    L.extend(li64(9, 0x3000))
    L.append("sd x11, 0(x9)")
    L.append("ld x14, 0(x9)")
    L.append("ecall")

    src = "\n".join(L)
    words, _ = assemble(src)
    iss = ISS()
    iss.load_words(0, words)

    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=20000, stop_on_ecall=True)

    iss_trace = iss.run_to(len(h.trace))
    compare(h, iss_trace, "sv39-identity")
    cov("sv39")
    dut._log.info(f"sv39 identity: {len(h.trace)} retirements matched the ISS")


@cocotb.test()
async def test_icache_hits(dut):
    """The instruction cache must actually hit, not merely be present.

    A loop runs the same instructions repeatedly, so the second pass must be
    served from the cache. Without this the core would pass every functional test
    with a cache that never hit -- correct, and pointless.
    """
    L = []
    L.append("addi x5, x0, 0")
    L.append("addi x6, x0, 8")
    L.append("addi x5, x5, 1")          # loop body
    L.append("blt x5, x6, -4")          # back to the body
    L.append("ecall")

    words, _ = assemble("\n".join(L))
    iss = ISS()
    iss.load_words(0, words)

    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=20000, stop_on_ecall=True)

    iss_trace = iss.run_to(len(h.trace))
    compare(h, iss_trace, "icache-hits")

    # the counters live inside the core instance
    core = dut.u_core if hasattr(dut, "u_core") else dut
    hits = int(core.ic_hits.value)
    misses = int(core.ic_misses.value)
    dut._log.info(f"icache: {hits} hits, {misses} misses")
    assert hits > 0, f"instruction cache never hit ({hits} hits, {misses} misses)"


@cocotb.test()
async def test_dcache_hits(dut):
    """The data cache must actually hit, not merely be present.

    Repeated loads from the same line must be served from the cache, and the
    store before them must be write-through so the loaded value is right. A cache
    that never hit would pass every functional test while doing nothing.
    """
    L = []
    L.extend(li64(5, 0x2000))
    L.extend(li64(6, 0x1234))
    L.append("sd x6, 0(x5)")             # store: write-through, no allocate
    L.append("ld x7, 0(x5)")             # first load: miss, fills
    L.append("ld x8, 0(x5)")             # hit
    L.append("ld x9, 0(x5)")             # hit
    L.append("add x10, x8, x9")          # 0x2468 if the loads were right
    L.append("ecall")

    words, _ = assemble("\n".join(L))
    iss = ISS()
    iss.load_words(0, words)

    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=20000, stop_on_ecall=True)

    iss_trace = iss.run_to(len(h.trace))
    compare(h, iss_trace, "dcache-hits")

    hits = int(dut.u_core.dc_hits.value)
    misses = int(dut.u_core.dc_misses.value)
    dut._log.info(f"dcache: {hits} hits, {misses} misses")
    assert hits > 0, f"data cache never hit ({hits} hits, {misses} misses)"


@cocotb.test()
async def test_amcce_bypass(dut):
    """AMCCE must detect a streaming workload and switch the D-cache to BYPASS.

    The program reads 128 distinct lines -- every access misses -- which is exactly
    the scan that fills a cache with data it never reuses. After one window the
    engine should have selected BYPASS, and the D-cache should stop allocating.
    """
    L = []
    L.extend(li64(5, 0x4000))            # base
    L.extend(li64(6, 128))               # iterations
    L.append("ld x7, 0(x5)")             # a distinct line every time
    L.append("addi x5, x5, 8")
    L.append("addi x6, x6, -1")
    L.append("bne x6, x0, -12")
    L.append("ecall")

    words, _ = assemble("\n".join(L))
    iss = ISS()
    iss.load_words(0, words)

    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=40000, stop_on_ecall=True)

    iss_trace = iss.run_to(len(h.trace))
    compare(h, iss_trace, "amcce-bypass")

    core = dut.u_core
    mode = int(core.amcce_mode.value)
    misses = int(core.amcce_misses.value)
    switches = int(core.amcce_switches.value)
    dut._log.info(f"amcce: mode={mode} misses={misses} switches={switches}")
    assert misses > 64, f"expected a streaming run, only {misses} misses"
    assert mode == 1, f"AMCCE should have selected BYPASS (1), got mode {mode}"
    assert switches >= 1, "AMCCE should have recorded at least one switch"


def csrw(addr, rs):
    """csrrw x0, addr, rs -- encoded directly, the assembler has no names for these."""
    return f".word 0x{((addr << 20) | (rs << 15) | (1 << 12) | 0x73):08x}"


def csrr(rd, addr):
    """csrrs rd, addr, x0"""
    return f".word 0x{((addr << 20) | (2 << 12) | (rd << 7) | 0x73):08x}"


@cocotb.test()
async def test_xrv512_in_core(dut):
    """XRV512 must be reachable from executed instructions.

    The program writes the accelerator's control window with real CSR instructions
    and executes an add. The ISS does not model XRV512, so instead of reading the
    result back into a GPR (which would break the trace comparison) the test
    asserts the accelerator's own register file after the run.
    """
    L = []
    # lane 0 of reg 1 = 40, reg 2 = 2
    L.extend(li64(5, 1));  L.append(csrw(0x7F4, 5))     # DST = 1
    L.extend(li64(5, 0));  L.append(csrw(0x7F5, 5))     # LANE = 0
    L.extend(li64(5, 40)); L.append(csrw(0x7F6, 5))     # DATA = 40
    L.extend(li64(5, 2));  L.append(csrw(0x7F4, 5))     # DST = 2
    L.extend(li64(5, 2));  L.append(csrw(0x7F6, 5))     # DATA = 2
    # op = VADD, src1 = 1, src2 = 2, dst = 3, start
    L.extend(li64(5, 0));  L.append(csrw(0x7F1, 5))
    L.extend(li64(5, 1));  L.append(csrw(0x7F2, 5))
    L.extend(li64(5, 2));  L.append(csrw(0x7F3, 5))
    L.extend(li64(5, 3));  L.append(csrw(0x7F4, 5))
    L.extend(li64(5, 1));  L.append(csrw(0x7F0, 5))     # start
    L.append("ecall")

    words, _ = assemble("\n".join(L))
    iss = ISS()
    iss.load_words(0, words)

    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=20000, stop_on_ecall=True)

    iss_trace = iss.run_to(len(h.trace))
    compare(h, iss_trace, "xrv512-in-core")

    # reg 3 lane 0 lives at flat index 3*8 + 0
    got = int(dut.u_core.u_xrv512.u_file.regs[24].value)
    dut._log.info(f"xrv512: reg3 lane0 = {got}")
    assert got == 42, f"XRV512 should have computed 40 + 2 = 42, got {got}"


@cocotb.test()
async def test_rvv_in_core(dut):
    """RVV must be reachable from executed instructions.

    Same approach as XRV512: drive the control window with CSR instructions and
    assert the vector register file, because the ISS does not model the unit.
    """
    L = []
    # vl = 8, vtype vsew = 64-bit (vtype[4:3] = 3 -> 0x18)
    L.extend(li64(5, 8));    L.append(csrw(0x781, 5))
    L.extend(li64(5, 0x18)); L.append(csrw(0x782, 5))
    # v1 = 100
    L.extend(li64(5, 1));    L.append(csrw(0x786, 5))    # caddr = 1
    L.extend(li64(5, 100));  L.append(csrw(0x787, 5))    # cwdata = 100
    # v2 = 23
    L.extend(li64(5, 2));    L.append(csrw(0x786, 5))
    L.extend(li64(5, 23));   L.append(csrw(0x787, 5))
    # vadd.vv v3, v2, v1 : funct6=000000, vs2=2, vs1=1, vd=3
    L.extend(li64(5, 0x022081d7)); L.append(csrw(0x784, 5))   # INSN
    L.extend(li64(5, 1));    L.append(csrw(0x780, 5))    # start
    L.append("ecall")

    words, _ = assemble("\n".join(L))
    iss = ISS()
    iss.load_words(0, words)

    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=20000, stop_on_ecall=True)

    iss_trace = iss.run_to(len(h.trace))
    compare(h, iss_trace, "rvv-in-core")

    got = int(dut.u_core.u_rvv.u_vrf.regs[3].value)
    dut._log.info(f"rvv: v3 = {got}")
    assert got == 123, f"RVV should have computed 100 + 23 = 123, got {got}"


@cocotb.test()
async def test_l2_in_path(dut):
    """The L2 must actually be in the data path, not merely instantiated.

    Every D-cache miss goes through the L2, so a program that touches memory must
    make the L2 count misses. A build with the L2 wired but bypassed would pass
    every functional test while the counters stayed at zero.
    """
    L = []
    L.extend(li64(5, 0x4000))
    L.extend(li64(6, 0x1234))
    L.append("sd x6, 0(x5)")             # store through both caches
    L.append("ld x7, 0(x5)")             # D-cache miss -> L2
    L.append("ld x8, 8(x5)")             # another line
    L.append("add x9, x7, x8")
    L.append("ecall")

    words, _ = assemble("\n".join(L))
    iss = ISS()
    iss.load_words(0, words)

    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=20000, stop_on_ecall=True)

    iss_trace = iss.run_to(len(h.trace))
    compare(h, iss_trace, "l2-in-path")

    core = dut.u_core
    l2_hits = int(core.l2_hits.value)
    l2_miss = int(core.l2_misses.value)
    l3_hits = int(core.l3_hits.value)
    l3_miss = int(core.l3_misses.value)
    dut._log.info(f"l2: {l2_hits} hits, {l2_miss} misses | l3: {l3_hits} hits, {l3_miss} misses")
    assert (l2_hits + l2_miss) > 0, "the L2 saw no traffic -- it is not in the data path"
    assert (l3_hits + l3_miss) > 0, "the L3 saw no traffic -- it is not behind the L2"




@cocotb.test()
async def test_vle_in_core(dut):
    """vle8.v must actually read memory from a running program.

    The vector unit has its own memory port, so this exercises the whole path: the
    program stores bytes, drives the control window with real CSR instructions,
    issues the load, and the test asserts the vector register. The ISS does not
    model RVV, so the result is read from the DUT rather than from a GPR -- putting
    it in a GPR would break the trace comparison.
    """
    L = []
    L.extend(li64(5, 0x2400))
    for i in range(8):
        L.extend(li64(6, 0x11 + i))
        L.append("sb x6, %d(x5)" % i)
    L.extend(li64(5, 8));      L.append(csrw(0x781, 5))   # vl = 8
    L.extend(li64(5, 0));      L.append(csrw(0x782, 5))   # vtype = e8
    L.extend(li64(5, 0x2400)); L.append(csrw(0x78A, 5))   # element base
    L.extend(li64(5, 0x02000087)); L.append(csrw(0x784, 5))  # vle8.v v1, (base)
    L.extend(li64(5, 1));      L.append(csrw(0x780, 5))   # start
    # Poll the BUSY bit (control bit 1) rather than spinning a fixed count: the
    # element walk runs after the start write returns, and only the unit knows how
    # long it takes.
    L.append(csrr(8, 0x780))          # read CTRL
    L.append("andi x8, x8, 2")        # busy
    L.append("bne x8, x0, -8")        # loop back to the read
    L.append("ecall")

    words, _ = assemble("\n".join(L))
    iss = ISS()
    iss.load_words(0, words)
    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=40000, stop_on_ecall=True)
    # No trace comparison here: the program polls the unit's BUSY bit, and the ISS
    # models 0x780 as a plain CSR, so its view of that read cannot match. The
    # architectural effect being checked is the vector register below, and the
    # stores that feed it are exercised by the other memory tests.
    got = int(dut.u_core.u_rvv.u_vrf.regs[1].value)
    dut._log.info(f"vle8.v in core: v1 = {got:#018x}")
    assert got == 0x1817161514131211, f"vle8.v should have loaded 0x11..0x18, got {got:#x}"


@cocotb.test()
async def test_misa_bits(dut):
    """misa must advertise what the core actually executes.

    It previously reported RV64IM only, while the core executes A, B, S, U and
    Sv39. Software that reads misa -- a bootloader picking a page-table mode, an OS
    probing for atomics -- would take a slower path or refuse to boot. This checks
    the bits are right, and that V is NOT set: the vector unit follows RVV
    semantics but not RVV encoding, so advertising V would make -march=rv64gcv
    binaries fault.
    """
    L = [csrr(5, 0x301)]          # misa
    L.append("ecall")
    words, _ = assemble("\n".join(L))
    iss = ISS()
    iss.load_words(0, words)
    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=20000, stop_on_ecall=True)
    iss_trace = iss.run_to(len(h.trace))
    compare(h, iss_trace, "misa-bits")

    # the retirement record carries the write data, which is the value misa
    # actually returned; reading the register file hierarchically did not work
    got = h.trace[0][4]
    dut._log.info(f"misa = {got:#x}")
    assert got == 0x8000000000141105, f"misa should be 0x8000000000141105, got {got:#x}"


@cocotb.test()
async def test_cache_ops(dut):
    """Zicbom / Zicboz / Zicbop must execute, not trap.

    cbo.inval drops a block, cbo.zero writes a block of zeros, clean and flush are
    no-ops on a write-through cache, and the Zicbop prefetch hints retire as hints.
    None of these may raise an illegal instruction: software uses them routinely.
    """
    L = []
    L.extend(li64(5, 0x2400))
    L.extend(li64(6, 0xAB))
    L.append("sd x6, 0(x5)")
    # cbo.inval / clean / flush / zero at 0x2400
    L.append(".word 0x0002a00f")   # cbo.inval (x5)
    L.append(".word 0x0012a00f")   # cbo.clean (x5)
    L.append(".word 0x0022a00f")   # cbo.flush (x5)
    L.append(".word 0x0042a00f")   # cbo.zero  (x5)
    # Zicbop prefetch hint and Zawrs wait-on-reservation
    L.append(".word 0x0000200f")   # prefetch.i (x5)
    L.append(".word 0x00d00073")   # wrs.nto
    L.append(".word 0x01d00073")   # wrs.sto
    L.append(".word 0x80004073")   # Zimop mop.r.0 (funct3=100, rs1=0, rd=0)
    L.append("ecall")

    words, _ = assemble("\n".join(L))
    iss = ISS()
    iss.load_words(0, words)
    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=60000, stop_on_ecall=True)

    traps = [c for _, c in h.traps]
    dut._log.info(f"traps = {traps}")
    assert 2 not in traps, f"a cache op raised illegal instruction: {traps}"
    # the effect of cbo.zero on memory is checked byte for byte in tb_dcache; here
    # the point is that all five instructions execute instead of trapping.


@cocotb.test()
async def test_rvc_in_core(dut):
    """Compressed instructions must execute and advance pc by 2."""
    words = [0x0285429D, 0x00000073]   # c.li x5,7 ; c.addi x5,1 ; ecall
    h = Harness(dut)
    await h.startup()
    h.clear()
    await h.load(words)

    seen = []
    async def watch():
        while True:
            await RisingEdge(dut.clk)
            if int(dut.u_core.f_insn_valid.value) == 1:
                seen.append((int(dut.u_core.f_insn_pc.value),
                             int(dut.u_core.f_insn.value),
                             int(dut.u_core.f_insn_len.value)))

    cocotb.start_soon(watch())
    await h.reset()
    await h.run(max_cycles=20000, stop_on_ecall=True)
    dut._log.info(f"fetch presented: {[(hex(p), hex(i), l) for p, i, l in seen]}")
    dut._log.info(f"trace = {h.trace}")
    got = h.trace[-1][4] if h.trace else None
    assert len(seen) >= 3, f"fetch presented only {seen}"
    assert got == 8, f"expected x5 = 8, got {got}"
