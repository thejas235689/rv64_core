# RV64 core multi-agent engineering instructions

This repository uses **nine proposed subagent roles** for implementation planning and review. These are role definitions; adding this file does not launch autonomous background workers.

## Global instructions for all agents
1. Read `docs/NINE_WORKPACKAGES_SPEC.md`, `isa/rv64_profile.yaml`, `docs/ARCHITECTURE_FEATURE_CONTRACT.md`, and relevant RTL and tests before modifying files.
2. Record a baseline simulator command, result, Git commit and failures before any change.
3. Implement only one work package per branch. Produce spec -> RTL -> unit tests -> system tests -> formal/coverage -> docs -> PR.
4. Preserve current in-order defaults. Experimental options default off; no unimplemented ISA claims in misa.
5. Preserve precise traps, retirement ordering, PMP/translation authorization and reset behavior. Never turn an X into a 2-state payload in checkers; test unknown propagation explicitly where simulator permits.
6. Avoid invented test results, completion percentages or performance benefits. Include reproducible commands and real logs.
7. Other agents' interfaces are read-only until a coordinated integration PR is approved.

## Agent assignments
### `rvv-agent` — WP01
Read `rtl/rv64_vunit.sv`, `rtl/rv64_vregfile.sv`, `rtl/rv64_decoder.sv`, `rtl/riscv_core_top.sv`; treat PR #21's masking as pending until merged. Deliver native grouped operations, vector LSU, VS/vstart/vtype context and element restart semantics. Verify v0 masked writes, LMUL overlap, vstart faults and memory backpressure.

### `posit-agent` — WP02
Own parametric posit formats, quire width/overflow and rounding policy in numeric subsystem. Deliver independent Python/Rust oracle and error report, with NaR and tie-case assertions.

### `lns-agent` — WP03
Own signed logarithmic encoding, add/sub corner cases and deterministic rounding for arithmetic. Publish model-based absolute/relative error distribution and correctness envelope.

### `prefetch-agent` — WP04
Own fetch-side stride prefetch enable and throttle, address translation and PMP permission gating, cancellation and fence behavior. No unauthorized external requests and no architectural exceptions from speculative hints.

### `branch-agent` — WP05
Own TAGE/indirect prediction and speculative-history checkpoint protocol. Prove redirects flush wrong-path effects; measure accuracy against baseline on repeatable workloads.

### `frontend-agent` — WP06
Own trace/µop cache, execution-equivalent fusion and multi-stream instruction supply. Coordinate with branch agent on redirect/flush; enforce fence.i, coherence/invalidation and page permission handling.

### `unum-agent` — WP07
First author a precise versioned custom Unum binary specification and canonical model. Only then implement arithmetic and exceptions under a custom extension gate.

### `cache-agent` — WP08
Own MSHRs, miss merging, retry/replay, writeback buffer and selected coherence protocol. Specify probe, ownership, response ordering and progress assumptions before coding. Build dirty-eviction and snoop stress tests.

### `pipeline-agent` — WP09
First deliver a separately validated seven-stage in-order option; then staged superscalar; only after a commit/memory contract deliver ROB+rename+issue OoO mode. Maintain reference in-order retirement correspondence.

## Cross-agent gatekeepers
- **spec-agent:** approves requirement traceability and ISA feature claims.
- **integration-agent:** owns interface changes, rebase sequencing, conflict resolution and top-level build.
- **debug-agent:** records minimal reproducer, waveform, first failing cycle, root cause.
- **formal-agent:** checks safety/liveness, assumption quality and vacuity.
- **coverage-agent:** checks tests, bins, code/assertion coverage and explicit waivers.
- **signoff-agent:** refuses signoff if unknowns remain, CI fails or baseline regresses.

## Required PR template
```md
### Work package / dependency
### RTL and interface changes
### ISA/ABI impact
### Verification evidence (commands, commit, test log)
### Negative tests and assertions
### Coverage delta and open gaps
### Risk and rollback
### Agent signoffs
- [ ] spec
- [ ] integration
- [ ] debug
- [ ] formal
- [ ] coverage
- [ ] signoff
```
