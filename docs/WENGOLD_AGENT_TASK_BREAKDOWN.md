# WENGOLD Agent and Task Breakdown for RV64 CPU Completion

**Purpose:** Turn the master CPU plan into an executable, evidence-producing WENGOLD workflow.  
**Status:** Architecture and task contract; tool execution must be validated in the target Linux installation.

## 1. Operating principles

1. WENGOLD orchestrates; it must not fabricate tool results or silently mark tasks complete.
2. Each agent receives a bounded task, source commit, requirements, allowed tools, expected outputs and stop conditions.
3. Every result is tied to a commit SHA and exact tool version.
4. Tool installation, tool availability, parsing, elaboration, simulation, formal proof and sign-off are distinct states.
5. Agents may propose RTL edits, but integration requires tests and review.
6. A simulator disagreement is a triage item, not an automatic vote.
7. No agent may change the ISA profile to make a failing test pass without an explicit architecture decision and corresponding RTL/ISS/docs updates.

## 2. Agent topology

| Agent | Responsibility | Inputs | Outputs |
|---|---|---|---|
| SpecAgent | Extract requirements and detect contradictory claims | ISA profile, README, contracts, roadmap | Requirement database, contradiction report |
| RTLMapAgent | Inventory modules, ports, hierarchy and connectivity | RTL file list, top module | Module graph, interface matrix, integration status |
| BuildAgent | Reproducible build and source-list management | CI scripts, packages, toolchain | Build manifest, dependency graph |
| VerilatorAgent | Lint, elaborate, supported simulation | RTL manifest, lint policy | Machine-readable lint/elaboration report |
| XezimAgent | Independent parse/elaboration/replay | Same RTL manifest and selected tests | Cross-frontend report and minimized reproductions |
| CocotbAgent | Directed/random architectural simulation | Test plan, DUT, Python ISS | JUnit/XML, trace comparisons, seeds |
| UvmAgent | UVM environment and throughput | UVM packages, vectors, ISS | UVM test results and performance metrics |
| SatyaPSSAgent | Scenario model and PSS execution | Scenario requirements, installed Satya toolchain | PSS source, generated tests, scenario coverage |
| FormalAgent | Assertions and formal property runs | RTL, assumptions, property library | Proof status, counterexamples, assumptions |
| CoverageAgent | Functional/code/assertion/requirement coverage | Test reports, coverpoints, property results | Coverage dashboard and hole analysis |
| DebugAgent | Failure correlation and replay | Logs, VCD/FST, traces, source map | Root-cause report, replay bundle |
| IntegrationAgent | Run full-core and cross-agent gates | Approved RTL changes and all reports | Integration matrix and release candidate |
| SignoffAgent | Evidence-based release decision | All manifests, waivers and coverage | Pass/conditional/fail decision |

Agents should be independent where useful, but shared resources (build directories, generated files, simulators) must be isolated per job to prevent races.

## 3. Task lifecycle and status model

Use these states:
- `BACKLOG`: not yet assessed.
- `READY`: requirements and dependencies are clear.
- `RUNNING`: an agent has an active job.
- `BLOCKED`: missing tool, dependency, spec decision or infrastructure.
- `FAILED`: job executed and failed.
- `NEEDS_REVIEW`: results exist but require human/architecture review.
- `PASS`: acceptance criteria met with evidence attached.
- `WAIVED`: approved exception with owner, rationale, risk and revisit date.

Do not use a single Boolean `complete` field. Store state transitions with timestamp, agent, commit SHA and evidence reference.

## 4. Execution pipeline

### Stage 0 — Discover and freeze the baseline
1. Resolve repository path and current commit SHA.
2. Read `isa/rv64_profile.yaml`, README, architecture contract, roadmap, completion plan and CI workflow.
3. Build the actual RTL file list using the repository's canonical script.
4. Identify top-level module and trace every declared subsystem port to an instantiated module or external boundary.
5. Generate discrepancy report: README vs profile vs RTL vs tests vs roadmap.
6. Freeze a baseline manifest before any RTL modifications.

**Gate:** all feature claims are labelled integrated, standalone, partial, absent or unverified.

### Stage 1 — Tool preflight
For every tool, capture version, executable path, licence/dependency state (where applicable), supported frontend and smoke-test result:
- Verilator
- Xezim
- Icarus Verilog
- Cocotb
- Satya PSS compiler/solver/backend
- Python ISS dependencies
- Yosys/SymbiYosys and selected solver
- Slang, if used as a SystemVerilog frontend

Tool status values: `NOT_INSTALLED`, `INSTALLED`, `VERSION_CHECKED`, `SMOKE_TEST_PASS`, `UNSUPPORTED_FOR_TARGET`, `FAILED`.

Do not assume Satya's PSS support or a Verilator/Xezim integration interface. Discover the actual installed command and supported language subset first.

