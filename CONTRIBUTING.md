# Contributing

## Ground rules

1. **Nothing ships unverified.** A change to `rtl/` needs a self-checking test
   that fails without it. A test that cannot fail is not a test.
2. **The RTL is synthesizable SystemVerilog.** No simulation-only constructs, no
   delays, no `initial` blocks in `rtl/`. One module per file, explicit reset,
   parameterised where it matters.
3. **Do not "fix" the RTL for a tool.** Yosys 0.70 cannot parse a function
   returning a packed struct; the flow runs sv2v first. Icarus rejects `break`
   inside `always_comb` loops and functions with `output` ports; write around it
   in the RTL rather than pinning a tool version, and note the constraint in a
   comment.
4. **Keep one golden model.** The UVM scoreboard compares against vectors
   generated from the Python ISA model in `tb/cocotb/rv64_iss.py`. Do not add a
   second implementation of the ISA to the scoreboard.

## Before you send a change

```sh
python3 sim/run.py && python3 sim/run.py --suite pmp && python3 sim/run.py --suite plic
./sim/synth.sh
```

All three must pass. If your change touches the pipeline, also run
`bash sim/run_uvm.sh` — it is slow, but it exercises the design under
backpressure and constrained-random stimulus that the fast harness does not.

## When a test fails

Assume the testbench first. Two of the defects found in this project were stale
*expectations* rather than broken RTL: an opcode still listed as illegal after
it was implemented, and a handler that wrote `mepc` before incrementing it. Check
what the test believes before you change the design.

## Commits

Explain what was wrong, not just what changed. If a test caught a defect, say
which test and what it saw. The commit log is the defect history of this project
and it is worth keeping readable.
