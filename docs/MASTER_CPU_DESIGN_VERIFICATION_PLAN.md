# Master CPU Design and Verification Plan

**Repository:** `thejas235689/rv64_core`  
**Target branch:** `main`  
**Status:** Planning baseline; implementation and sign-off are not implied.  
**Authority:** `isa/rv64_profile.yaml` is the single source of truth for advertised ISA claims.  
**Last plan review:** 2026-11-17

## 1. Purpose and rules

This plan defines the work required to take the existing RV64 core from its current documented state to a reproducible, evidence-backed CPU release. It separates implemented, partially implemented, standalone, integrated, and future capabilities.

A feature is **complete** only when:
1. Its architectural/interface contract is documented.
2. RTL is present and connected at the intended integration boundary.
3. Directed and constrained-random tests execute and check the feature.
4. The independent reference model agrees where applicable.
5. Required assertions/formal properties pass or have reviewed waivers.
6. Functional coverage goals are met or holes are dispositioned.
7. CI records the exact commit, tool versions, commands, logs and artifacts.

A module compiling, a decoder recognising an opcode, a CSR window existing, or a README claim is not sufficient evidence of CPU-level integration.

## 2. Baseline and source-of-truth policy

The repository documents an in-order five-stage RV64 pipeline, integer/M operations, bit-manipulation extensions, privilege/trap/CSR support, PMP, Sv39 work, atomics, debug, PLIC-lite, custom numeric and accelerator blocks, and Cocotb/ISS and UVM verification assets. The verification report contains historical passing results; CI must reproduce them on the target commit before they are treated as release evidence.

Known documentation and verification cautions:
- Reconcile README claims with `docs/ROADMAP.md`, RTL hierarchy and `isa/rv64_profile.yaml`. In particular, do not describe caches as integrated unless instantiated and connected at the top-level ports.
- Distinguish the custom CSR-controlled vector unit from standard RVV instruction compatibility. Do not set `misa.V` unless standard RVV instruction encodings and architectural behaviour are implemented and verified.
- Resolve recorded ISA deviations in the profile, including privilege-specific ECALL cause behaviour, against the applicable RISC-V specification.
- The verification report documents a full-size UVM ISA throughput limitation. Do not mark that wrapper closed based on a reduced sweep.
- Historical results in reports are not a substitute for a fresh CI run against the release SHA.

## 3. Architecture work packages

### WP-A: Core and pipeline
- A01: Top-level hierarchy, reset, clock and integration contract.
- A02: Packages, types, parameters, XLEN/ILEN and build file lists.
- A03: Integer register file and x0 semantics.
- A04: Fetch request/response tracking, buffering, redirects and faults.
- A05: Compressed instruction expansion and instruction-length handling.
- A06: Decode and illegal/reserved instruction handling.
- A07: IF/ID, ID/EX, EX/MEM and MEM/WB stage-valid, stall, bubble and flush behaviour.
- A08: Forwarding, RAW/load-use hazards and interlocks.
- A09: Branch/jump execution and predictor recovery.
- A10: Retirement trace, architectural event ordering and debug observability.

### WP-B: ISA and execution
- B01: RV64I arithmetic, logical, shift, word, branch, jump and system instructions.
- B02: RV64M multiply/divide/remainder, including all signedness and exceptional operands.
- B03: Claimed Zba/Zbb/Zbc/Zbs/Zicond/Zicsr/Zifencei/Zihintpause behaviour.
- B04: RV64C decompression, instruction length, alignment and fetch-boundary cases.
- B05: RV64A LR/SC and AMOs, including reservation invalidation and failure cases.
- B06: Floating-point F/D operations, conversions, rounding, flags and architectural state.
- B07: ISA profile conformance: `misa`, implemented extensions, non-claimed probes and documentation consistency.

