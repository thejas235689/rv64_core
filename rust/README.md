# A rustdv testbench for rv64_core

**Status: UNVERIFIED — this crate has never been compiled.**

It was written in an environment that cannot reach a Rust toolchain:
`static.rust-lang.org` and every mirror (rsproxy, ustc) return HTTP 502, and only
GitHub is reachable. `rustup` therefore cannot install `rustc`, so nothing here
has been built or run. Treat it as a design that follows rustdv's API, not as
working code.

## What it does

`riscv_core_top` has no memory of its own: it exposes an instruction port and a
data port with valid/ready handshakes. So the testbench *is* the memory, and
that is what makes this a genuine VPI testbench rather than a wrapper — every
fetch the core performs is served from Rust.

```
  MemoryAgent  --> DUT instruction/data ports   (the testbench is the memory)
  RetireMonitor --> [retire_q] --> Scoreboard --> sim/uvm_vectors/*.retire.hex
```

- `src/item.rs` — `MemBeat`, `RetireItem`, `TrapItem`, mirroring the
  SystemVerilog environment's transaction types
- `src/bfm.rs` — typed handles on every DUT port, the program image, and the
  queues the components share
- `src/components.rs` — the memory agent (one-cycle response, byte-lane writes),
  the retire monitor, and the scoreboard
- `src/env.rs` — the component tree
- `src/rv64_tb.rs` — crate root, `vpi_bootstrap!`, and the test

## The property worth keeping

**There is no second ISA model here.** The scoreboard reads the same golden
vectors the SystemVerilog scoreboard reads, produced by the Python model in
`tb/cocotb/rv64_iss.py`. The two environments therefore cannot disagree about
what "correct" means, and the oracle has exactly one place to be wrong. Do not
add an ISA implementation to this crate.

## Build and run

```sh
# one-time: get a toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# generate the vectors the scoreboard reads
python3 sim/gen_uvm_vectors.py

rust/run_rust_uvm.sh release sim/uvm_vectors/alu
```

The flow is rustdv's own: `cargo build` produces `librv64_tb.so`, it is copied
to `build/rv64_tb.vpi`, Icarus compiles **the DUT only** (`-s riscv_core_top`,
no Verilog testbench), and `vvp -M build -m rv64_tb` loads the VPI module, which
bootstraps the regression from Rust.

## If it does not compile

Two details were taken from `rustdv/tinyalu_tb` but could not be checked against
a compiler, and are the most likely points of friction:

1. **Reading a signal.** The code uses `LogicHandle::get_u64()`, matching the
   `set_u64()` seen in the reference BFM. If the reader is named differently
   (e.g. `get()` returning `u64`), it is a mechanical rename in
   `src/components.rs` — the helper `fn u(&LogicHandle) -> u64` is the single
   place to change.
2. **Creating a child component.** `MemoryAgent::new_comp()` and
   `ConfigDb::set(None, "*", "BFM", Rc::new(bfm))` follow the reference
   testbench's `build` phase. If the constructor is generated differently, only
   `src/env.rs` and `src/rv64_tb.rs` need touching.

Nothing else depends on an API guess: the port names in `src/bfm.rs` were taken
from `riscv_core_top`'s own port list, and the vector format from
`sim/gen_uvm_vectors.py`.
