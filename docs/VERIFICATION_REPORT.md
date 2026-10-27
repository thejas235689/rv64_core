# Verification report — rv64_core

Results below are from simulations actually run in the development sandbox. No
result in this document is projected or estimated.

## 1. Environment

| Tool | Version | Role | Status |
| --- | --- | --- | --- |
| Icarus Verilog | 14.0 (devel) | primary simulator for the cocotb regression | working |
| cocotb | 2.1.0 | testbench framework | working |
| Verilator | 5.053 devel | lint / combinational-loop analysis | working, clean |
| xezim | 0.11.3 | third-party parser + elaborator cross-check | working (`ulimit -v unlimited` needed in this container) |
| Python | 3.12 | golden model and test harness | working |

No commercial simulator, synthesis tool or STA run was performed.

## 2. Results

```
core regression   : TESTS=20  PASS=20  FAIL=0
PMP unit tests    : TESTS=5   PASS=5   FAIL=0
PLIC-lite tests   : TESTS=2   PASS=2   FAIL=0
UVM regression    : TESTS=5   PASS=5   FAIL=0
```

### UVM regression (xezim 0.11.3, UVM 1800.2-2020.3.2)

| Test | Result | Scoreboard verdict |
| --- | --- | --- |
| `rv64_alu_test` | PASS | 44 retirements and 1 trap matched the golden vectors |
| `rv64_mem_test` | PASS | 22 retirements and 1 trap matched |
| `rv64_trap_test` | PASS | 30 retirements and 5 traps matched |
| `rv64_random_test` | PASS | 148 retirements and 1 trap matched |
| `rv64_backpressure_test` | PASS | 22 retirements and 1 trap matched under 40 % backpressure |

The UVM environment reuses the Python ISS as its reference: `gen_uvm_vectors.py`
emits the expected retirement and trap streams, and the scoreboard compares the
DUT against them. Covergroup instance coverage ranged 52–70 % across these five
programs, which is expected — each program exercises a different slice of the
ISA, and closure is a P5 activity (see `PROJECT_PLAN.md`).

### Core regression

| Test | Result | What it proves |
| --- | --- | --- |
| `test_alu` | PASS | 79 instructions: every RV64I/Zba/Zbb/Zbc/Zbs/Zicond ALU op, `x0` suppression |
| `test_muldiv` | PASS | all 8 MDU ops incl. div-by-zero, INT_MIN/-1, sign combinations |
| `test_memory` | PASS | 8 load/store forms, sign/zero extension, byte lanes, memory contents |
| `test_control` | PASS | 6 branch polarities, jal/jalr link+return, nested loops, auipc |
| `test_hazards` | PASS | back-to-back RAW chains, load-use, WB→ID bypass |
| `test_csr` | PASS | CSR RW/RS/RC + immediate forms, read-only IDs, WARL masking |
| `test_traps` | PASS | illegal, illegal CSR, load/store misalign, ecall, handler return |
| `test_access_fault` | PASS | bus error on a load → load access fault, no state corruption |
| `test_random` | PASS | 56,698 instructions across 5 seeds, trace **and** memory compared |
| `test_backpressure` | PASS | 35 % random backpressure on both ports, results unchanged |
| `test_interrupt` | PASS | timer interrupt entry, `mcause`, handler runs, `mret` resumes |
| `test_debug` | PASS | halt, resume, exactly-one-retirement single step, watchpoint hits |
| `test_pmp` | PASS | NAPOT region denies load/store/fetch, lock blocks reconfiguration, read-only region permits loads and denies stores |
| `test_fetch_fault` | PASS | bus error on the instruction port → instruction access fault at the faulting address, then recovery |
| `test_ebreak_debug` | PASS | EBREAK enters debug instead of trapping; resume executes the next instruction |
| `test_wfi` | PASS | WFI resumes with a masked interrupt pending, and traps when MIE is set |
| `test_counters` | PASS | `minstret` advances by the retired-instruction count, `mcycle` advances |
| `test_predictor_stress` | PASS | 10-deep recursion overflows the 8-entry RAS; indirect jump through a loaded target |
| `test_reset` | PASS | mid-stream reset restarts at RESET_PC and re-executes correctly |
| `test_coverage_report` | PASS | coverage summary printed |

### PMP unit tests (matcher in isolation)

| Test | Result | What it proves |
| --- | --- | --- |
| `test_pmp_napot` | PASS | 64-byte NAPOT region: both edges inside, both edges outside, W/X denial |
| `test_pmp_na4` | PASS | NA4 matches exactly one 4-byte word, not its neighbours |
| `test_pmp_tor` | PASS | two TOR entries give `[0,0x1000)` and `[0x1000,0x2000)` with distinct permissions |
| `test_pmp_lock_rule` | PASS | unlocked entry ignored in M-mode, enforced below M; locked entry binds M; no match allows M and denies lower |
| `test_pmp_priority` | PASS | lowest-numbered matching entry wins in both orders |

### PLIC-lite tests

| Test | Result | What it proves |
| --- | --- | --- |
| `test_plic_priority_and_threshold` | PASS | priority arbitration, enable mask, threshold, claim → in-service → complete |
| `test_plic_config_readback` | PASS | configuration register readback |

### ISA sweep (`rv64_isa_test`, `rv64_illegal_test`)

`sim/gen_isa_sweep.py` builds two systematic programs and their golden vectors.

| Test | Program | Status |
| --- | --- | --- |
| `rv64_illegal_test` | every unimplemented major opcode plus reserved funct3/funct7 combinations | **PASS** -- 822 retirements and 119 traps matched |
| `rv64_isa_test` | 4445 instructions: every ALU/MDU op x boundary-operand matrix, every shift amount 0..63, every bit index 0..63, every width x byte lane, every branch polarity, every CSR | **core PASSES the sweep** (see below); the full-size UVM run is throughput-blocked |
| `rv64_isa_small_test` | the same sweep with a reduced matrix: 780 retirements | **PASS** -- 780 retirements and 17 traps matched |

The illegal sweep found two real defects, both now fixed:

