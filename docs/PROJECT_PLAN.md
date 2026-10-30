# Project plan — RV64 CPU design and verification

This is the working plan for the core in `rtl/` and everything that proves it.
It states what is in scope, how the work is sequenced, what has to be true before
each phase is considered finished, and where the project actually stands today.
It is a living document: the status table in §5 is updated as phases close.

No calendar dates are given. Estimates of duration would be invented, and the
order of work plus the exit criteria are the parts that matter.

---

## 1. Scope

**In scope.** A single-hart, 64-bit RISC-V core in synthesizable SystemVerilog:
RV64I plus M, Zicsr, Zihintpause, Zba, Zbb, Zbc, Zbs and Zicond; machine mode
only; in-order five-stage pipeline; 8-entry PMP; machine CSRs, traps and
interrupts; a multi-cycle MDU; tournament branch prediction; debug halt/resume/
step; and the verification environment that proves all of it.

**Out of scope** (see `ROADMAP.md` for the full mapping): caches, out-of-order
execution, S/U privilege, Sv39, atomics, RVV, the custom numeric ABI, XRV512,
Xcetask, Qisa, the AI accelerator, and every research block. These are recorded
as absent, not as "in progress".

**Definition of done for the project.** Every implemented feature is exercised
by a self-checking test; the regression is green and reproducible by a third
party from the repository alone; the coverage report names what is covered and
what is not; and no claim in the documentation outruns the evidence.

---

## 2. Two tracks and the contract between them

| Track | Owns | Produces |
| --- | --- | --- |
| Design | `rtl/` | synthesizable RTL, the feature contract, the microarchitecture |
| Verification | `tb/`, `sim/`, `docs/TESTPLAN.md` | stimulus, reference models, coverage, the pass/fail verdict |

The interface between them is `docs/ARCHITECTURE_FEATURE_CONTRACT.md`. It is
written first and changed only by agreement, because everything downstream —
decoder legality, trap causes, CSR behaviour, bus timing — is checked against it.

**Rule the project runs by:** verification does not quietly edit the design.
Defects found by tests are reported with a failing test as evidence; the fix is
a deliberate, separate change, recorded in `VERIFICATION_REPORT.md`. During
bring-up that rule was followed with 14 fixes, each traceable to the test that
caught it. If a delivery requires the design to be frozen, the honest artefact
is a failing report against the frozen RTL, not a silently corrected one.

---

## 3. Phases

Each phase has an objective, a set of exit criteria that can be checked
mechanically where possible, and the artefacts it leaves behind.

### P0 — Contract and scaffold
**Objective.** Fix the ISA profile, microarchitecture and bus timing before any
code exists.
**Exit criteria.** Contract written; project tree laid out (`rtl/`, `tb/`, `sim/`,
`docs/`); build and lint flow working.
**Artefacts.** `ARCHITECTURE_FEATURE_CONTRACT.md`, `README.md`, tree skeleton.

### P1 — RTL bring-up
**Objective.** A core that compiles, elaborates and executes its first
instruction under a real simulator.
**Exit criteria.** Clean compile and elaboration on three independent tools;
first directed program retires; no X propagation from reset.
**Artefacts.** 12 RTL modules, testbench harness with a memory model.

### P2 — Functional verification
**Objective.** Every implemented instruction and control path compared against
an independent reference model.
**Exit criteria.** Directed suites for ALU, MDU, memory, control flow, hazards,
CSRs and traps all green against the golden model; randomised streams green;
backpressure and error-injection paths exercised.
**Artefacts.** `tb/cocotb/` (assembler, ISS, tests), `TESTPLAN.md`.

### P3 — Feature completion
**Objective.** Close the areas the first pass left untested.
**Exit criteria.** PMP (including lock semantics) verified at core level and as a
unit; instruction access fault; EBREAK debug entry; WFI both ways; counters;
return-address-stack overflow and indirect targets; mid-stream reset.
**Artefacts.** Additional directed tests, PMP unit testbench.

### P4 — UVM environment
**Objective.** A reusable class-based environment for teams that require UVM
rather than cocotb, reusing the same reference model.
**Exit criteria.** Environment builds and runs under a UVM-capable simulator;
scoreboard compares the full retirement and trap streams against golden vectors;
coverage collected; at least five tests green including a backpressure variant.
**Artefacts.** `tb/uvm/`, `sim/gen_uvm_vectors.py`, `sim/run_uvm.sh`.

### P5 — Coverage closure
**Objective.** Turn "the tests pass" into "the design is covered, and here is
the evidence".
**Exit criteria.** Every ISA class the core implements is hit by a retired
instruction; every exception cause the core can generate is observed; each
covergroup reports instance coverage with a stated target; gaps are either
closed or explicitly waived with a reason.
**Artefacts.** Coverage sections in `VERIFICATION_REPORT.md`.

