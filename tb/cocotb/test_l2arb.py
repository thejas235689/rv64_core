"""Block-level arbitration tests for rv64_l2arb.

The arbiter was orphaned -- rtl/riscv_core_top.sv never instantiates it -- and the
only test that existed for it, tb/tb_l2arb.sv, is a plain Verilog testbench that no
regression list ran. This module drives the arbiter's ports directly (toplevel
`rv64_l2arb`, `sim/run.py --suite l2arb`) with a memory model in Python, so grant
policy, response routing and the held-grant rule are all checked from outside.

What the RTL promises (rtl/rv64_l2arb.sv):
  * round-robin on grant, and the grant is HELD until the response returns;
  * per-port ready, so under contention exactly one port is told it was taken;
  * the response routes to the port that owns the transaction, not the one asking
    now;
  * a write is fire-and-forget: the transaction ends at issue, because this bus
    sends no write response.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

PORTS = ("a", "b")


def sig(dut, name):
    return getattr(dut, name)


def val(dut, name):
    return int(getattr(dut, name).value)


async def _start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    dut.rst_n.value = 0
    for p in PORTS:
        sig(dut, f"{p}_req_valid").value = 0
        sig(dut, f"{p}_req_addr").value = 0
        sig(dut, f"{p}_req_we").value = 0
        sig(dut, f"{p}_req_wstrb").value = 0
        sig(dut, f"{p}_req_wdata").value = 0
    dut.l2_req_ready.value = 0
    dut.rsp_valid.value = 0
    dut.rsp_rdata.value = 0
    dut.rsp_error.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


class Mem:
    """Memory behind the arbiter. `rsp_delay` cycles between the request being
    accepted and the response landing; `accept_delay` withholds l2_req_ready."""

    def __init__(self, dut, rsp_delay=2, accept_delay=0):
        self.dut = dut
        self.mem = {}
        self.rsp_delay = rsp_delay
        self.accept_delay = accept_delay
        self.reads = 0
        self.writes = 0
        self.txns = []          # (addr, we, wstrb, wdata) in acceptance order
        self.accepted = False

    async def run(self):
        d = self.dut
        pending = None
        while True:
            await FallingEdge(d.clk)
            d.l2_req_ready.value = 0
            if pending is not None:
                c, data = pending
                if c <= 0:
                    d.rsp_valid.value = 1
                    d.rsp_rdata.value = data
                    d.rsp_error.value = 0
                    pending = None
                else:
                    d.rsp_valid.value = 0
                    pending = (c - 1, data)
            else:
                d.rsp_valid.value = 0

            if val(d, "req_valid") == 0 or val(d, "busy") == 0:
                self.accepted = False
                continue
            if self.accepted or pending is not None:
                continue
            for _ in range(self.accept_delay):
                await FallingEdge(d.clk)
                if val(d, "req_valid") == 0:
                    break
            addr = val(d, "req_addr")
            we = val(d, "req_we")
            wstrb = val(d, "req_wstrb")
            wdata = val(d, "req_wdata")
            self.txns.append((addr, we, wstrb, wdata))
            self.accepted = True
            d.l2_req_ready.value = 1
            if we:
                self.mem[addr] = wdata
                self.writes += 1
            else:
                self.reads += 1
                # like tb/tb_l2arb.sv: an unwritten address echoes addr+0x1000, so a
                # response can be traced back to the request that caused it
                pending = (self.rsp_delay, self.mem.get(addr, addr + 0x1000))


async def issue(dut, p, addr, we=0, wstrb=0, wdata=0, timeout=300):
    """Present a request on port `p` and hold it until that port is granted.
    Returns once the request has been dropped."""
    await FallingEdge(dut.clk)           # align: drive just after a falling edge
    sig(dut, f"{p}_req_addr").value = addr
    sig(dut, f"{p}_req_we").value = we
    sig(dut, f"{p}_req_wstrb").value = wstrb
    sig(dut, f"{p}_req_wdata").value = wdata
    sig(dut, f"{p}_req_valid").value = 1
    await Timer(1, "ns")                 # combinational ready settles
    if val(dut, f"{p}_req_ready") != 1:
        for _ in range(timeout):
            await FallingEdge(dut.clk)
            await Timer(1, "ns")
            if val(dut, f"{p}_req_ready") == 1:
                break
        else:
            raise AssertionError(f"port {p} was never granted {addr:#x}")
    await FallingEdge(dut.clk)           # the granting rising edge has passed
    sig(dut, f"{p}_req_valid").value = 0


async def read(dut, p, addr, timeout=300):
    """A read on port `p`; returns the data that came back on that port."""
    await issue(dut, p, addr)
    for _ in range(timeout):
        if val(dut, f"{p}_rsp_valid") == 1:
            return val(dut, f"{p}_rsp_rdata")
        await FallingEdge(dut.clk)
    raise AssertionError(f"port {p} never saw a response for {addr:#x}")


# ============================================ 1. a lone request, either port
@cocotb.test()
async def test_l2arb_lone_request_routing(dut):
    """One request on A, then one on B, with the other port idle.

    Expected: each port gets exactly its own response (memory echoes addr+0x1000),
    the idle port sees nothing, and the grant counters count one each.
    """
    await _start(dut)
    mem = Mem(dut, rsp_delay=2)
    cocotb.start_soon(mem.run())

    d = await read(dut, "a", 0x100)
    assert d == 0x1100, f"A got {d:#x}, want 0x1100 (its own address echoed)"
    assert val(dut, "b_rsp_valid") == 0, "B saw a response for a request it never made"

    d = await read(dut, "b", 0x200)
    assert d == 0x1200, f"B got {d:#x}, want 0x1200"
    assert mem.reads == 2, f"expected 2 bus reads, saw {mem.reads}"
    assert val(dut, "grant_a_count") == 1, f"grant_a_count = {val(dut,'grant_a_count')}"
    assert val(dut, "grant_b_count") == 1, f"grant_b_count = {val(dut,'grant_b_count')}"


# ============================================ 2. exactly one ready in contention
@cocotb.test()
async def test_l2arb_one_ready_under_contention(dut):
    """Both ports request in the same cycle: exactly one must be told it was taken.

    Expected: a_req_ready XOR b_req_ready is 1 while both request and the arbiter is
    idle. If both were told ready, the loser would drop a request that was never
    granted and wait forever -- the failure mode the RTL's comment describes.
    """
    await _start(dut)
    mem = Mem(dut, rsp_delay=4)
    cocotb.start_soon(mem.run())

    assert val(dut, "busy") == 0, "arbiter must be idle for this test"
    sig(dut, "a_req_valid").value = 1
    sig(dut, "a_req_addr").value = 0x300
    sig(dut, "b_req_valid").value = 1
    sig(dut, "b_req_addr").value = 0x400
    await Timer(1, "ns")
    ra, rb = val(dut, "a_req_ready"), val(dut, "b_req_ready")
    assert ra + rb == 1, f"a_req_ready={ra} b_req_ready={rb}: exactly one port must be ready"
    assert (ra ^ rb) == 1, f"a_req_ready={ra} b_req_ready={rb}"

    # drop the loser's request as its own ready would have told it to, keep the winner
    winner = "a" if ra else "b"
    loser = "b" if ra else "a"
    sig(dut, f"{loser}_req_valid").value = 0
    # the winner must stay up THROUGH the granting rising edge; dropping it at the
    # next falling edge is one edge too early and the arbiter never grants it
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    sig(dut, f"{winner}_req_valid").value = 0

    got = None
    for _i in range(60):
        if val(dut, f"{winner}_rsp_valid") == 1:
            got = val(dut, f"{winner}_rsp_rdata")
            break
        await FallingEdge(dut.clk)
    assert got is not None, f"the granted port {winner} never got its response"
    want = 0x1300 if winner == "a" else 0x1400
    assert got == want, f"{winner} got {got:#x}, want {want:#x}"
    # the loser's request was dropped on purpose, so it must not be answered
    assert val(dut, f"{loser}_rsp_valid") == 0, f"{loser} was answered for a request it dropped"


# ==================================== 3. the grant is held until the response
@cocotb.test()
async def test_l2arb_grant_held_until_response(dut):
    """While a transaction is in flight the arbiter must not switch ports.

    Expected: from the grant until the response, `busy` stays 1, the address
    presented to memory stays A's, and B is never told its request was taken even
    though B is asking the whole time. The response then goes to A. Afterwards B is
    served normally.
    """
    await _start(dut)
    mem = Mem(dut, rsp_delay=10)
    cocotb.start_soon(mem.run())

    sig(dut, "a_req_valid").value = 1
    sig(dut, "a_req_addr").value = 0x500
    for _ in range(20):
        await FallingEdge(dut.clk)
        if val(dut, "busy") == 1:
            break
    else:
        raise AssertionError("the arbiter never became busy: A's request was not granted")
    sig(dut, "a_req_valid").value = 0

    seen = 0
    while val(dut, "busy") == 1:
        # B asks for the whole flight
        sig(dut, "b_req_valid").value = 1
        sig(dut, "b_req_addr").value = 0x600
        await Timer(1, "ns")
        assert val(dut, "b_req_ready") == 0, (
            f"B was told ready while A's transaction was in flight (cycle {seen})")
        assert val(dut, "grant_a") == 1, "the owner changed mid-transaction"
        assert val(dut, "req_addr") == 0x500, (
            f"the address on the bus changed to {val(dut,'req_addr'):#x} mid-transaction")
        await FallingEdge(dut.clk)
        seen += 1
    assert seen >= 5, f"only {seen} in-flight cycles observed; the window is too narrow"

    got = None
    for _ in range(40):
        if val(dut, "a_rsp_valid") == 1:
            got = val(dut, "a_rsp_rdata")
            break
        await FallingEdge(dut.clk)
    assert got == 0x1500, f"A got {got if got is None else hex(got)}, want 0x1500"

    # B was asking for the whole flight, so the arbiter grants it as soon as A's
    # transaction ends: keep the request up through that grant, then take its response
    await FallingEdge(dut.clk)
    sig(dut, "b_req_valid").value = 0
    got_b = None
    for _ in range(60):
        if val(dut, "b_rsp_valid") == 1:
            got_b = val(dut, "b_rsp_rdata")
            break
        await FallingEdge(dut.clk)
    assert got_b == 0x1600, (
        f"B got {got_b if got_b is None else hex(got_b)} after the flight, want 0x1600")


# ================================================= 4. round-robin, no starvation
@cocotb.test()
async def test_l2arb_round_robin_fairness(dut):
    """Both ports request continuously for 8 transactions.

    Expected: the grants alternate A,B,A,B,... -- round-robin, not fixed priority --
    so neither port starves, each port gets exactly 4 grants, and every response
    carries the right address. A fixed-priority arbiter would give B zero.
    """
    await _start(dut)
    mem = Mem(dut, rsp_delay=2)
    cocotb.start_soon(mem.run())

    order = []
    for i in range(8):
        sig(dut, "a_req_valid").value = 1
        sig(dut, "a_req_addr").value = 0x1000 + i * 8
        sig(dut, "b_req_valid").value = 1
        sig(dut, "b_req_addr").value = 0x2000 + i * 8
        for _ in range(20):
            await FallingEdge(dut.clk)
            if val(dut, "busy") == 1:
                break
        else:
            raise AssertionError(f"iteration {i}: neither port was granted")
        order.append("a" if val(dut, "grant_a") else "b")
        sig(dut, "a_req_valid").value = 0
        sig(dut, "b_req_valid").value = 0
        # let the transaction drain
        for _ in range(60):
            if val(dut, "busy") == 0:
                break
            await FallingEdge(dut.clk)
        await FallingEdge(dut.clk)

    assert order == ["a", "b"] * 4, f"grant order was {order}, want alternating a,b,a,b,..."
    ga, gb = val(dut, "grant_a_count"), val(dut, "grant_b_count")
    assert ga == 4 and gb == 4, f"grants A={ga} B={gb}, want 4 and 4"
    assert mem.reads == 8, f"expected 8 bus reads, saw {mem.reads}"


# ======================================== 5. a write ends at issue, no response
@cocotb.test()
async def test_l2arb_write_fire_and_forget(dut):
    """A write must reach the bus once and must not wait for a response.

    Expected: the write appears on the bus exactly once with we=1 and the caller's
    strobes and data, the arbiter goes idle by itself (no response is coming on this
    bus), the writing port sees no response, and the next read on the other port is
    served normally. A write that waited for a response would hang here.
    """
    await _start(dut)
    mem = Mem(dut, rsp_delay=2)
    cocotb.start_soon(mem.run())

    await issue(dut, "b", 0x700, we=1, wstrb=0xFF, wdata=0x0123456789ABCDEF)
    for _ in range(40):
        if val(dut, "busy") == 0:
            break
        await FallingEdge(dut.clk)
    assert val(dut, "busy") == 0, "the write did not complete: the arbiter is still busy"
    assert mem.writes == 1, f"expected 1 bus write, saw {mem.writes}"
    assert mem.txns[-1] == (0x700, 1, 0xFF, 0x0123456789ABCDEF), (
        f"the write on the bus was {mem.txns[-1]}")
    assert val(dut, "b_rsp_valid") == 0, "a write must not produce a response"
    assert mem.mem.get(0x700) == 0x0123456789ABCDEF, "the write did not land in memory"

    d = await read(dut, "a", 0x700)
    assert d == 0x0123456789ABCDEF, (
        f"reading back through the other port returned {d:#x}, want the written value")
    assert mem.txns[-1] == (0x700, 0, 0, 0), f"the read-back was not on the bus: {mem.txns[-1]}"


# ============================ 6. one read is accepted exactly once
@cocotb.test()
async def test_l2arb_no_duplicate_issue(dut):
    """One logical read must be taken by the memory exactly once.

    While busy_q is low the arbiter forwards the live requester inputs:

        req_valid = a_req_valid ? 1 : b_req_valid

    so the request is visible to the memory before any grant exists. That looks
    like a duplicate-transaction hazard, and the first version of this test
    asserted two acceptances because of it. Measurement said otherwise: with a
    memory whose ready is combinational (`l2_req_ready = req_valid`, the same shape
    tb/tb_core_top.sv uses) the read is accepted exactly ONCE, in the same cycle the
    arbiter becomes busy, because the arbiter samples l2_req_ready only while
    `busy_q && !issued_q` and then drops req_valid. So the pre-grant presentation is
    harmless, and the assertion below is the invariant that matters: no duplicate.

    Expected: req_valid is high before the grant (asserted, so a change to that
    passthrough is noticed), and exactly one acceptance -- no second transaction for
    the same read, in either the idle or the busy window.
    """
    await _start(dut)

    accepts = []
    stop = False

    async def eager_mem():
        d = dut
        d.l2_req_ready.value = 0
        while not stop:
            await FallingEdge(d.clk)
            ready = 1 if val(d, "req_valid") else 0
            d.l2_req_ready.value = ready
            if ready:
                accepts.append((val(d, "req_addr"), val(d, "busy")))
            if accepts and val(d, "busy") == 0 and val(d, "req_valid") == 0:
                d.rsp_valid.value = 1
                d.rsp_rdata.value = accepts[-1][0] + 0x1000
            else:
                d.rsp_valid.value = 0

    cocotb.start_soon(eager_mem())
    await FallingEdge(dut.clk)

    sig(dut, "a_req_valid").value = 1
    sig(dut, "a_req_addr").value = 0x900
    await Timer(1, "ns")
    assert val(dut, "busy") == 0, "arbiter should still be idle here"
    assert val(dut, "req_valid") == 1, (
        "req_valid is expected to be presented before the grant; if the RTL is "
        "changed to gate it on busy_q this expectation must be updated")

    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    sig(dut, "a_req_valid").value = 0
    for _ in range(40):
        await FallingEdge(dut.clk)
        if val(dut, "busy") == 0:
            break
    stop = True

    print(f"l2arb: one read -> {len(accepts)} acceptance(s), busy at accept "
          f"{[b for (_, b) in accepts]}")
    assert len(accepts) == 1, (
        f"one read was accepted {len(accepts)} times (busy at each: "
        f"{[b for (_, b) in accepts]}); the arbiter must not issue the same "
        f"transaction twice")
    assert accepts[0][0] == 0x900, f"the accepted address was {accepts[0][0]:#x}"
    assert accepts[0][1] == 1, (
        "the acceptance did not coincide with the grant: the memory took the request "
        "in the pre-grant window, which would leave the arbiter waiting")
