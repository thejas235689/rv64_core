import cocotb
from cocotb.triggers import RisingEdge, Timer
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from test_core import Harness
from rv64_asm import assemble

@cocotb.test()
async def test_two_store(dut):
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
    seen = []
    async def w():
        while True:
            await RisingEdge(dut.clk); await Timer(1, "ns")
            try:
                c = dut.u_core; f = c.u_fetch
                seen.append((hex(int(c.pc_f.value)), hex(int(f.insn_raw.value)),
                             int(f.insn_valid.value), int(c.f_consume.value),
                             int(c.f_insn_len.value), hex(int(f.insn_pc.value))))
            except Exception:
                pass
    cocotb.start_soon(w())
    h = Harness(dut)
    await h.startup(); h.clear(); await h.load(words); await h.reset()
    await h.run(max_cycles=200, stop_on_ecall=True)
    prev = None
    for e in seen:
        if e[0] != prev or e[3] == 1:
            dut._log.warning(f"  pc_f={e[0]} insn_raw={e[1]} valid={e[2]} consume={e[3]} len={e[4]} insn_pc={e[5]}")
            prev = e[0]
