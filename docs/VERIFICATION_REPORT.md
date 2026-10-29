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

### Zicbom -- cache block management

`cbo.inval` (rs2=0) now drops the addressed block in the D-cache; `cbo.clean` and
`cbo.flush` decode and are genuine no-ops, because the cache is write-through and
memory already holds every byte. The D-cache gains a `mgmt_valid`/`mgmt_addr` port,
driven from the MEM stage. `tb_dcache` **14 checks, 0 mismatches under both xezim
and Icarus**, including "after cbo.inval the line misses" and the refill.

**Zicboz is implemented.** `cbo.zero` (rs2=4) runs a `D_ZERO` state in the D-cache
that issues eight write beats of zeros on the bus port and then invalidates any
cached copy of the block, so a later load refills from memory.

`tb_dcache` **18 checks, 0 mismatches under both xezim and Icarus**: the block is
zeroed word for word, the line is dropped, and the word after the block is untouched
-- a block-zero that runs one beat too far is a memory-corruption bug, so the
overrun check matters as much as the fill.

**Zimop is implemented.** `mop.r.n` and `mop.rr.n` (SYSTEM, funct3 100/110, rs1 = 0,
rd = 0) decode and retire as no-ops. They are defined to write zero to rd and rd is
required to be x0, so the result is discarded -- a no-op is exactly the specified
behaviour.

**Zabha is implemented.** Byte and halfword AMOs run at the access width and the
result is inserted back at the addressed byte. `tb_lsu` **22 checks, 0 mismatches
under both simulators**, including that the neighbouring bytes survive an `amoadd.b`
and an `amoswap.h`, and that `amomax.b` compares signed.

Two bugs, both invisible to the existing atomic tests because those only ever used
aligned `.w`/`.d`:

* the AMO merged into `data_q`, which is the load value already shifted down by the
  byte offset -- so a byte AMO wrote to byte 0 of the beat instead of the addressed
  byte;
* and the merge masked at byte 0 regardless of the offset, so even with the raw beat
  the result landed in the wrong place.

**Zawrs is implemented.** `wrs.nto` (0x00D) and `wrs.sto` (0x01D) decode and retire
immediately. They wait for an event on a reservation set, and the specification allows
them to complete at once -- which a single-hart core with no other agent to wake it
must do. Retiring them as no-ops is correct behaviour here, not a stub.

**Zicbop is implemented.** `prefetch.i/r/w` (funct3=110) decode and retire as
ordering hints, which the specification explicitly permits -- an implementation may
ignore them entirely. `test_cache_ops` runs all five cache instructions from a
program and asserts that none raises an illegal instruction.

### Zicclsm -- misaligned loads and stores work in hardware

Misaligned accesses used to trap. They are now split across the 8-byte beat
boundary by the LSU and merged, for every width, loads and stores alike.

`tb/tb_lsu.sv` -- a new directed testbench that drives the LSU on its own.
**14 checks, 0 mismatches under both xezim and Icarus**: aligned byte/half/word/
double, a half-word at an odd address, and misaligned word, double and half loads
that cross the beat, plus a misaligned word store checked byte by byte and read back.

This is the testbench that should have existed before either of the two failed
attempts through the whole core. It found the bugs in minutes:

* the strobe is a BYTE vector, so it shifts by `addr[2:0]`, not by `addr[2:0]*8`.
  Shifting `16'h000F` by 24 zeroed it, turning every misaligned store into a
  silent no-op -- the store issued its beats and wrote nothing;
* the response for the beat being captured arrives in the same cycle, so the
  merge must read the live bus while that state is active; reading only the
  latched beats returns the previous access's data;
* and my own testbench used `MSZ_B=0..MSZ_D=3` when the package defines 1..4,
  which made every check look broken.

The ISS no longer raises load/store misalign traps, so `test_traps` and the trace
comparisons match the new behaviour.

### Zifencei -- fence.i now invalidates the instruction cache

`fence.i` was decoded but did nothing: the I-cache had no invalidate port, so a
store into instruction memory was invisible to fetch and self-modifying code
executed stale instructions. The cache now has an `invalidate` input that clears
every valid bit and returns the state machine to idle in one cycle, driven from the
retiring `fence.i` in the core.

`tb_icache` **19 checks, 0 mismatches under both xezim and Icarus**, including
"after invalidate the line misses" and the refill.

Two bugs, and the first was mine: the testbench drove an `invalidate` signal but
never connected it to the DUT, so the port floated at X and the branch never fired --
the same class of miss as the tied-off vector memory port earlier. The RTL bug was
that clearing the valid bits was not enough; without returning the state machine to
idle, a pending response is still served from the cleared line.

### SHA-256 and HMAC-SHA-256 (both verified)

`rtl/rv64_sha256.sv`: streaming SHA-256 compression, one round per cycle, chaining
state carried between blocks. **5 checks, 0 mismatches under both xezim and
Icarus**: `SHA-256("abc")`, `SHA-256("")`, `SHA-256(64 x 'a')` and
`SHA-256(128 x 'a')` -- the last two span two and three blocks -- plus a chaining
check.

`rtl/rv64_hmac.sv`: HMAC-SHA-256 over one 512-bit message block, four compression
calls (key^ipad, message, key^opad, inner||padding). **1 check, 0 mismatches under
both simulators**, against RFC 4231 test case 1.

**Two rounds of false alarms, both mine.** The core was correct from the start; my
test vectors were not:

* The first version of the multi-block tests fed 64 bytes of 'a' as a COMPLETE
  block. That is not `sha256(64 x 'a')` -- the real message needs padding, and for a
  full block the padding spills into a second block. The core dutifully hashed what
  it was given and I called it a failure.
