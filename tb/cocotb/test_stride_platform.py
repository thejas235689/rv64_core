"""Run with sim/run.py --sim verilator --suite stride."""
import cocotb
from cocotb.triggers import FallingEdge

from test_core import Harness
from rv64_asm import assemble


async def run_program(dut, source):
    harness = Harness(dut)
    await harness.startup()
    words, _ = assemble(source)
    await harness.load(words)
    await harness.reset()
    speculative = []
    for _ in range(1000):
        await FallingEdge(dut.clk)
        if int(dut.if_req_valid.value) and int(dut.if_req_ready.value):
            if int(dut.u_core.u_icache.speculative_q.value):
                speculative.append(int(dut.if_req_addr.value))
        if int(dut.trap_valid.value):
            assert int(dut.trap_cause.value) == 11
            break
    else:
        raise AssertionError("instruction stream did not finish")
    assert await harness.read_gpr(6) == 42
    return speculative


@cocotb.test()
async def test_stride_prefetch_in_authorized_window(dut):
    addresses = await run_program(
        dut, "addi x0, x0, 0\n" * 20 + "addi x6, x0, 42\necall\n"
    )
    assert addresses, "authorized stream issued no speculative reads"
    assert all(0x10 <= addr <= 0x38 for addr in addresses), addresses


@cocotb.test()
async def test_stride_prefetch_blocked_by_active_pmp(dut):
    # An unlocked active entry still permits ordinary machine-mode fetches.
    prefix = "addi x5, x0, 31\ncsrrw x0, pmpcfg0, x5\n"
    addresses = await run_program(
        dut, prefix + "addi x0, x0, 0\n" * 20 + "addi x6, x0, 42\necall\n"
    )
    assert not addresses, addresses
