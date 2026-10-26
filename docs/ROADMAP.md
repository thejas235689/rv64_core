# Roadmap — target feature set vs. what exists in this repository

The target architecture described in the project brief is much larger than this
core. This file is deliberately blunt about the gap so nobody mistakes an
aspiration for an implementation.

Legend: **done** = implemented and simulated here; **partial** = a bounded slice
exists; **absent** = not in this repository.

## Default CPU features (the brief's first table)

| Area | Target | Here |
| --- | --- | --- |
| Architecture | single-hart RV64, M-mode, `misa`=RV64IM | **done** |
| Pipeline | in-order IF/ID/EX/MEM/WB, stalls, forwarding, flush, redirect | **done** |
| Integer execution | RV64I incl. word ops | **done** |
| Multiply/divide | mul/div/rem | **done** (multi-cycle, spec-exact special cases) |
| Bit manipulation | Zba, Zbb, Zbc, Zbs, Zicond, Zihintpause | **done** |
| Register state | 32×64 with `x0` handling | **done** |
| Front end | fetch buffering, request/response tracking | **partial** — no predecode tags, dependency/fusion hints |
| Branch prediction | BHT, gshare/tournament, BTB, RAS, indirect target | **partial** — tournament BHT+gshare, BTB, RAS; no loop predictor, no tagged history, no perceptron |
| Memory ops | all widths, sign extension, strobes, misalignment traps | **done** |
| Caches | I-cache, L1 D, L2/L3 integration, RRIP | **absent** — the ports are cache-ready but no cache is instantiated |
| Protection | 8 PMP entries, TOR/NA4/NAPOT, whole-access checks | **done** — core-level and unit-level tests, including lock semantics |
| System control | machine CSRs, exceptions, illegal traps, MRET, WFI | **done** |
| Interrupts | software/timer/external, 4-source PLIC-lite claim/complete | **done** — PLIC-lite is a separate verified block wired to the core's IRQ inputs |
| Debug | DMI halt/resume, single step, EBREAK entry | **partial** — halt/resume/step/EBREAK all tested; no DMI transport |
| Watchpoints | address comparator + hit reporting | **done** (no precise debug entry, by design) |
| Observability | retirement PC/insn, GPR writes, trap cause, IRQ class, priv, debug events | **done** |
| Interfaces | separate I/D, backpressure, 64-bit beats, strobes | **done** |
| Clock/reset | single clock, active-low reset | **done** |

## Optional CPU configurations

| Feature | Status | Note |
| --- | --- | --- |
| Out-of-order backend (rename, free list, issue queue, PRF, ROB) | **absent** | would be a separate backend behind the same ISA contract |
| Supervisor/user modes | **absent** | M-mode only; `mstatus.MPP` is hardwired to 11 |
| Sv39 translation (TLB, PTW, faults, ASID) | **absent** | |
| Atomics (LR/SC, AMOs) | **absent** | |
| Fetch-fault metadata | **done** | instruction access fault with faulting address |
| Transactional data memory | **partial** | separate response channel, backpressure, response error; no SC-failure channel |
| RVV subset (VLEN=64, LMUL=1) | **absent** | |
| Custom numeric ABI (posit/quire, LNS, RNS, fixed-Q, error tracking) | **partial** | 32x64 numeric bank, fixed-Q Q32.32, 128-bit quire, adaptive precision, error tracking and sticky-flag/config CSRs are implemented and verified; posit/LNS/RNS/IEEE families reserved but unimplemented; not yet wired into the pipeline |
| XRV512 (32×512-bit bank) | **absent** | |
| Xcetask (task slots, completion, timeout IRQ) | **partial** | bounded slot lifecycle, token ownership, per-slot timeout, cancel/free, stray-completion rejection and optional completion interrupt implemented and verified (38 checks); not yet wired into the core (no CSR or opcode path) | |
| QISA (8-entry qubit model) | **absent** | |
| AI accelerator (INT8 4×4×4) | **absent** | |
| Adaptive cache / AMCCE compression sidecar | **absent** | |

## Optional platform features

Machine-mode ROM boot, RAM payload execution, UART, memory-mapped PLIC/CLINT,
OpenSBI boot, SHA-256 boot authentication, sealed code: **all absent**. This
repository is a core plus its verification environment, not a platform. The
PLIC-lite block is the only platform-adjacent piece included, because the core's
interrupt inputs need something to drive them.

## Standalone / research RTL

Compressed-instruction decompressor, floating-point blocks, AXI4/AXI5/ACE5/CHI
adapters, coherent and L4 caches, DNA vector/stream/object engines, genomic
primitives, neurocore, photonic accelerator control, power/security/telemetry
fabrics: **all absent** from this repository.

## Suggested order of work from here

1. ~~Directed PMP suite~~ — done (`test_pmp`, `test_pmp_unit`).
2. ~~EBREAK and WFI directed tests~~ — done (`test_ebreak_debug`, `test_wfi`).
3. **Instruction cache** in front of the existing fetch port, with the same
   trace-based comparison reused as the check.
4. **Atomics (A extension)** — needs the memory model to grow a reservation
   monitor before LR/SC means anything.
5. **UVM environment** reusing `rv64_iss.py` as the scoreboard reference, if the
   target flow requires UVM rather than cocotb.
