# Architecture feature contract — rv64_core

What this core is, in prose. The machine-readable form is
`isa/rv64_profile.yaml`, and that file wins: this document, `README.md`, the RTL
and the ISS are all checked against it by `tb/cocotb/test_isa_conformance.py`, so
a disagreement fails the build instead of living in the tree.

## 1. Contract

The ISA profile is pinned in **`isa/rv64_profile.yaml`** and that file is the
single source of truth. `tb/cocotb/test_isa_conformance.py` reads it and fails
when this document, `README.md`, the RTL or the ISS disagree with it; nothing
below should be edited without editing the profile first.

```
ISA profile    : RV64I + M + A + C + D + F + S + U
                 misa = 0x800000000014112D (MXL=2, A C D F I M S U set, H clear)
                 Zicsr, Zifencei, Zicntr, Zihintpause, Zicclsm, Zawrs,
                 Zba, Zbb, Zbc, Zbs, Zicond
                 M/S/U privilege, Sv39 translation, misa.V clear (see the profile)
Microarchitecture: in-order 5-stage IF/ID/EX/MEM/WB, 1 instruction per cycle peak
                 forwarding: EX/MEM and MEM/WB into EX, plus WB->ID write-through
                 interlock: load-use (1 cycle), MDU busy, CSR-vs-MRET
                 branch: resolved in EX, tournament prediction in IF
                 trap: single precise trap point at MEM
Bus interface  : separate I, D and vector valid/ready ports, 64-bit beats, byte
                 strobes on the write ports, backpressure on request, separate
                 response channel with an error flag; one outstanding request
                 per port
Clock/reset    : one clock, synchronous active-low reset (rst_n), single domain
Custom CSRs    : nine windows, 0x780-0x807 (see the profile's csr_map)
```

## 2. Architectural state

| State | Width | Notes |
| --- | --- | --- |
| `x0`–`x31` | 64 | `x0` reads 0, writes suppressed |
| `pc` | 64 | |
| `mstatus` | MIE(3), MPIE(7), MPP(12:11), FS(14:13), SUM(18), MXR(19) | MPP records the mode a trap came from: 11 M, 01 S, 00 U |
| `misa` | 64 | read-only, 0x800000000014112D = A C D F I M S U, MXL=2 (computed from isa/rv64_profile.yaml) |
| `mie` / `mip` | MSIE(3), MTIE(7), MEIE(11) | `mip` is read-only from the platform |
| `mtvec` | 64 | direct mode only, low 2 bits forced 0 |
| `mepc` | 64 | low 2 bits forced 0 (IALIGN=32) |
| `mcause`, `mtval` | 64 | full write |
| `mscratch`, `mcounteren` | 64 | |
| `pmpcfg0` | 8 × 8 | entries 0–7 |
| `pmpaddr0`–`7` | 54 | upper bits read as 0 |
| `mcycle`, `minstret` | 64 | writable, `*h` halves accessible |
| `mvendorid`/`marchid`/`mimpid`/`mhartid` | 64 | read-only |

Any CSR access to an address not listed above raises an illegal-instruction
exception.

## 3. Instruction set

RV64I: `lui auipc jal jalr beq bne blt bge bltu bgeu lb lh lw ld lbu lhu lwu
sb sh sw sd addi slti sltiu xori ori andi slli srli srai add sub sll slt sltu
xor srl sra or and addiw slliw srliw sraiw addw subw sllw srlw sraw fence
fence.i ecall ebreak mret sret wfi` and the CSR instructions.

RV64M: `mul mulh mulhsu mulhu div divu rem remu`.
RV64A: `lr.w/d sc.w/d` and all nine AMOs in `.w` and `.d`, plus the Zabha
byte/halfword AMOs.
RV64C: the RV64C encodings, widened by `rv64_rvc_expand`; `pc` advances by the
instruction's own length.
RV64F / RV64D: `fadd fsub fmul fdiv fsqrt fsgnj fsgnjn fsgnjx fmin fmax` and
`fcvt.*`, `fmv.*`, `feq flt fle` in `.s` and `.d`.

Zba: `add.uw sh1add sh2add sh3add slli.uw`.
Zbb: `andn orn xnor clz ctz cpop max maxu min minu sext.b sext.h zext.h rol ror
rori rolw rorw rev8 orc.b`.
Zbc: `clmul clmulh clmulr`.
Zbs: `bset bclr binv bext bseti bclri binvi bexti`.
Zicond: `czero.eqz czero.nez`.
Zihintpause: `pause`.

