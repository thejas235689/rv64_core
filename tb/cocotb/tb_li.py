import cocotb, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from test_core import Harness
from rv64_asm import assemble

@cocotb.test()
async def test_li(dut):
    """li must build every boundary value exactly, in hardware."""
    cases = [
        (0x7FFFFFFF,), (0x80000000,), (0xFFFFFFFF,), (-1,),
        (0x7FFFFFFFFFFFFFFF,), (0x8000000000000000,),
        (0,), (1,), (2047,), (-2048,), (1 << 32,), (1 << 48,), (-(1 << 20),),
    ]
    h = Harness(dut)
    await h.startup()
    bad = {}
    for (v,) in cases:
        src = f"li x5, {v}\naddi x6, x5, 0\nec a ll".replace("ec a ll", "ecall")
        words, _ = assemble(src)
        h.clear(); await h.load(words); await h.reset()
        await h.run(max_cycles=2000, stop_on_ecall=True)
        if 2 in [c for (_, c) in h.traps]:
            bad[hex(v & ((1<<64)-1))] = "illegal trap"
            continue
        vals = {t[3]: t[4] for t in h.trace if t[3] is not None}
        got = vals.get(6)
        # a 32-bit literal sign-extends to 64 bits, exactly as a compiler's li does:
        # li x5, 0x80000000 gives 0xFFFFFFFF80000000, not 0x0000000080000000.
        if -0x80000000 <= v <= 0xFFFFFFFF:
            v32 = v & 0xFFFFFFFF
            want = (v32 | 0xFFFFFFFF00000000) if v32 >> 31 else v32
        else:
            want = v & ((1 << 64) - 1)
        if got != want:
            bad[hex(want)] = (hex(got) if got is not None else None, hex(want))
    dut._log.warning(f"li in hardware: {len(cases)-len(bad)}/{len(cases)} exact")
    if bad: dut._log.warning(f"  bad: {bad}")
    assert not bad, f"li wrong: {bad}"
