# Nine-work-package UVM and Portable Stimulus verification scaffold

**Status: fixture only, not complete CPU feature verification.** This self-contained harness is intended to demonstrate UVM compilation and transaction plumbing without changing the existing `tb/uvm` tests. It does **not** prove any of the nine RTL blocks.

## Files
- `wp9_if.sv`: proposed generic request/response contract. Real adapters must replace it or map existing interfaces.
- `wp9_pkg.sv`: transaction, sequencer, driver, monitor, deterministic **fixture** comparator, coverage subscriber, agent, environment, sequence and test.
- `wp9_top.sv`: combinational toy responder. This is **not the RV64 DUT**.
- `../../pss/wp9/rv64_wp9.pss`: nine scenario action families, no compiled/verified backend mapping yet.
- `../../sim/run_wp9_uvm.sh`: explicit xezim/UVM runner.

## Execution
```bash
bash sim/run_wp9_uvm.sh      # all nine IDs, sixteen op classes each
bash sim/run_wp9_uvm.sh 8    # cache-only transaction fixture
satya check pss/wp9/rv64_wp9.pss
satya solve pss/wp9/rv64_wp9.pss --action cache_coherence --seed 1
```
Commands above are intended invocations; **they have not been executed in the GitHub editing environment**. PSS CLI compatibility is subject to the installed Satya version.

## What a real WP adapter must implement
| WP | Driver | Monitor / scoreboard | Assertions & coverage |
| --- | --- | --- | --- |
| 01 RVV | instruction stream, LMUL, vector memory, trap injection | architectural vector register + memory comparison with ISS | mask/tail, restart, alignment, vstart, VS |
| 02 Posit | numeric ISA operations and accumulated sequences | independently implemented posit/quire oracle | rounding, NaR, worst-case errors |
| 03 LNS | signed operands and arithmetic | high-precision LNS oracle/error bounds | zero, cancellation, sign and range |
| 04 Prefetch | program stride, PMP/page settings, stalls | count permitted external requests, discard hints | no unauthorized request, fence, cancel |
| 05 BPU | branch/indirect control-flow program | retired-PC path against ISS (not internal guesses) | history rollback and no wrong-path retirement |
| 06 Frontend | self-modifying code, page-crossing, redirects | retirement equivalence and instruction bytes | uop invalidation, fusion/flush |
| 07 Unum | canonical encoded Unum operands | independent arithmetic/interval oracle | malformed encodings, exceptional cases |
| 08 Cache | multiple masters, evictions, snoops and stalls | coherence state and data-integrity model | MSHR, dirty eviction, deadlock, ordering |
| 09 Pipeline | dependency, exception and concurrency programs | retirement trace against ISS and memory-order model | ROB order, rollback, precise trap |

## Signoff gates
1. Replace the toy responder and generic `fixture_expected` expression with real RTL interface adapters and separate architectural reference models.
2. For each WP, add directed and constrained-random negative cases, UVM sequences, SVA properties, requirement-tagged functional coverage, and portable-backend mapping.
3. Connect PSS action outputs to actual stimulus emitters (assembly/sequence JSON/UVM). Do not describe PSS as integrated until a generated test executes against DUT.
4. Run lint, xezim/UVM, Verilator/cocotb, and formal checks where available; save logs.
5. Confirm baseline current-core regression passes. Only then mark corresponding GitHub issue complete.

The 9 x 16 cross is **synthetic interface coverage**: it is not ISA, numerical correctness, cache coherence or OoO coverage.
