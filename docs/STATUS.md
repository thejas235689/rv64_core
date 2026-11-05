# rv64_core — status

## Phase 1: architectural specification and ISA selection — COMPLETE

The ISA profile is now pinned in **`isa/rv64_profile.yaml`**, a single machine-readable
file, and **`tb/cocotb/test_isa_conformance.py`** enforces it in 17 tests that all pass:

    TESTS=17 PASS=17 FAIL=0

The gate checks that `misa` on the DUT, `misa` in the ISS, the custom CSR windows in
`riscv_core_top.sv`, the bus signal names, and the values written in `README.md` and
`docs/ARCHITECTURE_FEATURE_CONTRACT.md` all agree with the profile — and it **executes at
least one instruction from every advertised extension**, asserting none traps.

That last check is the one that matters. It is what would have caught the F/D defect on
the day F was set: `misa` claimed F while `fadd.s` trapped as illegal. Nothing compared
the claim to the behaviour, so the claim drifted for months.

### The F/D decision, made and executed

The core now implements **both** single and double precision, so it can honestly claim
both. `misa` = `0x800000000014112D` = **A C D F I M S U**, MXL=2.

Single precision was added by extending the existing blocks rather than writing a
parallel FPU — `rv64_fp_round.sv` takes a format argument and the rounding decision still
exists in exactly one place. Block-level verification: **106,192 vectors, 0 mismatches**
across both formats.

Five real RTL bugs were found by that sweep: subnormal alignment taken in the wrong
binade scale; the NaN quiet-bit indexed at bit 51 in single precision; the comparator's
magnitude mask excluding the exponent; single-precision overflow sign forced to bit 63;
and single-precision `fsqrt` needing one bit of headroom because forcing the exponent
even makes the root span two binades.

### Deviations recorded rather than hidden

- **H instructions do not trap.** `hret`, `hfence.*`, `hinval.*`, `hlv.*`, `hsv.*` retire
  as no-ops or ordinary accesses. H is not claimed in `misa`, and the profile records
  `expect: retires_as_noop` with the evidence rather than pretending otherwise.
- **`ecall` always reports cause 11.** `riscv_core_top.sv` assigns `CAUSE_ECALL_M`
  unconditionally; `CAUSE_ECALL_S`/`_U` are declared and unused. An ecall in S-mode gives
  11, not 9. Recorded in `privilege.deviations` and pinned by a test.
- **`ci/check_csr_map.py` sees 8 windows, not 9** — its regex only matches the
  `"<base> + 12'dN"` form, so the numeric window is invisible to it. The conformance test
  parses both forms.

## Verification

| Suite | Result |
| --- | --- |
| ISA conformance | **17 / 17** |
| FPU blocks (both formats) | 106,192 vectors, 0 mismatches |
| cocotb + pyuvm | 123 / 123 |
| UVM (xezim) | 17/23 confirmed; six fixed, seven not re-run |
| Rust DV | runs: 44/44 retirements, 0 mismatches on `alu` |

## Not done

- 7 UVM tests not re-run after the ISS changes.
- RSA-4096 key handling, SoC interconnect, security chain of trust, formal, FPGA,
  timing closure, DFT.
