import cocotb
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from test_core import Harness
from rv64_asm import assemble

@cocotb.test()
async def test_two_store(dut):
    """Two stores with instructions after them -- the shape that used to hang."""
    src = """
        addi x5, x0, 0x11
        sw   x5, 16(x0)
        lw   x6, 16(x0)
        addi x7, x0, 0x22
        sw   x7, 24(x0)
        lw   x8, 24(x0)
        ecall
    """
    words, _ = assemble(src)
    h = Harness(dut)
    await h.startup(); h.clear(); await h.load(words); await h.reset()
    await h.run(max_cycles=400, stop_on_ecall=True)
    vals = {t[3]: t[4] for t in h.trace if t[3] is not None}
    dut._log.warning(f"RESULT x6={vals.get(6)} x8={vals.get(8)} pcs={[hex(t[0]) for t in h.trace][:9]}")
    assert vals.get(6) == 0x11, f"first load wrong: {vals.get(6)}"
    assert vals.get(8) == 0x22, f"second load wrong: {vals.get(8)}"
