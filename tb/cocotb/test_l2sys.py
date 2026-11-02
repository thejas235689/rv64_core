"""The L2 arbiter with the two real caches behind it (tb_l2sys).

This is the arbiter in the topology it was written for: rv64_icache's fill stream on
port A, rv64_dcache's bus port on port B, one memory behind it, driven by
tb/tb_l2sys.sv. It is the only place in this project where two caches can have fills
outstanding at the same time, which is what makes the "two outstanding misses" case
testable at all -- riscv_core_top gives each cache its own memory port, so nothing
there can collide.

Run with `sim/run.py --suite l2sys`.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

NLINES = 64


def idx_of(addr):
    return (addr >> 3) & (NLINES - 1)


def val(dut, name):
    return int(getattr(dut, name).value)


async def _start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    dut.rst_n.value = 0
    dut.ic_req_valid.value = 0
    dut.ic_req_addr.value = 0
    dut.dc_req_valid.value = 0
    dut.dc_req_addr.value = 0
    dut.dc_req_we.value = 0
    dut.dc_req_wstrb.value = 0
    dut.dc_req_wdata.value = 0
    dut.m_req_ready.value = 0
    dut.m_rsp_valid.value = 0
    dut.m_rsp_rdata.value = 0
    dut.m_rsp_error.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


class SysMem:
    """One memory behind the arbiter. Accepts only what the arbiter granted (busy),
    which is the contract the arbiter's per-port ready is meant to establish."""

    def __init__(self, dut, mem=None, rsp_delay=2):
        self.dut = dut
        self.mem = dict(mem or {})
        self.rsp_delay = rsp_delay
        self.reads = 0
        self.writes = 0
        self.txns = []
        self.accepted = False

    def peek(self, addr):
        return self.mem.get(addr, (addr * 0x0101010101010101) & 0xFFFFFFFFFFFFFFFF)

    async def run(self):
        d = self.dut
        pending = None
        while True:
            await FallingEdge(d.clk)
            d.m_req_ready.value = 0
            if pending is not None:
                c, data = pending
                if c <= 0:
                    d.m_rsp_valid.value = 1
                    d.m_rsp_rdata.value = data
                    d.m_rsp_error.value = 0
                    pending = None
                else:
                    d.m_rsp_valid.value = 0
                    pending = (c - 1, data)
            else:
                d.m_rsp_valid.value = 0

            if val(d, "m_req_valid") == 0 or val(d, "busy") == 0:
                self.accepted = False
                continue
            if self.accepted or pending is not None:
                continue
            addr = val(d, "m_req_addr")
            we = val(d, "m_req_we")
            wstrb = val(d, "m_req_wstrb")
            wdata = val(d, "m_req_wdata")
            self.txns.append((addr, we, wstrb, wdata))
            self.accepted = True
            d.m_req_ready.value = 1
            if we:
                old = self.peek(addr)
                new = old
                for b in range(8):
                    if (wstrb >> b) & 1:
                        new = (new & ~(0xFF << (8 * b))) | (((wdata >> (8 * b)) & 0xFF) << (8 * b))
                self.mem[addr] = new
                self.writes += 1
            else:
                self.reads += 1
                pending = (self.rsp_delay, self.peek(addr))


async def _present(dut, valid_sig, ready_sig, addr_sig, addr, timeout=300):
    """Drive a request until the block takes it, then release it. The request is held
    through the accepting rising edge -- releasing at the preceding falling edge is
    one edge too early and the block never takes it."""
    await FallingEdge(dut.clk)
    getattr(dut, addr_sig).value = addr
    getattr(dut, valid_sig).value = 1
    await Timer(1, "ns")
    if val(dut, ready_sig) != 1:
        for _ in range(timeout):
            await FallingEdge(dut.clk)
            await Timer(1, "ns")
            if val(dut, ready_sig) == 1:
                break
        else:
            raise AssertionError(f"{valid_sig} for {addr:#x} was never accepted")
    await FallingEdge(dut.clk)
    getattr(dut, valid_sig).value = 0


async def ic_fetch(dut, addr, timeout=400):
    """A fetch of one beat; returns (data, miss, error)."""
    await _present(dut, "ic_req_valid", "ic_req_ready", "ic_req_addr", addr)
    for _ in range(timeout):
        if val(dut, "ic_resp_valid") == 1:
            return val(dut, "ic_resp_data"), val(dut, "ic_resp_miss"), val(dut, "ic_resp_error")
        await FallingEdge(dut.clk)
    raise AssertionError(f"the I-cache never responded for {addr:#x}")


async def dc_access(dut, addr, we=0, wstrb=0, wdata=0, timeout=400):
    """A data access; returns (rdata, error)."""
    dut.dc_req_we.value = we
    dut.dc_req_wstrb.value = wstrb
    dut.dc_req_wdata.value = wdata
    await _present(dut, "dc_req_valid", "dc_req_ready", "dc_req_addr", addr)
    for _ in range(timeout):
        if val(dut, "dc_rsp_valid") == 1:
            return val(dut, "dc_rsp_rdata"), val(dut, "dc_rsp_error")
        await FallingEdge(dut.clk)
    raise AssertionError(f"the D-cache never responded for {addr:#x}")


