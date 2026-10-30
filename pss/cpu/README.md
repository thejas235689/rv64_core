# Portable stimulus testbench for the RV64 CPU

`rv64_cpu_pss.pss` is the portable layer: it describes *what* must be exercised
(7 actions covering ALU, word ops, branches, RAW chains, traps, CSR access and
memory) and the invariants, and the solver produces the concrete stimulus. The
same model feeds every backend, so the UVM, cocotb and C benches all consume one
definition of intent instead of three hand-written lists.

`uvm_seq/*.sv` are the generated UVM sequence classes, one per action.

## Verified

Satya v0.41.0: 7 actions parse, solve with 0 warnings, and the solved values were
checked -- not just the constraint counts. Across three seeds per action every
boolean field is 0 or 1 and every bounded field is inside its declared range, and
the relational constraint `taken == 0 || offset > 0` holds (seed 3: taken=1,
offset=498).

## Two Satya traps, measured not assumed

1. **Named constraint blocks are ignored.** `constraint c { x == 236; }` parses,
   reports "constraints: 1/1 satisfied", and returns a value that violates it.
   Constraints must be UNNAMED: `constraint x == 236;`.
2. **`rand bit` is not a 1-bit domain.** It produced 520 and 385 where only 0 or 1
   is valid, while still reporting satisfied. Boolean fields must be declared
   `rand int in [0..1]`.

Both failure modes produce a green log over meaningless stimulus, which is worse
than an error. Reading the solved values from the JSON backend is the only check
that catches either.

## Not done

The generated sequences extend `uvm_sequence #(uvm_sequence_item)`; they need
adapting to the CPU bench's transaction type and sequencer before they can drive
it. The model expresses intent correctly and the stimulus is solvable and
in-range, but it has not yet been run against the core.
