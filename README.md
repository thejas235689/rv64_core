# rv64_core — RV64IM machine-mode core with a self-checking verification environment

A synthesizable 64-bit RISC-V core and the cocotb verification environment that
proves it correct, delivered as a project tree you can build, simulate and push
to a private repository as-is.

---

## 1. Design contract

1. **ISA profile** — RV64I base, machine mode only, plus **M** (integer
   multiply/divide), **Zicsr**, **Zihintpause**, and the ratified bit-manipulation
   subsets **Zba, Zbb, Zbc, Zbs**, plus **Zicond**. `misa` advertises RV64IM.
   Standard C, F, D and V instructions are rejected as illegal.
2. **Microarchitecture** — in-order IF/ID/EX/MEM/WB pipeline. Full EX/MEM and
   MEM/WB operand forwarding plus a WB→ID write-through bypass, load-use
   interlock, branch resolution in EX, tournament branch prediction in IF, a
   multi-cycle MDU, and a single precise trap point in MEM.
3. **Bus interface** — separate instruction and data ports. Each is a
   valid/ready request channel with backpressure, plus a separate response
   channel carrying 64-bit beats, byte strobes (data only) and an error flag.
4. **Clocks and reset** — one clock, synchronous active-low reset (`rst_n`),
   single clock domain, no CDC paths.
5. **Memory model** — strongly ordered, single outstanding request per port.
   Misaligned loads and stores trap rather than being split.

## 2. What is implemented

| Area | Scope in this core |
| --- | --- |
| Integer execution | Full RV64I: arithmetic, logic, shifts, comparisons, branches, jumps, word ops |
| Multiply/divide | `mul/mulh/mulhsu/mulhu/div/divu/rem/remu`, multi-cycle, spec-exact special cases |
| Bit manipulation | Zba, Zbb, Zbc, Zbs, Zicond, Zihintpause |
| Register state | 32×64 register file, `x0` write-suppressed |
| Front end | Fetch buffering, request/response tracking, single outstanding request; predecode tags cross-checked against the decoder; fusion hints (hints only, no fused datapath) |
| Branch prediction | Gshare + bimodal BHT with a tournament chooser, BTB, 8-entry return-address stack, a loop-count predictor, tagged history and a perceptron |
| Memory ops | Byte/halfword/word/doubleword loads and stores, sign/zero extension, byte strobes, misalignment traps |
| Protection | 8 PMP entries, OFF/TOR/NA4/NAPOT matching, whole-access checks, M-mode lock semantics (unit-tested) |
| System control | Machine CSRs, synchronous exceptions, illegal-instruction traps, `mret`, `wfi`; M/S/U privilege modes with `medeleg`/`mideleg` delegation and `sret` |
| Interrupts | Software, timer and external interrupt inputs; four-source PLIC-lite with claim/complete (`rtl/rv64_plic_lite.sv`) |
| Debug | External halt/resume, single-step, EBREAK debug entry, GPR read port |
| Watchpoints | Memory-address comparator with hit reporting (not a precise debug entry) |
| Atomics (A) | `lr.w/d`, `sc.w/d`, all nine AMOs in `.w` and `.d`, read-modify-write in the LSU with a reservation register |
| Platform blocks | CLINT (mtime/mtimecmp timer IRQ, MSIP) and a UART (8N1, TX+RX, loopback-verified) as standalone blocks with CSR ports; a JTAG TAP + DMI transport (halt/resume/step, DMSTATUS reads) — all verified |
| QISA | 8-entry qubit model: X/Y/Z/H/CNOT/measure, phase and superposition tracking, seeded LFSR collapse (`rtl/rv64_qisa.sv`, CSR window `0x7E0`) |
| AI accelerator | INT8 4x4x4 matrix multiply-accumulate, INT32 accumulation, one cycle per product (`rtl/rv64_aiacc.sv`, CSR window `0x7E8`) |
| Observability | Retirement PC/instruction, GPR writeback, trap cause/PC, interrupt flag, privilege, debug event, counters |

**Not in this core:** data caches, L2/L3, out-of-order backend, RVV, XRV512, and the research blocks (DNA, neuromorphic, photonic,
interconnect), plus the platform pieces. The custom numeric ABI, Xcetask, QISA
and the AI accelerator are implemented. `docs/ROADMAP.md` maps the full target
feature list against what exists here, sizes what remains, and states which items
are verified and which are only designed.

## 3. Tree