H, V, Q, Zfh and Zacas are not implemented. H instructions retire as no-ops
rather than trapping (recorded in the profile); V, Q, Zfh and Zacas instructions
raise an illegal-instruction exception with `mtval` = the instruction word.
Anything else unimplemented also raises an illegal-instruction exception.

`fence`, `fence.i` and `pause` are accepted as ordering no-ops: the memory model
is strongly ordered with a single hart.

## 4. Exceptions and interrupts

| Cause | Source | `mtval` |
| --- | --- | --- |
| 0 instruction address misaligned | not reachable (IALIGN=16; C is implemented, so 2-byte alignment is legal) | — |
| 1 instruction access fault | fetch response error or PMP deny | faulting address |
| 2 illegal instruction | decoder, or unimplemented CSR | instruction word |
| 3 breakpoint | `ebreak` when `EBREAK_ENTERS_DEBUG=0` | 0 |
| 4 load address misaligned | load | access address |
| 5 load access fault | PMP deny or response error | access address |
| 6 store address misaligned | store | access address |
| 7 store access fault | PMP deny or response error | access address |
| 11 environment call from M-mode | `ecall` | 0 |
| 0x8000…03 / 07 / 0B | software / timer / external interrupt | 0 |

Precise and in-order: `mepc` holds the PC of the faulting instruction, nothing
younger retires, and `mstatus.MPIE←MIE`, `MIE←0`, `MPP←11` on entry. `mret`
restores `MIE←MPIE`, `MPIE←1`.

Interrupts are taken at a retirement boundary: `mepc` is the PC of the next
instruction to execute. Priority is external > timer > software.

## 5. PMP

Eight entries. `A` field: OFF (0), TOR (2), NA4 (1), NAPOT (3). Lowest-numbered
matching entry wins. In M-mode an entry with `L=0` is ignored and one with
`L=1` is enforced; with no matching entry M-mode is allowed. Checks are
whole-access: R for loads, W for stores, X for instruction fetch.

## 6. Memory interface timing

```
Instruction port (single outstanding request)
  req_valid && req_ready  ->  one beat accepted
  rsp_valid && rsp_data   ->  one cycle or more later, 64-bit aligned beat
  rsp_error               ->  instruction access fault at the requested address

Data port (single outstanding request)
  req_valid, req_addr, req_we, req_wdata, req_wstrb, req_ready
  store: completes when req_ready; no response
  load : rsp_valid + rsp_rdata one or more cycles after the request is accepted
  rsp_error on a load     ->  load access fault
```

`req_valid` is held stable until `req_ready`. Addresses are naturally aligned;
misaligned accesses never reach the port — the LSU splits them (Zicclsm) — while
instruction-address misalignment traps in the core. The vector unit has its own
`v_req_*`/`v_rsp_*` port with the same shape.

## 7. Debug and watchpoints

* External halt drains the pipeline, then asserts `dbg_halted`; the register
  file is readable through `dbg_reg_addr`/`dbg_reg_data`.
* Resume clears `dbg_halted`; with `dbg_step` exactly one instruction retires
  before the core re-halts.
* `ebreak` enters debug when `EBREAK_ENTERS_DEBUG=1` (the default) and retires
  as a normal instruction; the core resumes after it.
* The watchpoint comparator reports a hit pulse for matching data addresses.
  **It does not provide a precise debug entry** — the hit is reported, the core
  is not stopped.

## 8. Explicitly out of scope

The H extension (no VS/VU mode, no two-stage translation), full RVV (the core
executes a limited M-mode integer OP-V subset and leaves `misa.V` clear),
Q, Zfh, Zacas, cache coherence, cache inclusion, write-back
caches, prefetch, an out-of-order backend, and the four research blocks (DNA,
neuromorphic, photonic, interconnect). CLINT, UART, DMI, PLIC-lite and the L2
arbiter exist as verified blocks reachable through their CSR windows but are not
memory-mapped behind a peripheral bus. See `docs/ROADMAP.md`.

`isa/rv64_profile.yaml` lists every one of these with the reason it is not
claimed, and the conformance test asserts the recorded behaviour of each.
