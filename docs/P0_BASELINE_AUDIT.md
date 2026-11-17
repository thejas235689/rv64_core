# P0 Baseline Audit — RV64 Core

**Audited branch:** `main`  
**Audited commit:** `629c63580a5bac6900ea8a509da181d7f2eac5a1`  
**Audit date:** 2026-11-17  
**Method:** GitHub source inspection of RTL, ISA profile, simulation harness, CI workflow and project status documents. No local RTL simulation or formal run was performed by this audit.

## 1. Executive assessment

The repository has a substantial in-order RV64 implementation and a meaningful Cocotb/ISS regression environment. However, the project status documents are no longer a reliable single view of the current design. Several top-level instances are present while the roadmap or verification matrix still describes them as absent or standalone. Conversely, some profile claims are not consistent with top-level wiring.

The immediate objective is not to add more architecture. It is to establish a trustworthy baseline, close the explicit architectural deviations, and make every integration claim traceable to a test and current commit.

## 2. P0 discrepancies requiring resolution

| ID | Finding | Source evidence | Required action |
|---|---|---|---|
| AUD-001 | Cache hierarchy status is stale. | `rtl/riscv_core_top.sv` instantiates `rv64_icache u_icache`, `rv64_dcache u_dcache`, and two `rv64_l2cache` instances (`u_l2`, `u_l3`). D-cache requests route through L2/L3 to the external data port. I-cache fill connects to the instruction response path. `docs/ROADMAP.md` still says caches are absent; `docs/CACHE_VERIFICATION.md` describes a much narrower cache topology. | Update the topology drawing and roadmap to distinguish instantiated/connected from verified end-to-end. Run current I-cache, D-cache, L2-system and full-core tests. |
| AUD-002 | PLIC integration status is contradictory. | `riscv_core_top.sv` instantiates `rv64_plic_lite u_plic`; `plic_irq` is ORed into `irq_ext_eff`. `docs/VERIFICATION_MATRIX_STATUS.md` says PLIC-lite is not instantiated. | Correct the matrix. Add/confirm a CPU-level PLIC CSR/claim/complete-to-trap test, not just standalone PLIC tests. |
| AUD-003 | I-cache maintenance path appears disconnected. | In the I-cache instance, `.invalidate(1'b0)` is tied low; the RTL comment says there is no fence.i commit signal. The ISA profile claims Zifencei and says fence.i invalidates the whole I-cache. | Treat as a functional P0 bug: implement a precise fence.i invalidation pulse and test self-modifying code (store instruction bytes, fence.i, refetch). Do not count Zifencei complete until proven. |
| AUD-004 | ECALL cause is wrong in S/U modes by recorded design. | `isa/rv64_profile.yaml` records observed cause 11 in every privilege mode; `riscv_core_top.sv` assigns `CAUSE_ECALL_M` unconditionally. RISC-V requires causes 11/9/8 from M/S/U respectively. | Fix cause selection based on current privilege; update ISS and profile; add M/S/U directed tests and differential checks. |
| AUD-005 | Verification matrix contains stale integration statements. | It says PLIC not instantiated and claims some blocks only at area level. Current top-level contains PLIC, CLINT, UART, vector, numeric, Xcetask, QISA, XRV512 and AI accelerator instances. | Re-audit each block's actual CSR decode, datapath/port connectivity, interrupt path and software-visible completion. Mark each standalone, instantiated, connected, CPU-tested or sign-off complete. |
| AUD-006 | CI has a current failing core regression on the documentation PR. | GitHub Actions run 44081015448 for PR #34: Icarus lint passed, ISA conformance passed, core regression failed, posit/quire targeted regression passed; PLIC regression was skipped after the failure. | Inspect the full failing batch/test log and reproduce on the same SHA. Do not merge PR #34 as green until the failure is understood or documented as an unrelated reproducible baseline failure. |

## 3. P1 findings and verification limitations

### PSS

The repository contains `tb/cocotb/test_pss_matrix.py`. It calls `gen_pss_program.solve()`, which invokes Satya, converts solver output to RISC-V words, loads those words into the core and checks retirement. It iterates eight actions with three seeds each.