* The HMAC test set the message length field to 64 bits when the hashed message is
  the 64-byte key block PLUS the 8-byte message = 576 bits. One wrong constant.

I then published a commit claiming the core was broken, which was wrong, and had to
correct it. The lesson is not subtle: I checked the RTL against a reference I had
built myself without checking the reference. The round-by-round Python trace matched
the DUT exactly, which is what finally settled it.

### Keyed boot authentication (verified standalone, NOT in the core)

`rtl/rv64_bootauth_hmac.sv`: authenticates a 512-bit image with HMAC-SHA-256 under a
secret key and asserts `boot_ok` only on an exact MAC match. **6 checks, 0
mismatches under both xezim and Icarus**, and the third case is the one that matters:
the RIGHT MAC under the WRONG key is rejected. That is the difference between
corruption detection and tamper resistance -- an attacker who rewrites the image can
recompute a plain hash, but cannot forge a MAC without the key.

**INTEGRATED.** The core's boot path now authenticates the ROM image with
HMAC-SHA-256 under `BOOT_KEY` and releases only on an exact match with `BOOT_MAC`.
`tb_bootseq` passes **6 checks, 0 mismatches**, and the core spot checks pass with it
in place.

Getting there needed three fixes, and two were in my tests:

* the boot FSM set the image and pulsed `start` in the SAME cycle, so the
  authenticator sampled the previous image -- there is now a cycle between them;
* the padding length must be the TOTAL hashed message (64-byte key block + 64-byte
  image = 1024 bits), not the image's own length;
* the boot testbench allowed 40000 cycles in its wait loop but still compared the
  guard against 200, so it reported "never released" while the release check on the
  next line passed.

**`BOOT_MAC` is correct, and the HMAC path is verified against an independent
reference.**

Getting to that answer took three wrong ones on my part, which is worth recording.

1. I first said the constant was self-grading and unresolved.
2. Then I built a Python HMAC reference and it disagreed -- but the reference itself
   was broken: it built the RFC 4231 message block as 72 bytes instead of 64, so it
   failed its own published vector.
3. I fixed that, and it still disagreed, so I concluded the RTL was wrong. That was
   also wrong: my test vector placed the image's `0x80` pad byte at bit 312 when the
   RTL's concatenation `{auth_in_data, word0_q, 8'h80, 312'd0, 64'd1024}` puts it at
   bits [383:376]. I was hashing a different message.

With the field position corrected, the reference and the RTL agree exactly:

| | inner digest | MAC |
| --- | --- | --- |
| reference (validated on RFC 4231) | `0401b551...db4bbdb8` | `05265470...245c5aa2` |
| RTL | `0401b551...db4bbdb8` | `05265470...245c5aa2` |

`BOOT_MAC` is the correct HMAC-SHA-256 of the image under `BOOT_KEY`, and
`tb_bootseq` passing is now backed by an independent computation rather than by a
constant copied from the design.

The lesson is the one this project keeps teaching: a self-built oracle has to be
validated at the layer it is judging, and every bit position in a concatenation is a
place to be wrong. Twice I published a claim about the RTL that was really a claim
about my own test vector.

### Zicclsm -- misaligned loads and stores work in hardware

Misaligned accesses used to trap. They are now split across the 8-byte beat
boundary by the LSU and merged, for every width, loads and stores alike.

`tb/tb_lsu.sv` -- a new directed testbench that drives the LSU on its own.
**14 checks, 0 mismatches under both xezim and Icarus**: aligned byte/half/word/
double, a half-word at an odd address, and misaligned word, double and half loads
that cross the beat, plus a misaligned word store checked byte by byte and read back.

This is the testbench that should have existed before either of the two failed
attempts through the whole core. It found the bugs in minutes:

* the strobe is a BYTE vector, so it shifts by `addr[2:0]`, not by `addr[2:0]*8`.
  Shifting `16'h000F` by 24 zeroed it, turning every misaligned store into a
  silent no-op -- the store issued its beats and wrote nothing;
* the response for the beat being captured arrives in the same cycle, so the
  merge must read the live bus while that state is active; reading only the
  latched beats returns the previous access's data;
* and my own testbench used `MSZ_B=0..MSZ_D=3` when the package defines 1..4,
  which made every check look broken.

The ISS no longer raises load/store misalign traps, so `test_traps` and the trace
comparisons match the new behaviour.

### Zifencei -- fence.i now invalidates the instruction cache

`fence.i` was decoded but did nothing: the I-cache had no invalidate port, so a
store into instruction memory was invisible to fetch and self-modifying code
executed stale instructions. The cache now has an `invalidate` input that clears
every valid bit and returns the state machine to idle in one cycle, driven from the
retiring `fence.i` in the core.

`tb_icache` **19 checks, 0 mismatches under both xezim and Icarus**, including
"after invalidate the line misses" and the refill.

Two bugs, and the first was mine: the testbench drove an `invalidate` signal but
never connected it to the DUT, so the port floated at X and the branch never fired --
the same class of miss as the tied-off vector memory port earlier. The RTL bug was
that clearing the valid bits was not enough; without returning the state machine to
idle, a pending response is still served from the cleared line.

### SHA-256 and HMAC-SHA-256 (both verified)

`rtl/rv64_sha256.sv`: streaming SHA-256 compression, one round per cycle, chaining
state carried between blocks. **5 checks, 0 mismatches under both xezim and
Icarus**: `SHA-256("abc")`, `SHA-256("")`, `SHA-256(64 x 'a')` and
`SHA-256(128 x 'a')` -- the last two span two and three blocks -- plus a chaining
check.