### Stage 2 — Static analysis and elaboration
1. Run Verilator lint on the canonical source list.
2. Run Xezim parse/elaboration on the same source list.
3. Run existing Icarus elaboration path.
4. Compare diagnostics by file/line/category.
5. Fail the gate on missing RTL files, empty/truncated file lists, missing top, unresolved critical warnings or unsupported required constructs.
6. Store logs and normalized diagnostics.

### Stage 3 — Unit and architectural simulation
1. Run unit tests for ALU, MDU, PMP, PLIC, numeric and other independent blocks.
2. Run core directed tests.
3. Run deterministic random tests and record seeds.
4. Run ISS retirement/trap/memory differential checks.
5. Run selected tests in multiple simulators where supported.
6. Replay failures with identical input streams and memory response schedules.

### Stage 4 — PSS scenario execution
1. Convert requirement scenarios into PSS actions, resources and constraints.
2. Generate legal scenarios using the verified Satya toolchain.
3. Map generated scenarios into an existing Cocotb/UVM execution adapter.
4. Execute scenarios; capture seed, generated test, coverage and scoreboard verdict.
5. Minimize failing scenarios and attach replay artifacts.

If an adapter is not implemented, mark the task BLOCKED; do not report PSS execution merely because PSS source compiled.

### Stage 5 — Formal and coverage
1. Select properties for pipeline, bus, traps, CSR, PMP, MMU, atomics and debug.
2. Run supported formal frontend and solver.
3. Classify proof outcomes accurately.
4. Merge functional coverage across tests without double-counting bins.
5. Collect code coverage where available.
6. Identify unreachable, uncovered and vacuous bins.
7. Require a reviewed disposition for every mandatory hole.

### Stage 6 — Failure triage
Every failure record contains:
- unique failure ID and requirement ID;
- commit SHA, tool/version and exact command;
- test and random seed;
- expected versus observed result;
- first divergence cycle/retirement;
- RTL source location and relevant hierarchy;
- waveform/transaction trace;
- reproduction command;
- suspected category: RTL, testbench, reference model, simulator/frontend, environment or specification;
- owner and next action.

### Stage 7 — Integration and sign-off
1. Re-run impacted unit tests.
2. Re-run all dependent integration tests.
3. Run full mandatory regression on candidate SHA.
4. Check profile/docs/RTL/test consistency.
5. Check formal and coverage gates.
6. Generate evidence manifest and waiver list.
7. SignoffAgent issues PASS, CONDITIONAL or FAIL with explicit reasons.

## 5. Required WENGOLD data contracts

### Requirement record
```json
{
  "requirement_id": "MEM-003",
  "title": "Misaligned access splitting",
  "source": "isa/rv64_profile.yaml",
  "status": "READY",
  "priority": "P1",
  "rtl_paths": [],
  "tests": [],
  "properties": [],
  "dependencies": ["MEM-001", "MEM-002"],
  "acceptance": ["all supported crossing lanes checked", "ISS memory effects match"],
  "evidence": []
}
```

### Job record
```json
{
  "job_id": "run-<uuid>",
  "agent": "VerilatorAgent",
  "requirement_ids": ["CPU-001", "CPU-002"],
  "commit_sha": "<git-sha>",
  "tool": "verilator",
  "tool_version": "<captured-version>",
  "command": "<exact-command>",
  "status": "RUNNING",
  "started_at": "<ISO-8601>",
  "exit_code": null,
  "log_artifact": null,
  "result_artifact": null
}
```

### Evidence record
```json
{
  "evidence_id": "EV-<uuid>",
  "requirement_id": "CPU-010",
  "commit_sha": "<git-sha>",
  "kind": "simulation",
  "tool": "cocotb",
  "tool_version": "<captured-version>",
  "test": "test_retirement_trace",
  "seed": 12345,
  "result": "PASS",
  "artifact_uri": "artifacts/<sha>/sim/...",
  "reviewed": false
}
```

### Failure record
```json
{
  "failure_id": "FAIL-<uuid>",
  "requirement_id": "SYS-003",
  "commit_sha": "<git-sha>",
  "test": "test_precise_trap",
  "tool": "icarus",
  "seed": 12345,
  "first_divergence": {"cycle": 0, "retirement": 0},
  "classification": "UNTRIAGED",
  "reproducer": "artifacts/<sha>/triage/...",
  "owner": null
}
```

## 6. WENGOLD UI workspaces

1. **Project / Spec:** repository, branch, commit, ISA profile, requirement matrix.
2. **RTL Explorer:** module hierarchy, ports, connectivity, source cross-probe.
3. **Build & Lint:** tool versions, diagnostics, file list, elaboration status.
4. **Simulation:** Cocotb/UVM tests, seeds, ISS trace diff and regression history.
5. **PSS Scenarios:** scenario library, constraints, generated tests and scenario coverage.
6. **Formal:** properties, assumptions, proof status and counterexamples.
7. **Coverage:** functional, code, assertion and requirement coverage.
8. **Waveform Debug:** VCD/FST, pass/fail comparison, protocol lanes, transaction IDs and source cross-probe.
9. **Triage:** failure queue, replay, classification and root-cause tracking.
10. **Signoff:** release gates, evidence manifest, waivers and final decision.

