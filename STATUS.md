# STATUS — rv64_core

**Date:** 2026-10-26
**Scope:** an RV64IM core with Zicsr and the B extensions, a custom numeric
register bank, and a custom task-slot peripheral — RTL, verification and
synthesis.
**Environment:** oss-cad-suite (Icarus Verilog 14.0, Yosys) and xezim 0.11.3 for
the UVM regression; cocotb 2.1.0 drives Icarus.

Everything below was produced by running the commands shown. Nothing in this
file is aspirational.

## Build & run

```sh
pip install cocotb
export PATH=/path/to/oss-cad-suite/bin:$PATH

python3 sim/run.py                  # core regression,   expect 22/22 PASS
python3 sim/run.py --suite pmp      # PMP unit,          expect  5/5  PASS
python3 sim/run.py --suite plic     # PLIC unit,         expect  2/2  PASS

bash sim/run_uvm.sh                 # UVM regression on xezim
./sim/synth.sh                      # sv2v + Yosys
```

## Verified

- [x] Core regression — **22/22 pass**, including the numeric ABI and Xcetask
      reached from executed instructions
- [x] PMP unit — **5/5 pass**; PLIC unit — **2/2 pass**
- [x] ISA sweep — **24,861 retirements** match the golden model with zero
      mismatches: every ALU/MDU op over a boundary-operand matrix, every shift
      amount 0..63, every bit index 0..63, every width x byte lane, every branch
      polarity, every implemented CSR
- [x] Illegal-encoding sweep — **822 retirements and 119 traps** matched: every
      unimplemented major opcode and the reserved funct3/funct7 combinations
- [x] UVM regression on xezim — **7 of 8 pass** (alu, mem, trap, random,
      backpressure, illegal, isa_small)
- [x] Synthesis — 144,090 generic cells, 15,039 flip-flops, no inferred latches,
      longest combinational path 203 logic levels ending at `u_mdu.res_q[63]`

## Not verified, and stated plainly

- [ ] `rv64_isa_test` (the full 4444-retirement sweep through the UVM
      environment) does not complete: the UVM memory driver delivers roughly
      3250 simulated cycles per retired instruction, so the run needs ~14M
      cycles. The same sweep passes against the core through the cocotb harness.
- [ ] No timing analysis. The synthesis numbers are cell counts and logic depth,
      not a frequency. The MDU is the critical path and needs sequencing at any
      realistic clock.
- [ ] No formal verification.
- [ ] Coverage closure is partial; there is no stated coverage target.

## Not implemented

Posit/quire-code, logarithmic, residue and IEEE FP16/32/64 arithmetic — the
opcodes are reserved and raise the invalid flag. Out-of-order execution,
S/U privilege modes, Sv39, atomics, RVV, XRV512, QISA, an AI accelerator, an
adaptive cache and AMCCE are absent. `docs/ROADMAP.md` carries the full table
with honest per-row status.