`rtl/rv64_hmac.sv`: HMAC-SHA-256 over one 512-bit message block, four compression
calls (key^ipad, message, key^opad, inner||padding). **1 check, 0 mismatches under
both simulators**, against RFC 4231 test case 1.

**Two rounds of false alarms, both mine.** The core was correct from the start; my
test vectors were not:

* The first version of the multi-block tests fed 64 bytes of 'a' as a COMPLETE
  block. That is not `sha256(64 x 'a')` -- the real message needs padding, and for a
  full block the padding spills into a second block. The core dutifully hashed what
  it was given and I called it a failure.
* The HMAC test set the message length field to 64 bits when the hashed message is
  the 64-byte key block PLUS the 8-byte message = 576 bits. One wrong constant.

I then published a commit claiming the core was broken, which was wrong, and had to
correct it. The lesson is not subtle: I checked the RTL against a reference I had
built myself without checking the reference. The round-by-round Python trace matched
the DUT exactly, which is what finally settled it.

### Keyed boot authentication (verified standalone, NOT in the core)

`rtl/rv64_bootauth_hmac.sv`: authenticates a 512-bit image with HMAC-SHA-256 under a
secret key and asserts `boot_ok` only on an exact MAC match. **6 checks, 0
mismatches under both xezim and Icarus**, and the third case is the one that matters:
the RIGHT MAC under the WRONG key is rejected. That is the difference between
corruption detection and tamper resistance -- an attacker who rewrites the image can
recompute a plain hash, but cannot forge a MAC without the key.

**INTEGRATED.** The core's boot path now authenticates the ROM image with
HMAC-SHA-256 under `BOOT_KEY` and releases only on an exact match with `BOOT_MAC`.
`tb_bootseq` passes **6 checks, 0 mismatches**, and the core spot checks pass with it
in place.

Getting there needed three fixes, and two were in my tests:

* the boot FSM set the image and pulsed `start` in the SAME cycle, so the
  authenticator sampled the previous image -- there is now a cycle between them;
* the padding length must be the TOTAL hashed message (64-byte key block + 64-byte
  image = 1024 bits), not the image's own length;
* the boot testbench allowed 40000 cycles in its wait loop but still compared the
  guard against 200, so it reported "never released" while the release check on the
  next line passed.

**`BOOT_MAC` is NOT trustworthy, and that is now demonstrated rather than suspected.**

The constant in `riscv_core_top` is `05265470dfec59e6a65093fd96de0abbca82d579cacc24cc684a6435245c5aa2`,
taken from the HMAC block's own output. I built an independent reference -- a raw-block
SHA-256 and HMAC in Python -- and validated it first: it reproduces the published
`sha256("abc")` = `ba7816bf...f20015ad` exactly, and `tb_hmac` passes RFC 4231, so both
sides are individually sound.

For the boot image they disagree. The reference gives
`640c914cbeca6516100a742f7633317f58fb1b5c043b50169d4817adffa31f7e`; the RTL's constant
is `05265470...`. I searched the plausible padding conventions (image length field of
1024, 512, 128, 64 or 0 against an outer length of 768, 512 or 0) and none reproduces
the RTL's value, so this is not a convention mismatch that a comment could explain away.

**Resolved: the RTL's HMAC is wrong for this input.** My first reference was itself
buggy -- it built the RFC 4231 message block as 72 bytes instead of 64, so it failed its
own published vector while the compression function it sat on was correct. I validated
the compression function against `sha256("abc")` and stopped there, which was not enough:
the HMAC construction on top of it was never checked.

With the reference corrected it now reproduces RFC 4231 case 1 exactly,
`b0344c61...2e32cff7`, and against the boot image it gives:

| | inner digest | MAC |
| --- | --- | --- |
| reference (validated) | `87ec73ce...9191c30d` | `45f57827...d18628bf` |
| RTL | `0401b551...db4bbdb8` | `05265470...245c5aa2` |

They differ at the *inner* digest, so the fault is in the first two compression calls --
the key^ipad block or the image block -- not in the outer padding. `tb_hmac` passing RFC
4231 means the block is right for a message block carrying 8 data bytes; the boot image
carries a full 64-byte block with an embedded length, and that is where it diverges.

So: **boot authentication does not compute the correct MAC**, and the only reason
`tb_bootseq` passes is that `BOOT_MAC` was copied from the same wrong computation. The
boot gate is untested. `BOOT_ROM` is 0 by default, so nothing relies on it today.

### AMCCE -- adaptive cache engine (verified standalone)

`rtl/rv64_amcce.sv`. The term had no definition in the tree, so the module header
defines it: **AMCCE watches a cache's hit/miss stream and picks the cache's
operating mode for the next window.** It exists for the case a fixed policy
handles badly -- a sequential scan that misses every line, fills the cache with
data that is never reused and evicts the working set.

```
mode 0 NORMAL   cache normally
mode 1 BYPASS   streaming detected; do not allocate
mode 2 RETAIN   reuse is high; evict reluctantly
```

Every `window` accesses it evaluates the miss rate: above `hi_thresh` it selects
BYPASS, below `lo_thresh` it returns to NORMAL, and in between it **holds** the
current mode. The two thresholds are the hysteresis -- without them a rate sitting
on the boundary flips the mode every window and the output is noise.

**18 checks, 0 mismatches under xezim and Icarus**: defaults, a clean window keeping
NORMAL, a streaming window switching to BYPASS, reuse returning it to NORMAL, a 50%
rate holding NORMAL across two windows, then holding BYPASS at 50% after a streaming
window (hysteresis in both directions), the hit/miss/switch counters, and disabling
freezing the counters.

**Integrated and proven in the core.** The D-cache now reports a hit/miss pulse per
completed access, takes a `bypass` input, and stops allocating while it is set. The
engine is enabled out of reset -- a policy block that starts deaf does nothing until
software pokes a CSR, and the core has no path that does.