## 7. Waveform/debug contract

- Preserve original VCD/FST files and metadata; never silently downsample source artifacts.
- Align pass/fail traces by transaction/retirement identity, not only absolute timestamp.
- Display RTL and testbench signals in separate groups.
- Provide protocol lanes for instruction, data, vector and accelerator interfaces.
- Correlate request/response handshakes, IDs, addresses, strobes, errors and backpressure.
- Cross-probe a signal to elaborated hierarchy and source location.
- Distinguish X/Z, uninitialized and unsupported values from 0/1.
- Every debug conclusion links to the original trace and commit SHA.

## 8. CI job matrix

| Job | Tool/path | Required artifact | Gate |
|---|---|---|---|
| source_manifest | canonical RTL list | file list + SHA | mandatory |
| verilator_lint | Verilator | log + normalized diagnostics | mandatory |
| xezim_elab | Xezim | parse/elab report | mandatory when supported |
| icarus_elab | Icarus | compile log | existing compatibility gate |
| unit_regression | Cocotb | JUnit + logs | mandatory |
| core_regression | Cocotb + ISS | JUnit + retirement diff | mandatory |
| pss_scenarios | Satya + adapter | generated scenario + result | mandatory after adapter readiness |
| formal_smoke | Yosys/SBY + solver | proof status + VCD counterexamples | mandatory for selected properties |
| coverage_report | supported coverage tools | coverage database/report | mandatory |
| evidence_manifest | WENGOLD | JSON manifest | mandatory |

CI must distinguish a skipped job from a passing job. Unsupported tool features are recorded as unsupported, not green.

## 9. Initial implementation backlog

### WENGOLD-001: Repository and RTL inventory
**Acceptance:** canonical source list, module graph, top-level connectivity and feature-status matrix generated for a pinned SHA.

### WENGOLD-002: Toolchain preflight
**Acceptance:** Verilator, Xezim, Icarus, Cocotb, Satya and formal tool versions/smoke tests recorded; missing tools reported as BLOCKED.

### WENGOLD-003: Requirement database
**Acceptance:** master plan work-package IDs imported; each requirement links to RTL, tests, properties and evidence.

### WENGOLD-004: Verilator lint agent
**Acceptance:** repeatable lint job, normalized diagnostics, severity policy and artifact retention.

### WENGOLD-005: Xezim independent frontend agent
**Acceptance:** same canonical file list parsed/elaborated; diagnostics classified; selected replay tests documented.

### WENGOLD-006: Cocotb/ISS regression agent
**Acceptance:** requested-versus-executed accounting, deterministic seeds, retirement/memory/trap differential reports.

### WENGOLD-007: Satya PSS adapter
**Acceptance:** installed Satya version and PSS subset documented; at least one generated scenario executes through the DUT harness and is scoreboard-checked.

### WENGOLD-008: Formal property runner
**Acceptance:** selected properties, assumptions, solver versions and proof classifications stored; counterexamples linked.

### WENGOLD-009: Coverage aggregator
**Acceptance:** independent functional/code/assertion/requirement metrics; no combined misleading percentage; holes dispositioned.

### WENGOLD-010: VCD/FST failure comparator
**Acceptance:** pass/fail traces aligned by retirement or transaction identity, source cross-probe and replay link.

### WENGOLD-011: Failure triage and replay
**Acceptance:** every failed job produces a structured failure record and reproducible command.

### WENGOLD-012: Signoff dashboard
**Acceptance:** PASS/CONDITIONAL/FAIL derived only from evidence and approved waivers; missing jobs cannot be counted as passes.

### WENGOLD-013: CI integration
**Acceptance:** CI runs supported jobs on pull requests; uploads logs/reports; records skipped/unsupported status honestly.

## 10. First sprint order

1. WENGOLD-001 — inventory and baseline discrepancy report.
2. WENGOLD-002 — verify local toolchain and Satya support.
3. WENGOLD-003 — import requirements and dependencies.
4. WENGOLD-004/005 — static checks with Verilator and Xezim.
5. WENGOLD-006 — reproduce existing core regression.
6. WENGOLD-007/008 — prove PSS and formal paths with one small smoke case each.
7. WENGOLD-009/010/011 — evidence, coverage and debug.
8. WENGOLD-012/013 — sign-off dashboard and CI enforcement.

Do not start broad RTL feature development until the baseline audit identifies the highest-risk correctness gaps.

## 11. Sign-off honesty

WENGOLD must show the difference between:
- planned and implemented;
- installed and smoke-tested;
- parsed and elaborated;
- elaborated and simulated;
- simulated and scoreboard-checked;
- bounded-checked and formally proven;
- module-level and CPU-integrated;
- passing and waived.

A green dashboard is valid only if every mandatory gate has fresh evidence for the same candidate commit.