### WP-C: Memory, translation and protection
- C01: LSU state machine and all access widths/byte lanes.
- C02: Misaligned access splitting and Zicclsm behaviour.
- C03: Request stability, response latency, backpressure and error semantics.
- C04: Atomic reservation and read-modify-write sequencing.
- C05: Sv39 page-table walker, PTE validity, permissions and page faults.
- C06: TLB hit/miss/replacement, invalidation, ASID and superpage policy.
- C07: PMP TOR/NA4/NAPOT priority, lock and whole-access checks.
- C08: I-cache/D-cache integration only after actual hierarchy connectivity is confirmed.
- C09: L2/L3, replacement policy and coherent cache work as separate future work packages unless RTL integration is demonstrated.

### WP-D: Privilege, system and debug
- D01: Machine/supervisor/user privilege transitions and CSR access rules.
- D02: Trap entry/return, EPC precision, cause/value and younger-instruction flush.
- D03: Exception and interrupt delegation.
- D04: Software/timer/external interrupt behaviour and PLIC-lite integration.
- D05: WFI, wakeup and interrupt eligibility.
- D06: Debug halt/resume, single-step, EBREAK and watchpoints.
- D07: DMI transport and debug register access, if part of the target release.

### WP-E: Custom and research engines
Each engine is verified independently and then at its CPU integration boundary:
- E01: Custom numeric ABI, fixed-point, quire, Posit, LNS, RNS and error reporting.
- E02: RVV/custom vector unit; standard RVV is a separate architectural commitment.
- E03: XRV512 register bank and operations.
- E04: QISA state model and CSR interface.
- E05: INT8 AI accelerator and software-visible control.
- E06: Xcetask lifecycle, cancellation, timeout and completion interrupt.
- E07: CLINT, UART and platform-facing register/interrupt paths.
- E08: Modexp and cryptographic blocks; independent known-answer tests.
- E09: SHA-256/HMAC boot/authentication only as a platform work package.

### WP-F: Future architecture (not required to sign off the present in-order core)
- F01: Multi-hart and coherent interconnect.
- F02: Coherent cache hierarchy and memory consistency.
- F03: Hypervisor extension and two-stage translation.
- F04: Out-of-order backend: rename, free list, physical register file, issue queues, ROB, load/store queue, precise retirement.
- F05: Superscalar issue and retirement.
- F06: DNA, neuromorphic, photonic and other research accelerators after requirements are specified.

## 4. Verification plan

### 4.1 Simulation and reference checking
- Use Cocotb + the independent Python ISS as the primary fast architectural differential path.
- Compare retirement PC, instruction, destination register/value, memory effects and trap/interrupt events.
- Run directed tests for every supported instruction and corner case.
- Run deterministic constrained-random tests with recorded seeds.
- Inject variable memory latency, backpressure, response errors and reset events.
- Retain minimized reproductions for every regression failure.
- Keep UVM tests as an additional reusable verification environment; measure and improve driver throughput before using large sweeps as a CI gate.

### 4.2 Simulator and frontend diversity
- Verilator: lint, elaboration, structural checks, supported simulation and coverage.
- Xezim: independent parser/elaborator and selected simulation replay. Record unsupported constructs and tool limitations explicitly.
- Icarus: retain the currently configured Cocotb regression path where supported.
- A pass in one frontend does not erase a failure in another. Classify semantic differences, unsupported language constructs, testbench defects and RTL defects.

### 4.3 PSS scenario plan
Use Satya PSS only after confirming its installed version, supported PSS subset, compiler and execution backend. Generate portable scenario intent and map it to the repository's actual test harness. Required scenario families:
- Dependency chains and mixed ALU/MDU instruction streams.
- Branches, nested calls, returns and misprediction recovery.
- Load/store mixes, alignment, memory errors and backpressure.
- LR/SC reservation invalidation and AMO sequences.
- Privilege transitions, traps, delegation and interrupt timing.
- PMP configuration and access-denial sequences.
- Sv39 translation, permission faults and TLB invalidation.
- Debug halt/resume/single-step with in-flight traffic.
- Custom engine CSR programming, execution, completion and error paths.
- Reset injection at legal and adversarial transaction boundaries.

A generated scenario is not a pass until it executes and its results are checked by a scoreboard/reference model.

