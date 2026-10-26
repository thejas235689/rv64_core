"""
test_plic.py -- self-checking testbench for the four-source PLIC-lite.

Checks priority selection, the enable mask, the priority threshold, the
claim/in-service handshake and completion, all against expected values
computed in the test.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer


class Plic:
    def __init__(self, dut):
        self.d = dut

    async def start(self):
        d = self.d
        d.rst_n.value = 0
        d.src.value = 0
        d.cfg_we.value = 0
        d.cfg_addr.value = 0
        d.cfg_wdata.value = 0
        d.claim.value = 0
        d.complete.value = 0
        d.complete_id.value = 0
        cocotb.start_soon(Clock(d.clk, 10, "ns").start())
        for _ in range(3):
            await RisingEdge(d.clk)
        d.rst_n.value = 1
        await RisingEdge(d.clk)

    async def write(self, addr, value):
        d = self.d
        d.cfg_addr.value = addr
        d.cfg_wdata.value = value
        d.cfg_we.value = 1
        await RisingEdge(d.clk)
        d.cfg_we.value = 0
        await RisingEdge(d.clk)

    async def read(self, addr):
        d = self.d
        d.cfg_addr.value = addr
        await RisingEdge(d.clk)
        await FallingEdge(d.clk)
        return int(d.cfg_rdata.value)

    async def set_src(self, value):
        self.d.src.value = value
        await RisingEdge(self.d.clk)
        await FallingEdge(self.d.clk)

    async def claim_one(self):
        """Assert claim, sample the arbitration result in the same cycle,
        then let the clock edge move the source into the in-service set."""
        d = self.d
        d.claim.value = 1
        await Timer(1, unit="ns")            # let the combinational result settle
        valid = int(d.claim_valid.value)
        cid = int(d.claim_id.value)
        await RisingEdge(d.clk)              # claim is taken here
        d.claim.value = 0
        await RisingEdge(d.clk)
        return cid if valid else None

    async def complete_one(self, cid):
        d = self.d
        d.complete.value = 1
        d.complete_id.value = cid
        await RisingEdge(d.clk)
        d.complete.value = 0
        await RisingEdge(d.clk)


@cocotb.test()
async def test_plic_priority_and_threshold(dut):
    """Highest-priority enabled source above threshold wins; claim/complete cycles."""
    p = Plic(dut)
    await p.start()

    # sources 1..4 at priorities 1,3,2,5
    for i, prio in enumerate([1, 3, 2, 5]):
        await p.write(i, prio)
    await p.write(4, 0b1111)      # enable all four
    await p.write(5, 0)           # threshold 0

    assert int(dut.irq.value) == 0, "irq asserted with no source pending"

    # source 3 pending -> irq, claim gives id 2
    await p.set_src(0b0100)
    assert int(dut.irq.value) == 1, "irq did not assert for source 3"
    cid = await p.claim_one()
    assert cid == 2, f"claimed id {cid}, expected 2 (source 3)"

    # the claimed source is in service: it cannot be claimed again
    cid2 = await p.claim_one()
    assert cid2 is None, f"source re-claimed while in service (id {cid2})"

    # complete it, then it becomes claimable again
    await p.complete_one(2)
    cid3 = await p.claim_one()
    assert cid3 == 2, f"after complete, claim gave {cid3}, expected 2"
    await p.complete_one(2)

    # two sources pending: highest priority (4, prio 5) must win over 1 (prio 1)
    await p.set_src(0b1001)
    cid4 = await p.claim_one()
    assert cid4 == 3, f"claimed {cid4}, expected 3 (highest priority)"
    await p.complete_one(3)
    # source 4 is still pending and still the highest priority, so it is
    # re-claimable; drop it to reach the next-priority source
    await p.set_src(0b0001)
    cid5 = await p.claim_one()
    assert cid5 == 0, f"claimed {cid5}, expected 0 (next priority)"
    await p.complete_one(0)

    # threshold above every priority masks the interrupt
    await p.write(5, 7)
    await p.set_src(0b1111)
    assert int(dut.irq.value) == 0, "irq asserted below threshold"

    # threshold at 4 lets only priority 5 through
    await p.write(5, 4)
    assert int(dut.irq.value) == 1, "irq did not assert above threshold"
    cid6 = await p.claim_one()
    assert cid6 == 3, f"claimed {cid6}, expected 3 above threshold"
    await p.complete_one(3)

    # disabling a source removes it
    await p.write(5, 0)
    await p.write(4, 0b0000)
    await p.set_src(0b1111)
    assert int(dut.irq.value) == 0, "irq asserted with all sources disabled"
    dut._log.info("plic-lite: priority, threshold, claim/complete and enable all correct")


@cocotb.test()
async def test_plic_config_readback(dut):
    """Configuration registers read back what was written."""
    p = Plic(dut)
    await p.start()
    await p.write(0, 5)
    await p.write(1, 2)
    await p.write(4, 0b1010)
    await p.write(5, 3)
    assert await p.read(0) == 5, "priority 0 readback"
    assert await p.read(1) == 2, "priority 1 readback"
    assert await p.read(4) == 0b1010, "enable readback"
    assert await p.read(5) == 3, "threshold readback"
    dut._log.info("plic-lite: configuration readback correct")