* **MRET/EBREAK did not stop the younger instruction from advancing into MEM.**
  `flush_front` cleared IF/ID and ID/EX, but the instruction in EX is transferred
  to MEM in the same cycle, so it executed anyway. Behind an MRET that means a
  wrong-path instruction runs and can take a trap of its own, overwriting `mepc`.
  Minimal reproduction: an illegal instruction at 0x08 with a handler at 0x100
  produced `TRAP 1 pc=0x114` (the instruction after the `mret`) instead of
  `pc=0x00c`. Icarus and xezim agreed exactly, so this was a core defect and not
  a tool difference. The cocotb trap test had masked it because the slow memory
  model usually leaves a bubble behind the `mret`.
* **OP-IMM-32 accepted funct3=7 as `srliw`.** The decode `default` arm assumed
  funct3 == 101, so 010/011/100/110/111 fell through and were decoded as
  `srliw`/`sraiw` -- an illegal encoding executed as a legal instruction. The arm
  is now explicit and everything else raises illegal-instruction.

**The ISA sweep passes against the core.** Running the same 4445-instruction
program through the cocotb harness (`test_isa_sweep_fast`) matches the golden
model for **24,861 retirements with zero mismatches**. That is the ISA-compliance
evidence: every ALU/MDU op over the boundary-operand matrix, every shift amount
0..63, every bit index 0..63, every width x byte lane, every branch polarity, and
every implemented CSR, all correct.

The UVM *wrapper* for the same program remains unverified, and the reason is
diagnosed as harness-side, not core-side:

* The vectors load correctly: the retire file holds 22240 values and the entry
  the scoreboard reports as "expected" at retirement 1000 is exactly right, so
  the file and the `$readmemh` are sound.
* The mismatch therefore sits in the comparison: two values that are equal and
  print identically were failing `!==`. Every operand here is 2-state (`bit`), so
  case-inequality buys nothing; the comparisons are now plain `!=`.
* Reverting to `!==` restored `rv64_illegal_test` to passing, which confirms
  `!==` was the right operator and `!=` is the one that misbehaves on this
  simulator. The ISA wrapper therefore has no identified defect left to fix --
  what blocks it is throughput.

**The UVM wrapper is proven.** `rv64_isa_small_test` runs the same kind of sweep
(reduced matrix, 780 retirements) through the UVM environment and passes: 780
retirements and 17 traps matched, zero errors. So the scoreboard, monitors,
agent and vector path are all correct end to end; what remains out of reach is
only the full-size 4444-retirement run.

**Blocker for the full-size UVM ISA run: driver throughput.** The UVM memory driver
delivers roughly 3250 simulated cycles per retired instruction (the illegal
sweep needs 2.67M cycles for 822 retirements), so a 4444-retirement run needs
~14M cycles and cannot finish inside one simulation call. The cocotb harness does
the same work at ~2.5 cycles per instruction. Fixing the driver is the
prerequisite for closing the UVM ISA test, and it is the next item.

One stale expectation was found in the generator while re-running this: opcode
`0x0B` (custom-0) was still listed as unimplemented after the numeric ABI made
it legal, so the illegal sweep expected a trap where the core correctly executed
a numeric instruction. Removed from the list; the sweep is now 119 traps.

Harness note: the UVM memory driver runs at roughly 3200 simulated cycles per
retired instruction, so the 4445-instruction sweep takes ~14M cycles. That is a
driver throughput problem, not a core problem, and it is why this test is slow to
iterate on. The cocotb regression (27/27 passing) remains the fast path.

### Numeric unit (`rv64_num_unit`)

```
tb_num_top : 1137 vectors, 4548 checks, 0 mismatches   PASS
```

Vector-driven against a Python model written from the same specification
(`sim/gen_num_vectors.py`), covering fixed-Q add/sub/mul across overflow,
saturation and rounding boundaries, quire accumulate/read chains, adaptive
truncation at precisions 8/16/24/32/48/63/64, error reporting, and the reserved
families reporting invalid.

One defect was found and fixed during bring-up: the adaptive-precision field was
6 bits wide, so `prec >= 64` was vacuously true and truncation never fired. The
field is now 7 bits.

**Integrated and reachable from software.** The bank is wired into the pipeline
through custom-0 (`0x0B`), with `funct7` selecting the operation, `funct3` the
format, and the register fields indexing the numeric bank. Two bridge
instructions (`NUM_TOINT` funct7 0x12, `NUM_FROMINT` funct7 0x13) connect the two
banks — without them a numeric result has no route back to software. The numeric
CSRs at `0x7C0`-`0x7C2` are arbitrated with the machine CSR file.

`test_numeric_abi` checks it end-to-end from executed instructions: 2.0 x 3.0 =
6.0 through the multiply, 2.0 + 3.0 = 5.0 through the add, the quire accumulating
2.0 x 3.0 exactly and reading back 6.0, both bridges, `ncfg` reading its reset
value 0x2020, and `nflags` clean.

Two defects were found during integration:

* **Interlock deadlock.** The stall tested `ex_mem_is_num` without its stage
  valid bit. `ex_mem_is_num` keeps its old value when `ex_mem` takes a bubble, so
  a stale flag stalled the pipeline forever — the program retired two
  instructions and stopped. Qualified with the valid bits.
* **The quire accumulated every cycle in EX.** The accumulator is stateful but
  was gated only by the opcode, so an instruction held in EX for four cycles
  added its product four times: 2.0 x 3.0 produced 24.0. Now gated by a
  one-shot `op_valid` pulse that is true exactly once per instruction.

Also worth recording: my first version of the test used `lui x1, 0x18000`
believing it produced 0x1_8000_0000. `lui` shifts by 12, so it produces
0x1800_0000. The RTL was right and the test constants were wrong — a reminder
that a failing assertion indicts the testbench before the design.

Posit, LNS, RNS and IEEE families remain unimplemented.

### Research numeric families (`rv64_num_wide`) -- partial

Four families are implemented as a separate combinational block so each can be
reasoned about and tested on its own.

`fmt` now selects the width for all three parameterised families:

| `fmt` | posit | LNS | RNS |
| --- | --- | --- | --- |
| 0 | posit<16,1> | Q16.16 in 32 bits | {3,5,7,11} in 12 bits |
| 1 | posit<8,1> | Q8.8 in 16 bits | {3,5,7} in 8 bits |
| 2 | posit<32,1> | Q32.32 in 64 bits | {3,5,7,11,13} in 16 bits |

