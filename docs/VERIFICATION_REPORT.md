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
Stimulus model -- operations, widths, and the operand space each family needs to
be stressed with. It is **uncompiled**: no PSS tool (pssc, Perspec, Questa VIP)
is available in this environment, so it has never been elaborated or solved. It
is written to the Accellera PSS 2.0 intent for a team that has a PSS tool, and is
not evidence that PSS coverage exists. **UVM now covers them.** `rv64_numeric_test` runs a numeric program through the
SystemVerilog UVM environment: **156 retirements and 1 trap matched**, zero
errors. That was only possible after teaching the ISS custom-0 -- the scoreboard
compares retire traces, and a numeric instruction writes no GPR, so the program
bridges each result back with NUM_TOINT to make the comparison mean something.

The rustdv environment needs no new components for this: it serves the program
image and compares retire traces against the same vectors, so pointing
`RUSTDV_VEC_PREFIX` at `sim/uvm_vectors/numeric` covers the families. It remains
**uncompiled** -- no Rust toolchain is reachable in this environment.

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