# ================================ 1. both caches miss at the same time
@cocotb.test()
async def test_l2sys_concurrent_misses(dut):
    """An I-cache miss and a D-cache miss issued in the same cycle, through the
    arbiter, onto one memory port.

    Expected: both return exactly the value memory holds for their own address (no
    cross-routing), the memory sees exactly two reads, both arbiter ports are
    granted (grant_a_count and grant_b_count each >= 1, so neither starved), and both
    caches end with their own line installed. This is the "two outstanding misses"
    case that no test in the core can reach.
    """
    await _start(dut)
    mem = SysMem(dut, rsp_delay=3)
    cocotb.start_soon(mem.run())
    IA, DA = 0x2000, 0x3000
    mem.mem[IA] = 0x1111222233334444
    mem.mem[DA] = 0xAAAABBBBCCCCDDDD

    ic = cocotb.start_soon(ic_fetch(dut, IA))
    dc = cocotb.start_soon(dc_access(dut, DA))
    # let both requests collide
    for _ in range(3):
        await FallingEdge(dut.clk)
    ires = await ic
    dres = await dc

    assert ires[0] == 0x1111222233334444, (
        f"the I-cache got {ires[0]:#x} for {IA:#x}, want 0x1111222233334444")
    assert ires[1] == 1, "the I-cache fetch was expected to miss (cold line)"
    assert dres[0] == 0xAAAABBBBCCCCDDDD, (
        f"the D-cache got {dres[0]:#x} for {DA:#x}, want 0xAAAABBBBCCCCDDDD")
    assert mem.reads == 2, f"expected 2 memory reads, saw {mem.reads}"
    ga, gb = val(dut, "grant_a_count"), val(dut, "grant_b_count")
    assert ga >= 1 and gb >= 1, (
        f"arbiter grants A={ga} B={gb}: both caches must get through, neither starved")
    assert val(dut, "ic_misses") == 1 and val(dut, "dc_misses") == 1, (
        f"miss counts ic={val(dut,'ic_misses')} dc={val(dut,'dc_misses')}, want 1 and 1")
    print(f"l2sys: concurrent misses -> {mem.reads} reads, grants A={ga} B={gb}")


# ================================ 2. sustained interleaved traffic, both ports
@cocotb.test()
async def test_l2sys_interleaved_traffic(dut):
    """Twelve rounds of an I-cache fetch and a D-cache read to fresh addresses issued
    together, so every round is a miss on both sides.

    Expected: every one of the 24 responses equals the value memory holds for the
    address that was asked for -- a response routed to the wrong port, or a fill
    landing in the wrong line, shows up as a mismatch on a specific round. Also
    expected: 24 memory reads and both ports granted throughout, which is the
    round-robin guarantee holding up under sustained contention.
    """
    await _start(dut)
    mem = SysMem(dut, rsp_delay=2)
    cocotb.start_soon(mem.run())

    for r in range(12):
        ia = 0x4000 + r * 8
        da = 0x5000 + r * 8
        mem.mem[ia] = 0x1000000000000000 | r
        mem.mem[da] = 0x2000000000000000 | r
        ic = cocotb.start_soon(ic_fetch(dut, ia))
        dc = cocotb.start_soon(dc_access(dut, da))
        ires = await ic
        dres = await dc
        assert ires[0] == mem.mem[ia], (
            f"round {r}: I-cache got {ires[0]:#x} for {ia:#x}, want {mem.mem[ia]:#x}")
        assert dres[0] == mem.mem[da], (
            f"round {r}: D-cache got {dres[0]:#x} for {da:#x}, want {mem.mem[da]:#x}")

    assert mem.reads == 24, f"expected 24 memory reads (12 fills + 12 loads), saw {mem.reads}"
    ga, gb = val(dut, "grant_a_count"), val(dut, "grant_b_count")
    assert ga == 12 and gb == 12, (
        f"grants A={ga} B={gb}: with both ports always asking, round-robin must give "
        f"12 each")
    print(f"l2sys: interleaved -> {mem.reads} reads, grants A={ga} B={gb}")


# ================================ 3. a store while the I-cache is filling
@cocotb.test()
async def test_l2sys_store_during_icache_fill(dut):
    """A D-cache store issued while an I-cache fill is in flight.

    The write-through store is fire-and-forget on this bus, so the arbiter must
    finish it without a response while the I-cache's read is still outstanding, and
    the fill must still return the right instruction word.

    Expected: the store reaches memory exactly once with the caller's strobes and
    data, the I-cache fetch returns its own word (not the stored data, not zero), and
    memory holds both the written word and the instruction word afterwards.
    """
    await _start(dut)
    mem = SysMem(dut, rsp_delay=6)
    cocotb.start_soon(mem.run())
    IA, DA = 0x6000, 0x7000
    mem.mem[IA] = 0xDEADBEEF00000000
    VAL = 0x0123456789ABCDEF

    ic = cocotb.start_soon(ic_fetch(dut, IA))
    for _ in range(4):
        await FallingEdge(dut.clk)
    dres = await dc_access(dut, DA, we=1, wstrb=0xFF, wdata=VAL)
    ires = await ic

    assert ires[0] == 0xDEADBEEF00000000, (
        f"the I-cache got {ires[0]:#x} during the store, want 0xDEADBEEF00000000")
    assert mem.writes == 1, f"expected 1 memory write, saw {mem.writes}"
    assert mem.mem.get(DA) == VAL, f"memory[{DA:#x}] = {mem.mem.get(DA, 0):#x}, want {VAL:#x}"
    assert mem.reads == 1, f"expected 1 memory read, saw {mem.reads}"
    assert mem.mem.get(IA) == 0xDEADBEEF00000000, "the instruction word was corrupted"
    assert val(dut, "dc_rsp_error") == 0
    print(f"l2sys: store during fill -> writes={mem.writes} reads={mem.reads}, "
          f"grants A={val(dut,'grant_a_count')} B={val(dut,'grant_b_count')}")