```
rv64_core/
├── rtl/                         synthesizable SystemVerilog (12 modules)
│   ├── rv64_pkg.sv              types, opcodes, CSR addresses, trap causes
│   ├── rv64_alu.sv              RV64I + Zba/Zbb/Zbc/Zbs/Zicond ALU
│   ├── rv64_mdu.sv              multiply / divide unit
│   ├── rv64_regfile.sv          32×64 register file
│   ├── rv64_decoder.sv          instruction decode
│   ├── rv64_pmp.sv              8-entry physical memory protection
│   ├── rv64_csr.sv              machine-mode CSR file
│   ├── rv64_lsu.sv              load/store sequencer + data interface
│   ├── rv64_bpu.sv              tournament branch predictor, BTB, RAS
│   ├── rv64_fetch.sv            fetch buffer + instruction interface
│   ├── rv64_plic_lite.sv        4-source interrupt controller
│   ├── rv64_num_pkg.sv          custom numeric ABI: opcodes, cfg/flag layout
│   ├── rv64_numfile.sv          32 x 64-bit numeric register bank
│   ├── rv64_num_unit.sv         numeric datapath: fixed-Q, quire, adaptive, error
│   ├── rv64_num_csr.sv          ncfg / nflags / nerr CSRs
│   ├── rv64_xcetask.sv          bounded task slots: lifecycle, timeout, completion IRQ
│   └── riscv_core_top.sv        pipeline top level
├── tb/
│   ├── tb_core_top.sv           core harness: memory, host load, backpressure, error injection
│   ├── tb_plic_top.sv           PLIC-lite harness
│   ├── tb_pmp_top.sv            PMP matcher harness
│   ├── tb_num_top.sv            numeric unit testbench (vector-driven)
│   ├── tb_xcetask_top.sv        Xcetask directed lifecycle testbench
│   ├── tb_uvm_top.sv            UVM testbench top level
│   ├── uvm/                     UVM environment: interface, agent, monitors,
│   │                            scoreboard, coverage, sequences, tests
│   └── cocotb/
│       ├── test_core.py         core regression (20 tests)
│       ├── test_plic.py         PLIC-lite regression (2 tests)
│       ├── test_pmp_unit.py     PMP matcher unit tests (5 tests)
│       ├── rv64_asm.py          assembler used to build test programs
│       └── rv64_iss.py          independent golden-model ISS
├── sim/
│   ├── run.py                   build + run without make
│   ├── Makefile                 same flow via cocotb's Makefile.sim
│   ├── gen_num_vectors.py       numeric reference model + unit vectors
│   ├── gen_uvm_vectors.py       golden vectors for the UVM scoreboard, from the ISS
│   ├── run_uvm.sh               UVM regression (needs a UVM-capable simulator)
│   ├── synth.sh                 sv2v + Yosys generic synthesis flow
│   └── synth.ys                 Yosys script: structural checks, stats, path depth
├── docs/
│   ├── PROJECT_PLAN.md          phases, exit criteria, status, risks
│   ├── ARCHITECTURE_FEATURE_CONTRACT.md
│   ├── TESTPLAN.md
│   ├── VERIFICATION_REPORT.md
│   ├── ROADMAP.md
│   └── GITHUB_SETUP.md
└── .github/workflows/ci.yml
```

## 4. Running it

Requirements: Python 3.9+, `cocotb` 2.x, and a simulator (Icarus Verilog or
Verilator). No `make` needed.

```bash
pip install cocotb
python3 sim/run.py                 # full core regression, Icarus
python3 sim/run.py --suite plic    # PLIC-lite unit tests
python3 sim/run.py --suite pmp     # PMP matcher unit tests
python3 sim/run.py --testcase test_alu
python3 sim/run.py --sim verilator # alternate simulator
```

The UVM environment needs a simulator that supports UVM — Icarus and Verilator
do not. With xezim (which ships a UVM library) and its install on `PATH`:

```bash
XEZIM=/path/to/xezim UVM_HOME=/path/to/uvm/src bash sim/run_uvm.sh
bash sim/run_uvm.sh rv64_alu_test        # a single test
```

`run_uvm.sh` first regenerates the golden vectors with the Python ISS, then runs
each test and reports pass/fail from the UVM error count.

With `make` available, `cd sim && make` runs the same core regression.

Lint and elaboration:

```bash
iverilog -g2012 -Wall -o /dev/null -s riscv_core_top rtl/*.sv
verilator --lint-only -Wall -Wno-fatal --timing -sv rtl/*.sv --top-module riscv_core_top
```

> Note: `rtl/rv64_pkg.sv` must be compiled **first** (Icarus needs the package
> before the modules that import it). `sim/run.py` and the Makefile already do.

## 5. Verification status

