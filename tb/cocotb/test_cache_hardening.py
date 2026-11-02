"""Cache hardening tests, driven through the real core (tb_core_top).

These go deeper than tb/cocotb/test_scenarios.py on the data cache, which the
architecture review called the P1 gap. Every test states its expected result and
checks it three ways where it can: the architectural register value, the cache's
own hit/miss counters, and the contents of the cache line itself (read out of
`u_core.u_dcache` by hierarchy). Checking the line as well as the register is what
separates "the load returned the right number" from "the cache did the right
thing".

The design, measured rather than assumed (rtl/rv64_dcache.sv):
  * WRITE-THROUGH. A store that hits updates the line and always goes to memory.
    A store that misses goes to memory and does NOT allocate. There are no dirty
    lines, so there is no dirty eviction and no writeback to test.
  * DIRECT-MAPPED, 64 lines of one 64-bit beat, index = addr[8:3], tag = addr[63:9].
    The only "eviction" that exists is a same-index conflict, and that is what the
    eviction test below exercises.
  * The cache FSM accepts a request only in D_IDLE (`req_ready = (dst == D_IDLE)`)
    and the LSU issues one memory operation at a time, so at the core level a
    second access can never overlap a refill. Tests that would need two accesses in
    flight say so in their docstring; the block-level suite
    (tb/cocotb/test_dcache_unit.py) is where that is actually checked.

Address map used below (index/tag from the RTL, not guessed):
  0x100  -> index 32, tag 0
  0x400  -> index  0, tag 2
  0x1100 -> index 32, tag 8   (same index as 0x100: the conflict pair)
"""

import cocotb
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from test_core import Harness, cov
from cocotb.triggers import RisingEdge, FallingEdge

NLINES = 64
A = 0x100        # index 32
B = 0x400        # index 0
C = 0x1100       # index 32, different tag from A -> conflicts with A


# --------------------------------------------------------------------- helpers
def _dc(dut):
    return dut.u_core.u_dcache


def idx_of(addr):
    return (addr >> 3) & (NLINES - 1)


def tag_of(addr):
    return (addr >> 9) & ((1 << 55) - 1)


def line(dut, addr):
    """(valid, tag, data) of the line that holds `addr` if the tag matches."""
    c = _dc(dut)
    i = idx_of(addr)
    return int(c.valid_q[i].value), int(c.tag_q[i].value), int(c.data_q[i].value)


def line_holds(dut, addr, want_data):
    """True when the line for `addr` is valid, tagged for `addr`, and holds want_data."""
    v, t, d = line(dut, addr)
    return v == 1 and t == tag_of(addr) and d == want_data


def counters(dut):
    c = _dc(dut)
    return int(c.hit_count.value), int(c.miss_count.value)


def check_regs(h, want, label):
    vals = {t[3]: t[4] for t in h.trace if t[3] is not None}
    for reg, w in want.items():
        got = vals.get(reg)
        assert got == w, f"{label}: x{reg} = {None if got is None else hex(got)}, want {hex(w)}"


def no_illegal(h, label):
    causes = [c for (_, c) in h.traps]
    assert 2 not in causes, f"{label}: illegal-instruction trap at {h.traps[:3]}"