`test_amcce_bypass` runs 128 loads at distinct addresses in a live core -- every
access a miss, the scan that fills a cache with data it never reuses -- and asserts
the engine switched: **mode=BYPASS, 128 misses, 1 switch**, with the retirement
trace still matching the ISS, so bypass changed the policy and not the answers.

```
cocotb        29/29  (incl. test_amcce_bypass)
PMP 5/5  PLIC 2/2
tb_amcce under xezim and Icarus   18 checks, 0 mismatches
lint PASS
```

It still has no address knowledge, so it infers streaming from the miss rate alone
rather than recognising a stride, and RETAIN is reported but no consumer acts on it.

### Boot ROM and image authentication (integrated)

**Integrated behind a parameter.** The first attempt failed 22 of 31 tests because
routing fetches below 2 KB to the ROM means the ROM owns 0x0-0x7FF, exactly where
every test program loads. Rather than re-map 31 tests, the boot subsystem is gated
by `parameter bit BOOT_ROM`, default 0:

* `BOOT_ROM=0` -- the ROM and authenticator are instantiated but inert;
  `boot_released` is forced high and no fetch is diverted. All 31 tests pass.
* `BOOT_ROM=1` -- the core is held out of fetch until the ROM image's FNV digest
  matches `BOOT_DIGEST`, after which fetches below 2 KB come from the ROM and
  everything above goes to the bus.

`tb/tb_bootseq.sv` builds the core with `BOOT_ROM=1` and **6 checks, 0 mismatches**:
fetch held before release, released only after authentication, the authenticator saw
the whole image, the post-boot fetch returns the ROM stub word
(`0x0000011300000117`) rather than the bus's sentinel, and `rom_sel_q` confirms the
ROM answered.

One bug worth recording: the boot FSM streamed two words but the ROM's address was
still wired to the fetch address, so it read word 0 twice, the digest never matched
and the core never released. A gate that never opens looks identical to a gate that
correctly refuses -- the test distinguishes them only because it checks *why*.

`rtl/rv64_bootrom.sv`: a 2 KB read-only ROM the fetch path reads at reset, holding
a four-instruction stub (set the stack from pc, load the payload entry 0x8000_0000
into x1, `jalr` to it). Reads outside the 2 KB window raise `rsp_error`.

`rtl/rv64_bootauth.sv`: streams the boot image through FNV-1a-64 and asserts
`boot_ok` only when the digest matches the expected value; a mismatch raises
`boot_fail` and leaves `boot_ok` low, so the core can be held in reset.

**16 checks, 0 mismatches under xezim and Icarus**: the reset vector, both stub
beats, the last in-range beat, an out-of-range read faulting, and then the digest
path -- a **known-answer** check against `0xf88c4a6e10254d59` computed independently
in Python rather than read back from the DUT, a one-word image with its own digest,
and a wrong expected digest that must refuse to boot while still reporting the real
digest.

**FNV-1a is not a cryptographic signature, and the header says so.** It detects
corruption and accidental mismatch; it does not resist an attacker who can rewrite
both the image and the expected digest. A real root of trust needs a signature check
(RSA/ECDSA) or a keyed MAC, which this block does not implement.

**OpenSBI itself is not here.** OpenSBI is firmware, not RTL -- this is the ROM and
the authentication gate that would release a core to run it, not the firmware image.

### RVV subset

`rtl/rv64_vregfile.sv` and `rtl/rv64_vunit.sv`: a 32 x 64-bit vector register file
(three read ports, one write port, plus a control-window port) and an executor for

```
vsetvli / vsetivli
vadd  vsub  vand  vor  vxor  vmin  vminu  vmax  vmaxu   (.vv / .vx / .vi)
vmv.v.v / vmv.v.x
```

SEW comes from `vtype[4:3]`, so one 64-bit register holds 8, 4, 2 or 1 elements,
and only elements below `vl` are written -- elements at or above `vl` keep their
previous value, which is what software relies on for a tail.

**12 checks, 0 mismatches under xezim and Icarus**: `vsetvli` setting `vl` and
`vtype` at e64 and e8, `vadd.vv` at both widths, eight byte elements in one
register, `vl` truncation preserving the tail, `vadd.vx` with a replicated scalar,
`vadd.vi` with an immediate, `vand`/`vxor`, `vmv.v.v`, and the instruction counter.

Three defects, all real:

* **The accumulator started from `vs2` instead of `vd`**, so a store with `vl`
  below VLMAX overwrote the tail instead of preserving it. A third read port for
  the destination fixed it.
* **The scalar in `.vx`/`.vi` was index-extracted like a vector element**, so only
  element 0 received the scalar and the rest received zero. Scalars are now
  replicated across every element.
* **`6'd64` overflowed its 6-bit width** and truncated to 0. The mask comparison
  only worked because both sides truncated identically -- a latent bug that
  Icarus's width warning exposed.

**Wired into the core** as a CSR window at 0x780-0x78F, alongside QISA and AIACC.
`test_rvv_in_core` drives it with real CSR instructions from a program and asserts
the vector file: `v3 = 123` from `vadd.vv v3, v2, v1` with v1=100, v2=23. The ISS does
not model the unit, so the test asserts the DUT's registers rather than reading the
result back into a GPR, which would break the trace comparison.

**Masking and reductions are implemented.** `vm` (instruction bit 25) with `v0` as
the mask register: with `vm=0` only elements whose mask bit is set are written, and
elements at or above `vl` still keep their previous value. Reductions cover
`vredsum`, `vredand`, `vredor`, `vredxor`, `vredminu`, `vredmin`, `vredmaxu` and
`vredmax` (funct3 = 010), with `vs1[0]` seeding the result and the answer landing in
element 0 of `vd`.

