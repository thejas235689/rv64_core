"""Block-level D-cache tests: rv64_dcache driven through its own ports.

Why a second suite. tb/cocotb/test_cache_hardening.py drives the cache through the
core, which is the right level for end-to-end data integrity but cannot reach three
things:

  * bus backpressure -- the testbench memory answers every request in one cycle;
  * response timing -- a fill completes when the bus says so, and the core cannot
    hold it off;
  * a second access during a fill, or a cbo during a fill -- the pipeline is
    in-order and the LSU is blocking, so software cannot issue either.

This suite instantiates rv64_dcache directly (toplevel `rv64_dcache`, run with
`sim/run.py --suite dcache`) and models the bus in Python, so those cases are
reachable and checked rather than described.

The design being tested (rtl/rv64_dcache.sv, measured from the RTL):
  * direct-mapped, 64 lines of one 64-bit beat; index = addr[8:3], tag = addr[63:9];
  * write-through; a store hit updates the line and always goes to the bus; a store
    miss goes to the bus and does NOT allocate;
  * one transaction at a time: `req_ready = (dst == D_IDLE)`, and D_FILL waits for
    bus_rsp_valid before anything else is accepted;
  * cbo.inval is honoured in the same always_ff that installs a fill, which is why
    the invalidate-during-fill test below is interesting.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

A = 0x100        # index 32, tag 0
B = 0x400        # index  0, tag 2
C = 0x1100       # index 32, tag 8 -- conflicts with A
D = 0x800        # index  0, tag 4 -- conflicts with B
NLINES = 64


def idx_of(addr):
    return (addr >> 3) & (NLINES - 1)


def tag_of(addr):
    return (addr >> 9) & ((1 << 55) - 1)


def line(dut, addr):
    i = idx_of(addr)
    return (int(dut.valid_q[i].value), int(dut.tag_q[i].value), int(dut.data_q[i].value))


def counters(dut):
    return int(dut.hit_count.value), int(dut.miss_count.value)


async def _start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    dut.rst_n.value = 0
    dut.req_valid.value = 0
    dut.req_addr.value = 0
    dut.req_we.value = 0
    dut.req_wstrb.value = 0
    dut.req_wdata.value = 0
    dut.bus_req_ready.value = 0
    dut.bus_rsp_valid.value = 0
    dut.bus_rsp_rdata.value = 0
    dut.bus_rsp_error.value = 0
    dut.mgmt_valid.value = 0
    dut.mgmt_zero.value = 0
    dut.mgmt_addr.value = 0
    dut.bypass.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


class Bus:
    """A memory behind the cache's bus port.

    rsp_delay    : cycles between the request being accepted and the response
    stall_every  : if non-zero, withhold bus_req_ready for `stall_len` cycles before
                   every acceptance (models a congested bus / a busy L2)
    """

    def __init__(self, dut, rsp_delay=2, stall_every=0, stall_len=3):
        self.dut = dut
        self.mem = {}
        self.rsp_delay = rsp_delay
        self.stall_every = stall_every
        self.stall_len = stall_len
        self.reads = 0
        self.writes = 0
        self.txns = []          # (addr, we, wstrb, wdata) in acceptance order
        self.accepted = False
        self.force_delay = None  # override rsp_delay for the next read
        self.n = 0

    async def run(self):
        d = self.dut
        d.bus_req_ready.value = 0
        d.bus_rsp_valid.value = 0
        pending = None                      # (countdown, data, err)
        while True:
            await FallingEdge(d.clk)
            # ready is a one-cycle pulse: cleared here, raised below only when this
            # cycle accepts a transaction, so the next rising edge samples it.
            d.bus_req_ready.value = 0
            if pending is not None:
                c, data, err = pending
                if c <= 0:
                    d.bus_rsp_valid.value = 1
                    d.bus_rsp_rdata.value = data
                    d.bus_rsp_error.value = err
                    pending = None
                else:
                    d.bus_rsp_valid.value = 0
                    pending = (c - 1, data, err)
            else:
                d.bus_rsp_valid.value = 0

            if int(d.bus_req_valid.value) == 0:
                self.accepted = False
                continue
            if self.accepted or pending is not None:
                continue

            self.n += 1
            if self.stall_every and (self.n % self.stall_every) == 1:
                # withhold ready for stall_len cycles, then accept
                for _ in range(self.stall_len):
                    await FallingEdge(d.clk)
                    if int(d.bus_req_valid.value) == 0:
                        break

            addr = int(d.bus_req_addr.value)
            we = int(d.bus_req_we.value)
            wstrb = int(d.bus_req_wstrb.value)
            wdata = int(d.bus_req_wdata.value)
            self.txns.append((addr, we, wstrb, wdata))
            self.accepted = True
            d.bus_req_ready.value = 1
            if we:
                old = self.mem.get(addr, 0)
                new = old
                for b in range(8):
                    if (wstrb >> b) & 1:
                        new = (new & ~(0xFF << (8 * b))) | (((wdata >> (8 * b)) & 0xFF) << (8 * b))
                self.mem[addr] = new
                self.writes += 1
            else:
                self.reads += 1
                delay = self.rsp_delay if self.force_delay is None else self.force_delay
                pending = (delay, self.mem.get(addr, 0), 0)


async def wait_idle(dut, timeout=200):
    for _ in range(timeout):
        await FallingEdge(dut.clk)
        if int(dut.req_ready.value) == 1:
            return
    raise AssertionError("cache never returned to D_IDLE")


async def access(dut, addr, we=0, wstrb=0, wdata=0, bypass=0, timeout=400):
    """Present one request and return (rdata, error). Drives req_valid for exactly
    the cycle the cache accepts it, which is what req_ready is for."""
    await wait_idle(dut)
    dut.req_valid.value = 1
    dut.req_addr.value = addr
    dut.req_we.value = we
    dut.req_wstrb.value = wstrb
    dut.req_wdata.value = wdata
    dut.bypass.value = bypass
    await FallingEdge(dut.clk)          # the rising edge in between has sampled it
    dut.req_valid.value = 0
    for _ in range(timeout):
        if int(dut.rsp_valid.value) == 1:
            return int(dut.rsp_rdata.value), int(dut.rsp_error.value)
        await FallingEdge(dut.clk)
    raise AssertionError(f"no response for {addr:#x} within {timeout} cycles")


# ============================================== 1. back-to-back miss, same line
@cocotb.test()
async def test_dcache_unit_back_to_back_same_line(dut):
    """Two accesses to the same line: the second must hit and must not re-request.

    Expected: both return 0xdeadbeefcafe1234, exactly ONE read on the bus (the
    second access is a hit, not a refill), hit_count = 1, miss_count = 1, and the
    line valid with that data. A second bus read would mean the cache refilled a
    line it already held.
    """
    await _start(dut)
    bus = Bus(dut, rsp_delay=2)
    cocotb.start_soon(bus.run())
    bus.mem[A] = 0xDEADBEEFCAFE1234

    d1, e1 = await access(dut, A)
    d2, e2 = await access(dut, A)
    assert e1 == 0 and e2 == 0, f"unexpected bus error {e1}/{e2}"
    assert d1 == 0xDEADBEEFCAFE1234, f"first access returned {d1:#x}"
    assert d2 == d1, f"second access returned {d2:#x}, first returned {d1:#x}"
    assert bus.reads == 1, f"expected exactly 1 bus read, saw {bus.reads}"
    assert counters(dut) == (1, 1), f"hits/misses = {counters(dut)}, want (1, 1)"
    v, t, d = line(dut, A)
    assert (v, t, d) == (1, tag_of(A), 0xDEADBEEFCAFE1234), (
        f"line A = valid {v}, tag {t:#x}, data {d:#x}")


# ============================== 2. a second request cannot overlap a refill
@cocotb.test()
async def test_dcache_unit_no_second_request_during_fill(dut):
    """A miss to line B presented while line A's refill is outstanding.

    This is the miss/eviction race the review asked about, tested where it can
    actually be driven. Expected: while the fill of A is outstanding, req_ready is
    LOW on every cycle (so B is never accepted mid-fill), A's response returns A's
    data, B's request is then accepted and returns B's data, A's line is still valid
    and still holds A's data, and the bus saw exactly two reads.
    """
    await _start(dut)
    bus = Bus(dut, rsp_delay=8)      # a wide fill window
    cocotb.start_soon(bus.run())
    bus.mem[A] = 0xAAAA0000AAAA0000
    bus.mem[B] = 0xBBBB0000BBBB0000

    await wait_idle(dut)
    dut.req_valid.value = 1
    dut.req_addr.value = A
    dut.req_we.value = 0
    dut.req_wstrb.value = 0
    dut.req_wdata.value = 0
    await FallingEdge(dut.clk)
    dut.req_valid.value = 0

    # A's fill is now outstanding. Present B for the whole window and check that
    # the cache never claims to accept it.
    assert int(dut.bus_req_valid.value) == 1, "the fill request never reached the bus"
    cycles_checked = 0
    while int(dut.bus_req_valid.value) == 1:
        assert int(dut.req_ready.value) == 0, (
            f"req_ready was asserted while a fill was outstanding (cycle "
            f"{cycles_checked}): the cache would have accepted a second request "
            f"mid-refill")
        dut.req_valid.value = 1
        dut.req_addr.value = B
        await FallingEdge(dut.clk)
        cycles_checked += 1
    assert cycles_checked >= 4, (
        f"only {cycles_checked} fill cycles observed; the window is too narrow for "
        f"this test to mean anything")

    # A's response must arrive with A's data before B's
    d_a = None
    for _ in range(50):
        if int(dut.rsp_valid.value) == 1:
            d_a = int(dut.rsp_rdata.value)
            break
        await FallingEdge(dut.clk)
    assert d_a == 0xAAAA0000AAAA0000, f"the fill of A returned {d_a}"

    dut.req_valid.value = 0
    d_b, _ = await access(dut, B)
    assert d_b == 0xBBBB0000BBBB0000, f"the fill of B returned {d_b:#x}"
    assert bus.reads == 2, f"expected 2 bus reads, saw {bus.reads}"
    v, t, d = line(dut, A)
    assert (v, t, d) == (1, tag_of(A), 0xAAAA0000AAAA0000), (
        f"after B's fill, line A = valid {v}, tag {t:#x}, data {d:#x} -- A must be "
        f"undisturbed by B (different index)")


# ======================= 3. invalidation while a fill is outstanding
@cocotb.test()
async def test_dcache_unit_invalidate_during_fill(dut):
    """cbo.inval for a line whose fill is still outstanding.

    Unreachable from software (in-order pipeline, blocking LSU), so it is driven
    here: start a miss on A, assert mgmt_valid for A's address while the fill is in
    flight, then let the fill complete.

    Expected: the invalidation wins -- the block is dropped, so the line ends
    INVALID and the next access re-reads memory and returns the new value.

    This test found a real bug. On the RTL as published at 84c4e4dc the line ended
    VALID and holding the beat the fill had read, because the always_ff evaluated
    the cbo branch first and the D_FILL branch's `valid_q <= 1` was the later
    assignment, so the install overwrote the invalidation. It failed here with
    "invalidation lost: line A is still valid (tag 0x0, data 0x1111111111111111)",
    and the follow-up load returned that stale beat instead of memory's new value.
    rtl/rv64_dcache.sv now carries `inval_fill_q`, which suppresses the install when
    the block being filled is invalidated; the assertion below is the spec-correct
    one and passes on the fixed RTL. Nothing was relaxed to get here.
    """
    await _start(dut)
    bus = Bus(dut, rsp_delay=8)
    cocotb.start_soon(bus.run())
    bus.mem[A] = 0x1111111111111111

    await wait_idle(dut)
    dut.req_valid.value = 1
    dut.req_addr.value = A
    dut.req_we.value = 0
    dut.req_wstrb.value = 0
    dut.req_wdata.value = 0
    await FallingEdge(dut.clk)
    dut.req_valid.value = 0
    assert int(dut.bus_req_valid.value) == 1, "the fill never reached the bus"

    # the second master changes memory after the fill has read it but before the
    # beat lands: wait for the acceptance so the captured data is provably the old
    # value, otherwise the "stale" assertion below could pass by luck.
    for _ in range(40):
        if bus.reads == 1:
            break
        await FallingEdge(dut.clk)
    assert bus.reads == 1, "the fill was never accepted by the bus model"
    bus.mem[A] = 0x2222222222222222
    # and the block is invalidated while that fill is still outstanding
    dut.mgmt_valid.value = 1
    dut.mgmt_zero.value = 0
    dut.mgmt_addr.value = A
    await FallingEdge(dut.clk)
    dut.mgmt_valid.value = 0

    for _ in range(60):
        if int(dut.rsp_valid.value) == 1:
            break
        await FallingEdge(dut.clk)
    v, t, d = line(dut, A)
    hits0, misses0 = counters(dut)

    # the invalidation must have won: the line must not be valid
    assert v == 0, (
        f"invalidation lost: line A is still valid (tag {t:#x}, data {d:#x}) after "
        f"cbo.inval during its fill -- the fill's install overwrote the invalidation")

    d2, _ = await access(dut, A)
    assert d2 == 0x2222222222222222, (
        f"the access after the invalidation returned {d2:#x}, want the current "
        f"memory contents 0x2222222222222222 -- a stale beat survived")


# ============================================== 4. refill ordering, two fills
@cocotb.test()
async def test_dcache_unit_refill_ordering(dut):
    """Two fills in sequence, under bus backpressure, must not corrupt either line.

    The cache can only have one fill outstanding (checked by test 2), so "two
    outstanding misses" is not a state this block can be in; the ordering question
    that remains is whether the second fill installs the second line correctly and
    leaves the first alone. Driven with a stalling bus and a delayed response so the
    fills take an uneven number of cycles.

    Expected: A then B each return their own data, exactly 2 bus reads, both lines
    valid and holding their own data, 2 misses and 0 hits; then A and B are re-read
    from the cache with 0 further bus reads (2 more hits).
    """
    await _start(dut)
    bus = Bus(dut, rsp_delay=3, stall_every=2, stall_len=3)
    cocotb.start_soon(bus.run())
    bus.mem[A] = 0x0123456789ABCDEF
    bus.mem[B] = 0xFEDCBA9876543210

    da, _ = await access(dut, A)
    db, _ = await access(dut, B)
    assert da == 0x0123456789ABCDEF, f"A returned {da:#x}"
    assert db == 0xFEDCBA9876543210, f"B returned {db:#x}"
    assert bus.reads == 2, f"expected 2 bus reads, saw {bus.reads}"
    assert counters(dut) == (0, 2), f"hits/misses = {counters(dut)}, want (0, 2)"
    for addr, want in ((A, 0x0123456789ABCDEF), (B, 0xFEDCBA9876543210)):
        v, t, d = line(dut, addr)
        assert (v, t, d) == (1, tag_of(addr), want), (
            f"line {addr:#x} = valid {v}, tag {t:#x}, data {d:#x}, want tag "
            f"{tag_of(addr):#x} data {want:#x}")

    da2, _ = await access(dut, A)
    db2, _ = await access(dut, B)
    assert (da2, db2) == (da, db), f"re-reads returned {da2:#x}/{db2:#x}"
    assert bus.reads == 2, f"the re-reads went to the bus ({bus.reads} reads): they must hit"
    assert counters(dut) == (2, 2), f"hits/misses = {counters(dut)}, want (2, 2)"


# ============================ 5. store, then a miss elsewhere, then load back
@cocotb.test()
async def test_dcache_unit_store_then_load_across_miss(dut):
    """A store to A, a miss to B, then a load of A.

    Write-through with no allocate on a store miss, so the load of A is itself a
    miss whose fill must return what the store put in memory.

    Expected: the store appears on the bus exactly once with we=1, addr=A, all
    eight byte strobes and the stored data; no fill is issued for A by the store;
    the load of B is one read; the load of A is another read (miss, not a hit) that
    returns the stored value; 3 misses, 0 hits; and the write reached the bus BEFORE
    the read of A (the ordering that makes the value visible).
    """
    await _start(dut)
    bus = Bus(dut, rsp_delay=2)
    cocotb.start_soon(bus.run())
    bus.mem[B] = 0x00000000000000BB
    VAL = 0x0123456789ABCDEF

    await access(dut, A, we=1, wstrb=0xFF, wdata=VAL)
    assert bus.writes == 1, f"expected 1 bus write, saw {bus.writes}"
    assert bus.txns[-1] == (A, 1, 0xFF, VAL), f"store on the bus was {bus.txns[-1]}"
    assert bus.mem.get(A) == VAL, f"memory after the store = {bus.mem.get(A, 0):#x}"
    v, _, _ = line(dut, A)
    assert v == 0, "a store miss must not allocate, but line A is valid"

    db, _ = await access(dut, B)
    assert db == 0x00000000000000BB, f"B returned {db:#x}"

    da, _ = await access(dut, A)
    assert da == VAL, (
        f"the load of A after the miss to B returned {da:#x}, want the stored value "
        f"{VAL:#x} -- write-through ordering or the fill data is wrong")
    assert bus.reads == 2, f"expected 2 bus reads (B and A), saw {bus.reads}"
    assert [t[1] for t in bus.txns] == [1, 0, 0], (
        f"bus order must be write, read B, read A; got {[(hex(t[0]), t[1]) for t in bus.txns]}")
    assert counters(dut) == (0, 3), f"hits/misses = {counters(dut)}, want (0, 3)"