# =========================================================== 1. back-to-back miss
@cocotb.test()
async def test_cache_1_back_to_back_miss_same_line(dut):
    """Two accesses to the same line back to back: the second must hit, not refill.

    Expected: after `sw A` (miss, write-through, no allocate) and `lw A` (miss,
    fill), the immediately following `lw A` is a HIT and returns exactly the byte
    pattern memory holds. Concretely: x6 == x7 == 0x5a, exactly 2 misses and
    1 hit for the three accesses, and line A valid, tagged for A, holding 0x5a.

    A refill that returned stale or partially merged data would show up either in
    x7 or in the line contents; a second miss would show up in miss_count.
    """
    from rv64_asm import assemble
    src = """
        addi x5, x0, 0x5a
        sw   x5, 0x100(x0)     # miss: write-through, no allocate
        lw   x6, 0x100(x0)     # miss: fill
        lw   x7, 0x100(x0)     # must HIT
        ecall
    """
    words, _ = assemble(src)
    h = Harness(dut)
    await h.startup(); h.clear(); await h.load(words); await h.reset()
    await h.run(max_cycles=3000, stop_on_ecall=True)
    no_illegal(h, "back_to_back")
    check_regs(h, {6: 0x5A, 7: 0x5A}, "back_to_back")
    assert [c for (_, c) in h.traps] == [11], f"unexpected traps {h.traps}"
    hits, misses = counters(dut)
    assert (misses, hits) == (2, 1), (
        f"expected 2 misses (store + first load) and 1 hit (second load), "
        f"measured {misses} misses / {hits} hits")
    assert line_holds(dut, A, 0x5A), (
        f"line A after the run: valid/tag/data = {line(dut, A)}, want valid=1 "
        f"tag={tag_of(A):#x} data=0x5a")
    cov("cache.back_to_back_miss_same_line")


# ==================================================== 2. miss / eviction conflict
@cocotb.test()
async def test_cache_2_miss_eviction_index_conflict(dut):
    """A miss to line B that maps to line A's index must evict A, and neither line
    may come back holding the other's data.

    NOT TESTED, and cannot be: "a miss to B while A is being refilled". The dcache
    FSM only accepts a request in D_IDLE, so a second access cannot overlap a fill
    at all; the LSU issues one memory operation at a time. That race is checked at
    the block level instead (test_dcache_unit_no_second_request_during_fill).

    What IS reachable in a direct-mapped, single-way cache is the conflict
    eviction: 0x100 and 0x1100 share index 32. Expected: x7 = 0xaa (A filled),
    x8 = 0xbb (B filled, evicting A), x9 = 0xaa (A re-fills -- it must come from
    memory, not from the line now holding B), x10 = 0xbb (B re-fills). Exactly 6
    misses and 0 hits, because every one of these six accesses is a store or a
    load to a line that is not present.
    """
    from rv64_asm import assemble
    src = """
        addi x5, x0, 0xaa
        addi x6, x0, 0xbb
        li   x10, 0x1100
        sw   x5, 0x100(x0)     # memory[A] = 0xaa          (miss)
        lw   x7, 0x100(x0)     # fill A                     (miss)
        sw   x6, 0(x10)        # memory[C] = 0xbb          (miss)
        lw   x8, 0(x10)        # fill C at index 32, evicting A (miss)
        lw   x9, 0x100(x0)     # A is gone: must MISS and refill 0xaa (miss)
        lw   x11, 0(x10)       # C was evicted by A: must MISS and refill 0xbb (miss)
        ecall
    """
    words, _ = assemble(src)
    h = Harness(dut)
    await h.startup(); h.clear(); await h.load(words); await h.reset()
    await h.run(max_cycles=3000, stop_on_ecall=True)
    no_illegal(h, "eviction")
    check_regs(h, {7: 0xAA, 8: 0xBB, 9: 0xAA, 11: 0xBB}, "eviction")
    hits, misses = counters(dut)
    assert (misses, hits) == (6, 0), (
        f"every access in this program is a store or a load to an absent line, so "
        f"expected 6 misses / 0 hits; measured {misses} misses / {hits} hits -- a hit "
        f"here would mean a line was served with another address's tag")
    # the survivor is C, and it must hold C's data, not A's
    assert line_holds(dut, C, 0xBB), (
        f"line at index 32 after the run: valid/tag/data = {line(dut, C)}, want "
        f"tag={tag_of(C):#x} data=0xbb (C, the last filler)")
    v, t, d = line(dut, A)
    assert not (v == 1 and t == tag_of(A)), (
        f"A must not be present after C evicted it: valid/tag = {v}/{t:#x}")
    cov("cache.miss_eviction_index_conflict")