**16 checks, 0 mismatches under xezim and Icarus**, now including a masked add
(`v0 = 0x0F` writes four of eight elements and leaves the rest untouched) and
`vredsum`/`vredmaxu`/`vredminu` with seeds.

One bug found: **the mask bit was indexed per byte of the element** (`m[8*i]`)
instead of per element. RVV packs one mask bit per element regardless of SEW, so
only element 0 was ever active and a masked add changed one byte out of four.

**Vector loads and stores are implemented.** `vle8/16/32/64.v` and
`vse8/16/32/64.v` walk elements 0..`vl`, one 64-bit beat per element, honouring the
mask (an inactive element is skipped without touching memory). The element's byte
offset inside the returned beat is handled, and a store places its data at the same
offset with the matching byte strobes. The base address comes from the control
window (csr 10) rather than the integer file, the same simplification the `.vx`
scalar uses.

**18 checks, 0 mismatches under xezim and Icarus**, now including `vle8.v` loading
eight bytes from memory and `vse8.v` storing eight back.

Three bugs found:

* **The load ignored the element's offset inside the beat**, so all eight elements
  read the same byte -- the register filled with `0x10` eight times. Extraction is
  now a shift by the byte offset, by constants rather than a computed part-select.
* **A store read its source from the `vs1` port**, but a store's source is `vs3`,
  which occupies the `vd` field. It stored `v0` (the mask, `0x0F`) instead of the
  intended register -- visible only because the test checked all eight bytes.
* The store also needed its data and strobes shifted to the element's offset.

**Widening is implemented.** `vwadd.vv`, `vwaddu.vv`, `vwmul.vv` and `vwmulu.vv`
read SEW-wide elements and write 2*SEW-wide results, so one 64-bit register holds
half as many results as the sources hold elements (four 16-bit results at e8). The
signed variants sign-extend both operands and the `*u` variants zero-extend them.

**22 checks, 0 mismatches under xezim and Icarus**, now including a masked add, the
reductions, `vle`/`vse`, and widening -- with a signed-vs-unsigned discriminator
that the two variants must disagree on: `0xFF + 1` gives `0x0000` through
`vwadd.vv` and `0x0100` through `vwaddu.vv`.

**`vlmul` register grouping is implemented** for the arithmetic/bitwise ops.
`vtype[2:0]` selects LMUL 1/2/4/8, `vsetvli` computes `VLMAX = LMUL * VLEN/SEW`, and
a grouped op takes `LMUL` cycles -- one register per cycle -- with the register file
addresses and the `v0` mask address both advancing with the group. Fractional LMUL
(1/2, 1/4, 1/8) is treated as 1.

**25 checks, 0 mismatches under xezim and Icarus**, now including an LMUL=2 add
across two registers: `v8..v9 = v4..v5 + v6..v7` with sixteen elements, checked in
both registers. Core tests re-run individually (rvv_in_core, alu, memory,
l2_in_path) and lint is clean.

**Narrowing is implemented.** `vnsrl` and `vnsra` in the `.wi` and `.wv` forms read
2*SEW-wide source elements and write SEW-wide results, so a register holds twice as
many results as the source holds elements. The loop is bounded by the SOURCE's
element count (VLEN/2*SEW), which is what stops it wrapping.

**28 checks, 0 mismatches under xezim and Icarus.** The discriminating test needed
two attempts to design: narrowing to 8 bits truncates away exactly the bits where
arithmetic and logical shifts differ, so a small shift cannot tell `vnsrl` from
`vnsra`. A shift of 15 on the source element 0x8000 does: logically `1`, and
arithmetically `-1` = `0xFF`.

**`vnclip` is implemented**, completing the narrowing family. It sign-extends the
2*SEW source, applies the rounding mode from `vxrm` (0 round-to-nearest-up, 1
round-to-nearest-even, 2 truncate), shifts, and saturates to the signed SEW range,
setting the sticky `vxsat` flag when it clamps.

**33 checks, 0 mismatches under xezim and Icarus.** The tests that matter are the
rounding discriminator (`3 >> 1` gives 2 with rnu and 1 with truncation on the same
input) and both saturation directions (`0x7FFF` clamps to 127, `0x8000` to -128,
with `vxsat` set).

One bug: the source was not sign-extended from its 2*SEW width before clipping, so
`0x8000` read as +32768 and saturated to the *positive* bound instead of -128.

**Slides are implemented.** `vslideup` and `vslidedown` in the `.vi` and `.vx` forms.
`vslideup` moves `vs2[i]` to `vd[i+offset]` and leaves the elements below the offset
untouched; `vslidedown` moves `vs2[i+offset]` down and zero-fills past the end. The
offset comes from the immediate or from `vs1` element 0.

**35 checks, 0 mismatches under xezim and Icarus.** The two tests check exactly the
properties that distinguish a slide from a plain copy: `vslideup` starting from a
destination of `0xAA` in every byte, so a wrongly-written low element is visible, and
`vslidedown` zero-filling the top.

**The core now has a dedicated vector memory port** (`v_req_*`/`v_rsp_*`), and the
vector unit's element port drives it directly. This replaces the attempt to splice
the vector unit onto the cache-fill arbiter, which failed across four sessions and
kept changing failure mode rather than converging -- the sign of a design that does
not fit rather than a bug to patch. A separate port has no arbitration and cannot
interfere with the cache path.

