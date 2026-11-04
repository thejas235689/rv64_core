# rv64_core — verification status

Measured in this tree. Nothing claimed that was not run.

| Suite | Result |
| --- | --- |
| cocotb + pyuvm | **123 / 123** |
| UVM (xezim) | **17/23 confirmed green; 6 fixed, 7 not re-run** |
| Scalar FPU unit | 36,042 vectors, 0 mismatches |
| Cache / L2 | 19 tests + 10 Verilog checks, 0 failures |
| Rust DV | **RUNS: 44/44 retirements, 0 mismatches** |

## The six UVM failures — every one was an ISS bug

No RTL was changed for any of them. The golden model was wrong in all six cases.

| Test | Root cause |
| --- | --- |
| `rv64_csr_test` | `fcsr`/`fflags`/`frm` are one register, three views. The ISS kept three independent dict entries. |
| `rv64_xcetask_test` | Custom CSR windows absent from the whitelist; **and** accelerator windows are command ports, not RMW CSRs — the top passes raw `csr_wdata`, not `csr_wval`. |
| `rv64_accel_test` | Same two causes; plus XRV512 CTRL is combinational so `busy` is a one-cycle pulse. |
| `rv64_debug_test` | `EBREAK_ENTERS_DEBUG` defaults to 1, so `ebreak` retires and halts in Debug Mode rather than raising cause 3. Confirmed against the feature contract and the cocotb `test_ebreak_debug`. |
| `rv64_sv39_test` | **The premise was wrong.** `0x12000073` is not a CSR access — funct3=0 means bits 31:20 are funct7, and funct7 `0001001` is **sfence.vma**. The ISS misdecoded it as `csrrw 0x120`. |
| `rv64_illegal_test` | `mepc` masking: the ISS did `& ~3`, the DUT stores `trap_pc` unmasked. Illegal encodings include **compressed** ones, so mepc bit 1 differed by 2 and the handler's `mepc+4` returned 2 bytes early. Fixed to `& ~1`. A second ISS bug surfaced behind it: Zabha byte/halfword AMOs are implemented in the decoder but the ISS rejected them. |

## Rust DV — it runs

```
0.00ns INFO  rustdv: found 1 test(s)
2910.00ns INFO  [BaseTest]: sim/uvm_vectors/alu: 44 retirements observed
2910.00ns INFO  scoreboard: 44/44 retirements compared, 0 mismatch(es)
2910.00ns INFO  BaseTest PASSED
REGRESSION: PASS
```

The toolchain was obtainable all along: `static.rust-lang.org` is not allowlisted but
**conda-forge is**. `rust-1.99.1` plus the separate noarch `rust-std` package, with
`pip install ziglang` providing the linker (there is no gcc in this image). Scripted as
`rust/bootstrap_toolchain.sh` and `rust/bootstrap_icarus.sh`.

**Nine defects** had to be fixed, each fatal on its own. The hang was not the scoreboard:
~25 DUT inputs (`if_rsp_error`, `d_rsp_error`, `v_*`, `irq_*`, `sha_*`, `plic_*`, `dbg_*`)
were **never driven and sat at X**. In `rv64_fetch.sv` the accept arm is `else if
(!rsp_error)`, and `!x` is x, so every fetched beat was silently dropped — the icache
cycled IDLE→FILL→DONE forever and nothing retired.

**The pass is real**, not vacuous: corrupting one golden value produces
`x12 DUT=0x0 expected 0xdeadbeefdeadbeef` → `REGRESSION: FAIL`.

15 of 21 vector programs pass with full windows compared. Six fail on testbench gaps
(vector/accelerator/debug ports tied off), except `csr`, which disagrees on one CSR value
and needs its own look.

## Not done

- 7 UVM tests not re-run after the ISS changes (zifencei, memwidth, cache, frontend, rvv,
  amcce, alu_matrix). They passed at baseline, but the ISS is their golden model too.
- H extension: no VS mode, no two-stage translation. `misa` correctly does not claim it.
- RSA-4096: key handling, constant-time design, integration.
- SoC interconnect, security/boot chain, formal, FPGA, timing, DFT.
