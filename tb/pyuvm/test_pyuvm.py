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