# ====================================== 3. invalidation / no stale after cbo.inval
@cocotb.test()
async def test_cache_3_invalidation_drops_the_line(dut):
    """cbo.inval must drop the line, and the next access must refill rather than
    answer from the dropped copy.

    Reachability, measured rather than assumed. Two things this test does NOT
    claim to do:

    * "invalidation while a fill is outstanding" is unreachable from software: the
      pipeline is in-order and the LSU is blocking, so no cbo can be issued while
      a load's fill is in flight. The block-level suite drives that case directly
      (test_dcache_unit_invalidate_during_fill).
    * a genuinely stale line cannot be manufactured from this testbench either.
      The first version of this test wrote a new value into the testbench memory
      through the host port and expected the post-inval load to see it. It saw
      0x11, not 0x99, and the cause was measured, not guessed: the D-cache's bus
      sits behind u_l2 AND u_l3 (rtl/riscv_core_top.sv), which the host port does
      not write, so the refill legitimately returned the L2's copy. The host port
      is a testbench artifact, not a second master.

    So the property asserted here is the one that is reachable and that actually
    distinguishes a working invalidation from a broken one: the negative control.
    Before the cbo, an access to A is a HIT; after it, the same access must be a
    MISS and the line must be refilled. Expected: x6 = x7 = x8 = x9 = 0x11, exactly
    3 misses (store, first fill, post-inval refill) and exactly 2 hits (the two
    accesses that were served from the line), the cbo word retires at its pc
    without trapping, and line A ends valid, tagged for A, holding 0x11.

    If cbo.inval did nothing, x8 would hit and the counters would read 2 misses /
    3 hits, so the test fails rather than passing vacuously.
    """
    from rv64_asm import assemble
    # cbo.inval x10,(a0): opcode 0001111, funct3=010, rs2=00000 (inval), rs1=x10.
    # The decoder accepts it (rv64_decoder.sv: funct3==010 -> is_cbo) and the top
    # drives the dcache mgmt port from ex_mem; rv64_asm has no cbo mnemonic, so the
    # word is emitted raw.
    cbo_inval_x10 = (0 << 20) | (10 << 15) | (2 << 12) | (0 << 7) | 0x0F
    src = f"""
        addi x5, x0, 0x11
        sw   x5, 0x100(x0)     # memory[A] = 0x11   (miss)
        lw   x6, 0x100(x0)     # fill A             (miss)
        lw   x7, 0x100(x0)     # control: must HIT
        li   x10, 0x100
cbo:
        .word {cbo_inval_x10:#x}
        lw   x8, 0x100(x0)     # must MISS: the line was dropped
        lw   x9, 0x100(x0)     # must HIT again
        ecall
    """
    words, labels = assemble(src)
    h = Harness(dut)
    await h.startup(); h.clear(); await h.load(words); await h.reset()
    await h.run(max_cycles=3000, stop_on_ecall=True)
    no_illegal(h, "invalidation")
    check_regs(h, {6: 0x11, 7: 0x11, 8: 0x11, 9: 0x11}, "invalidation")

    # the cbo itself must have retired as a real instruction, not trapped or skipped
    cbo_pc = labels["cbo"]
    retired = [t for t in h.trace if t[0] == cbo_pc]
    assert retired, f"the cbo.inval at pc {cbo_pc:#x} never retired"
    assert retired[0][1] == cbo_inval_x10, (
        f"pc {cbo_pc:#x} retired {retired[0][1]:#010x}, want cbo.inval {cbo_inval_x10:#010x}")

    hits, misses = counters(dut)
    assert (misses, hits) == (3, 2), (
        f"expected 3 misses (store, first fill, refill after the invalidation) and 2 "
        f"hits (the control access and the access after the refill); measured "
        f"{misses} misses / {hits} hits. 2 misses / 3 hits means cbo.inval did not "
        f"drop the line")
    assert line_holds(dut, A, 0x11), (
        f"line A after the refill: valid/tag/data = {line(dut, A)}, want "
        f"tag={tag_of(A):#x} data=0x11")
    cov("cache.invalidation_drops_the_line")