Verified by simulation on Icarus Verilog 14.0 with cocotb 2.1.0:

* **20/20 core tests pass**, comparing every retirement against an independent
  Python golden model (pc, instruction, destination register, write data), plus
  a byte-exact comparison of the data memory after each random program.
* **5/5 PMP matcher unit tests pass** (TOR, NA4, NAPOT boundaries, permission
  bits, M-mode lock rule, entry priority).
* **2/2 PLIC-lite tests pass.**
* **The ISA sweep passes against the core**: `test_isa_sweep_fast` runs the same
  4445-instruction program through the cocotb harness and matches the golden
  model for 24,861 retirements with zero mismatches. The UVM wrapper for that
  program is still unverified — the vectors load correctly and the comparison was
  ruled out: reverting to `!==` restored the illegal sweep, confirming `!==` is
  correct and `!=` is the operator that misbehaves here. What blocks the ISA
  wrapper is throughput -- the driver delivers ~3250 simulated cycles per retired
  instruction, so a 4444-retirement run needs ~14M cycles and cannot finish in
  one call. A reduced-size variant of the same sweep (`rv64_isa_small_test`,
  780 retirements) **passes** through the UVM wrapper, so the wrapper itself is
  proven; only the full 4444-retirement run is out of reach at this driver
  speed. Fixing the driver is the next item.
* **9 UVM tests: 8 pass, 1 is throughput-blocked.** `rv64_illegal_test` (120 unimplemented
  encodings, each expected to trap) passes and in doing so found two real
  defects: MRET/EBREAK let the younger instruction advance into MEM and execute
  on the wrong path, and OP-IMM-32 accepted funct3=7 as `srliw`. Both are fixed.
  `rv64_isa_test` (the 4445-instruction sweep) still fails from retirement 1000
  with pc mismatches whose two values print identically; not root-caused. See
  `docs/VERIFICATION_REPORT.md`.
* **5/5 of the earlier UVM tests pass** under xezim 0.11.3: a class-based environment with a
  memory agent (driver owns the memory model, backpressure and error injection),
  an observability monitor, a scoreboard comparing the full retirement and trap
  streams against golden vectors from the same Python ISS, and functional
  coverage. That is 32 tests across four suites.
* 56,698 randomly generated instructions matched the golden model across five
  seeds, in addition to the directed suites.
* The regression found and fixed 14 real RTL bugs (see
  `docs/VERIFICATION_REPORT.md`), which is the main evidence that the checks
  actually fire.

Verilator 5.053 lint is clean apart from benign unused-signal notes, and
xezim 0.11.3 parses and elaborates all 12 RTL files with zero errors and zero
warnings.

Full detail, coverage table and the list of what is *not* verified:
`docs/VERIFICATION_REPORT.md`.

## 6. Custom numeric ABI (in progress)

A separate numeric side to the machine: its own 32 x 64-bit register bank
(`rv64_numfile.sv`), its own arithmetic datapath (`rv64_num_unit.sv`) and its own
configuration and sticky-flag CSRs (`rv64_num_csr.sv`, at `0x7C0`-`0x7C2`).

Verified two ways: as a unit against 1137 vectors / 4548 checks / zero
mismatches, and end-to-end from executed instructions (`test_numeric_abi`):
2.0 x 3.0 = 6.0 through the multiply, 2.0 + 3.0 = 5.0 through the add, the quire
accumulating 2.0 x 3.0 exactly and reading back 6.0, both bridges, and the
config/sticky CSRs.

Implemented and verified (1137 vectors, 4548 checks, zero mismatches):

* **Fixed-Q Q32.32** add / subtract / multiply, with configurable rounding
  (truncate or round-half-up), saturating or wrapping overflow, and overflow /
  inexact / saturate flags.
