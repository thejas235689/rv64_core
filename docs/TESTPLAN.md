# Testplan — rv64_core

Each requirement from the architecture contract maps to at least one test and to
a coverage point that the run reports. "Golden" means compared against the
independent Python ISS in `tb/cocotb/rv64_iss.py`.

## Test matrix

| # | Requirement | Test | Check | Coverage point |
| --- | --- | --- | --- | --- |
| 1 | Every RV64I ALU op | `test_alu` | golden trace | `isa:op`, `isa:op-imm`, `isa:op-32`, `isa:op-imm-32` |
| 2 | Every Zba/Zbb/Zbc/Zbs/Zicond op | `test_alu` | golden trace | `isa:zba`, `isa:zbb/zbc`, `isa:zbs`, `isa:zicond`, `isa:shift/bit-imm` |
| 3 | `x0` stays zero under writes | `test_alu` (`add x0,…`, `addi x0,…`) | golden trace | `isa:op` |
| 4 | LUI / AUIPC pc semantics | `test_alu`, `test_control` | golden trace | `isa:lui`, `isa:auipc` |
| 5 | MUL/DIV/REM incl. div-by-zero and INT_MIN/-1 | `test_muldiv` | golden trace | `isa:muldiv`, `mdu_ops` |
| 6 | All load widths, sign/zero extension, byte lanes | `test_memory` | golden trace + memory compare | `isa:load`, `mem_widths` |
| 7 | All store widths and strobes | `test_memory` | golden trace + memory compare | `isa:store` |
| 8 | All six branch conditions | `test_control` | golden trace | `branch_cond`, `isa:branch` |
| 9 | JAL/JALR link and return, loops, auipc | `test_control` | golden trace | `isa:jal`, `isa:jalr` |
| 10 | RAW through EX/MEM and MEM/WB forwarding | `test_hazards` | golden trace | `forward_paths` |
| 11 | Load-use interlock | `test_hazards` | golden trace | `forward_paths` |
| 12 | WB→ID write-through with a fetch bubble | `test_hazards`, random | golden trace | `forward_paths` |
| 13 | CSR read / write / RMW / immediate forms | `test_csr` | golden trace | `isa:csr`, `csr_ops` |
| 14 | Read-only ID CSRs, WARL fields | `test_csr` | golden trace | `csr_ops` |
| 15 | Illegal instruction | `test_traps` | trap cause 2 + golden trace | `trap:illegal` |
| 16 | Unimplemented CSR address | `test_traps` | trap cause 2 | `trap:illegal` |
| 17 | Misaligned load | `test_traps` | trap cause 4, `mtval` | `trap:load_misalign` |
| 18 | Misaligned store | `test_traps` | trap cause 6, `mtval` | `trap:store_misalign` |
| 19 | `ecall` from M-mode | `test_traps` | trap cause 11 | `trap:ecall_m` |
| 20 | Trap entry / `mret` return, `mepc`+4 skip | `test_traps` | golden trace | `trap:*` |
| 21 | Load access fault from a bus error | `test_access_fault` | trap cause 5 | `trap:load_access`, `load_access_fault` |
| 22 | Timer interrupt entry, `mcause`, return | `test_interrupt` | trap cause 0x8000…07, GPRs via debug port | `trap:m_timer_int`, `timer_interrupt` |
| 23 | External halt, resume, single step | `test_debug` | exactly one retirement per step | `debug_halt_step` |
| 24 | Watchpoint hit reporting | `test_debug` | hit pulses observed | `watchpoint` |
| 25 | Request backpressure on both ports | `test_backpressure` | golden trace | `backpressure` |
| 26 | Random instruction streams | `test_random` ×5 seeds | golden trace + memory compare | `random_streams`, `isa:*` |
| 27 | PLIC priority, threshold, claim/complete | `test_plic.py` | directed expectations | — |
| 28 | PMP NAPOT region, denied load/store/fetch, lock rule, permitted region | `test_pmp` | explicit causes + CSR read-back | `pmp_napot`, `pmp_denied_*`, `pmp_lock` |
| 29 | PMP matcher: TOR / NA4 / NAPOT boundaries, R/W/X, entry priority | `test_pmp_unit.py` | explicit expectations | — |
| 30 | Instruction access fault from a bus error, and recovery | `test_fetch_fault` | trap cause 1 at the faulting address | `inst_access_fault` |
| 31 | EBREAK debug entry and resume past it | `test_ebreak_debug` | debug halt, no cause-3 trap, post-EBREAK instruction runs | `ebreak_debug_entry` |
| 32 | WFI resume with a masked interrupt, and trap with MIE set | `test_wfi` | no trap vs cause 0x8000…07 | `wfi_masked_resume`, `wfi_interrupt_wake` |
| 33 | `minstret` counts retirements, `mcycle` advances | `test_counters` | bounded delta read through the debug port | `counter_minstret`, `counter_mcycle` |
| 34 | RAS overflow (10-deep recursion) and indirect jump target | `test_predictor_stress` | golden trace + memory | `ras_overflow`, `indirect_target` |
| 35 | Mid-stream reset restarts at RESET_PC | `test_reset` | golden trace from pc 0 | `mid_stream_reset` |

## Stimulus notes

* **Directed programs** are written in assembly (`tb/cocotb/rv64_asm.py`) so the
  intent is readable: every ALU op with edge operands, div-by-zero, INT_MIN/-1,
  every branch polarity, trap handlers at a fixed `mtvec`.
* **Random programs** mix ALU, MDU, shifts, memory and control flow with random
  registers and immediates, including writes to `x0`. Stores are confined to a
  data region so a stray write cannot corrupt the instruction stream.
* **Backpressure** is driven pseudo-randomly on both ports at 35 % to exercise
  the ready/valid handshakes and the single-outstanding-request rule.
* **Error injection** makes one aligned address return `rsp_error` to prove the
  access-fault path.

## Coverage accounting

`COV` in `test_core.py` accumulates across all tests in one run and is printed by
`test_coverage_report`. Two kinds of point are tracked: ISA classes
(`isa:<class>`, derived from each retired instruction) and scenario points
(`trap:<cause>`, `branch_cond`, `mem_widths`, `csr_ops`, `forward_paths`,
`random_streams`, `backpressure`, `timer_interrupt`, `debug_halt_step`,
`watchpoint`).

## What this testplan does not cover

* Cycle-accurate performance or branch-predictor accuracy measurement.
* Formal equivalence, CDC (single clock domain), or power intent.
* Anything in `docs/ROADMAP.md` that is not implemented (caches, OoO, Sv39,
  RVV, custom numeric, research blocks).
* FPGA/ASIC timing closure — no synthesis or STA has been run.