# ================================== 4. store-then-load ordering across a miss
@cocotb.test()
async def test_cache_4_store_then_load_across_miss(dut):
    """A store, then a miss to another line, then a load of the stored line must
    return the stored value.

    This is the write-through ordering guarantee, and it is not vacuous: the store
    does NOT allocate, so the later load is a MISS and its fill has to read the
    value back out of memory. Expected: x6 = 0 (line B, untouched), x7 = 0x123
    (line A, refilled from memory), exactly 3 misses and 0 hits, and line A valid
    and holding 0x123. If the store had been lost, buffered past the fill, or the
    fill had returned the pre-store memory contents, x7 would be 0 and the test
    would fail.
    """
    from rv64_asm import assemble
    src = """
        addi x5, x0, 0x123
        sw   x5, 0x100(x0)     # store A: miss, write-through, no allocate
        lw   x6, 0x400(x0)     # miss on a different line, different index
        lw   x7, 0x100(x0)     # A again: miss -> the fill must see the stored value
        ecall
    """
    words, _ = assemble(src)
    h = Harness(dut)
    await h.startup(); h.clear(); await h.load(words); await h.reset()
    await h.run(max_cycles=3000, stop_on_ecall=True)
    no_illegal(h, "store_then_load")
    check_regs(h, {6: 0x0, 7: 0x123}, "store_then_load")
    hits, misses = counters(dut)
    assert (misses, hits) == (3, 0), (
        f"the store does not allocate, so the load of A must miss: expected 3 misses "
        f"/ 0 hits, measured {misses} misses / {hits} hits")
    assert line_holds(dut, A, 0x123), (
        f"line A after the refill: valid/tag/data = {line(dut, A)}, want "
        f"tag={tag_of(A):#x} data=0x123")
    cov("cache.store_then_load_across_miss")


# ================================================== 5. refill ordering (2 misses)
@cocotb.test()
async def test_cache_5_refill_ordering_two_misses(dut):
    """Two refills in sequence must not corrupt either line.

    "Two OUTSTANDING misses" cannot happen in this core: the dcache accepts a
    request only in D_IDLE and the LSU issues one operation at a time, so there is
    never more than one fill in flight, and the two caches have separate memory
    ports today (the arbiter that would merge them is not instantiated -- see
    docs/CACHE_VERIFICATION.md). Refill ordering with genuinely concurrent fills is
    therefore checked on the arbiter topology in the l2sys suite, not here.

    What is reachable and worth asserting: two consecutive fills land in two
    different lines, both stay valid, and each keeps its own data -- i.e. the
    second fill does not install the first fill's address or data. Expected:
    x7 = x9 = 0xa1 (line A, filled then hit), x8 = x10 = 0xb2 (line B, filled then
    hit), 4 misses (2 stores + 2 fills) and exactly 2 hits, with both lines valid
    and holding their own data at the end.
    """
    from rv64_asm import assemble
    src = """
        addi x5, x0, 0xa1
        addi x6, x0, 0xb2
        sw   x5, 0x100(x0)     # memory[A] = 0xa1  (miss)
        sw   x6, 0x400(x0)     # memory[B] = 0xb2  (miss)
        lw   x7, 0x100(x0)     # fill A            (miss)
        lw   x8, 0x400(x0)     # fill B            (miss)
        lw   x9, 0x100(x0)     # HIT A
        lw   x10, 0x400(x0)    # HIT B
        ecall
    """
    words, _ = assemble(src)
    h = Harness(dut)
    await h.startup(); h.clear(); await h.load(words); await h.reset()
    await h.run(max_cycles=3000, stop_on_ecall=True)
    no_illegal(h, "refill_ordering")
    check_regs(h, {7: 0xA1, 8: 0xB2, 9: 0xA1, 10: 0xB2}, "refill_ordering")
    hits, misses = counters(dut)
    assert (misses, hits) == (4, 2), (
        f"expected 4 misses (2 stores + 2 fills) and 2 hits (the two re-reads), "
        f"measured {misses} misses / {hits} hits")
    assert line_holds(dut, A, 0xA1), f"line A: {line(dut, A)}, want data 0xa1"
    assert line_holds(dut, B, 0xB2), f"line B: {line(dut, B)}, want data 0xb2"
    assert idx_of(A) != idx_of(B), "the two lines must not share an index here"
    cov("cache.refill_ordering_two_misses")
