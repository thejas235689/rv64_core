# rv64_core — RV64IM core with caches, Sv39, RVV and keyed boot authentication

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

39 RTL files, 8,882 lines. Everything below is instantiated in `riscv_core_top`
unless the row says otherwise.

| Area | Scope in this core |
| --- | --- |
| Integer execution | Full RV64I: arithmetic, logic, shifts, comparisons, branches, jumps, word ops |
| Multiply/divide | `mul/mulh/mulhsu/mulhu/div/divu/rem/remu`, multi-cycle, spec-exact special cases |
| Bit manipulation | Zba, Zbb, Zbc, Zbs, Zicond, Zihintpause |
| Atomics (A) | `lr.w/d`, `sc.w/d`, all nine AMOs in `.w` and `.d`, RMW in the LSU with a reservation register |
| Privilege | M/S/U with `medeleg`/`mideleg` delegation, `sret`, S-mode CSR set |
| Virtual memory | **Sv39**: 16-entry TLB + 3-level walker in the LSU, permission and fault rules, MPRV gating, real `satp` (MODE 0 or 8 only) |
| Front end | Fetch buffering, single outstanding request; predecode tags cross-checked against the decoder; fusion hints (hints only, no fused datapath) |
| Branch prediction | Gshare + bimodal with a tournament chooser, BTB, 8-entry RAS, loop-count predictor, tagged history and a perceptron |
| Caches | 64-line direct-mapped **I-cache** in the fetch path; write-through **D-cache** in the load/store path; a **2 KB L2** (16 sets x 4 ways) and a **16 KB L3** (64 sets x 8 ways) behind it, both the same geometry-parameterised module with RRIP replacement |
| Adaptive cache control | **AMCCE** watches the D-cache's hit/miss stream and switches it to BYPASS under a streaming scan, with hysteresis |
| Memory ops | Byte/halfword/word/doubleword, sign/zero extension, byte strobes, misalignment traps |
| **Zifencei** | `fence.i` invalidates the whole instruction cache, so self-modifying code is visible to fetch |
| Protection | 8 PMP entries, OFF/TOR/NA4/NAPOT, whole-access checks, M-mode lock semantics |
| System control | Machine CSRs, synchronous exceptions, illegal-instruction traps, `mret`, `wfi` |
| Interrupts | Software, timer and external inputs; a four-source PLIC-lite with claim/complete |
| Debug | External halt/resume, single-step, EBREAK debug entry, GPR read port, watchpoint comparator |
| Boot | 2 KB **boot ROM** at the reset vector, and **HMAC-SHA-256** image authentication that releases the core only on an exact keyed MAC. Behind `parameter BOOT_ROM` (default 0) because the ROM owns 0x0-0x7FF, where test programs load |
| Crypto | `rv64_sha256` (streaming compression, one round/cycle, chaining) and `rv64_hmac` (HMAC-SHA-256 over one 512-bit block) |
| Custom numeric ABI | RNS, LNS, IEEE binary32 and **posit** (`<8,1>`, `<16,1>`, `<32,1>`), own register bank, `nerr`/`ncfg`/`nflags` CSRs (window `0x7C0`) |
| QISA | 8-entry qubit model: X/Y/Z/H/CNOT/measure, seeded LFSR collapse (`0x7E0`) |
| AI accelerator | INT8 4x4x4 MAC, INT32 accumulation (`0x7E8`) |
| XRV512 | 32 x 512-bit bank, eight 64-bit lanes, 11 elementwise ops, lane port (`0x7F0`) |
| RVV subset | 32 x 64-bit vector file: `vsetvli`/`vsetivli` with VLMAX, add/sub/and/or/xor/min/max and `vmv` in `.vv/.vx/.vi`, SEW 8-64, tail-preserving `vl`, **masking**, **reductions**, **widening**, **narrowing with `vnclip`**, **`vlmul` 1-8**, **slides**, **`vle`/`vse`** and binary32 **`vfadd`/`vfsub`/`vfmul`** (`0x780`, own memory port) |
| Xcetask | Task descriptor engine (window `0x7D0`) |
| Observability | Retirement PC/instruction, GPR writeback, trap cause/PC, interrupt flag, privilege, debug event, counters |

**`rv64_rvc_expand`** converts the RV64C compressed encodings to their 32-bit
equivalents (verified, 13 checks, but **not yet instantiated** — wiring it in needs
variable-length fetch, which the pipeline does not have).

**Not in this core:** cache coherence, cache inclusion or write-back, prefetch, an
out-of-order backend, and the four research blocks (DNA, neuromorphic, photonic,
interconnect). CLINT, UART, DMI and the L2 arbiter exist as verified standalone
blocks but are **not** instantiated. `docs/ROADMAP.md` maps the target feature list
against what exists.

## 3. Tree

