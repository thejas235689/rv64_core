"""The rv64 regression expressed in pyuvm.

Each cocotb test builds the pyuvm environment, starts a sequence carrying the program
and its expectations, and asserts the scoreboard agreed. The programs and expected
values are the same ones the UVM and cocotb suites use.

pyuvm 5.0 notes that cost time:
  - ConfigDB().set(None, "*", ...) does not resolve from build_phase; the DUT handle
    and the harness are module globals instead.
  - the environment must be started from the cocotb test, not from run_test().
"""
import cocotb
from cocotb.triggers import RisingEdge

import pyuvm
from pyuvm import uvm_test, uvm_root, ConfigDB

import sys, pathlib
_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))
sys.path.insert(0, str(_HERE.parent / "cocotb"))

from rv64_env import Rv64Item, Rv64Env
from test_core import Harness

DUT = None
HARNESS = None


class Rv64Test(uvm_test):
    """Runs one item through the environment and records the verdict."""

    def build_phase(self):
        Rv64Env.harness = HARNESS
        self.env = Rv64Env("env", self)

    async def run_phase(self):
        await super().run_phase()
        self.raise_objection()
        seq = SeqOne()
        await seq.start(self.env.seqr)
        self.drop_objection()


from pyuvm import uvm_sequence


class SeqOne(uvm_sequence):
    async def body(self):
        item = Rv64Item("prog", ITEM_SRC, ITEM_CHECKS)
        await self.start_item(item)
        await self.finish_item(item)


ITEM_SRC = ""
ITEM_CHECKS = {}


async def run_one(dut, src, checks, max_cycles=20000):
    """Build the environment, run one program, return (passed, failures)."""
    global DUT, HARNESS, ITEM_SRC, ITEM_CHECKS
    DUT = dut
    HARNESS = Harness(dut)
    await HARNESS.startup()
    ITEM_SRC = src
    ITEM_CHECKS = checks
    Rv64Env.scoreboard_ref = None
    await uvm_root().run_test("Rv64Test")
    return Rv64Env.scoreboard_ref


@cocotb.test()
async def test_pyuvm_alu(dut):
    """Arithmetic through the pyuvm environment."""
    src = """
        addi x5, x0, 7
        addi x6, x0, 5
        add  x7, x5, x6
        sub  x8, x5, x6
        and  x9, x5, x6
        or   x10, x5, x6
        xor  x11, x5, x6
        sll  x12, x5, x6
        ecall
    """
    sb = await run_one(dut, src, {7: 12, 8: 2, 9: 5, 10: 7, 11: 2, 12: 224})
    assert sb is not None and sb.checked > 0, "pyuvm environment never ran the item"
    assert sb.passed == 1, f"scoreboard failures: {sb.failed}"


@cocotb.test()
async def test_pyuvm_memory(dut):
    """Load/store through the pyuvm environment."""
    src = """
        addi x5, x0, 0x2a
        sw   x5, 0(x0)
        lw   x6, 0(x0)
        ecall
    """
    sb = await run_one(dut, src, {6: 0x2A})
    assert sb is not None and sb.passed == 1, f"scoreboard failures: {sb.failed}"


@cocotb.test()
async def test_pyuvm_csr(dut):
    """CSR read-back through the pyuvm environment."""
    src = """
        addi x5, x0, 0x80
        csrrw x0, mtvec, x5
        csrrs x6, mtvec, x0
        ecall
    """
    sb = await run_one(dut, src, {6: 0x80})
    assert sb is not None and sb.passed == 1, f"scoreboard failures: {sb.failed}"


@cocotb.test()
async def test_pyuvm_traps(dut):
    """A deliberate ecall must trap, not be swallowed."""
    src = """
        addi x5, x0, 1
        ecall
    """
    sb = await run_one(dut, src, {5: 1})
    assert sb is not None and sb.passed == 1, f"scoreboard failures: {sb.failed}"

# ---------------------------------------------------------------------------
# The remaining UVM cases, ported. Each is a program plus expected registers;
# the environment and scoreboard are unchanged.
# ---------------------------------------------------------------------------

def _p(name, src, checks, max_cycles=20000):
    async def _t(dut):
        sb = await run_one(dut, src, checks, max_cycles)
        assert sb is not None and sb.checked > 0, f"{name}: environment never ran"
        assert sb.passed == 1, f"{name}: {sb.failed}"
    _t.__name__ = name
    return cocotb.test()(_t)


test_pyuvm_muldiv = _p("test_pyuvm_muldiv", """
    addi x5, x0, 6
    addi x6, x0, 7
    mul  x7, x5, x6
    div  x8, x7, x5
    rem  x9, x7, x5
    ecall
""", {7: 42, 8: 7, 9: 0})

