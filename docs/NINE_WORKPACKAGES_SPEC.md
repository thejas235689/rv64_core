# Nine-work-package completion contract (2026-11-11)

> **Status: planned, NOT implemented.** This document is the acceptance contract for future implementation. Do not advertise V ISA, coherence, out-of-order execution or Unum as supported until the tests and integration gates below pass.

## Baseline and merge policy
- Integration base: `feature/rtl-parallel-integration`.
- Open masked-RVV PR: https://github.com/thejas235689/rv64_core/pull/21 (targets integration base). Rebase or merge that work independently after review; do not silently assume it is in `main`.
- Preserve existing single-issue in-order behavior as a supported reference configuration, with experimental features disabled by default.
- The `README.md`, `isa/rv64_profile.yaml`, and conformance tests are release gates. Documentation on different branches has drifted; base each implementation claim on reproducible test evidence.
- No subagent may change another agent's owned RTL without an integration review. Keep each work package in a separate branch and PR.
- All new memory state must be invalidated/rolled back on reset, exception, interrupt, misprediction, fence, and privilege transition when applicable.

## Work packages / exit criteria

| ID | Owner | Existing touchpoints | Minimum accepted deliverable | Required verification |
|---|---|---|---|---|
| WP01 | rvv-agent | `rtl/rv64_vunit.sv`, `rtl/rv64_vregfile.sv`, `rtl/rv64_decoder.sv`, `rtl/riscv_core_top.sv` | LMUL grouping and illegal overlap handling; native vector load/store unit-stride and fault behavior; VS state and vstart/vl/vtype state updates | Mask and tail policy, EMUL alignment, backpressure, precise element faults, vstart restart, privilege/context transitions; compare reference model |
| WP02 | posit-agent | `rtl/rv64_num_wide.sv`, `rtl/rv64_num_unit.sv`, `rtl/rv64_num_pkg.sv` | Parametric posit widths and es; exact or sufficiently wide quire; deterministic rounded readback, NaR and edge cases | Randomized reference-model comparison, saturation, ties and carry extremes |
| WP03 | lns-agent | `rtl/rv64_num_wide.sv`, `rtl/rv64_num_unit.sv` | Signed-value encode/decode; add/subtract/multiply/divide with explicit range and rounding policy | Opposite signs, cancellation, near-zero, error budgets and model comparisons |
| WP04 | prefetch-agent | `rtl/rv64_icache.sv`, `rtl/rv64_fetch.sv`, `rtl/riscv_core_top.sv`, `rtl/rv64_pmp.sv` | Software/core enable, bounded stride prefetch, prefetch privilege/translation/PMP authorization, cancellation and no architectural side effects | Access-denied, page boundary, fence.i, mispredict, backpressure, bandwidth-throttling |
| WP05 | branch-agent | `rtl/rv64_bpu.sv`, `rtl/rv64_fetch.sv` | Feature-gated TAGE + indirect target predictions, checkpoint/recovery, multipath only after correct single-path retirement | Aliasing, cold starts, RAS, speculative-history rollback, prediction accuracy and deterministic regressions |
| WP06 | frontend-agent | `rtl/rv64_predecode.sv`, `rtl/rv64_fetch.sv`, `rtl/riscv_core_top.sv` | Trace or µop cache with tag/context/translation validation; proven fusion semantics; multi-stream fetch with ordered commit | Self-modifying code, fence.i, page crossings, trap PC, fusion equivalence, replay and flush |
| WP07 | unum-agent | `rtl/rv64_num_pkg.sv`, `rtl/rv64_num_wide.sv`, `rtl/rv64_num_unit.sv` | Written versioned Unum encoding and operations, exceptional encodings and interval semantics when applicable | Software golden model, round trips, boundaries, malformed inputs, random arithmetic |
| WP08 | cache-agent | `rtl/rv64_dcache.sv`, `rtl/rv64_icache.sv`, `rtl/rv64_l2cache.sv`, `rtl/rv64_l2arb.sv`, `rtl/rv64_lsu.sv` | Nonblocking misses/MSHRs with miss coalescing and replay; then coherent ownership/state machine with explicit probe/snoop port contract | Dirty eviction pending, read/write races, same-line merging, MSHR full, deadlocks, snoop races, ordered atomics, fence |
| WP09 | pipeline-agent | `rtl/riscv_core_top.sv`, `rtl/rv64_decoder.sv`, `rtl/rv64_lsu.sv`, `rtl/rv64_csr.sv` | 7-stage mode first; superscalar rename/dispatch/issue; ROB, recovery, precise exceptions and memory ordering for OoO mode | In-order equivalence, commit trace/ISS, RAW/WAW/WAR, mispredict, exceptions, interrupt, CSR ordering, LR/SC, deadlock |

## Dependency order
1. Freeze architectural ISA/ABI and memory-port contracts; baseline regression must pass.
2. Land WP01–03 separately; update `isa/rv64_profile.yaml` only after measurable completeness.
3. WP04–06 share frontend contracts and require integration arbitration.
4. WP08 requires a memory-ordering and coherence protocol specification **before** RTL.
5. WP09 cannot begin OoO integration until commit, store-buffer, and memory-order contract is approved; seven-stage is a separate milestone.
6. WP07 experimental custom extension must not be confused with ratified RISC-V ISA.

## Required evidence for EACH work package
- Specification with interface table, invariants, failure cases, performance claims and version.
- RTL and/or model in its own PR with tests and assertions.
- `sim/lint.sh`; `ci/run_all_checks.sh`; relevant directed and cocotb suites, with logs and simulator versions.
- Coverage ledger: requirements -> assertions/tests/functional bins, gaps explicitly listed.
- Formal where tractable: no lost requests, no double retirement, no incorrect privilege access, safety/progress under documented fairness assumptions.
- Update README and ISA profile **only** for verified features.
- Two independent reviews (architecture/integration and DV/signoff); no auto-merge on red or missing CI.
- Never report 'complete' based solely on a file existing or a passing smoke test.

## Signoff checklist
- [ ] WP01 RVV
- [ ] WP02 Posit
- [ ] WP03 LNS
- [ ] WP04 Prefetch
- [ ] WP05 Prediction
- [ ] WP06 Frontend
- [ ] WP07 Unum
- [ ] WP08 Coherent cache
- [ ] WP09 Advanced pipeline

**Current checkboxes are intentionally unchecked.** This plan does not assert nine features are implemented.
