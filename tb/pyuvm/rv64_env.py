"""pyuvm environment for the rv64 core.

The cocotb Harness is reused as the bus-functional model: it already knows how to
load a program, pulse reset, run cycles and retire instructions. pyuvm supplies the
structure around it -- sequence items, a sequencer, a driver and a scoreboard -- so
the same tests exist in both frameworks without duplicating the pin wiggling.

Why this shape: the alternative (a pyuvm driver that drives pins itself) would
re-implement Harness and drift from it. One BFM, two control layers.
"""
import pyuvm
from pyuvm import (uvm_component, uvm_driver, uvm_sequencer, uvm_sequence_item,
                   uvm_analysis_port, uvm_subscriber)


class Rv64Item(uvm_sequence_item):
    """One program to run: assembly source plus expectations."""

    def __init__(self, name="item", src="", checks=None, max_cycles=20000):
        super().__init__(name)
        self.src = src
        self.checks = checks or {}      # reg index -> expected value
        self.max_cycles = max_cycles
        self.result = None              # filled by the driver
        self.traps = []

    def __str__(self):
        return f"Rv64Item({len(self.src.splitlines())} lines, {len(self.checks)} checks)"


class Rv64Driver(uvm_driver):
    """Runs each item on the DUT through the cocotb Harness."""

    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        from rv64_asm import assemble
        while True:
            item = await self.seq_item_port.get_next_item()
            h = self.harness
            words, _ = assemble(item.src)
            h.clear()
            await h.load(words)
            await h.reset()
            await h.run(max_cycles=item.max_cycles, stop_on_ecall=True)
            item.traps = list(h.traps)
            item.result = {t[3]: t[4] for t in h.trace if t[3] is not None}
            self.seq_item_port.item_done()
            self.ap.write(item)


class Rv64Scoreboard(uvm_subscriber):
    # uvm_subscriber provides analysis_export; a plain uvm_component has no TLM endpoint

    """Checks each item's expectations against what the core actually retired."""

    def build_phase(self):
        self.passed = 0
        self.failed = []
        self.checked = 0



    def write(self, item):
        self.checked += 1
        bad = []
        for reg, want in item.checks.items():
            got = item.result.get(reg)
            if got != want:
                bad.append(f"x{reg}: got {got if got is None else hex(got)}, want {hex(want)}")
        illegal = [c for (_, c) in item.traps if c == 2]
        if illegal:
            bad.append(f"illegal-instruction trap at {[hex(p) for p, c in item.traps if c == 2][:3]}")
        if bad:
            self.failed.append((item.get_name(), bad))
        else:
            self.passed += 1


class Rv64Env(uvm_component):
    # set by the cocotb test before the environment is built
    harness = None
    # set at build time so the test can read the verdict without walking the tree
    scoreboard_ref = None

    def build_phase(self):
        self.seqr = uvm_sequencer("seqr", self)
        self.driver = Rv64Driver("driver", self)
        self.scoreboard = Rv64Scoreboard("scoreboard", self)
        # the driver needs the BFM, and it must be attached after the driver exists
        self.driver.harness = Rv64Env.harness
        self.scoreboard.driver = self.driver
        Rv64Env.scoreboard_ref = self.scoreboard

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)
        self.driver.ap.connect(self.scoreboard.analysis_export)
