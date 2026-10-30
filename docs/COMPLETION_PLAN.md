# Plan: completing the RTL and its verification

Scope: what it takes to go from the current core to a complete, verified, sign-off
ready RISC-V implementation. Effort figures are engineer-weeks for one person who
knows the codebase, and they assume the discipline this project has already proved
necessary -- a directed testbench before any RTL that touches an existing path.

Current position: 39 RTL modules / ~9,000 lines, 36 cocotb tests, 30 block
testbenches, two simulators, lint clean, ~16 of 211 catalogued extensions.

---

## Phase 0 -- Close what is already open (1 week)

No new features. These are defects and gaps, and every later phase inherits them if
they are not fixed first.

| Item | Why first | Exit criteria |
| --- | --- | --- |
| RVC in the ISS | Compressed programs are currently verified by observation, not against a golden model. Every later phase that touches fetch or decode needs this. | A mixed compressed/32-bit program trace-compares with zero mismatches |
| Wire the six orphaned modules | FNV bootauth is **deleted** (superseded by the HMAC version, and only its own TB referenced it). The other five -- CLINT, UART, DMI, PLIC-lite, L2 arbiter -- cannot simply be wired in: each is memory-mapped, and **the core has no peripheral bus**. Wiring them is a design task, not cleanup, and it needs a bus fabric first. | FNV deleted; the other five either wired via a new peripheral bus, or documented as waiting on one |
| One green regression run | 36 tests pass individually; none of that is visible in CI because the suite exceeds one command timeout | `sim/run.py` completes within the CI budget, or splits into shards that do |
| UVM sweep throughput | The 4445-instruction sweep is throughput-blocked at ~3250 cycles per retired instruction | Full-size UVM sweep passes, or the driver's speed is documented as a known limit |

**Verification gate:** CI runs the whole suite green from a clean checkout.

---

## Phase 1 -- Scalar floating point, F and D (6 weeks)

The single largest gap. Without it the core cannot run a general-purpose ABI.

| Work | Notes |
| --- | --- |
| `rv64_fregfile` | 32 x 64-bit, with the NaN-boxing rules for narrower values |
| `rv64_fpu` | add, sub, mul, div, sqrt, min/max, compare, sign-inject, convert, move. Binary32 and binary64 |
| Rounding and flags | RNE/RTZ/RDN/RUP/RMM, `fflags` and `fcsr`, the accrued-exception rules |
| Decode and pipeline | OP-FP (opcode `0x53`), `flw`/`fld`/`fsw`/`fsd`, the FP load/store forms, `fmv.x.w`/`fmv.w.x` and the 64-bit variants |
| Context | `mstatus.FS`, `fcsr` in `mstatus`, lazy save/restore semantics |

The binary32 add/sub/mul already in `rv64_vunit` is a starting point for the datapath
but is not reusable as-is: it has no rounding modes, no flags, no div/sqrt, and no
NaN-boxing.

**Verification:** a SoftFloat-derived golden model is the only credible oracle here --
hand-written expected values will not survive. Directed tests per operation per
rounding mode per special case (NaN, inf, signed zero, denormal, exact ties), then a
random differential run of at least 10^6 vectors against SoftFloat.

**Exit criteria:** every OP-FP instruction trace-compared against SoftFloat; `fflags`
correct for every case; IEEE-754 conformance suite subset passing.

---

## Phase 2 -- Float extensions (3 weeks)

Depends on Phase 1.

`Zfh`/`Zfhmin` (binary16 with NaN-boxing into the FP register), `Zfa` (the additional
FP instructions: `fli`, `fminm`/`fmaxm`, `fcvtmod`, `fround`, `fleq`/`fltq`),
`Zcf`/`Zcd` (the compressed float load/store forms). Each is small once the FPU exists.

**Exit criteria:** each extension verified against SoftFloat, with the compressed forms
covered by the RVC path.

---

## Phase 3 -- The Zc* compressed family (2 weeks)

Depends on Phase 1 for the float members. C already works, so this is now reachable.

