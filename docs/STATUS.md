# Verification status

Everything below was run against the published tree; nothing here is inferred.

## Test results

| Framework | Result | Command |
| --- | --- | --- |
| cocotb | **43 / 43 pass** | `sim/run.py --testcase <t>` |
| UVM (xezim) | **22 / 22 pass** | `sim/run_uvm.sh` |
| Montgomery sweep | **6 / 6 widths** | `ci/sweep_montmul.sh` |
| Modexp sweep | **4 / 4 widths** | `ci/sweep_modexp.sh` |
| CSR map | **0 overlaps** | `ci/check_csr_map.py` |
| CLIC in core | **pass** | `test_clic_in_core` |
| Fetch/store interleave | **pass** | `tb_two_store` -- added for the fetch bug below |
| CLIC (standalone) | **10 / 10 checks** | `tb/tb_clic.sv` |

### Running the tests

```bash
export PATH=/scratch/work/ocs/oss-cad-suite/bin:$PATH
/usr/local/bin/python3 sim/run.py --testcase test_alu
```

Use the **absolute** system python. With the OSS CAD Suite on `PATH`, bare `python3`
resolves to their bundled interpreter and cocotb dies with
`Unexpected sys.executable value`.

## Instantiated in `riscv_core_top`

27 blocks, including everything added recently:

```
alu  mdu  regfile  decoder  csr  pmp  fetch  bpu  icache  dcache  l2cache
lsu  amcce  bootrom  bootauth_hmac  sha256  hmac  plic_lite
fp_add  fregfile
vunit  numfile  num_unit  num_csr  xrv512  aiacc  qisa
clint  uart  clic  montmul  modexp  xcetask
```

## CSR map

```
0x780-0x78F  RVV
0x7C0-0x7C2  numeric
0x7D0-0x7D8  Xcetask
0x7D9-0x7DF  CLINT      mtime lo/hi, mtimecmp lo/hi, msip, status, timer_en
0x7E0-0x7E6  QISA
0x7E8-0x7ED  AIACC
0x7F0-0x7F7  XRV512
0x7FC-0x7FF  UART       tx, rx
0x800-0x807  modexp     control, n0inv, e_bits, ld_sel, ld_addr, ld_wdata, r_addr, status
```

`ci/check_csr_map.py` fails on any overlap. Run it before adding a window.

## RSA

`rv64_montmul` — CIOS Montgomery multiplier, verified at W = 1, 2, 3, 4, 8, 16 against
`a*b*R^-1 mod N` with the final conditional subtract performed in hardware.

`rv64_modexp` — square-and-multiply over the multiplier, verified at W = 1, 2, 3, 4
against Python's `pow()`. The engine owns the multiplier: it holds the operand
memories and drives a/b/n one word per cycle.

**Not constant-time.** The branch on the exponent bit leaks timing. That matters for
real RSA and is stated in the RTL header rather than left to be discovered.

**Reachable from software.** CSR window at 0x800-0x807: software loads an operand by
writing ld_sel/ld_addr/ld_wdata, then writes 0x800 with bit0 set to strobe it in, and
reads busy/done from 0x807. Verified by `test_modexp_csr`, which round-trips a 64-bit
value through 0x801.

Note: the CSR address is 12 bits, so 0x800-0xFFF was always free. Custom blocks had
been confined to 0x7C0-0x7FF unnecessarily, which is why three collisions happened
inside a 64-address range that did not need to be a constraint.

## Still orphaned

| Module | Needs |
| --- | --- |
| `rv64_l2arb` | a real peripheral bus — infrastructure that does not exist |
| `rv64_dmi` | a JTAG transport — infrastructure that does not exist |
| `rv64_num_wide` | nothing — it is a number-system library, not a peripheral |

CLINT, UART and CLIC are wired. Those three only needed *integration*: their interfaces
already existed. The two remaining hardware orphans need *new infrastructure*.

The CLIC has no CSR window (the map has no free block), so it is driven through
top-level ports the way `plic_src` is, and its `cause_id`/`cause_valid` are exposed so
a handler reads the vector without a claim round-trip.

## Known gaps

- **`misa` advertises F** but `fdiv`, `fsqrt`, `fmul`, `fcvt`, `fcmp` and the Zfhmin
  family are absent. A toolchain will emit them and they will trap.
- **`misa` advertises H** but there is no VS mode and no two-stage translation. Only
  the CSRs and the `HRET`/`HFENCE`/`HINVAL` decode exist.
- **Rust DV** — `rust/` has 5 source files that have never been compiled.

## Recent core fixes

Three real defects in the fetch path, all found by instrumented dumps rather than by
reasoning, and all invisible to the pre-existing suite:

1. **`icache.invalidate` was never connected.** The FSM's `else if (invalidate)` branch
   sat between the reset and the case statement; with the port floating it had no defined
   value and the cache could sit in `C_IDLE` forever. Now tied low (a fence.i-driven path
   is separate work).

2. **`insn_len` was computed from a stale `insn_raw`.** When no valid beat was present the
   old word was still used, `is_rvc` came out true, and the PC advanced by 2 instead of 4.

3. **The fetch response was matched against a moving address.** `out_addr` is latched at
   issue, but the response compared it against `aligned`, which is combinational from
   `pc_i` and moves on. Responses were filed as the second beat and `beat_data` kept stale
   data. Fixed by latching `out_align` at issue.

Bug 3 is the important one: it corrupted the instruction stream for any program with a
store followed by more instructions. It survived 43 cocotb and 22 UVM tests because none
of them had that shape. `tb_two_store` now does.

## How the bugs were found

Every defect fixed in the recent work was found by dumping a signal or reading a
traceback. Every wasted turn was a theory formed before looking. The tools that make
this mechanical rather than a memory exercise:

- `ci/sweep_montmul.sh`, `ci/sweep_modexp.sh` — a single passing width is not
  verification; both blocks passed at one width while failing at others
- `ci/check_csr_map.py` — a per-block test cannot see a CSR collision; three were made
  in one session
- the cocotb harness `_i()` helper reports X samples with the signal name instead of
  dying inside trace collection
