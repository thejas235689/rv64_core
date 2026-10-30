# Verification matrix: status against the evidence that exists

Source: `RV64_Core_Verification_Matrix.xlsx` (174 items, 26 areas, all marked
"Open"). This document records what the RTL actually has evidence for.

## Three statuses, not two

An area having a test does **not** prove a specific item in it. Marking all 174
items "Covered" because 26 areas each have a test would be exactly the
"it looks plausible" trap this project has fallen into repeatedly. So:

| Status | Meaning |
| --- | --- |
| **Covered** | a named, runnable test exercises **this** scenario |
| **Area-tested** | the area has a test, but this specific scenario is not proven |
| **Open** | no evidence at all |

**Result: 174 items — 0 Covered by individual proof, 174 Area-tested, 0 Open at
area level.** That is deliberately conservative. The honest headline is that every
area has some test, and almost none of the 174 items has been proven individually.

## Where individual items ARE proven

These can be traced to a named test:

| Item | Evidence |
| --- | --- |
| INT-03 shift amounts | `rv64_isa_test` sweeps every shift amount 0..63 |
| RVV-11 vector float | `tb_vunit` covers binary32 `vfadd`/`vfsub`/`vfmul` at SEW=32 |
| NUM-01 quire exactness | `test_numeric_abi` accumulates 2.0x3.0 and reads 6.0 |
| A floating-point add | `test_fp_arith_in_core` asserts 1.0+2.0 = 3.0 through the core |

## Areas with a caveat that changes the status

| Area | Caveat |
| --- | --- |
| **Interrupts** | PLIC-lite is verified standalone but **not instantiated**; `irq_*` are top-level inputs. The core does not contain an interrupt controller. |
| **Boot** | `BOOT_ROM` defaults to 0, so the ROM path is not in the default build. |
| **Observability** | 34 output ports exist; every cocotb test compares retire_pc/insn/rd/wdata. |
| **Cross-cutting** | `test_random` (56k instructions, 5 seeds), `test_backpressure`, `test_isa_sweep_fast`, `test_reset`, lint, Yosys. |

## What is genuinely open

- **Formal**: 6 items in the matrix specify Formal as the method. There is no
  formal property suite in this repository, only lint and elaboration.
- **Mutation**: 1 item. No mutation testing exists.
- **Equivalence**: 6 items. No equivalence checking exists.
- **Scalar F observation**: `fmv.x.d` reads a stale operand, so no FP result can
  be observed from software. F items cannot be signed off while this is true.
- **`fcsr` / `mstatus.FS`**: not implemented, so FP state is not context-switchable.

## Frameworks and what each actually runs

| Framework | State |
| --- | --- |
| UVM (SV, xezim) | 8 core tests PASS; FPU 315/315 |
| pyuvm (cocotb) | FPU 315/315, PASS |
| cocotb | 36+ tests, green individually |
| PSS (Satya) | 7 actions solved with verified values; **not wired to a sequencer** |
| Rust DV | 8 files, **cannot build** — no toolchain in this environment |

The matrix's P1 sign-off gate cannot be met while PSS is unwired and Rust is
unbuildable, because two of the four required frameworks do not drive the DUT.

## How to use this

`docs/matrix_status.csv` carries the per-item mapping. Re-run `map_matrix.py`
against an updated spreadsheet to regenerate it. Any item moved to **Covered** must
name a test in the evidence column — that is the rule this document is enforcing.
