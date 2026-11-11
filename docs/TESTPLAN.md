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

## UVM environment (`tb/uvm/`)

The UVM regression reuses the same golden model, driven through a class-based
environment. Golden vectors are produced by `sim/gen_uvm_vectors.py` from
`tb/cocotb/rv64_iss.py`, so the scoreboard checks the DUT against the model that
was validated separately, rather than a second hand-written copy of the ISA.

| Test | Program | Checks |
| --- | --- | --- |
| `rv64_alu_test` | directed ALU/bitmanip/MDU mix | 44 retirements + 1 trap vs golden vectors |
| `rv64_mem_test` | all load/store widths and lanes | 22 retirements + 1 trap |
| `rv64_trap_test` | illegal, illegal CSR, misaligned load/store, ecall | 30 retirements + 5 traps |
| `rv64_random_test` | 120-instruction random stream (seed 7) | 148 retirements + 1 trap |
| `rv64_backpressure_test` | memory program with 40 % request backpressure on both ports | 22 retirements + 1 trap |

Environment structure:

* `rv64_mem_agent` — driver owns the memory model, answers both ports with a
  one-cycle response, applies byte-strobed writes, injects backpressure and
  error responses, and owns reset so a sequence can load a program while the
  core is held in reset.
* `rv64_obs_monitor` — passive; turns the retirement and trap streams into
  transactions.
* `rv64_scoreboard` — compares pc, instruction, write-enable, destination and
  write data for every retirement, and pc/cause for every trap. Retirements
  after the golden window are ignored, not judged. A write indication to `x0`
  is accepted as no write, because the register file suppresses it.
* `rv64_coverage` — covergroup on instruction class, write/no-write, destination
  register and the class x write cross.

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


## Research RTL verification matrix

The [RTL specification](RTL_FEATURE_SPEC.md) defines scope and acceptance
criteria. Use `bash sim/verify_rtl.sh` to run the integrated configurations.
The runner exits with failure if cocotb records a failed test or produces no
test cases. Satya-dependent skips remain visible in the simulator summary.

| Requirement | Executable check | Next coverage and assertions |
| --- | --- | --- |
| RTL-01 RVV | `test_native_rvv_grouped_integer`, `test_native_rvv_masked_integer`, `test_native_rvv_invalid_config` | Cross SEW, LMUL, mask position, tail policy, alignment and trap. Assert exactly one retirement per vector instruction and group writes complete first. |
| RTL-02 Posit quire | `test_posit8_quire_in_core`, `test_posit8_quire_rounded_readback`, `test_posit16_quire_in_core` | Sweep exponent and regime boundaries, ties, cancellation and signed overflow against an independent exact model. Assert rejected updates preserve the accumulator. |
| RTL-03 Signed LNS | `test_signed_lns_abi`, `test_lns_add_sub_abi` | Compare each format against a high-precision reference across sign, delta, zero, overflow and underflow. Measure approximation error separately from output quantization. |
| RTL-04 Stride prefetch | `test_stride_prefetch_in_authorized_window`, `test_stride_prefetch_blocked_by_active_pmp`, `tb_icache_stride.sv` | Cross stride sign, PMP, privilege, page boundary, backpressure and invalidation. Assert every accepted speculative read belongs to the authorized range. |
| RTL-05 Predictor | `tb_bpu_indirect.sv`, `test_control` | Cross history, source-PC alignment, target confidence and redirect outcome. Compare committed instruction traces when predictor entries alias. |
| RTL-06 Frontend | `tb_fetch_cache.sv`, `test_fence_i_self_modifying_code`, `test_instruction_translation_sv39_sv48` | Cross compressed/uncompressed, redirect, page boundaries and refill errors. Assert an expansion-cache hit matches decoding the current raw encoding. |
| RTL-07 Unum | `test_unum_bounded_add_sub` | Exhaust supported encoding widths against a rational reference, including cancellation, invalid inputs, saturation and interval containment. |
| RTL-08 Cache | `tb_icache_hit_under_miss.sv`, `tb_icache_stride.sv` | Assert that every accepted ID returns once or is invalidated, with no refill data installed after invalidation. Add an independent scoreboard when multiple misses are implemented. |
| RTL-09 Pipeline | `test_backpressure`, `test_debug`, `test_instruction_translation_sv39_sv48` with and without `--fetch-stage` | Assert queue stability on stall, one delivery per accepted instruction, and no retirement of flushed instructions. Cross branch, fence, trap and debug redirects with a full queue. |

Run `bash sim/verify_rtl_units.sh` with Icarus Verilog and vvp to exercise the indirect predictor, hit-under-miss, stride prefetch, and fetch/cache benches. The core regression
exercises CPU behavior. Assertion and coverage goals in the last column remain
open until the corresponding checks and coverage results are recorded.