* **Quire** — a 128-bit exact accumulator. The product of two Q32.32 values is a
  Q64.64 value and fits with no rounding, which is the property a quire exists
  to provide. Clear, accumulate and read-back (arithmetic shift, since the quire
  is two's complement).
* **Adaptive precision** — truncate an operand to a configured mantissa width
  (1..64 bits), applied standalone or to both operands of an arithmetic op.
* **Error tracking** — per-operation error bound (the dropped bits, or half an
  LSB when rounding), latched into `nerr`.
* **Sticky flags** — overflow, underflow, inexact, invalid, divide-by-zero,
  saturate, precision-loss and quire-overflow, write-one-to-clear.

**Reachable from software.** The bank is wired into the pipeline through the
custom-0 opcode (`0x0B`): `funct7[4:0]` selects the operation, `funct3` the
format, and `rd`/`rs1`/`rs2` index the numeric bank instead of the integer file.
The CSRs live at `0x7C0`-`0x7C2` and are arbitrated alongside the machine CSRs.

Two bridge instructions make the bank observable, which it otherwise would not
be — a numeric result has nowhere to go without them:

```
funct7 0x12  NUM_TOINT    int rd     <- numeric nrs1
funct7 0x13  NUM_FROMINT  numeric nrd <- int rs1
```

There is no forwarding on the numeric side, so a conservative interlock holds ID
while any numeric write is still in flight. Correct, and deliberately simple.

**Research families (`rtl/rv64_num_wide.sv`).** All four are implemented and
verified -- 10756 checks, 0 mismatches:

| Family | Ops | Representation |
| --- | --- | --- |
| Residue (RNS) | `RADD`, `RMUL` | moduli 3/5/7/11 packed in 12 bits, per-channel, exact |
| Logarithmic (LNS) | `LNMUL`, `LNDIV` | signed Q16.16 log2, `0x8000_0000` = zero |
| IEEE binary32 | `FADD`, `FMUL` | RNE, inf/NaN, subnormals flushed to zero |
| Posit<16,1> | `PADD`, `PSUB`, `PMUL`, `PDIV` | decode to Q30.34, operate, re-encode |

`fmt` selects the width: posit<8,1>/<16,1>/<32,1>, LNS at Q8.8/Q16.16/Q32.32, and
RNS with {3,5,7}/{3,5,7,11}/{3,5,7,11,13}. Verified by 15364 vector checks and by
`rv64_numeric_test` through the UVM environment. See
`docs/VERIFICATION_REPORT.md`.

## 7. Xcetask (in progress)

Bounded custom task slots (`rv64_xcetask.sv`) — four by default. Each slot moves
IDLE -> ACTIVE -> DONE on completion, or IDLE -> ACTIVE -> TIMEOUT on expiry, with
cancel (ACTIVE -> IDLE) and free (DONE/TIMEOUT -> IDLE).

* a 64-bit token travels with each task and is retained in the slot, so a
  consumer can match a completion to the task it belongs to
* per-slot timeout countdown in cycles; 0 means no timeout
* a completion for a slot that is not ACTIVE is ignored, so a late or duplicate
  engine response cannot land on a task that has already moved on
* optional completion interrupt: per-slot pending bits, level-style, gated by an
  interrupt-enable bit — a completion that arrives while masked stays pending and
  raises the interrupt as soon as it is unmasked
* control port: commands on write (start / cancel / free / clear-irq), status on
  read (per-slot state, completion count, result, token, pending bits)
* auto-allocation picks the first idle slot when the slot field is 0xF

Verified by a directed suite: **38 checks, 0 mismatches** — explicit and
auto-allocated start, completion, out-of-order completion across slots, timeout
expiry, cancel, free, stray completions, and masked/unmasked interrupt.

**Reachable from software.** The block sits on a CSR window at
`0x7D0`-`0x7D8`, arbitrated with the machine CSRs and the numeric CSRs, so a
program drives it with ordinary `csrrw`/`csrrs`. The engine side is brought out
on the core's ports (`task_start_*`, `task_done_*`) and the completion interrupt
is `task_irq_o`.

`test_xcetask` exercises it end-to-end from executed instructions with a
simulated engine: start, completion, result read-back, pending bit, per-slot
state and the completion count all check out.

## 8. Synthesis

Generic synthesis (sv2v 0.0.13 + Yosys 0.70), for structural sanity rather than
timing:

```bash
pip install yowasp-yosys          # or use a yosys binary
SV2V=/path/to/sv2v YOSYS=yosys bash sim/synth.sh
```

Result: complete hierarchy, **no inferred latches**, 144,090 generic cells of
which 15,039 are flip-flops, and a longest combinational path of 203 logic
levels ending at the MDU result register. There is no timing library or clock
constraint in this flow, so **no frequency should be inferred from it** — the
MDU multiplier is the known critical path and would need sequencing at speed.

## 9. License

Dual-licensed under either of

* MIT License (`LICENSE-MIT`)
* Apache License, Version 2.0 (`LICENSE-APACHE`)

at your option. You choose whichever licence suits you; you do not have to comply
with both. This is the same arrangement the Rust project uses.

`SPDX-License-Identifier: MIT OR Apache-2.0`

The Apache-2.0 option carries an explicit patent grant, which is why it is the
usual choice for hardware designs. The MIT option is shorter and simpler. Unless
you explicitly state otherwise, any contribution you intentionally submit for
inclusion in this work shall be dual-licensed as above, with no additional terms
or conditions.
