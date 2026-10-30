# Wiring the FPU into the core

The binary64 adder now passes 315/315 against an independent oracle, and the
register file exists. Neither is reachable from an instruction: the CPU cannot
execute a single floating-point operation. This note records exactly what that
integration requires, measured against the RTL rather than estimated.

## Why it is not a small change

The pipeline is integer-only by construction. Three things encode that:

| Location | Assumption |
| --- | --- |
| `rv64_decoder.sv` | no `OP-FP` (opcode `0x53`) decode exists at all |
| `riscv_core_top.sv:447` | one register file, one write port, `mem_wb_rd` indexes it |
| `rv64_csr.sv` | no `fcsr`, no `mstatus.FS` -- so lazy FP context switching is impossible |

A floating-point instruction needs all three to change together.

## What the rework needs

1. **OP-FP decode.** Opcode `0x53`, with `funct7` selecting the operation
   (`0x01` = `fadd.d`, `0x05` = `fsub.d`) and `rs3` in bits 31:27 for the
   fused forms. The decoder must also stop trapping these as illegal.

2. **A second write port and a second register file.** The FP file is
   architecturally separate -- `f1` and `x1` are different registers -- so the
   writeback stage needs a destination-file select and the hazard logic needs to
   track FP dependencies separately from integer ones.

3. **`mstatus.FS` and `fcsr`.** `fcsr` holds the rounding mode and `fflags`;
   `mstatus.FS` must be Off/Initial/Clean/Dirty so the OS can lazily save FP
   state. Without them the FPU is not context-switchable, which makes it useless
   to a general-purpose OS even though the arithmetic is correct.

4. **FP load/store.** `flw`/`fld`/`fsw`/`fsd` are LSU operations that target the
   FP file, so the LSU's writeback path needs the same file select.

5. **NaN-boxing enforcement.** A binary32 value lives in the low half with the
   upper 32 bits all ones. Any consumer expecting binary32 must check that and
   substitute the canonical NaN otherwise. The register file documents this; the
   decode and execute paths must honour it.

## Order of work

Decode first, then the second write port, then `fcsr`/`FS`, then FP loads and
stores. Each is independently testable:

* decode: an illegal-instruction test must stop trapping `fadd.d`
* write port: `fadd.d f1, f2, f3` then `fmv.x.d x1, f1` shows the value
* `fcsr`/`FS`: a CSR test reads back the rounding mode and sees `FS` change
* loads/stores: `fld` then `fsd` round-trips through memory

## Verification

The adder's two environments (SystemVerilog UVM under xezim, pyuvm under cocotb)
already prove the arithmetic at 315/315 and can be pointed at the integrated
block unchanged. What is needed on top is a core-level test that issues
`fadd.d` from an assembled program and trace-compares against the ISS, which
means the ISS needs an FP model -- the same prerequisite the RVC work needed.

## Status

Not started. The adder and register file are verified standalone and instantiated
nowhere. `misa` correctly does not advertise F or D, so software will not emit
floating-point instructions that would fault.
