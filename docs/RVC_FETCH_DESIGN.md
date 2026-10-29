# Wiring RVC into the front end

The RVC expander (`rtl/rv64_rvc_expand.sv`) is verified: 13 checks, 0 mismatches
under both xezim and Icarus, against expected 32-bit forms computed independently
from the ISA. This note records what remains to make `C` executable, measured
against the current RTL rather than estimated.

## Why it is not a small change

`rtl/rv64_fetch.sv:62` reads:

```systemverilog
assign cur_insn = pc_i[2] ? beat_data[63:32] : beat_data[31:0];
```

A 32-bit instruction is selected by `pc[2]`, which is only correct because the core
always advances `pc` by 4. Three places encode that assumption:

| Location | Assumption |
| --- | --- |
| `riscv_core_top.sv:773` | `WB_PC4` returns `id_ex_pc + 4` (the `auipc`/`jal` link value) |
| `riscv_core_top.sv:962` | a not-taken branch redirects to `id_ex_pc + 4` |
| `riscv_core_top.sv:940` | `wfi` resumes at `wfi_pc_q + 4` |

With RVC, `pc` is only 2-byte aligned, so all three become `pc + insn_len`.

## The straddle case is real, not hypothetical

Once `pc` can be 2 mod 4, a 32-bit instruction can start at beat offset 2 or 6. At
offset 6 its upper 16 bits live in the *next* 64-bit beat, so the current
single-beat window cannot see it. This is reachable from ordinary compiled code:
a compressed instruction followed by a 32-bit one at offset 4 puts the 32-bit one
at offset 6.

## What the rework needs

1. **Halfword selection.** Replace the `pc[2]` mux with a halfword mux on `pc[2:1]`,
   and a 32-bit window aligned to `pc[1:0]` within the beat.
2. **A held beat.** Keep the previous beat so a straddling instruction can be
   assembled from two. `rv64_fetch` already holds `prev_insn_q`, so the register
   exists; it needs the full beat rather than the decoded word.
3. **`insn_len`.** The fetch must report 2 or 4, and the three `+4` sites above must
   use it.
4. **`misa`.** Set bit 2 only once 1-3 are verified. Claiming `C` before then would
   make software emit compressed binaries that fault.

## Verification plan

- Extend `tb_fetch_cache` with compressed sequences at every `pc[2:0]` offset,
  including a 32-bit instruction at offset 6.
- A directed test that runs a mixed compressed/uncompressed program through the core
  and trace-compares against the ISS, which would need RVC decoding added to
  `rv64_iss.py` first.
- Only then set the `misa` C bit.

## Status

Not started. The expander is verified and instantiated nowhere; the README and
`docs/VERIFICATION_REPORT.md` both say so. `C` is not claimed in `misa`.