Limitations visible in the test:
- The test is not evidence that all PSS actions or all PSS source files are executed by default CI. Confirm CI selection and run inclusion.
- For integer actions, x7 is checked against the generated expected value.
- For Posit and quire actions, the source comments explicitly say the check is execution, not numerical value, because there is no numeric reference model in that bench.
- PSS coverage is not the same as architectural coverage or proof of all operand combinations.

Action: document the exact Satya version, solver invocation, selected actions, seeds, execution count and scoreboard strength. Add independent numeric oracle checks before calling Posit/quire PSS scenarios value-verified.

### Verilator and Xezim

`sim/run.py` exposes a Verilator simulator option, and the verification report documents historical Verilator and Xezim use. The current GitHub Actions workflow inspected here uses Icarus for the mandatory lint/build and Cocotb regressions. It does not currently show separate Verilator or Xezim jobs.

Action: add explicit CI jobs only after confirming the supported RTL subset and runtime. Keep frontend parse/elaboration, lint and simulation results distinct.

### Formal

The verification matrix says there is no formal property suite. No current CI formal job was found in the inspected workflow.

Action: begin with small, synthesizable properties for x0, valid/flush/retire ordering, request stability, response matching and precise trap flush. Record bounded versus unbounded proof status accurately.

### Cache behaviour

The cache documentation identifies high-risk cases including a reported two-store fetch hang, self-modifying code with no I-cache invalidate path, and reset during outstanding fill. These are not closed by merely instantiating the cache blocks.

Action: prioritize cache-system directed tests and failure reproduction before expanding the cache feature set. Keep cache coherence, write-back, multi-hart and DMA coherence out of the current release contract unless separately specified.

## 4. Verified source observations versus claims

The following are source-inspection observations, not fresh simulation results:

- Top-level module instantiates I-cache, D-cache, L2 and L3 cache blocks.
- Top-level module instantiates PLIC-lite and combines its IRQ output into the external interrupt path.
- Top-level module instantiates CLINT and UART.
- Top-level module instantiates QISA, XRV512, vector, AI accelerator, Xcetask and numeric blocks.
- The vector unit has a dedicated vector memory request/response port.
- `isa/rv64_profile.yaml` deliberately does not claim standard RVV through `misa.V`; custom CSR-driven vector functionality is not standard RVV binary compatibility.
- The I-cache invalidate input is tied low in the inspected instance.
- The ECALL cause deviation is explicit in both the profile and RTL decode.
- `sim/run.py` offers Icarus and Verilator simulation choices and a canonical RTL file list.
- The current CI workflow's required simulator installation is Icarus.

None of the above by itself proves end-to-end correctness.

## 5. Recommended P0 closure sequence

1. **P0.1 — Reproduce CI failure:** retrieve the failing core-regression batch logs for run 44081015448; rerun that exact test and seed locally or in a reproducible CI job.
2. **P0.2 — Fix ECALL cause:** update RTL, ISS, profile and directed M/S/U tests in one change.
3. **P0.3 — Fix fence.i:** connect a one-shot architectural fence.i event to I-cache invalidation; add a self-modifying-code test.
4. **P0.4 — Cache topology and validation:** draw actual request/response wiring; reproduce the two-store hang; run I-cache, D-cache, L2-system and core-level tests.
5. **P0.5 — Correct integration matrix:** update PLIC, CLINT, UART, caches and custom engine statuses based on top-level connectivity and CPU-level tests.
6. **P0.6 — Formal smoke:** add a small property suite and wire it into CI after proving the frontend/solver path.

## 6. P0 exit criteria

P0 is closed only when:
- The current main SHA has a reproducible baseline run with exact requested/executed test accounting.
- The current CI core-regression failure is understood and resolved or explicitly dispositioned.
- ECALL cause behaviour matches the ISA profile and privilege mode.
- fence.i invalidates the I-cache and the self-modifying-code test passes.
- The cache and peripheral integration matrix reflects the actual top-level hierarchy.
- Every status claim distinguishes source presence, instantiation, connectivity, CPU-level test and sign-off evidence.

## 7. CI run observed during audit

GitHub Actions run: [44081015448](https://github.com/thejas235689/rv64_core/actions/runs/44081015448)

Observed job steps:
- Icarus lint: success
- ISA conformance: success
- Core regression: failure
- Targeted Posit/quire regression: success
- PLIC-lite regression: skipped

The run summary available to this audit does not identify the failing testcase. Retrieve the full job logs before assigning root cause.
