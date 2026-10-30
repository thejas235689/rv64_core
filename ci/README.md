# ci/

`verify_pushed.sh` clones the remote branch into a temporary directory and checks
*that* tree, not the working directory.

The distinction is not pedantic. Three separate defects in this project were
invisible locally and present in the published tree:

| Defect | How it survived |
| --- | --- |
| `id_ex_is_fp` declared and read, never latched | the FPU silently used the wrong writeback path |
| FP RAW interlock | described in a commit message, absent from the tree that commit published (`grep` returned 0) |
| tree replacement | a `base_tree` publish replaced 117 files with 15 |

In every case the working tree was correct. The check that catches all three is
to clone what shipped and run against that.

## Use

    ./ci/verify_pushed.sh            # verify main
    ./ci/verify_pushed.sh my-branch

Exits non-zero and leaves the clone in place for inspection on failure.

## What it checks

- the file count is plausible (catches a replaced tree)
- the four files that matter most are present
- `id_ex_is_fp` is actually latched (whitespace-tolerant: an earlier version of
  this check demanded four spaces and the file had three, producing a false FAIL)
- the FP RAW interlock is present
- the integer register file is gated against FP writes
- the design elaborates under slang

It does not yet run the cocotb suite -- that needs Icarus and cocotb on the runner.
That is the next addition, and it is the one that would catch functional
regressions rather than structural ones.