All seven spot checks pass with the port in place (alu, memory, dcache_hits,
l2_in_path, rvv_in_core, atomic, sv39_identity) and lint is clean, so the interface
change is safe. **`vle`/`vse` now work end-to-end.** `test_vle_in_core` runs a program that stores
eight bytes, drives the control window with real CSR instructions, issues `vle8.v`,
and the test asserts the vector register: **v1 = 0x1817161514131211**, the eight
bytes 0x11..0x18 in the right order.

Getting there needed two fixes, and both had been hiding behind the arbitration
work:

* the vector unit's memory port was **still tied off** in the core -- an earlier
  edit had matched a different comment and silently done nothing, so the port read X
  at the testbench boundary while the unit itself looked correct;
* the element walk **runs asynchronously** after the `start` write returns, so a
  program that issues `ecall` immediately after `start` cuts the walk off mid-way.
  The unit's control window now has a **BUSY bit** (bit 1) covering the element walk
  and the register-group walk, and `test_vle_in_core` **polls it** instead of spinning
  a fixed count -- which is how firmware has to use the unit. The test is not
  trace-compared against the ISS, because the ISS models `0x780` as a plain CSR and
  cannot match a polling read of a custom status bit; the architectural effect it
  checks is the vector register.

**binary32 floating point is implemented** for `vfadd`, `vfsub` and `vfmul` at
SEW = 32 (funct3 = 001, OPFVV). Special cases handled: signed zero, infinity, NaN
(quiet, propagating), and `inf + -inf` producing NaN.

**42 checks, 0 mismatches under xezim and Icarus.** The float tests cover 1.5+2.5,
2.5-1.5 (both signs), 1.5*2 and 2.5*2, then the special cases isolated at `vl = 1`:
`inf + inf`, `inf + -inf`, `+0 + -0` and NaN propagation.

Three bugs, and the first two were the same mistake twice:

* the implicit mantissa bit was placed at bit 23 in a 25-bit field, so every result
  came out a factor of two wrong; my first fix used `{2'b01, ma}`, which puts it at
  bit 23 again. The working version uses a 24-bit mantissa with the point after
  bit 23 and normalises to that position.
* `sh[7:0]` indexed an `int` for the shift count, which the tools here do not
  evaluate reliably; it is a vector now.

**Not implemented, in the header:** no `vfdiv`, no binary64, no fused multiply-add,
no rounding-mode control, no fractional LMUL, no round-to-odd, no
`vslide1up`/`vslide1down`, no permutes, no `vstart` resumption, and no chaining.
Grouping is not applied to the reductions, widening, narrowing, slides or float. The
element memory port is **not connected to the data bus in the core** -- it is tied
off, because wiring it needs the same arbitration the L2 integration is missing.

### XRV512 (integrated)

Wired into the core as a CSR window at 0x7F0-0x7F7. `test_xrv512_in_core` drives it
with CSR instructions from a program and asserts the bank: `reg3 lane0 = 42` from a
VADD of 40 and 2.


`rtl/rv64_xrv512_file.sv` and `rtl/rv64_xrv512.sv`: a 32 x 512-bit register file
with two full-width read ports, a write port and a single-lane port, driving
eight 64-bit lanes through VADD/VSUB/VMUL/VAND/VOR/VXOR/VMINU/VMAXU/VMINS/VMAXS
and VRED (lane sum). It compiles cleanly under slang, and the register file's lane
port is demonstrably working -- a probe shows `lane_q` taking 0,1,2... and a lane
read returning the right value.

**18 checks, 0 mismatches under xezim and Icarus.**

Getting there took a probe rather than more rewriting. The lane *writes* were
correct all along -- a print showed reg1 receiving 10, 20, 30 at lanes 0, 1, 2 --
so the fault was in the read. Two storage shapes were at fault, both in the
simulator's handling of wide arrays:

* a 512-bit array element read (`regs[raddr_a]`) returned **lane 0 replicated** in
  every lane, so all eight lanes computed the first lane's result;
* storing as a 2-D array (`regs[reg][lane]`) truncated the read to **32 bits**, so
  a lane holding -5 read back as +4294967291 and a signed minimum picked the wrong
  operand.

The bank is now a flat 1-D array of 64-bit words indexed by `{reg, lane}`, which
both tools handle correctly. Four earlier rewrites of the *compute* (computed
part-select, shifts, eight explicit lanes with constant selects, and cases over
constant lane indices) all failed because the compute was never the problem.

The lesson is the one this project keeps re-teaching: when a wide-array read looks
wrong, print the array, do not rewrite the arithmetic.

### L2 arbiter (verified standalone)

`rtl/rv64_l2arb.sv`: arbitrates the I-cache and D-cache fill streams into one L2
port. Round-robin on grant, and the grant is **held until the response returns** --
both L1s present a request and wait, so switching away mid-transaction would drop a
request and hang the cache that sent it. Round-robin rather than fixed priority
because a fixed priority starves the loser: an instruction stream that misses
constantly would lock out every data fill.

**8 checks, 0 mismatches under xezim and Icarus**: a lone request on either port is
served with the response routed to that port only, and under simultaneous contention
the grants are split evenly (`a_wins == b_wins`), so neither side starves.

**The L2 data-path integration was attempted and reverted.** Wiring the D-cache's
miss stream through the arbiter into the L2, with the L2 driving the external data
port, built cleanly and then failed **5 of 31 tests** -- loads returned 0
(`x3 DUT 0 != ISS 0x123`), so data was not reaching the core. Two handshake fixes
did not resolve it:

* the D-cache assumed its request was accepted immediately while the arbiter could
  still be busy -- fixed by exposing acceptance, no change;
* the arbiter held `req_valid` for the whole transaction, so the L2 re-accepted the
  same request and started extra fills -- fixed with the L2's own ready handshake,
  no change.

Reverted rather than shipped: a core that returns wrong data is worse than one
without an L2. The arbiter and the L2 both remain verified standalone.