`Zca` (already covered by C), `Zcb` (extra compressed integer, including byte/half
loads), `Zcmp` (push/pop multiple), `Zcmt` (table jumps), `Zcmop` (compressed
may-be-ops), `Zclsd` (compressed load/store pair).

**Exit criteria:** every new encoding expands correctly in `tb_rvc` against an
independently computed 32-bit form, and executes in-core.

---

## Phase 4 -- Remaining atomic and ordering extensions (2 weeks)

`Zacas` (128-bit compare-and-swap -- needs a paired read, a 128-bit compare and a
paired write in the LSU), `Ztso` (the ordering model, or a documented decision that
the existing strong ordering satisfies it), `Zawrs` is done.

**Exit criteria:** `tb_lsu` extended with the paired-access cases; `Zacas` verified
against a multi-agent memory model, since its whole purpose is interaction.

---

## Phase 5 -- Interrupt architecture (6 weeks)

Replaces PLIC-lite wholesale. This is a redesign, not an addition.

`Smaia`/`Ssaia` (the advanced interrupt architecture: `mip`/`mie`/`mideleg` extended,
`mtopi`, `stopi`, `mvien`/`mvip`), `Smclic`/`Ssclic` (the core-local interrupt
controller), `Sstc` (supervisor timer compare).

**Verification:** a directed interrupt controller testbench that injects every source
at every priority, plus a core-level test that each interrupt reaches the right
privilege level with the right `mcause`/`scause`.

**Exit criteria:** every interrupt source verified end-to-end into a handler; no
PLIC-lite dependency left in the top.

---

## Phase 6 -- Memory system: coherence, inclusion, writeback, prefetch (8 weeks)

The largest architectural change. Everything multi-hart or multi-master depends on it.

| Work | Notes |
| --- | --- |
| Write-back D-cache | Currently write-through. Needs dirty bits, eviction writeback, and the ordering rules |
| Coherence protocol | A directory or snooping protocol. Choose one and write the contract down before coding |
| Inclusion management | L2 inclusive of L1, or explicitly non-inclusive with the trade-off documented |
| Prefetch | `Zicbop` hints actually acted on; a stride detector feeding the L1s |
| Cache management | `Zicbom`/`Zicboz` already exist; extend to the L2 and L3 |
| The L2 arbiter | Finally instantiated, once there is more than one master that needs it |

**Verification:** this cannot be verified with directed tests alone. It needs a
coherence-litmus suite (message-passing and store-buffer patterns) run against a memory
model, plus random multi-agent traffic with an invariant checker.

**Exit criteria:** the litmus suite passes; a random multi-master run of 10^7 accesses
shows no coherence violation; no stale read after a `cbo.inval`.

---

## Phase 7 -- Multi-hart (4 weeks)

Depends on Phase 6. Replicate the core, add an interconnect, a shared L2/L3, and the
`mhartid` and IPI plumbing. Decide the topology before coding.

**Exit criteria:** a two-hart test running a message-passing workload with coherent
shared memory; per-hart `mhartid`; IPIs delivered.

---

## Phase 8 -- Hypervisor H (8 weeks)

Depends on Phase 6 for two-stage translation. VS-mode CSRs, `hgatp`, `hstatus`,
`hedeleg`, the `hlv`/`hsv` access instructions, guest/VS trap routing, and the
second-stage permission checks.

**Exit criteria:** a guest that faults on a stage-2 permission error with the right
`htval`/`htinst`; a guest context switch that preserves VS state.

---

## Phase 9 -- Address translation breadth (2 weeks)

`Sv48`, `Sv57`, `Svpbmt`, `Svnapot`, `Svinval`, `Svade`/`Svadu`. The walker is
parameterisable already; these are depth, attribute and invalidation changes.

**Exit criteria:** each mode verified with a walk of the full depth; `Svnapot` NAPOT
PTEs honoured; `Svinval` actually invalidating.

---

## Phase 10 -- Security and privilege extensions (5 weeks)

