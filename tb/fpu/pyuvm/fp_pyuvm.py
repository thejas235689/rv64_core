"""pyuvm testbench for the RV64 binary64 adder.

Mirrors the SystemVerilog UVM environment: driver, monitor, scoreboard, env,
sequence and test. The golden vectors are generated here from Python floats,
which ARE IEEE-754 binary64, so the oracle is independent of the DUT.

Run with cocotb + Icarus:
  MODULE=fp_pyuvm TOPLEVEL=tb_pyuvm TOPMODULE=tb_pyuvm \
  python -m cocotb_tools.runner ... (see run_pyuvm.sh)
"""
import struct
import random
import cocotb
from cocotb.triggers import RisingEdge, Timer
from pyuvm import (uvm_component, uvm_driver, uvm_monitor, uvm_scoreboard,
                   uvm_env, uvm_sequence, uvm_sequencer, uvm_test,
                   uvm_sequence_item, ConfigDB, uvm_root)


# pyuvm 5.0's ConfigDB does not resolve the wildcard path from build_phase, so the
# DUT handle and the vector list are passed as module globals. Less elegant than
# ConfigDB, but it works on every version and removes a silent-failure path.
DUT = None
VECTORS = []


def b64(x: float) -> int:
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def golden_vectors(n_random: int = 300, seed: int = 7):
    """Directed special cases plus random operands, expected values from Python."""
    QNAN = 0x7FF8000000000000
    INF = 0x7FF0000000000000
    NEG_INF = 0xFFF0000000000000
    NEG_ZERO = 0x8000000000000000

    v = [
        (b64(1.0), b64(2.0), 0, b64(3.0), "1+2"),
        (b64(1.5), b64(2.25), 0, b64(3.75), "1.5+2.25"),
        (b64(1.0), b64(1.0), 1, b64(0.0), "1-1=+0"),
        (b64(0.0), b64(0.0), 0, b64(0.0), "+0++0"),
        (NEG_ZERO, NEG_ZERO, 0, NEG_ZERO, "-0+-0=-0"),
        (b64(1.0), NEG_ZERO, 0, b64(1.0), "1+-0=1"),
        (INF, INF, 0, INF, "inf+inf"),
        (INF, NEG_INF, 0, QNAN, "inf+-inf=nan"),
        (QNAN, b64(1.0), 0, QNAN, "nan+1"),
        (b64(1.0), QNAN, 0, QNAN, "1+nan"),
        (b64(1.0), b64(2.0), 1, b64(-1.0), "1-2=-1"),
        (b64(1e308), b64(1e308), 0, INF, "overflow->inf"),
        (b64(5e-324), b64(5e-324), 0, b64(1e-323), "denorm+denorm"),
        (b64(1.0), b64(5e-324), 0, b64(1.0), "1+tiniest"),
        (b64(-1.0), b64(-2.0), 0, b64(-3.0), "neg+neg"),
    ]
    rnd = random.Random(seed)
    for _ in range(n_random):
        a = b64(rnd.uniform(-1e6, 1e6))
        b = b64(rnd.uniform(-1e6, 1e6))
        sub = rnd.randint(0, 1)
        fa = struct.unpack("<d", struct.pack("<Q", a))[0]
        fb = struct.unpack("<d", struct.pack("<Q", b))[0]
        exp = b64(fa - fb) if sub else b64(fa + fb)
        v.append((a, b, sub, exp, "rand"))
    return v


class FpTxn(uvm_sequence_item):
    def __init__(self, name="FpTxn"):
        super().__init__(name)
        self.a = 0
        self.b = 0
        self.sub = 0
        self.exp = 0
        self.got = 0
        self.tag = ""

    def __str__(self):
        return (f"{self.tag}: {self.a:016x} {'-' if self.sub else '+'} "
                f"{self.b:016x} -> {self.got:016x} exp {self.exp:016x}")


class FpDriver(uvm_driver):
    def build_phase(self):
        self.dut = DUT

    async def run_phase(self):
        while True:
            t = await self.seq_item_port.get_next_item()
            self.dut.sub.value = t.sub
            self.dut.a.value = t.a
            self.dut.b.value = t.b
            await RisingEdge(self.dut.clk)
            await Timer(1, "ns")
            self.seq_item_port.item_done()


class FpMonitor(uvm_monitor):
    def build_phase(self):
        self.dut = DUT
        self.ap = None

    async def run_phase(self):
        while True:
            await RisingEdge(self.dut.clk)
            await Timer(1, "ns")
            t = FpTxn("observed")
            t.a = int(self.dut.a.value)
            t.b = int(self.dut.b.value)
            t.sub = int(self.dut.sub.value)
            t.got = int(self.dut.result.value)
            if self.ap is not None:
                self.ap.write(t)


class FpScoreboard(uvm_scoreboard):
    """Compares against the golden table by index -- the monitor cannot know the
    expected value, so the oracle comes from the vector list the sequence drives."""

    def build_phase(self):
        self.vectors = VECTORS
        self.checked = 0
        self.errors = 0
        self.fifo = []

    def write(self, t):
        if self.checked >= len(self.vectors):
            return
        a, b, sub, exp, tag = self.vectors[self.checked]
        self.checked += 1
        if t.got != exp:
            self.errors += 1
            if self.errors <= 6:
                self.logger.error(
                    f"vec{self.checked-1} {tag}: {a:016x} "
                    f"{'-' if sub else '+'} {b:016x} -> "
                    f"got {t.got:016x} expected {exp:016x}")

    def check_phase(self):
        total = len(self.vectors)
        if self.errors:
            self.logger.error(f"checked={self.checked} of {total} errors={self.errors}")
            assert False, f"{self.errors} FP adder mismatches"
        if self.checked != total:
            assert False, f"only {self.checked} of {total} vectors observed"
        self.logger.info(f"checked={self.checked} of {total} errors=0")


class FpEnv(uvm_env):
    def build_phase(self):
        self.seqr = uvm_sequencer("seqr", self)
        self.drv = FpDriver("drv", self)
        self.mon = FpMonitor("mon", self)
        self.scb = FpScoreboard("scb", self)

    def connect_phase(self):
        self.drv.seq_item_port.connect(self.seqr.seq_item_export)
        self.mon.ap = self.scb


class FpGoldenSeq(uvm_sequence):
    def __init__(self, name="FpGoldenSeq"):
        super().__init__(name)
        self.vectors = []

    async def body(self):
        for (a, b, sub, exp, tag) in self.vectors:
            t = FpTxn("t")
            t.a, t.b, t.sub, t.exp, t.tag = a, b, sub, exp, tag
            await self.start_item(t)
            await self.finish_item(t)


class FpGoldenTest(uvm_test):
    def build_phase(self):
        self.env = FpEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        seq = FpGoldenSeq("seq")
        seq.vectors = VECTORS
        await seq.start(self.env.seqr)
        self.drop_objection()


@cocotb.test()
async def fp_pyuvm_test(dut):
    global DUT, VECTORS
    DUT = dut
    VECTORS = golden_vectors()
    await uvm_root().run_test("FpGoldenTest")
