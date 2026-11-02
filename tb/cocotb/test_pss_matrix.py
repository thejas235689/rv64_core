"""Every action of pss/rv64_full_matrix.pss, solved by Satya, executed on the core.

The matrix model states coverage intent in eight actions. This test closes the
loop for all eight: Satya solves the action, gen_pss_program.py turns the solve
into RISC-V words, the words are loaded into the core, and what the core retires
is compared against what the solver chose.

An action counts as runnable when its program retires at least one instruction,
reaches the trailing ecall, and takes no illegal-instruction trap (cause 2). For
the integer actions the value in x7 is additionally checked against a model of
the solved operands; for the posit and quire actions the check is execution, not
value, because this bench has no numeric reference model.
"""
import os
import pathlib

import cocotb

import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from test_core import Harness

ROOT = pathlib.Path(__file__).resolve().parents[2]
GEN = ROOT / "pss" / "gen_pss_program.py"
MODEL = ROOT / "pss" / "rv64_full_matrix.pss"
ACTIONS = ["alu_pair", "alu_imm", "alu_sign_boundary", "lsu_access",
           "lsu_roundtrip", "posit_op", "quire_op", "numeric_roundtrip"]


def generate(action, seed):
    """Solve with Satya and return (words, summary).

    Imported in-process rather than shelled out: inside cocotb sys.executable is
    the simulator's bundled interpreter, and a subprocess started with it cannot
    import this bench's own modules. Satya itself is still a real subprocess --
    gen_pss_program.solve() runs the satya binary.
    """
    sys.path.insert(0, str(ROOT / "pss"))
    import gen_pss_program as gen
    fields = gen.solve(action, seed, str(MODEL))
    words, summary = gen.build(action, fields)
    return words, summary


@cocotb.test()
async def test_pss_matrix(dut):
    """Run all eight rv64_full_matrix actions through solve -> generate -> execute.

    Three seeds per action, because the solver's picks drive which operand
    classes and which op the program exercises; a generator bug that only
    appears for one solve is still a bug.
    """
    SEEDS = (1, 2, 3)
    h = Harness(dut)
    await h.startup()
    h.clear()

    results = []
    for action in ACTIONS:
        for seed in SEEDS:
            words, summary = generate(action, seed)
            h.clear()
            await h.load(words)
            await h.reset()
            await h.run(max_cycles=4000, stop_on_ecall=True)

            retires = len(h.trace)
            causes = [c for (_, c) in h.traps]
            vals = {t[3]: t[4] for t in h.trace if t[3] is not None}
            x7 = vals.get(7)
            want = summary.get("expect_x7")
            ok = retires > 0 and 2 not in causes
            val_ok = None if want is None else (x7 == want)
            results.append((action, seed, len(words), retires, causes, x7, want, ok, val_ok))
            dut._log.info(
                f"PSS {action:18s} seed={seed} words={len(words):3d} "
                f"retires={retires:3d} traps={causes} "
                f"x7={'-' if x7 is None else hex(x7)} "
                f"expect={'-' if want is None else hex(want)} "
                f"{'RUNNABLE' if ok else 'NOT RUNNABLE'} "
                f"{'' if val_ok is None else ('value-ok' if val_ok else 'VALUE-MISMATCH')} "
                f"{ {k: v for k, v in summary.items() if k not in ('expect_x7', 'a', 'b')} }")

    dut._log.info("=" * 92)
    dut._log.info("PSS full-matrix summary")
    dut._log.info(f"{'action':20s} {'seeds':6s} {'words':6s} {'retires':10s} {'traps':10s} verdict")
    for action in ACTIONS:
        rows = [r for r in results if r[0] == action]
        ret = ",".join(str(r[3]) for r in rows)
        words = ",".join(str(r[2]) for r in rows)
        traps = ";".join("".join(str(c) for c in r[4]) for r in rows)
        ok = all(r[7] for r in rows)
        val = [r[8] for r in rows if r[8] is not None]
        verdict = "RUNNABLE" if ok else "NOT RUNNABLE"
        if val and not all(val):
            verdict += " VALUE-MISMATCH"
        dut._log.info(f"{action:20s} {len(rows):<6d} {words:6s} {ret:10s} {traps:10s} {verdict}")
    dut._log.info("=" * 92)

    bad = sorted({r[0] for r in results if not r[7]})
    assert not bad, f"actions that did not produce runnable programs: {bad}"
    mism = sorted({r[0] for r in results if r[8] is False})
    assert not mism, f"actions whose x7 disagreed with the solve: {mism}"