`Smepmp`, `Ssstateen`/`Smstateen`, `Zicfilp` (landing pads), `Zicfiss` (shadow stack),
`Sdtrig` (debug triggers), `Zkr` (entropy source). CFI in particular needs care: it
adds architectural state that must be context-switched and must not be forgeable.

**Exit criteria:** each verified with its own directed tests; CFI verified against an
attack corpus (forged return addresses, missing landing pads).

---

## Phase 11 -- Cryptography (10 weeks)

`Zk*` scalar (`Zkne`/`Zknd` AES, `Zknh` SHA-2, `Zksed` SM4, `Zksh` SM3, `Zbkb`/`Zbkc`/
`Zbkx`) and `Zvk*` vector. The SHA-256 and HMAC blocks already in the tree are a
starting point for `Zknh`.

**Verification:** NIST and GM/T known-answer vectors, plus a timing-safety check for
`Zkt` (no data-dependent branches or memory access).

**Exit criteria:** every cipher and hash verified against published vectors; `Zkt`
verified by construction review plus a statistical timing test.

---

## Phase 12 -- Out-of-order backend (16+ weeks)

Not an addition; a replacement. Reservation stations, register renaming, a reorder
buffer, precise exceptions from an imprecise machine, and a memory disambiguation
policy. The existing in-order pipeline stays as the reference model.

**Exit criteria:** the OoO core trace-compares against the in-order core on the full
random regression -- the existing ISS becomes the oracle for the new backend.

---

## Phase 13 -- Research blocks (unbounded)

DNA storage, neuromorphic, photonic, interconnect. **These cannot be planned until each
has a written contract** stating its interface, its behavioural specification and what
"verified" means. Writing those four contracts is itself a week's work and is the
prerequisite for estimating anything.

---

## Phase 14 -- Physical and sign-off (10 weeks)

Generic synthesis already runs (Yosys via sv2v). What remains: a real technology
library, timing closure at a target frequency, clock-domain crossing review (the UART
is genuinely asynchronous), power estimation, DFT insertion, and a lint/CDC/LINT
sign-off with no waivers. FPGA bring-up on a development board if a hardware target
exists.

**Exit criteria:** timing closed at the target frequency; CDC sign-off; a bitstream
running a test program on real hardware.

---

## Sequencing summary

```
Phase 0 (1w)  ──┬── Phase 1 F/D (6w) ── Phase 2 float ext (3w) ── Phase 3 Zc* (2w)
                ├── Phase 4 atomics (2w)
                ├── Phase 5 interrupts (6w)
                └── Phase 6 memory system (8w) ──┬── Phase 7 multi-hart (4w)
                                                 ├── Phase 8 H (8w)
                                                 └── Phase 9 translation (2w)
Phase 10 security (5w)      Phase 11 crypto (10w)      Phase 12 OoO (16w+)
Phase 13 research (needs contracts)                     Phase 14 physical (10w)
```

Phases 2-5 and 9-11 are independent of each other and can run in parallel with more
than one engineer. Phases 7, 8 and 12 are strictly serial behind Phase 6.

**Critical path to a general-purpose core: 0 -> 1 -> 6 -> 7/8 -> 12.** Roughly
35 weeks of serial work before an out-of-order, coherent, hypervisor-capable machine
exists, and that excludes crypto and the research blocks.

---

## Verification strategy, applied to every phase

The lesson this project keeps teaching, written down so it survives:

1. **Directed testbench first.** Every feature that landed here did so after a
   per-module testbench existed; every one that stalled was being debugged through the
   whole core. Build `tb_<module>` before touching `<module>`.
2. **The oracle must be validated at the layer it judges.** A reference that reproduces
   a published vector for the *operation* is not validated for the *composition* on top
   of it. Validate the oracle against a published end-to-end answer first.
3. **Trace comparison, not spot checks.** Every core test compares pc, instruction,
   destination and write data against the ISS for every retirement.
4. **An X is a failure, not a don't-care.** Every X in this project that was waved
   through turned out to be a real defect.
5. **A feature is not done until its test is committed and green**, and if a test
   cannot be written, that is stated in the report rather than glossed.
