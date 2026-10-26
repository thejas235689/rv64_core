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
| Front end | Fetch buffering, request/response tracking, single outstanding request |
| Branch prediction | Gshare + bimodal BHT with a tournament chooser, BTB, 8-entry return-address stack |
| Memory ops | Byte/halfword/word/doubleword loads and stores, sign/zero extension, byte strobes, misalignment traps |
| Protection | 8 PMP entries, OFF/TOR/NA4/NAPOT matching, whole-access checks, M-mode lock semantics (unit-tested) |
| System control | Machine CSRs, synchronous exceptions, illegal-instruction traps, `mret`, `wfi` |
| Interrupts | Software, timer and external interrupt inputs; four-source PLIC-lite with claim/complete (`rtl/rv64_plic_lite.sv`) |
| Debug | External halt/resume, single-step, EBREAK debug entry, GPR read port |
| Watchpoints | Memory-address comparator with hit reporting (not a precise debug entry) |
| Observability | Retirement PC/instruction, GPR writeback, trap cause/PC, interrupt flag, privilege, debug event, counters |

**Not in this core:** instruction/data caches, out-of-order backend, S/U modes,
Sv39, atomics, RVV, the custom numeric ABI, XRV512, Xcetask, QISA, the AI
accelerator, and the research blocks (DNA, neuromorphic, photonic, interconnect).
`docs/ROADMAP.md` maps the full target feature list against what exists here and
what remains.

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
│   └── riscv_core_top.sv        pipeline top level
├── tb/
│   ├── tb_core_top.sv           core harness: memory, host load, backpressure, error injection
│   ├── tb_plic_top.sv           PLIC-lite harness
│   ├── tb_pmp_top.sv            PMP matcher harness
│   └── cocotb/
│       ├── test_core.py         core regression (13 tests)
│       ├── test_plic.py         PLIC-lite regression (2 tests)
│       ├── test_pmp_unit.py     PMP matcher unit tests (5 tests)
│       ├── rv64_asm.py          assembler used to build test programs
│       └── rv64_iss.py          independent golden-model ISS
├── sim/
│   ├── run.py                   build + run without make
│   └── Makefile                 same flow via cocotb's Makefile.sim
├── docs/
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

## 6. License

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
