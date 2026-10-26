# A Tour of This Repository

*New here — human or AI? This is the walk-around. Ten minutes and you will know
what this project is, what has been proven, and where everything lives. Last
verified 2026-10-26; every claim below is checked by the regression, and
`STATUS.md` is the live status.*

## What this is

A five-stage in-order RV64IM core — plus Zicsr, Zba/Zbb/Zbc/Zbs/Zicond and
Zihintpause — written as synthesizable SystemVerilog, with two custom blocks
hanging off it: a 32x64-bit numeric register bank (fixed-Q arithmetic, an exact
128-bit quire, adaptive precision, error tracking, sticky-flag CSRs) and a
bounded task-slot peripheral (completion/timeout lifecycle, optional completion
interrupt).

It is not a toy and it is not finished. Nineteen real design defects have been
found and fixed by the verification, and the parts that are absent are listed as
absent.

## Where things live

| Path | What is there |
| --- | --- |
| `rtl/` | 16 synthesizable modules. `riscv_core_top.sv` is the core; `rv64_num_*` is the numeric ABI; `rv64_xcetask.sv` is the task slots |
| `tb/cocotb/` | The fast regression: harness, assembler, Python ISA model, tests |
| `tb/uvm/` | The UVM environment: agent, driver, monitors, scoreboard, sequences, tests |
| `sim/` | Runners (`run.py`, `run_uvm.sh`, `synth.sh`) and the vector generators |
| `docs/` | Architecture contract, testplan, verification report, roadmap, project plan |
| `ci/`, `docker/`, `.github/` | Tool install scripts, a reproducible container, CI |

## The two regressions, and why there are two

`sim/run.py` drives Icarus through cocotb. It is the fast path — about 2.5
simulated cycles per instruction — and it is where functional work happens. It
compares every retirement against a Python ISA model, so a test writes a program
and asserts nothing: the model is the oracle.

`sim/run_uvm.sh` drives xezim through a UVM environment with a real agent,
driver, monitors and scoreboard. It proves the *methodology* path — that the
design behaves under a constrained-random, phase-based testbench with a
transaction-level scoreboard — and it is deliberately slow.

Both share one golden model. The UVM scoreboard holds no second ISA
implementation; `sim/gen_uvm_vectors.py` and `sim/gen_isa_sweep.py` extract
vectors from the Python model and the scoreboard compares against those. Keep
that property: two independent models would mean two places to be wrong.

## What "verified" means here

Every test is self-checking and every number in `STATUS.md` came from a run. The
one test that cannot complete (the full-size ISA sweep under UVM) is described
as such rather than quietly dropped.

## Reading order

1. `docs/ARCHITECTURE_FEATURE_CONTRACT.md` — what the design promises, in five
   lines, before any RTL
2. `docs/VERIFICATION_REPORT.md` — what was proven, and every defect the
   verification found
3. `docs/ROADMAP.md` — what exists, what is partial, what is absent
4. `rtl/riscv_core_top.sv` — the pipeline