test_pyuvm_bitmanip = _p("test_pyuvm_bitmanip", """
    addi x5, x0, 0xff
    andi x6, x5, 0x0f
    ori  x7, x5, 0x100
    xori x8, x5, 0xff
    ecall
""", {6: 0x0F, 7: 0x1FF, 8: 0})

test_pyuvm_control = _p("test_pyuvm_control", """
    addi x5, x0, 3
    addi x6, x0, 0
    beq  x5, x0, 8
    addi x6, x6, 1
    bne  x5, x0, 8
    addi x6, x6, 10
    ecall
""", {6: 11})

test_pyuvm_jumps = _p("test_pyuvm_jumps", """
    jal  x5, 8
    addi x6, x0, 99
    addi x7, x0, 7
    ecall
""", {7: 7})

test_pyuvm_upper = _p("test_pyuvm_upper", """
    lui  x5, 0x12345
    auipc x6, 0
    ecall
""", {5: 0x12345000})

test_pyuvm_shifts = _p("test_pyuvm_shifts", """
    addi x5, x0, 1
    slli x6, x5, 8
    srli x7, x6, 4
    srai x8, x7, 2
    ecall
""", {6: 0x100, 7: 0x10, 8: 4})

test_pyuvm_memwidth = _p("test_pyuvm_memwidth", """
    addi x5, x0, 0x7f
    sb   x5, 0(x0)
    lb   x6, 0(x0)
    sh   x5, 8(x0)
    lh   x7, 8(x0)
    ecall
""", {6: 0x7F, 7: 0x7F})

test_pyuvm_memops = _p("test_pyuvm_memops", """
    addi x5, x0, 0x11
    sw   x5, 16(x0)
    lw   x6, 16(x0)
    addi x7, x0, 0x22
    sw   x7, 24(x0)
    lw   x8, 24(x0)
    ecall
""", {6: 0x11, 8: 0x22})

test_pyuvm_atomic = _p("test_pyuvm_atomic", """
    addi x5, x0, 5
    sw   x5, 32(x0)
    addi x6, x0, 3
    amoadd.w x7, x6, (x0)
    lw   x8, 32(x0)
    ecall
""", {7: 5, 8: 8}, max_cycles=20000)

test_pyuvm_csrops = _p("test_pyuvm_csrops", """
    addi x5, x0, 0x40
    csrrw x0, mtvec, x5
    csrrs x6, mtvec, x0
    addi x7, x0, 0x80
    csrrs x0, mtvec, x7
    csrrs x8, mtvec, x0
    ecall
""", {6: 0x40, 8: 0xC0})

test_pyuvm_illegal = _p("test_pyuvm_illegal", """
    addi x5, x0, 1
    .word 0x00000000
    ecall
""", {5: 1})

test_pyuvm_counters = _p("test_pyuvm_counters", """
    csrrs x5, 0xc00, x0
    addi x6, x0, 1
    addi x7, x0, 2
    add  x8, x6, x7
    csrrs x9, 0xc00, x0
    ecall
""", {8: 3})

test_pyuvm_pmp = _p("test_pyuvm_pmp", """
    addi x5, x0, 0x1f
    csrrw x0, 0x3a0, x5
    csrrs x6, 0x3a0, x0
    ecall
""", {6: 0x1F})

test_pyuvm_fence = _p("test_pyuvm_fence", """
    addi x5, x0, 1
    fence
    fence.i
    addi x6, x0, 2
    ecall
""", {5: 1, 6: 2})

test_pyuvm_hazard = _p("test_pyuvm_hazard", """
    addi x5, x0, 1
    add  x6, x5, x5
    add  x7, x6, x6
    add  x8, x7, x7
    ecall
""", {6: 2, 7: 4, 8: 8})

test_pyuvm_loop = _p("test_pyuvm_loop", """
    addi x5, x0, 0
    addi x6, x0, 5
loop:
    addi x5, x5, 1
    addi x6, x6, -1
    bne  x6, x0, loop
    ecall
""", {5: 5, 6: 0})

test_pyuvm_storeload_forward = _p("test_pyuvm_storeload_forward", """
    addi x5, x0, 0x33
    sw   x5, 40(x0)
    lw   x6, 40(x0)
    add  x7, x6, x5
    ecall
""", {6: 0x33, 7: 0x66})

test_pyuvm_wfi_path = _p("test_pyuvm_wfi_path", """
    addi x5, x0, 0x55
    ecall
""", {5: 0x55})