```
rv64_core/
├── rtl/                         39 synthesizable SystemVerilog modules
│   ├── riscv_core_top.sv        the core: pipeline, bus ports, boot, CSR windows
│   ├── rv64_pkg.sv              types, opcodes, CSR addresses, trap causes
│   ├── rv64_alu.sv              RV64I + Zba/Zbb/Zbc/Zbs/Zicond ALU
│   ├── rv64_mdu.sv              multiply / divide unit
│   ├── rv64_regfile.sv          32x64 register file
│   ├── rv64_decoder.sv          instruction decode
│   ├── rv64_pmp.sv              8-entry physical memory protection
│   ├── rv64_csr.sv              machine/S-mode CSR file, privilege, traps
│   ├── rv64_mmu.sv              Sv39 walker + TLB (inside the LSU)
│   ├── rv64_lsu.sv              load/store sequencer, atomics, translation phase
│   ├── rv64_bpu.sv              tournament predictor, BTB, RAS, loop, perceptron
│   ├── rv64_predecode.sv        predecode tags and fusion hints
│   ├── rv64_fetch.sv            fetch buffer + instruction interface
│   ├── rv64_icache.sv           instruction cache
│   ├── rv64_dcache.sv           write-through data cache
│   ├── rv64_l2cache.sv          geometry-parameterised cache: L2 and L3
│   ├── rv64_l2arb.sv            two-port arbiter (verified, not instantiated)
│   ├── rv64_amcce.sv            adaptive cache mode engine
│   ├── rv64_bootrom.sv          boot ROM at the reset vector
│   ├── rv64_bootauth.sv         FNV-1a authenticator (superseded)
│   ├── rv64_bootauth_hmac.sv    keyed boot authentication
│   ├── rv64_sha256.sv           SHA-256 compression core
│   ├── rv64_hmac.sv             HMAC-SHA-256
│   ├── rv64_num_pkg.sv          numeric ABI constants
│   ├── rv64_num_wide.sv         RNS / LNS / binary32 / posit datapath
│   ├── rv64_numfile.sv          numeric register bank
│   ├── rv64_num_unit.sv         numeric unit
│   ├── rv64_num_csr.sv          numeric CSRs
│   ├── rv64_qisa.sv             qubit model
│   ├── rv64_aiacc.sv            INT8 matrix accelerator
│   ├── rv64_xrv512_file.sv      32x512 register bank
│   ├── rv64_xrv512.sv           XRV512 lane unit
│   ├── rv64_vregfile.sv         32x64 vector register file
│   ├── rv64_vunit.sv            RVV executor
│   ├── rv64_xcetask.sv          task descriptor engine
│   ├── rv64_plic_lite.sv        4-source interrupt controller (standalone)
│   ├── rv64_clint.sv            timer / software interrupts (standalone)
│   ├── rv64_uart.sv             8N1 UART (standalone)
│   └── rv64_dmi.sv              JTAG TAP + DMI (standalone)
├── tb/                          28 SystemVerilog testbenches + the cocotb suite
├── sim/                         run.py, lint.sh, UVM runner, vector generators
├── docs/                        verification report, roadmap, design notes
└── README.md
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

**33 cocotb tests, 28 SystemVerilog testbenches, two simulators (Icarus 14.0 and
xezim 0.11.3), plus Verilator 5.053 and slang for lint.** Every retirement is
compared against an independent Python golden model (pc, instruction, destination
register, write data), and random programs are checked byte-exact against data
memory.

A caveat on how these are run: with three cache levels the full cocotb suite no
longer finishes inside one command timeout, so the tests are verified
**individually** rather than in a single green run. A CI run needs a longer
wall-clock budget than an interactive one.

| Suite | Result |
| --- | --- |
| Core ISA, hazards, traps, CSR, memory, control | pass, ISS trace-compared |
| PMP matcher | 5/5 |
| PLIC-lite | 2/2 |
| `test_isa_sweep_fast` | 24,861 retirements matched, zero mismatches |
| `test_sv39_identity` | passes with translation active (identity megapage + MPRV) |
| `test_icache_hits` / `test_dcache_hits` | pass, asserting the caches actually hit |
| `test_l2_in_path` | L2 1 hit/1 miss, L3 3 hits/1 miss -- both levels carry traffic |
| `test_amcce_bypass` | 128-miss scan flips the D-cache to BYPASS |
| `test_rvv_in_core` / `test_xrv512_in_core` | vector results asserted from executed instructions |
| `test_vle_in_core` | `vle8.v` loads 8 bytes from a program, polling the unit's BUSY bit |
| `test_numeric_sweep` | 299 retirements matched against the numeric ABI model |

**Standalone block testbenches** (Icarus and xezim unless noted): `tb_vunit` 42
checks, `tb_sha256` 5, `tb_hmac` 1 (RFC 4231), `tb_bootauth_hmac` 6, `tb_bootseq` 6,
`tb_fetch_cache` 26, `tb_mmu` 22, `tb_icache` 18, `tb_xrv512` 18, `tb_amcce` 18,
`tb_l2cache` 14, `tb_dcache` 12, `tb_l2arb` 10, plus the platform blocks.

The regression has found and fixed **40+ real RTL defects** across the project,
which is the main evidence the checks actually fire. Full detail, coverage table
and the list of what is *not* verified: `docs/VERIFICATION_REPORT.md`.

## 6. Custom numeric ABI

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

## 7. Xcetask

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