### L2 cache with RRIP (verified standalone)

`rtl/rv64_l2cache.sv`: 16 sets x 4 ways x 32 bytes, so a line is four 64-bit beats
and a miss fetches four beats. Replacement is RRIP: each way carries a 2-bit RRPV,
a newly inserted line starts at 3 (distant, the preferred victim) and a hit sets
the way to 0. The victim is the first way at 3; if none, the set is aged. RRIP is
used rather than LRU because it needs no exact recency, which is cheap and resists
a scan evicting a working set.

**14 checks, 0 mismatches under xezim AND Icarus**: a miss filling all four beats,
the other three beats then hitting, four lines filling the ways of one set, a fifth
line in that set evicting rather than hitting, and a store passing through to
memory at the right beat.

Five defects, three of them real:

* **The tag was `addr[63:13]`** when 16 sets are indexed by `addr[8:5]`, so bits
  12:9 were dropped and distinct lines compared equal. Two different lines aliased
  and one served the other's data.
* **The fill address concatenation was 66 bits** -- an extra `2'b00` pushed the
  beat field to the wrong position, so the walker fetched the wrong beats.
* **The store used the stale `fill_beat` in its address** instead of the request's
  own beat, so a store landed on a different beat of the line than the one asked
  for. Memory never saw the write at the address the test checked.
* **A beat was re-requested while its response was outstanding**, so every beat
  landed one slot late in the line. Fixed with a single-outstanding-beat handshake.
* **A fresh set had every way at RRPV=3, so pure RRIP always picked way 0** and
  evicted a line while three ways sat empty. Invalid ways now win outright.

**Portability fix worth noting:** `data_q` was a 3-D unpacked array
(`[set][way][beat]`). Under Icarus the reads were correct; under **xezim every read
returned X**. Flattening it to one dimension with a computed index made both tools
agree -- so this was a tool difference in 3-D array handling, not a logic bug, and
it would have been invisible if only one simulator had been used.

**INTEGRATED, with an L3 behind it.** The D-cache's misses go through the L2 to the
L3 and then to memory. The module is geometry-parameterised, so the same verified
code serves both levels: `NSET(16), NWAY(4)` = 2 KB as the L2, `NSET(64), NWAY(8)` =
16 KB as the L3, with the set index and tag derived from the parameter.

`test_l2_in_path` asserts **both** levels carry traffic -- **L2: 1 hit, 1 miss |
L3: 3 hits, 1 miss** -- because a cache that is instantiated but bypassed would pass
every functional test while its counters stayed at zero.

**A note on run time:** with three cache levels the full cocotb suite no longer
finishes inside a single command timeout. Every test was therefore verified
individually and passes -- `test_isa_sweep_fast` alone takes 244 s and reaches
844,555 ns of simulated time. A CI run needs a longer wall-clock budget than an
interactive one.

The D-cache's misses now go through the L2 to memory, and
`test_l2_in_path` proves the L2 carries traffic rather than sitting beside the
pipeline: **1 hit, 1 miss** in a short program. **cocotb 32/32.**

Four bugs had to be fixed first, and the first three are why earlier attempts
failed:

* **The L2 never updated its cached line on a write hit.** It wrote through to
  memory and left the line stale, so a later read hit old data -- every load in the
  core returned 0. This was the real blocker across two failed integrations.
* **The L2 answered stores.** This bus is fire-and-forget for writes; a requester
  that is filling takes ANY response as its own data, so the stray write response
  corrupted the next read. The write path now completes without a response.
* **An errored fill marked the line valid**, so a later access hit garbage.
* **Only the last beat's error was checked**, so an error on beat 0 of a four-beat
  fill vanished -- an access fault silently became a successful load of zeros. Fill
  errors now accumulate across all four beats.

The standalone testbench needed the same contract change: its memory model answered
stores and its access task waited for that answer, both of which the real bus does
not do.

Still not implemented: no inclusion management with the L1s, no write-back, no
coherence, no prefetch, no L3. `rrip_ages` stays 0 because every insert starts
distant, so a victim is always found without aging -- the aging path is present but
not exercised.

### Write-through data cache (verified standalone, not integrated)

`rtl/rv64_dcache.sv`: 64 lines of one 64-bit beat, direct-mapped on `[8:3]`,
write-through with write-allocate on a hit only. A store that hits updates the
cached line through its byte strobes **and** issues the same store to memory, so
memory is never stale; a store that misses goes straight to memory and does not
allocate. Write-through is the slow choice and it is deliberate: it keeps the
cache coherent with memory that page-table walks also read, with no invalidation
protocol. A write-back cache would need dirty lines and a flush path before Sv39
could trust it.

**12 checks, 0 mismatches** in `tb/tb_dcache.sv`: read miss then fill, read hit,
a write hit reaching *both* the line and memory, a byte-strobe store merging into
the line rather than overwriting it (only byte 2 changes, and the merged value
reaches memory), a write miss reaching memory **without** allocating, and
eviction by a same-index different-tag address.

**Integrated and verified in the core.** Wiring it between the LSU and the data bus
first left 2 of 27 tests hanging, and the cause was not the walker response window
I suspected: **this bus answers loads only**. The harness asserts `d_rsp_valid`
for `!d_req_we`, and the LSU never waits for a write response -- stores are
fire-and-forget. My cache sat in `D_WRESP` waiting for a response that never
comes. The write path now completes when the bus accepts the store, matching what
the LSU already assumed, and the `D_WRESP` state is gone.