### 4.4 Formal verification
Use the supported Yosys/SymbiYosys frontend and solver combination for blocks that elaborate correctly. Use Slang or another SystemVerilog frontend where needed, while keeping frontend success separate from proof success.

Minimum property families:
- Pipeline valid/flush: invalid stages never retire; no instruction retires twice.
- Retirement: architectural state updates only on valid retirement or specified system events.
- Register file: x0 is constant zero.
- Bus: request fields remain stable until handshake; responses correspond to accepted requests.
- LSU: no completion without a matching transaction.
- Trap: precise EPC/cause; younger instructions cannot commit across a redirecting trap.
- CSR: privilege and write-mask constraints.
- PMP/MMU: prohibited accesses cannot complete successfully.
- Atomic: reservation and SC outcome follow the documented memory model.
- Debug: single-step produces exactly one retirement.
- Cache: coherence/staleness properties under the explicitly stated memory model.

Classify proof outcomes as proven, bounded-only, failed, inconclusive, unsupported or waived. Never label bounded checking as an unbounded proof.

## 5. Coverage and release gates

Track separate metrics; do not combine them into one opaque percentage:
1. Requirement coverage: requirement IDs with linked evidence.
2. Functional coverage: instructions, operands, privilege, exceptions, memory, bus and scenario crosses.
3. Code coverage: line, branch, toggle and FSM where the selected tool supports it.
4. Assertion coverage: exercised, failed and vacuous properties.
5. Formal status: proven, bounded-only, failed, inconclusive and waived.
6. Regression status: requested tests versus tests actually executed.

Proposed release gates:
- Every mandatory architectural requirement has passing evidence or an approved waiver.
- All mandatory directed tests pass.
- No unexplained ISS retirement, memory-effect or trap mismatch.
- No unresolved critical lint/elaboration issue.
- Critical protocol and pipeline assertions pass.
- Required PSS scenarios execute and are checked.
- Functional coverage holes in mandatory bins are closed or dispositioned.
- All waivers identify owner, rationale, risk and expiry/revisit condition.
- Artifacts are reproducible from the exact release commit and tool manifest.

## 6. Execution phases

| Phase | Scope | Exit evidence |
|---|---|---|
| P0 | Reconcile docs, ISA profile and real RTL connectivity | Signed baseline matrix |
| P1 | Reproducible toolchain and clean build/lint/elaboration | Versioned logs and source manifest |
| P2 | Pipeline, fetch, decode, ALU/MDU and base ISA | ISS differential regression |
| P3 | LSU, atomics, PMP, MMU and memory | Directed/random/fault tests and properties |
| P4 | Privilege, traps, interrupts and debug | Architectural scenario closure |
| P5 | Custom units and platform integration | Unit + CPU-level integration evidence |
| P6 | Formal, coverage and release sign-off | Evidence manifest and waiver review |
| P7 | Multicore, coherence, OoO and research architecture | Separate architecture/specification programme |

Estimates must be assigned after P0 discovers the actual RTL/test gaps. Do not use speculative dates as commitments.

## 7. Required evidence manifest

For every job, save:
- repository and commit SHA;
- requirement/work-package IDs;
- tool name, version and executable path;
- exact command and environment variables;
- start/end status and exit code;
- stdout/stderr and structured test report;
- random seed(s);
- waveform/trace and minimized reproducer where relevant;
- coverage and formal result files;
- waiver reference, if any.

Suggested output layout:
```
artifacts/<commit-sha>/
  manifest.json
  tools/versions.txt
  lint/verilator.log
  lint/xezim.log
  sim/cocotb/
  sim/uvm/
  pss/
  formal/
  coverage/
  waves/
  triage/
  signoff/
```

## 8. Definition of done

The in-order CPU release is done only when the mandatory profile is frozen, the RTL hierarchy matches the contract, the regression is reproducible, architectural differential tests pass, critical formal properties are resolved, mandatory coverage is closed, and the sign-off manifest is reviewed. Future research engines and OoO/multicore capabilities must not be used to inflate the completion status of the baseline CPU.