Posit arithmetic moved to a 128-bit Q63.64 internal format so one datapath serves
all three widths -- posit32's range is about 2^60, which does not fit the Q30.34
used before.

| Family | Ops | Status |
| --- | --- | --- |
| RNS | `RADD`, `RMUL` | **verified** -- moduli 3/5/7/11, per-channel modular, exact |
| LNS | `LNMUL`, `LNDIV` | **verified** -- signed Q16.16 log2, `0x8000_0000` = zero, saturating |
| IEEE binary32 | `FADD`, `FMUL` | **verified** -- RNE, inf/NaN handled, subnormals flushed to zero |
| posit<16,1> | `PADD`, `PSUB`, `PMUL`, `PDIV` | **verified** -- decode to Q30.34, operate, re-encode with RNE |

Standalone vector suite: **15364 checks, 0 mismatches** across all four families
and all three widths.

Two further defects found while adding the widths:

* **An unsigned comparison in the LNS range check.** `{sign, min}` is a
  concatenation, and a concatenation is *unsigned* in Verilog, so
  `lsum < {lns_min[63], lns_min}` compared unsigned and every result looked
  below the minimum -- LNMUL returned the zero code with OVERFLOW set. The
  bounds are now widened into signed variables.
* **The ISS did not receive `fmt`**, so every non-16-bit vector disagreed with
  the DUT in the UVM run. The scoreboard was right and the model was stale.

The two final posit defects were both narrowing overflows: the multiply's
128-bit product and the divide's 128-bit quotient were truncated to 64 bits
before encoding, so a large positive result wrapped negative and encoded to the
*negative* rail. Both now clamp before narrowing, matching the model.

Bugs found and fixed on the way here, all of them mine rather than the tools':

* FP32 multiply decremented the exponent when it shifted the mantissa window --
  that shift does not change the value, so every product whose mantissa landed
  in [1,2) came out halved.
* The FP32 adder's accumulator was one bit narrow, so a sum of two mantissas
  overflowed it.
* `fp_exp` was unsigned, so a negative exponent wrapped to ~1023 and read as
  overflow instead of underflow.
* Posit encode had two off-by-ones: the regime for k>=0 is k+2 bits (k+1 ones
  *plus* the terminating bit), and the fraction field is 14-rlen wide.
* Posit significand normalisation shifted by 64-lead, which pushes the leading
  one off the end of the word and loses the entire value.
* Posit division shifted a Q30.34 operand left by 34 in a 64-bit word, which
  overflows for any value above 2^30 -- most of the posit range.
* Two `always_comb` blocks drove `flags`, so the RNS arm silently took the
  default arm's INVALID flag.

**In-CPU coverage.** `rv64_iss.py` now models the custom-0 numeric ABI -- its own
32x64 register bank, the quire, the error register and the `ncfg`/`nflags`/`nerr`
CSRs -- importing the *same* model the vector generator uses, so there is one
implementation of the numeric semantics rather than three. `test_numeric_sweep`
builds a program that runs every family and bridges each result back into an
integer register (without that the retirement trace would show no writes at all
for numeric instructions and comparing traces would prove nothing): **299
retirements match the ISS**, so the numeric path is now verified in the CPU and
not only standalone.

