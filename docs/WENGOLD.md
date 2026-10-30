# WENGOLD integration

WENGOLD (https://github.com/thejas235689/wengold) is a validity kernel: it keeps a
dependency graph of a design and answers *which of my previous verification results
still hold* after a change. It is dual-licensed MIT/Apache-2.0, the same terms as
this core.

## Why it belongs here

Every expensive mistake in this project was a validity question answered wrongly:

| Incident | What WENGOLD would have shown |
| --- | --- |
| `id_ex_is_fp` declared, read, never latched | the writeback mux depends on a signal with no driver |
| FP RAW interlock described in a commit, absent from the published tree | the interlock block is not in the graph at all |
| a stale clone verified instead of the pushed ref | the results were tied to a different revision |

None of those were hard bugs. They were *stale or missing evidence*, which is the
exact problem a dependency graph solves.

## Running it

    ./ci/wengold.sh index          # build the graph
    ./ci/wengold.sh completeness   # files vs blocks
    ./ci/wengold.sh cdc            # clock-domain crossings
    ./ci/wengold.sh classify       # what a change invalidates

`pip install pyslang` first — without it WENGOLD falls back to a bounded regex
elaborator that finds far fewer modules and says so, which is why the block count
below is an under-estimate.

## Results on this core

`wengold index rtl --backend regex`

    files: 41, contributing: 36, file_coverage: 0.878

Two issues reported, both real and both correctly attributed:

- the regex fallback under-counts blocks (honest, not a defect)
- `int` "instantiated as posit_width in rv64_num_wide but not defined" — a false
  positive: `int` is a SystemVerilog type, not a module. WENGOLD flags it because
  the regex elaborator cannot tell types from instantiations. With pyslang this
  disappears.

`wengold cdc rtl/riscv_core_top.sv`

**The core is single-clock-domain.** Every sequential element sits under `clk`;
everything WENGOLD could not resolve to a domain is combinational
(`dec_ctrl`, `lsb_busy`, `is_load`, `rst_n` and similar). There are **no CDC paths
to review**, which is a genuinely useful negative result — it rules out an entire
class of metastability bug that a 9,000-line core could easily have.

## What is not yet done

`wengold classify` — the command that actually answers "what does this change
invalidate" — has not been run against a real change set, because that needs a
baseline of recorded runs and this project has no ledger yet. That is the step that
would pay off most: it turns every future commit into a scoped question rather than
a full regression.

The ledger needs one thing from the project: every test run recorded with its
inputs (the RTL tree hash) and its verdict. `ci/run_full_suite.sh` is the natural
place to emit that.
