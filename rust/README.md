# A rustdv testbench for rv64_core

**Status: UNVERIFIED — this crate has never been compiled.**

It was written in an environment that cannot reach a Rust toolchain:
`static.rust-lang.org` and every mirror (rsproxy, ustc) return HTTP 502, and only
GitHub is reachable. `rustup` therefore cannot install `rustc`, so nothing here
has been built or run. Treat it as a design that follows rustdv's API, not as
working code.

## What it does

`riscv_core_top` has no memory of its own: it exposes an instruction port and a
data port with valid/ready handshakes. So the testbench *is* the memory, and that
is what makes this a genuine VPI testbench rather than a wrapper — every fetch
the core performs is served from Rust.

```
  MemoryAgent  --> DUT instruction/data ports   (the testbench is the memory)
  RetireMonitor --> [retire_q] --> Scoreboard --> sim/uvm_vectors/*.retire.hex
```

## Numeric families

The numeric ABI and the four research families are covered with **no new
component**: this testbench serves the program image and compares the retirement
trace against the same golden vectors the SystemVerilog scoreboard reads, so
pointing `RUSTDV_VEC_PREFIX` at the numeric prefix exercises them.

```sh
python3 sim/gen_isa_sweep.py            # writes sim/uvm_vectors/numeric.*
rust/run_rust_uvm.sh release sim/uvm_vectors/numeric
```

## The property worth keeping

**There is no second ISA model here.** The scoreboard reads the same golden
vectors the SystemVerilog scoreboard reads, produced by the Python model in
`tb/cocotb/rv64_iss.py` (which models the custom-0 numeric ABI). The two
environments cannot disagree about what "correct" means, and the oracle has
exactly one place to be wrong.

## Build and run

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
python3 sim/gen_uvm_vectors.py
rust/run_rust_uvm.sh release sim/uvm_vectors/alu
```

## If it does not compile

Every API call was reviewed against the rustdv source rather than guessed, and
the fixes that review produced are in place: `get_u64()` returns
`Result<u64, ValueError>`, the program image is a `RefCell` because the agent
holds the BFM as `Rc<CoreBfm>`, `#[component]` is not used on data fields, the
test waits on an `Event` instead of draining the queue the scoreboard owns, and
no `with_timeout` (its argument order is `(fut, dur)`).

Still unchecked: type inference, trait imports and borrow lifetimes. Nothing has
been through `rustc`.