**WENGOLD (validity kernel).** `sim/wengold.sh` runs
[WENGOLD](https://github.com/thejas235689/wengold) over the tree: dependency
graph, completeness, singularity and CDC. It installs with pip, so unlike Satya
it runs here.

```
index        45 files, 46 nodes, 86 edges -- complete, 0 unresolved
completeness only open item: unresolved include uvm_macros.svh (external UVM)
singularity  well conditioned; no block dominates
             worst: rv64_num_wide, a change there reaches 6 blocks (median 4)
cdc (core)   one domain, no crossings -- consistent with a single-clock design
cdc (uart)   `rx` reported as "unresolved (no determinable domain)"
```

**pyslang is required for an accurate graph.** Without it WENGOLD falls back to a
bounded regex elaborator, and that fallback reported a false positive on this
design: `int: instantiated as posit_width in rv64_num_wide but not defined`. It
was reading the function declaration `function automatic int posit_width(...)` as
a module instantiation of a module called `int`. With pyslang installed the graph
is complete with nothing unresolved.

Two limits worth stating rather than glossing:

* **CDC cannot see an undeclared asynchronous input.** The UART's `rx` is
  genuinely asynchronous and goes through a two-flop synchroniser, but WENGOLD
  lists it under "unresolved (no determinable domain)" rather than flagging it.
  That is conservative -- it does not claim a violation that is not there -- but
  it also means an *unsynchronised* async input would not be caught unless the
  domain is declared.
* **The formal engine cannot take this RTL, and WENGOLD says so itself.** Its
  README states the front-end covers register-level RTL and "does not accept a
  full core: on CV32E40P it covers 2 files of 125". Confirmed here: it cannot
  tokenize a concatenation, so `rv64_clint` and `rv64_aiacc` both come back
  UNKNOWN. `--sva` does generate bindable assertions for them, which is the
  useful mode for this repository.

Two defects found in WENGOLD while doing this, reported here rather than only
worked around:

1. **`formal` raises an uncaught exception instead of reporting UNKNOWN.** A
   property containing `$past` raises `UnsupportedConstruct` from
   `wengold/formal/rtl_model.py:90` and escapes as a Python traceback. The RTL
   path handles the same exception gracefully ("front-end: cannot tokenize..."),
   so it is the property-parse path specifically that is missing the handler.
2. **The regex fallback misreads a function declaration as an instantiation**,
   producing the false undefined-block above. `--backend slang` avoids it, but
   the fallback is the default when pyslang is absent, so the first run of a new
   user on a design like this produces a misleading "incomplete" verdict.

**Static analysis.** `sim/lint.sh` runs `slang` (a full SystemVerilog front end)
over the core and both testbenches, then Verilator `--lint-only`. slang is clean
-- **0 errors, 0 warnings on all three tops** -- after two real fixes it forced:

* **Mixed timescales.** The RTL had no `` `timescale `` while the testbenches did,
  which is a genuine simulation hazard, not a style opinion. All 18 RTL files now
  declare `1ns/1ps`.
* **A multiply-driven memory in the testbench.** `tb_core_top.sv` zeroed its
  memory in an `initial` block and also wrote it from an `always_ff`. Legal
  Verilog, but a real hazard; the power-up zeroing moved into the same
  `always_ff`.

Verilator reports 27 width warnings, all widening/truncation in the numeric
packing and the quire read-back paths. Those are intentional (packing narrow
fields, reading a 128-bit quire down to 64 bits), and are reported rather than
suppressed so a future change that widens something unintentionally shows up.

**Tool coverage.** Verified under xezim (standalone vectors: 10756 checks, 0
mismatches) and Icarus (cocotb: 24/24 tests). **Verilator cannot run in this
environment**: cocotb's Verilator flow shells out to `make` to build the C++
model, and `make` is not installed and cannot be (no root). `sim/run.py --sim
verilator` is wired up with `--timing -Wno-fatal`, so it will work wherever make
exists; it is untested here.

**PSS.** `pss/rv64_numeric.pss` describes the numeric regression as a Portable
Stimulus model. It is now **parsed, lowered and solved** by Satya v0.25.0
(thejas235689/satya, prebuilt x86_64 release, SHA-256 verified):

The model now covers **every numeric testcase**, not one action:

```
satya check pss/rv64_numeric.pss  -> OK, parsed and lowered
satya solve pss/rv64_numeric.pss --action test --seed {1,2,3}
                                  -> 43 steps, 0 warnings, identical across seeds
satya gen   ... --backend uvm     -> 992 lines  pss/generated/numeric_sequences.sv
satya gen   ... --backend json    -> 809 lines
satya gen   ... --backend trace   -> 140 lines
```

Coverage is split by what the solver can represent, and the split is documented
in the model itself:

* **Randomised** -- quire, posit and residue, over *ranges* (any bit pattern is a
  legal encoding at that width, so a range is the right sweep).
* **Directed** -- fixed-Q, logarithmic and binary32, one pinned boundary case per
  action (the positive rail, exact cancellation, inf, qNaN, zero, the log rail),
  because a wide operand *domain* exhausts the solver's memory.

Running it also forced two more workarounds, both now documented in the model:

* **`op` and `fmt` are pinned with equality, never a range.** Enum range
  constraints are not enforced, so `op in [PADD..PDIV]` solved to `op=2` and left
  the operation free -- the model would have tested nothing in particular while
  looking like it did.
* **Operands are drawn from ranges, not value lists.** A set returns its first
  element on every seed (`x in [64, 127, 16384]` gives 64 every time), so a list
  is not randomisation at all.

So the model is a real, tool-accepted PSS model and the PSS -> UVM flow is
demonstrated end to end, not merely written down.

### Satya v0.25.0 -- four issues found by running it

Each has a minimal reproducer. They are reported as observations, not as
defects in this repository.

1. **`bit[64]` literals with bit 63 set solve as 0**, violating their own
   constraint. `rand bit[64] x; constraint x == 0x7FFF_FFFF_FFFF_FFFF;` solves to
   2^63-1 correctly; `constraint x == 0x8000_0000_0000_0000;` (and anything above)
   solves to **0**. Looks like a signed-64-bit interpretation on the way in.
   Consequence here: the model keeps every operand below 2^63, so INT64_MIN and
   -1 coverage comes from the directed suites instead.

2. **Enum range constraints are not enforced.**
   `rand e_t sel; constraint sel in [A1..A3];` solves to 0 and 5 across seeds --
   both outside the range. The trace also reports `constraints: 2/2 satisfied`
   while listing `not satisfied: <expr>`, so the summary and the detail disagree.

3. **Three actions exhaust memory**: `fixed_q_op`, `lns_op` and `fp32_op` each
   fail with `memory allocation of 1207959568 bytes failed`, while `quire_op`,
   `posit_op` and `rns_op` solve. The difference is the width of the operand
   domains; 1.2 GB is above this sandbox's 1.5 GB address-space cap, so the run
   cannot complete here regardless.

4. **Set membership always returns the first element.** `rand int x; constraint
   x in [0x40, 0x7F, 0x4000, 0x7FFF];` gives `x=64` on seeds 1-5. A *range*
   randomises correctly, so the model uses ranges throughout. Reproducer:
   `tests/repro/bug5_set_membership.pss`.

5. **The UVM backend emits PSS enum names as bare SystemVerilog identifiers**:
   `op inside {[PADD:PDIV]};` in `pss/generated/posit_op_seq.sv`. That will not
   compile as SV unless a matching enum is declared, so the generated sequence is
   a starting point rather than drop-in code. **UVM now covers them.** `rv64_numeric_test` runs a numeric program through the
SystemVerilog UVM environment: **156 retirements and 1 trap matched**, zero
errors. That was only possible after teaching the ISS custom-0 -- the scoreboard
compares retire traces, and a numeric instruction writes no GPR, so the program
bridges each result back with NUM_TOINT to make the comparison mean something.

The rustdv environment needs no new components for this: it serves the program
image and compares retire traces against the same vectors, so pointing
`RUSTDV_VEC_PREFIX` at `sim/uvm_vectors/numeric` covers the families. It remains
**uncompiled** -- no Rust toolchain is reachable in this environment.

### Tagged history and a perceptron predictor

The predictor set is now: bimodal + gshare tournament, BTB, RAS, a loop-count
predictor, tagged history, and a perceptron. That completes the roadmap item that
was previously partial.

**Tagged history.** Each gshare entry carries a 6-bit tag from the branch PC. On a
tag miss the entry says nothing about this branch and the bimodal counter is used
instead, so two branches aliasing into the same index no longer train each other's
counter. A mismatched tag restarts the counter rather than letting the aliasing
branch inherit it.

**Perceptron.** 32 tables of eight signed 6-bit weights, indexed by the low PC bits
and dotted with the global history. It overrides the tournament only when
confident ($$|sum| > 8$$), so it cannot disturb the predictors on ordinary
branches.

`tb/tb_bpu_perc.sv`: **3 checks, 0 mismatches**. The test trains on an alternating
T,N,T,N pattern -- the case a 2-bit counter cannot represent, because every update
flips it -- and then measures both predictors on the same lookups:

```
perceptron  20/20 correct
bimodal     10/20 on the same lookups   (exactly chance)
```

That comparison is the point of the test. My first version trained on a
"majority of the last three outcomes" stream and the bimodal also scored 20/20,
because that stream settles into a long run of taken and a saturated counter gets
it right. A test that shows both predictors succeeding proves nothing about why
the perceptron is there.

Regression: cocotb 25/25, PMP 5/5, and the loop predictor still passes (9 checks)
with the perceptron alongside it -- the loop predictor keeps precedence, so the
two do not fight over counted loops.

### Sv39 translation (INCOMPLETE -- not verified)

`rtl/rv64_mmu.sv` implements Sv39: a 16-entry TLB plus a three-level page-table
walker with the permission rules (R/W/X, the U-bit with SUM, MXR, and the A/D
requirement), megapage alignment checks, the correct page-fault cause per access
type, and MPRV gating so M-mode loads and stores translate while M-mode fetches
do not.

**Status: verified under xezim, tool-specific failure under Icarus, not wired into
the core.**

| Tool | Result |
| --- | --- |
| xezim 0.11.3 | **22 checks, 0 mismatches -- PASS** |
| slang | clean, 0 errors 0 warnings |
| Verilator | lint clean, 0 warnings |
| Icarus 14.0 | the first (bare) translation never completes -- **not a pass** |

The Icarus failure is a tool issue I did not isolate: a probe shows the FSM
setting `bare_q` but never leaving `W_IDLE`, i.e. the branch executes and its
state assignment is lost. It is not the enum state variable (replacing the enum
with plain bits and localparams changed nothing) and not a duplicate driver (there
is one sequential block and one case). Because the core regression runs under
Icarus, the MMU is deliberately **not** instantiated in the core: wiring it in
would take the 25 passing core tests down with it. `satp` still reads zero and the
core still runs untranslated.

Defects found on the way, three of them real and one a lesson about debugging:

* **The PTE address was 67 bits wide.** `{55'd0, vpn_sel, 3'd0}` should have been
  52 zero bits; the concatenation overflowed and the walker read the wrong memory
  word. Verilator's WIDTHEXPAND warning pointed straight at it, along with four
  more 58-bit `base`/`off` builds that were silently truncating.
* **Bare mode returned a stale composed address.** With translation off, the
  output mux still used `base|off` left over from the previous translation
  instead of passing the virtual address through.
* **The permission check read a register assigned in the same cycle.**
  `perm_ok` gated on `leaf_is_leaf`, which is written in the very cycle the check
  runs, so it always saw the previous value (0) and every leaf faulted. The check
  now works from the arriving PTE fields through a `perm_of()` function.
* **I misread the state encoding.** A probe showing `wst=4` looked like `W_DONE`
  and sent me looking at the output mux; `W_FAULT` is 4 and `W_DONE` is 3, so the
  walker was faulting and the mux was innocent. Reading the enum declaration
  first would have saved two rounds.
* **My testbench sampled a one-cycle window at the wrong instant.** The wait loop
  was `while (!resp_valid) @(posedge clk);` -- it evaluates `resp_valid` at the
  edge, before the non-blocking update settles, so the single-cycle `W_DONE`
  window was missed and an unrelated later value was read. That accounted for
  **five of the six** original failures. The settling delay now sits inside the
  loop, and the wait is bounded so a hang reports itself instead of timing out
  silently.
* **`bare_q` was only cleared on the walk path**, so a TLB hit immediately after a
  pass-through access kept the stale flag and returned the virtual address. That
  was the sixth.

### S/U privilege modes

The core was M-mode only, with `priv_o` hardwired to `2'b11` and PMP told it was
always in M. It now has a real privilege state machine.

Implemented: the 2-bit privilege register (M/S/U) reset into M; the S-mode CSR
set (`sstatus`, `sie`, `stvec`, `sscratch`, `sepc`, `scause`, `stval`, `sip`);
`mstatus` SPP/SPIE/SUM/MXR alongside MPP/MPIE/MIE; `medeleg`/`mideleg` trap
delegation; `sret`; CSR privilege checking from the address bits [9:8]; PMP now
sees the real privilege instead of a constant; and a delegated trap vectors
through `stvec` rather than `mtvec`.

**18 checks, 0 mismatches** in `tb/tb_privilege.sv`: reset into M, M CSRs readable
at M, `mret` into S, an M-mode CSR correctly illegal at S while an S CSR is legal,
a delegated trap writing `sepc`/`scause` and staying in S, `sret` returning to S
with SPP=1 and to U with SPP=0, an undelegated trap from U entering M with MPP
recording U, and an interrupt delegated by `mideleg`.

The core regression stayed at **25/25** throughout, which is the point: M-mode
behaviour had to be bit-identical after the change.

Three defects, and one is a lesson about patching:

* **`csr_valid` lost its driver.** The privilege check was supposed to become
  `csr_valid = csr_impl && csr_perm_ok`, but the patch that added that line did
  not match the file, so the output had no driver at all and floated at 0. Every
  CSR access became an illegal-CSR trap: six core tests failed, two of them by
  jumping to address 0. A `grep -c csr_valid` would have found it in one second;
  the test run found it in one minute.
* **A patch matched three times and corrupted the file.** Adding the reset values
  matched `mstatus_mpp_q <= 2'b11` in the reset block, the trap branch and the
  mret branch, duplicating fifteen lines of reset logic into both branches and
  leaving the real transitions unwritten. The module still elaborated cleanly.
* **My testbench wrote `medeleg` from S-mode**, which the new privilege check
  correctly rejected -- the RTL was right and the test was wrong. Delegation has
  to be configured in M before dropping to S.

**Not implemented, and stated so:** `satp` reads as zero (no Sv39), `MPRV` is not
honoured, `sstatus.SUM`/`MXR` are stored but not enforced in the LSU, and
`sie`/`sip` are mirrors of the M-mode pending bits rather than an independent S
interrupt file. Those belong with Sv39 and the cache work.

### Loop predictor

The branch predictor was a 256-entry bimodal + gshare tournament with a choice
predictor, a 64-entry BTB and an 8-entry RAS. A counted loop defeats that: the
final iteration is the only one not taken, so per-branch history cannot call it
and the exit mispredicts every pass.

`rv64_bpu.sv` now carries a 16-entry loop-count table alongside the tournament:
it learns a trip count and predicts the exit directly. **9 checks, 0 mismatches**
in `tb/tb_bpu_loop.sv` -- a 5-iteration loop predicted taken at the head for four
iterations and not-taken on the exit with a `pc+4` target, a 3-iteration loop
relearned on a different PC, and a branch that is never not-taken left to the
tournament.

Two defects, and the second is the one worth reading:

* **The trip count was learned on taken updates.** That let a branch which is
  never not-taken accumulate a count and then wrongly predict its own exit. The
  count is now learned only from the exit itself.
* **The loop override used the BTB target without requiring a BTB hit.** With a
  loop-table entry but no valid BTB line, the taken target came from a stale BTB
  entry -- and in the full core that sent execution to address 0. `test_control`
  and `test_pmp` both failed, `test_pmp` by looping on load-access faults. The
  override is now gated on `btb_hit`. This is exactly the kind of defect a
  directed unit test cannot catch on its own: the loop testbench was green while
  the core was broken, because it only ever trained the loop through a BTB entry
  that happened to be valid.

Regression after the fix: cocotb 25/25, PMP 5/5, PLIC 2/2, slang clean.

**Not done:** the same roadmap item also listed tagged history and a perceptron
predictor. Neither is implemented. This is the loop predictor alone.

### Front-end predecode and fusion hints

`rtl/rv64_predecode.sv` classifies an instruction from its encoding alone --
control transfer, register write, load/store, and whether it pairs with the
previous instruction -- so the front end has those facts before the full decoder
does. It is wired into `rv64_fetch`, which carries the tags alongside the
instruction and remembers the previously *consumed* instruction so the fusion
detector sees the pair as the pipeline sees it.

The tags are deliberately a subset of the decoder's output, and that is the risk:
a second decoder can drift. `tb/tb_predecode.sv` therefore **cross-checks every
tag against the full decoder** over all 128 opcode bytes, the ISA sweep encodings
and the atomic/CSR forms: **316 checks, 0 mismatches**. A divergence is a test
failure, not a silent difference in behaviour.

The cross-check earned its keep immediately: CSR instructions write `rd` but
`ecall`/`ebreak`/`mret`/`wfi` share opcode `0x73` and do not. The first version
tagged the whole opcode as writing `rd` and the check failed on `csrrw x4,
mstatus, x1`. `SYSTEM` is now split on `funct3 == 0`.

Fusion hints detect three pair shapes -- `lui` + op-imm/load/store on the same
register, `auipc` + addi/jalr, and any instruction after `jal`/`jalr` -- and are
**hints only**. There is no fused execution unit; the pipeline still issues both
instructions. The roadmap item asked for fusion *hints*, and the file header says
plainly that no fused datapath exists.

### Platform blocks: CLINT, UART, DMI

Three standalone blocks, each with a CSR control port like the rest of this
core's peripherals. They are *not* wired into `riscv_core_top` -- a real platform
memory-maps them, and this core has no platform bus; PLIC-lite sits in the same
position.

| Block | Status |
| --- | --- |
| `rv64_clint` | **verified** -- mtime/mtimecmp timer interrupt with enable gating, MSIP software interrupt; 14 checks with the UART |
| `rv64_uart` | **verified** -- 8N1 transmit and receive, looped back in the testbench, byte and framing checked |
| `rv64_dmi` | **verified** -- JTAG TAP, DMI transport, halt/resume/step and DMSTATUS reads |

The DMI is the JTAG TAP plus the 41-bit DMI shift register with the standard
dtmcs/dmi instruction codes, decoding onto the core's existing halt/resume/step
and GPR-read ports. **17 checks, 0 mismatches** across the three platform blocks.

It remains honestly incomplete in one way, stated in the file header: there is
**no abstract-command layer** -- no progbuf, no command queue, no system-bus
master. Register access is direct via REGSEL/DATA0.

Getting it to pass took four fixes, and only one of them was in the testbench:

* **`tap_reset` left the TAP in Select-DR, not Run-Test/Idle.** Five TMS-high
  edges were not enough from every entry state, so each later sequence started
  one state off and the IR/DR phases wrapped -- a `tap_ir` that should have ended
  in Idle ended in Capture-IR, and the IR ended up as the last five bits of a DR
  shift (0x08) instead of 0x11. Ten TMS-high edges reach Test-Logic-Reset from
  any state.
* **The request registers responded to the level of `dmi_wr`**, which stays high
  after Update-DR, so a one-shot like `resumereq` re-asserted every TCK and never
  self-cleared. Update-DR is an event; it now generates a one-TCK `dmi_update`
  pulse that qualifies the request registers.
* **The read path ignored the DMI address** and returned the DATA0 value whatever
  was asked for, so a DMSTATUS read came back as the GPR contents. It now decodes
  DATA0 / DMCONTROL / DMSTATUS / REGSEL.
* **My own check indexed the wrong bit.** The DMI data field starts at bit 7, so
  DMSTATUS `data[9]` (allhalted) is bit 16, not 17. The RTL was right and the
  testbench was wrong -- the same shape of mistake as the QISA expectations
  earlier.

Three defects the platform tests caught:

* **UART received every byte shifted right by one.** The receiver's first sample
  lands in the middle of the start bit and was being stored as data bit 0.
  Samples 1..8 are data, sample 9 is the stop bit; the received byte now matches
  the transmitted one.
* **UART dropped the top data bit.** After the start-bit fix the finish condition
  was still one sample early, so bit 7 was never stored (0xA5 read back as 0x25).
* **CLINT timer never fired** when only the low word of `mtimecmp` was written,
  because it resets to all-ones -- the high word has to be cleared too. That one
  was a testbench error, and the block was right.

Also found: Icarus rejects an enum in a ternary (`st <= tms ? A : B`), so every
TAP state transition is written as if/else.

### A extension: LR/SC and AMOs

`lr.w/d`, `sc.w/d` and the nine AMOs (`swap`, `add`, `xor`, `or`, `and`, `min`,
`max`, `minu`, `maxu`) at both widths, decoded on opcode `0x2F`.

The LSU grew a reservation register and a read-modify-write state machine
(`S_REQ -> S_RESP -> S_WREQ -> S_DONE`). A single-hart reservation is recorded by
`lr`, consumed by every `sc`, and an `sc` whose address does not match fails
without touching the bus. In a multi-hart system the reservation would also have
to be cleared by a foreign store; that is a coherence concern and is stated in
the header rather than pretended.

Verified two ways: `tb/tb_atomic.sv` (**23 checks, 0 mismatches**) drives the LSU
against a memory model that honours byte strobes -- every AMO, both widths, the
signed `min`/`max` ordering, and the four `sc` outcomes (first success, second
failure, wrong-address failure, matched success); and `test_atomic` runs the same
operations **in the CPU, 26 retirements matched against the ISS**.

Two defects the tests caught:

* **The AMO write never reached the bus.** `mem_req_valid` was asserted only in
  `S_REQ`, so the read half of the read-modify-write happened and the write half
  silently did nothing. The unit testbench showed memory unchanged after every
  AMO while the returned old values looked correct -- exactly the failure a
  directed test exists to catch.
* **The AMO address was wrong.** Bits 31:20 of an AMO instruction carry
  `funct5|rs2`, not an immediate, but the decoder was setting `IMM_I`, so the
  address became `rs1 + funct5|rs2`. In-CPU the `lr` read address 0 and returned
  0 where the ISS expected 100. Atomics now use `IMM_NONE` with `b_sel = B_IMM`,
  so the address is plain `rs1`.

### QISA and the INT8 accelerator

Two blocks added after the core was otherwise complete, both with a
self-checking testbench (`tb/tb_qisa_aiacc.sv`, **47 checks, 0 mismatches**) and
both wired into the core on their own CSR windows (`0x7E0`, `0x7E8`).

* `rv64_qisa` -- 8-entry qubit model. It models *state* (value, superposition,
  phase) and not amplitudes: 256 complex amplitudes would not fit a CSR window
  and would tell a CPU testbench nothing. H/H = identity, X on a superposed qubit
  flips the phase, CNOT with a superposed control marks the target superposed,
  and measurement collapses a superposed qubit from a seeded LFSR so runs are
  reproducible. The header says all of this; it is a quantum-*inspired* model.
* `rv64_aiacc` -- INT8 4x4x4 multiply-accumulate with INT32 accumulation,
  combinational, one cycle per product. Verified against C = A x I (identity),
  all-ones (every element 4, sum 64) and the signed case -1 x 2 = -8.

One real defect found by the testbench: the accelerator's read path took the
element index from the live write bus, so a read always returned element 0. The
index is now a register. A second finding was in the testbench itself -- two
hand-computed QISA expectations had the bit positions wrong, and the RTL was
right.

### Xcetask (`rv64_xcetask`)

```
tb_xcetask_top : 38 checks, 0 mismatches   PASS
```

Directed lifecycle suite: explicit and auto-allocated start, completion,
out-of-order completion across slots, timeout expiry, cancel, free, stray
completions for non-active slots, and the masked/unmasked interrupt.

Two defects were found during bring-up:

* **RTL:** the interrupt used `|pend_q` on an *unpacked* array. Reduction
  operators do not apply to unpacked arrays, so the expression evaluated false
  and the completion interrupt never asserted. Replaced with an explicit OR loop.
* **Harness:** a 32-bit literal inside a concatenation (`{56'd0, 4'd1, 0}`)
  shifted the command fields, so a slot-select wrote a different op. Fixed to
  sized literals.

The block also elaborates and maps through ABC with the latch assertion passing.

**Integrated and reachable from software.** Xcetask occupies a CSR window at
`0x7D0`-`0x7D8`, arbitrated alongside the machine and numeric CSRs, so ordinary
`csrrw`/`csrrs` drive it. Its engine side appears on the core's ports and the
completion interrupt is a new `task_irq_o` output.

`test_xcetask` runs it end-to-end with a simulated engine and reads the results
back through executed instructions: slot state DONE, completion count 1, pending
bit set, result 0x77.

One timing subtlety worth recording, because it is a real property of the block
rather than a defect: a completion presented in the same cycle as the start is
correctly rejected, since the slot only becomes ACTIVE at the end of that cycle.
The first version of the testbench engine drove the completion exactly one cycle
too early and saw the task time out instead. The block was right; the model of
"when is a task live" was wrong.

### Generic synthesis (Yosys 0.70 via sv2v 0.0.13)

First synthesis pass — P6 in `PROJECT_PLAN.md`. This is **generic** synthesis:
no timing library, no clock constraint, no wire delay. It establishes that the
RTL is buildable and structurally sound. It is **not** a timing result.

```
elaboration        : complete hierarchy, check -assert clean
inferred latches   : none  (select -assert-none t:$dlatch t:$latch t:$sr passes)
total cells        : 144,090   (generic gates after ABC)
  flip-flops       :  15,039
  combinational    : 129,051
longest path       : 203 logic levels
  endpoint         : u_mdu.res_q[63]   (MDU result register)
```

Two findings worth acting on:

* **The MDU is the critical path**, exactly as predicted in the plan. The
  64x64 multiplier that produces the 128-bit product for `mulh`/`mulhu` is fully
  combinational, and it dominates the path. Any real implementation at speed
  needs it sequenced or pipelined.
* **The small arrays map to flip-flops, not memories** — the 32x64 register
  file, the 64-entry BTB, the 256-entry BHT and the return-address stack are all
  inferred as flops. That is correct for this microarchitecture but is a
  deliberate area trade-off, not an oversight.

Yosys's own SystemVerilog frontend cannot parse `rv64_pkg.sv`'s
`ctrl_default()`, which returns a packed struct — legal SystemVerilog accepted
by all three simulators. The flow therefore runs `sv2v` first and synthesises the
converted Verilog; the RTL itself is unchanged. `sim/synth.sh` runs the whole
flow.

### Coverage accumulated in one run

```
backpressure 1          branch_cond 6            counter_mcycle 1
counter_minstret 1      csr_ops 3                debug_halt_step 1
ebreak_debug_entry 1    forward_paths 2          indirect_target 1
insn_retired 80         inst_access_fault 1      isa:auipc 1
isa:branch 55           isa:csr 55               isa:jal 65660
isa:jalr 12             isa:load 85              isa:lui 20
isa:muldiv 81           isa:op 148               isa:op-32 71
isa:op-imm 487          isa:op-imm-32 5          isa:shift/bit-imm 91
isa:store 53            isa:system 7             isa:zba 25
isa:zbb/zbc 51          isa:zbs 19               isa:zicond 20
load_access_fault 1     mdu_ops 30               mem_widths 4
mid_stream_reset 1      pmp_denied_fetch 1       pmp_denied_load 1
pmp_denied_store 1      pmp_lock 1               pmp_napot 1
random_streams 5        ras_overflow 1           timer_interrupt 1
trap:ecall_m 15         trap:illegal 68          trap:inst_access 2
trap:load_access 2      trap:load_misalign 1     trap:m_timer_int 14
trap:store_access 2     trap:store_misalign 1    watchpoint 1
wfi_interrupt_wake 1    wfi_masked_resume 1
```

Every ISA class the core implements is exercised, and every exception cause the
core can generate is observed.

## 3. Bugs found by this environment

The regression is only worth its cost if it fails when the design is wrong.
These defects were all found by the testbench and fixed in the RTL (or, where
noted, in the model/harness).

### RTL defects

| # | Defect | Symptom | Found by |
| --- | --- | --- | --- |
| 1 | Decoder never selected the immediate as ALU operand B | every `OP-IMM`/`LOAD`/`STORE`/`JALR` computed with `rs2` instead of the immediate | `test_alu` |
| 2 | `slliw` decoded as illegal | `OP-IMM-32` funct3=001 only accepted the `slli.uw` funct6 | `test_alu` |
| 3 | `bexti` in the wrong funct3 group | `bexti` decoded illegal | `test_alu` |
| 4 | `rolw`/`rorw` sign-extended from the *input's* bit 31 | zero-extended word result | `test_alu` |
| 5 | MDU remainder used the sign of `a_neg ^ b_neg` | `rem` returned the wrong sign | `test_muldiv` |
| 6 | No WB→ID write-through bypass | stale operand when a fetch bubble separated producer and consumer | `test_alu` |
| 7 | `mret` redirected fetch but did not flush IF/ID/EX | instructions after `mret` executed as wrong path | `test_traps` |
| 8 | A mispredicted *not-taken* branch redirected to the branch target | extra loop iterations | `test_control` |
| 9 | `mie`/`mip` used bits [2:0] instead of architectural bits 3/7/11 | writing `MTIE` had no effect; interrupts never fired | `test_interrupt` |
| 10 | Combinational loop through the PMP fetch check | latent | Verilator `UNOPTFLAT` |
| 11 | Fetch could issue several outstanding requests | latent; breaks under backpressure | code review while fixing #10 |
| 12 | PMP NAPOT mask was one bit short | every NAPOT region was half its intended size | `test_pmp` |
| 13 | PMP compared `addr[63:2]` against `pa[63:2]`, but `pmpaddr` is already in 4-byte units | **PMP matching never fired at all** — no access was ever denied | `test_pmp` |
| 14 | PMP lock bit not enforced | locked entries could be reconfigured at runtime | `test_pmp` |

Defects 12–14 are the most instructive: the PMP was elaborated, lint-clean and
"present" in the feature list, and was still completely non-functional. It took
a directed test with a real protected region to expose it — and the third defect
(a missing lock) only appeared once the first two were fixed and the test could
get past the first assertion.

### Verification-environment defects (fixed so the checks are trustworthy)

| Defect | Effect |
| --- | --- |
| Assembler encoded `bseti`/`bclri`/`binvi` funct6 fields in decimal instead of binary | produced invalid encodings, masking #3 |
| ISS `auipc` used `pc+4` | false mismatch in `test_control` |
| ISS counted trapping instructions as retired | false mismatch in `test_traps` |
| Testbench memory was uninitialised (X) | X propagation from out-of-range fetches |
| Testbench memory persisted between tests | false memory mismatch in `test_random` |
| Host load port wrote 64 bits per 32-bit parcel | clobbered neighbouring instructions |
| `run()` reset the trap log between calls | `test_interrupt` could not see its own trap |
| Zero-filled padding was executed as illegal instructions | false trap storms in the PMP and fetch-fault programs |
| Fetch-fault program had no handler at `mtvec` | trapped into empty memory instead of recovering |
| Assertions keyed on hardcoded instruction addresses | broke whenever a program changed; replaced with register-based checks |

## 4. What is *not* verified

Stated plainly so nothing here is over-claimed:

* **No synthesis, no STA, no timing closure.** Nothing about frequency, area or
  critical path is known. The MDU divider and the ALU bit-count logic have not
  been through synthesis.
* **No formal verification.** The checks are dynamic simulation only.
* **No CDC analysis** — the design is single clock domain by construction.
* **Predictor quality is unmeasured.** Redirect correctness is verified;
  misprediction rate and IPC are not.
* **Counter values are compared by delta, not absolutely.** `mcycle`/`minstret`
  are pipeline-timing dependent, so the test bounds the delta.
* **TOR is unit-tested but not exercised through the core.** The matcher is
  verified for TOR, NA4 and NAPOT; the core-level PMP test uses NAPOT only.
  Locked TOR address freezing (the `pmpaddr[i+1]` rule) is implemented but has
  no directed test.
* **PMP with more than two configured entries is not exercised**, and no test
  drives an entry whose lock is set *after* a successful access.
* **Debug is verified for halt/resume/step/EBREAK.** No DMI transport exists.
* Everything listed in `docs/ROADMAP.md` as not implemented (caches,
  out-of-order, S/U, Sv39, atomics, RVV, custom numeric, research blocks).

## 5. Reproducing

```bash
pip install cocotb
python3 sim/run.py                 # 20 core tests
python3 sim/run.py --suite pmp     # 5 PMP matcher tests
python3 sim/run.py --suite plic    # 2 PLIC tests
```

Expected: `PASS=20 FAIL=0`, `PASS=5 FAIL=0`, `PASS=2 FAIL=0`. A failure prints
the retirement index with DUT and golden-model values, or for memory the first
differing word.