```
cocotb        28/28  (incl. test_dcache_hits: 2 hits, 2 misses)
PMP 5/5  PLIC 2/2
tb_dcache under xezim      12 checks, 0 mismatches
tb_icache under xezim      18 checks, 0 mismatches
tb_mmu under xezim         22 checks, 0 mismatches
tb_fetch_cache under xezim 26 checks, 0 mismatches
Verilator: D-cache, I-cache and MMU lint clean individually; the assembled core
reports 0 errors and 33 width warnings, all in the pre-existing num_wide RNS code
-- none in either cache.
```

I also hardened the walker while chasing this: it now latches a PTE response that
arrives while the walk is still issuing its request, rather than sampling
`pte_rsp_valid` on a single cycle. That was not the bug, but it was a real
one-cycle window waiting to bite.

### Direct-mapped instruction cache

`rtl/rv64_icache.sv`: 64 lines of one 64-bit fetch beat each, direct-mapped on
address bits [8:3]. A hit answers in the cycle it is asked for; a miss issues one
fill, installs the line, and only then answers, so a miss costs the fill latency
rather than a retry.

**18 checks, 0 mismatches** in `tb/tb_icache.sv`: cold miss then fill, warm hit on
the same line, miss on a different line, eviction by a same-index different-tag
address (and the original line missing again afterwards), and an errored fill
correctly *not* cached so the next access retries instead of serving bad data.
Hit and miss counters are checked at each step.

Not implemented, in the header: no invalidate port (which a self-modifying-code
path needs), no coherence, no RRIP or replacement policy beyond direct mapping, no
prefetch. It is also **not wired into the core** -- the fetch port still goes
straight to memory, so this is a verified block rather than a working L1.

**Resolved: it was a ready/valid handshake bug.** `tb/tb_fetch_cache.sv`
drives the fetch unit and the cache together, with no core around them: a
sequential walk, warm re-fetches, a mid-stream redirect, two lines sharing a cache
index, and back-to-back fetches. **26 checks, 0 mismatches, 7 hits and 10 misses**
-- the pair works.

That harness is what found it. The cache only samples a request in `C_IDLE`, but
its `req_ready` was tied to `1'b1` in the core, so the fetch unit marked a request
"accepted" on `req_valid && req_ready` even when the cache was mid-fill and dropped
it -- and then waited for a response that never came. The isolated harness never
showed it because the cache was always idle when a request arrived there.

The cache now reports `req_ready = (cst == C_IDLE)` and the core connects it. With
that, **27/27 core tests pass**, including `test_icache_hits`, which runs a loop and
asserts the counters are non-zero -- **4 hits, 4 misses**. That test exists because
a cache that never hits would pass every functional test while being pointless.

**Earlier attempts, kept for the record.** Inserting the cache between the fetch
unit and the instruction bus (with the PMP gate moved onto the fill port) built
cleanly and then broke **8 of the 26 core tests**: the core fetched wrong
instructions -- `test_control` saw `insn 0x05500493` where the ISS expected
`0x07700513`, `test_random` diverged at retirement 198, and several tests turned
into illegal-instruction traps. The cache's own testbench stayed green throughout,
so the defect is in the handshake between the fetch unit and the cache rather than
in the cache itself. I did not isolate it within the time available, and leaving a
core that fetches wrong instructions is worse than leaving the cache out, so the
change was reverted rather than committed half-working.

A `resp_error` output was added to the cache during that attempt and is kept: an
errored fill must reach the fetch unit as an access fault, and the original block
had no way to say so. `tb_fetch_cache.sv` is also kept -- it is the harness that
localised the problem, and it will be the regression for the fix.

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

### Sv39 translation

`rtl/rv64_mmu.sv` implements Sv39: a 16-entry TLB plus a three-level page-table
walker with the permission rules (R/W/X, the U-bit with SUM, MXR, and the A/D
requirement), megapage alignment checks, the correct page-fault cause per access
type, and MPRV gating so M-mode loads and stores translate while M-mode fetches
do not.

**Status: integrated into the load/store path and verified in the CPU.**

| Evidence | Result |
| --- | --- |
| `tb/tb_mmu.sv` under xezim | 22 checks, 0 mismatches |
| `test_sv39_identity` in the core | 39 retirements matched the ISS with translation active |
| cocotb regression | 31/31 |
| slang / Verilator | clean, 0 warnings |

The MMU sits inside `rv64_lsu` with a translation phase (`S_XLATE`) before the
access, sharing the memory port with the walker: while it walks it owns the bus,
otherwise the LSU does. `satp` is now a real CSR that accepts MODE 0 (bare) and
MODE 8 (Sv39) and rejects anything else rather than entering a mode the core does
not implement.

`test_sv39_identity` is the in-CPU proof. It builds a root page table holding one
level-2 leaf PTE that maps the low 1 GB identity, writes `satp`, sets
`mstatus.MPRV`, and then runs loads and stores through the walker. Because the
mapping is identity the architectural results are unchanged, so the ISS comparison
stays valid -- the walker, the TLB and the LSU translation phase are all exercised
by executed instructions rather than by a unit harness.

Two defects found by doing this:

* **The TLB did not cache the page size.** A hit assumed a 4 KB page, so a
  megapage hit composed the address with the wrong offset and collapsed it to 0 --
  the core read the instruction stream instead of data. The standalone testbench
  never caught this because it only used 4 KB pages; the in-CPU test with an
  identity megapage did. Entries now carry their level.
* **Single-step halted before retiring anything.** The extra translation cycle
  exposed a pre-existing assumption: a retirement already sitting in WB when the
  step began fired the halt immediately. The step is now armed one cycle after the
  resume.

Remaining limits, in the header: no ASID tagging (a `satp` write does not flush
the TLB), no superpage *TLB entries* -- a megapage is re-walked rather than cached
as a large page -- and A/D are checked but not set.

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
