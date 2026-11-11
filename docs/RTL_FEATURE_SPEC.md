# RV64 RTL feature specification

## Baseline and compatibility

The core is a single-hart RV64 processor with an in-order IF, ID, EX, MEM and WB
pipeline. The [ISA profile](../isa/rv64_profile.yaml) governs advertised
instructions. A feature is implemented when its RTL is wired into the documented
entry point. A standalone test establishes behavior at the module interface.
A CPU test establishes behavior for the configuration and instruction sequence
it exercises.

The default build uses the existing scalar pipeline and blocking cache path.
New optional modes must preserve the default configuration. Updates to shared
state must respect reset, redirects, retirement, exceptions and backpressure.

## Requirements

| ID | Area | Implemented scope and acceptance criteria |
| --- | --- | --- |
| RTL-01 | Vector execution | M-mode native integer add, subtract, AND, OR and XOR support SEW 8/16/32/64 and LMUL 1/2/4/8. Require aligned groups, preserve masked and tail elements, and hold younger issue until group writeback completes. Exercise m2 and m8, a mask bit above the first register, and illegal alignment. Native vector memory, fractional LMUL, and vector context management remain open. Keep `misa.V` clear. |
| RTL-02 | Posit quire | Accumulate exact posit8 products in signed Q40.24. `NUM_PQGET` format 0 returns raw bits and format 3 rounds to nearest even. Test midpoint ties, negative results, saturation and inexact flags. Posit16 uses a separate signed Q72.56 accumulator with format 1 for clear, accumulate and low-word read, and format 4 for high-word read. Rounded posit16 and posit32 accumulation remain open. |
| RTL-03 | Signed LNS | Formats 3 and 4 carry a sign in bit 32 or bit 16 above the Q16.16 or Q8.8 log magnitude. Add, subtract, multiply and divide use the existing custom opcodes. Canonicalize zero and preserve legacy formats. Directed checks cover both signs, exact cancellation and both formats. Add/subtract still uses an approximate log correction. |
| RTL-04 | Instruction prefetch | The stride engine learns equal strides, restricts a candidate to the current 4 KiB page and a configured idempotent range, and uses a separate one-beat buffer. A denied or invalidated speculative request must not return demand data or install a cache line. The core enables prefetch only with `ENABLE_STRIDE_PREFETCH`, a nonempty physical RAM range, M-mode, and no active PMP entries. A configured range must exclude boot ROM when present. Verify PMP denial and authorization changes before and after request acceptance. |
| RTL-05 | Branch prediction | A 32-entry indirect-target table uses the non-return JALR PC and resolved branch history. Require two matching observations before overriding the BTB target. Verify distinct histories, halfword PC tags and fallback after a target changes. TAGE and multipath prediction remain open. |
| RTL-06 | Frontend decode | The eight-entry compressed expansion cache is keyed by the current raw 16-bit encoding. A hit reuses expansion only after normal fetch and translation. Verify a cold expansion, a repeated encoding, a tag collision and redirect reuse. A general trace or µop cache, execution fusion and multi-stream fetch remain open. |
| RTL-07 | Unum arithmetic | Custom opcode 31 uses format 0 for add and 1 for subtract. The bounded Type-I encoding accepts exact finite inputs with 1–4 exponent and fraction bits. Results use 4-bit exponent and fraction fields with an interval marker for inexact values. Check reserved encodings, cancellation, overflow and interval endpoints. Interval operands and multiply/divide remain open. |
| RTL-08 | Non-blocking and coherent caches | The optional I-cache interface accepts tagged hits during one outstanding demand refill. Verify response identity, refill error, second-miss rejection and invalidation. Core integration, multiple misses, dirty writeback and a coherence protocol remain open. |
| RTL-09 | Advanced pipeline | The optional `ENABLE_FETCH_STAGE` register queues one instruction and its PC and prediction metadata ahead of ID. Redirects and debug resume clear the queue, and the core drains older queued work before a fetch fault. Run the same architectural tests in both configurations. A complete seven-stage design, superscalar issue and out-of-order execution remain open. |

The existing Sv39/Sv48 fetch path has CPU tests for non-identity supervisor
mappings and instruction page faults. Broader privileged-architecture coverage
remains open.

## Verification

Run the verification matrix from the repository root with Verilator on PATH.

```sh
python -m pip install 'cocotb>=2.1,<3' PyYAML
bash sim/verify_rtl.sh
# Requires Icarus Verilog and vvp on PATH
bash sim/verify_rtl_units.sh
```

The matrix covers the default core, the optional fetch stage, ISA conformance, and stride authorization with and without the extra fetch stage. Review the cocotb summary for failures and skips. Satya PSS cases require the
Satya solver. Record the commit, simulator version and enabled parameters with
the result. Run the standalone benches for interfaces that the default core
configuration does not exercise.

See the [test plan](TESTPLAN.md#research-rtl-verification-matrix) for the mapping from requirements to test cases.