### P6 — Hardening and sign-off
**Objective.** Evidence the RTL is buildable and timed, not merely simulatable.
**Exit criteria.** Synthesis clean at a chosen target with no inferred latches;
timing closure at a stated frequency; area and power reported; CDC review signed
off (single domain by construction); formal properties for the decoder and PMP
matching where practical.
**Artefacts.** Synthesis/STA reports, a sign-off checklist.
**Status: not started.** This is the largest remaining gap, and no claim of
timing closure or ASIC readiness should be made until it exists.

---

## 4. Verification strategy

Layered, cheapest evidence first, each layer catching what the one below cannot:

1. **Static** — compile and elaborate on Icarus, Verilator (lint, including
   combinational-loop detection) and xezim. Catches structural errors and
   loops before a single vector runs.
2. **Unit** — PMP matcher and PLIC controller tested in isolation against
   expectations computed in the test. Catches block-level logic errors that a
   full-core test would only see indirectly.
3. **Directed core** — one test per feature, each program written in assembly so
   the intent is readable, compared instruction-by-instruction against the ISS.
4. **Randomised core** — constrained-random instruction streams with the full
   retirement trace and the data memory compared. This is what catches
   interaction bugs: forwarding under fetch bubbles, branch redirects, CSR
   ordering.
5. **Environmental stress** — request backpressure, bus error injection, mid-
   stream reset, halt/resume/step.
6. **UVM** — the same reference model behind a class-based environment, for
   teams that need it and to prove the design is verifiable from a second
   framework.
7. **Formal (planned)** — decoder legality and PMP matching are small, closed
   problems where exhaustive proof is cheaper than simulation.

**The reference model is deliberately independent.** `tb/cocotb/rv64_iss.py` is a
Python ISS written from the specifications, not from the RTL. Agreement between
it and the RTL is therefore evidence; a model derived from the RTL would only be
a restatement.

**Every layer must be able to fail.** The value of the suite is measured by what
it has caught: 14 RTL defects and 10 harness defects to date, all listed in
`VERIFICATION_REPORT.md`. A test that has never failed proves nothing.

---

## 5. Status against the plan

| Phase | State | Evidence |
| --- | --- | --- |
| P0 Contract | **done** | `ARCHITECTURE_FEATURE_CONTRACT.md` |
| P1 RTL bring-up | **done** | clean on Icarus 14, Verilator 5.05, xezim 0.11.3 |
| P2 Functional verification | **done** | 20/20 cocotb core tests, 56,698 random instructions matched |
| P3 Feature completion | **done** | + 5/5 PMP unit tests, 2/2 PLIC tests; 27 tests total |
| P4 UVM environment | **done** | 5/5 UVM tests under xezim, scoreboard vs golden vectors |
| P5 Coverage closure | **partial** | ISA classes and all exception causes hit; covergroup instance coverage 52–70 %, no stated closure target yet |
| P6 Hardening and sign-off | **started** | generic synthesis clean: no latches, 144,090 cells (15,039 FF), 203 logic levels, MDU result path critical. No library timing, STA, formal or CDC report yet |

### Test totals

| Suite | Tests | Result |
| --- | --- | --- |
| cocotb core regression | 20 | 20 pass |
| PMP matcher unit | 5 | 5 pass |
| PLIC-lite unit | 2 | 2 pass |
| UVM regression | 5 | 5 pass |
| **total** | **32** | **32 pass** |

---

## 6. Risks and mitigations

| Risk | Impact | Mitigation in place / planned |
| --- | --- | --- |
| A feature is present but silently non-functional (PMP was, until tested) | High — false confidence in the feature list | One directed test per contract row; unit tests for blocks with internal logic; coverage per ISA class |
| Reference model shares a misconception with the RTL | High — both wrong, tests pass | Model written from the specs; cross-checked against published encodings during bring-up; RTL defects found this way are listed |
| Simulator quirks mask real behaviour | Medium | Three independent tools; Icarus for simulation, Verilator for lint, xezim for UVM and elaboration |
| Coverage looks complete but crosses are empty | Medium | Cross coverage on class × write; explicit gap list rather than a single percentage |
| No synthesis/STA means timing is unknown | High for any silicon claim | Stated as a gap in every document; P6 is the next major phase |
| Single maintainer on a large RTL body | Medium | Contract-first docs, one module per file, style guide in `README.md` |

---

## 7. Immediate next steps

In the order they are worth doing:

1. **P6 start — synthesis.** Take the core through Yosys at minimum, then a
   vendor flow. Report latches, area and a critical-path estimate. This is the
   single largest unknown.
2. **Coverage closure targets.** State a target per covergroup, measure the
   crosses, and either close the gaps or waive them with a reason.
3. **Formal for the decoder and PMP.** Both are small and closed; exhaustive
   proof would retire a whole class of risk that random tests only sample.
4. **Widen the UVM regression** — the five tests prove the environment works;
   the full directed set should migrate to it if UVM is the delivery framework.
5. **Synthesis-friendly review** of the MDU divider and the ALU bit-count
   network, which are the likely critical paths and have never been synthesised.
