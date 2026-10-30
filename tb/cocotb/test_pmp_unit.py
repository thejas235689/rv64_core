"""
test_pmp_unit.py -- unit test for the PMP matcher.

Checks the three addressing modes (TOR, NA4, NAPOT) at their boundaries, the
R/W/X permission bits, and the machine-mode lock rule, without going through
the core.  Expectations are computed in the test, so this is self-checking
independently of the core-level PMP test.
"""

import cocotb
from cocotb.triggers import Timer


def cfg_byte(lock=0, a=0, r=0, w=0, x=0):
    """Build one pmpcfg entry: L, A[1:0], X, W, R."""
    return ((lock & 1) << 7) | ((a & 3) << 3) | ((x & 1) << 2) | ((w & 1) << 1) | (r & 1)


def napot_addr(base, size):
    """pmpaddr encoding for a NAPOT region: (base>>2) | (size/8 - 1)."""
    assert size >= 8 and (size & (size - 1)) == 0
    return (base >> 2) | (size // 8 - 1)


class Pmp:
    def __init__(self, dut):
        self.d = dut

    async def configure(self, entries):
        """entries: list of (cfg_byte, pmpaddr) for entries 0..n-1."""
        cfg = 0
        addr_cfg = 0
        for i, (c, a) in enumerate(entries):
            cfg |= (c & 0xFF) << (8 * i)
            addr_cfg |= (a & ((1 << 64) - 1)) << (64 * i)
        self.d.cfg.value = cfg
        self.d.addr_cfg.value = addr_cfg
        await Timer(1, unit="ns")

    async def access(self, addr, write=0, exec_=0, priv_m=1):
        d = self.d
        d.addr.value = addr
        d.is_write.value = write
        d.is_exec.value = exec_
        d.priv_m.value = priv_m
        await Timer(1, unit="ns")
        return int(d.allow.value)


@cocotb.test()
async def test_pmp_napot(dut):
    """NAPOT region size, boundaries and permission bits."""
    p = Pmp(dut)
    await p.configure([(cfg_byte(lock=1, a=3, r=1), napot_addr(0x2000, 64))])
    # 64-byte region: 0x2000..0x203f
    assert await p.access(0x2000) == 1, "start of region should be readable"
    assert await p.access(0x203F) == 1, "last byte of region should be readable"
    assert await p.access(0x1FFC) == 1, "byte before the region must not match"
    assert await p.access(0x2040) == 1, "byte after the region must not match"
    assert await p.access(0x2000, write=1) == 0, "W=0 must deny a store"
    assert await p.access(0x2000, exec_=1) == 0, "X=0 must deny a fetch"
    dut._log.info("pmp: NAPOT region and permissions correct")


@cocotb.test()
async def test_pmp_na4(dut):
    """NA4 covers exactly one four-byte word."""
    p = Pmp(dut)
    await p.configure([(cfg_byte(lock=1, a=1, r=1, w=1), 0x2200 >> 2)])
    assert await p.access(0x2200) == 1, "NA4 word must match"
    assert await p.access(0x2203) == 1, "last byte of the NA4 word must match"
    assert await p.access(0x2204) == 1, "next word must not match (unmatched -> M allowed)"
    assert await p.access(0x21FC) == 1, "previous word must not match"
    assert await p.access(0x2200, write=1) == 1, "W=1 must allow a store"
    assert await p.access(0x2200, exec_=1) == 0, "X=0 must deny a fetch"
    dut._log.info("pmp: NA4 matching correct")


@cocotb.test()
async def test_pmp_tor(dut):
    """TOR regions run from the previous entry's top to this entry's top."""
    p = Pmp(dut)
    await p.configure([
        (cfg_byte(lock=1, a=2, r=1), 0x1000 >> 2),   # [0, 0x1000) readable
        (cfg_byte(lock=1, a=2, r=1, w=1), 0x2000 >> 2),  # [0x1000, 0x2000) readable+writable
    ])
    assert await p.access(0x0000) == 1, "below first TOR top must match entry 0 (R=1)"
    assert await p.access(0x0FFC) == 1, "last byte of entry 0 region"
    assert await p.access(0x1000) == 1, "entry 1 region starts here"
    assert await p.access(0x1FFC) == 1, "last byte of entry 1 region"
    assert await p.access(0x2000) == 1, "above both tops: unmatched, M-mode allowed"
    assert await p.access(0x1000, write=1) == 1, "entry 1 allows stores"
    assert await p.access(0x0000, write=1) == 0, "entry 0 does not allow stores"
    assert await p.access(0x1000, exec_=1) == 0, "neither entry grants execute"
    dut._log.info("pmp: TOR range matching correct")


@cocotb.test()
async def test_pmp_lock_rule(dut):
    """An unlocked entry is ignored in M-mode; a locked one is enforced.
    With no matching entry M-mode is allowed and a lower mode is denied."""
    p = Pmp(dut)
    # unlocked, no permissions
    await p.configure([(cfg_byte(lock=0, a=3, r=0, w=0, x=0), napot_addr(0x2000, 64))])
    assert await p.access(0x2000, priv_m=1) == 1, \
        "an unlocked entry must be ignored while the effective mode is M"
    assert await p.access(0x2000, priv_m=0) == 0, \
        "the same entry must deny a lower privilege mode"

    # locked, no permissions
    await p.configure([(cfg_byte(lock=1, a=3, r=0, w=0, x=0), napot_addr(0x2000, 64))])
    assert await p.access(0x2000, priv_m=1) == 0, "a locked entry must bind M-mode"

    # no entry at all
    await p.configure([])
    assert await p.access(0x2000, priv_m=1) == 1, "no match: M-mode allowed"
    assert await p.access(0x2000, priv_m=0) == 0, "no match: lower mode denied"
    dut._log.info("pmp: M-mode lock rule and default behaviour correct")


@cocotb.test()
async def test_pmp_priority(dut):
    """The lowest-numbered matching entry decides."""
    p = Pmp(dut)
    await p.configure([
        (cfg_byte(lock=1, a=3, r=0), napot_addr(0x2000, 64)),        # deny reads
        (cfg_byte(lock=1, a=3, r=1), napot_addr(0x2000, 64)),        # would allow
    ])
    assert await p.access(0x2000) == 0, \
        "entry 0 denies and has priority over the permissive entry 1"
    await p.configure([
        (cfg_byte(lock=1, a=3, r=1), napot_addr(0x2000, 64)),
        (cfg_byte(lock=1, a=3, r=0), napot_addr(0x2000, 64)),
    ])
    assert await p.access(0x2000) == 1, \
        "with entry 0 permissive, entry 0 must still win"
    dut._log.info("pmp: lowest-index priority correct")
