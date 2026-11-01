# Verification status

Everything below was run against the published tree; nothing here is inferred.

## Test results

| Framework | Result | Command |
| --- | --- | --- |
| cocotb | **39 / 39 pass** | `sim/run.py --testcase <t>` |
| UVM (xezim) | **22 / 22 pass** | `sim/run_uvm.sh` |
| Montgomery sweep | **6 / 6 widths** | `ci/sweep_montmul.sh` |
| Modexp sweep | **4 / 4 widths** | `ci/sweep_modexp.sh` |
| CSR map | **0 overlaps** | `ci/check_csr_map.py` |
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
clint  uart  montmul  modexp  xcetask
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

**Not reachable from software yet** — the engine has top-level ports but no CSR
window, so a program cannot start an exponentiation.

## Still orphaned

| Module | Needs |
| --- | --- |
| `rv64_clic` | `cause_id`/`cause_valid` wired into the trap logic |
| `rv64_l2arb` | a real peripheral bus |
| `rv64_dmi` | a JTAG transport |
| `rv64_num_wide` | nothing — it is a number-system library, not a peripheral |

## Known gaps

- **`misa` advertises F** but `fdiv`, `fsqrt`, `fmul`, `fcvt`, `fcmp` and the Zfhmin
  family are absent. A toolchain will emit them and they will trap.
- **`misa` advertises H** but there is no VS mode and no two-stage translation. Only
  the CSRs and the `HRET`/`HFENCE`/`HINVAL` decode exist.
- **Rust DV** — `rust/` has 5 source files that have never been compiled.

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
