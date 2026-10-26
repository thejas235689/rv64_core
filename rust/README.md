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

## What was checked against the rustdv source

Every API call was reviewed against the rustdv tree (`rustdv/rustdv/`) rather
than guessed, and five real errors were found and fixed this way:

| Was | Is | Why |
| --- | --- | --- |
| `h.get_u64()` | `h.get_u64().unwrap_or(0)` | it returns `Result<u64, ValueError>` |
| `bfm.mem.get_mut(..)` through `Rc` | `RefCell<Vec<u32>>` + `borrow_mut()` | cannot mutate through `Rc` |
| `#[component] exp: Vec<u64>` | plain field | `#[component]` is for child components, not data |
| test and scoreboard both drained `retire_q` | scoreboard owns it; test waits on an `Event` | two consumers on one queue steal items |
| `with_timeout(dur, fut)` | plain `await` | the real order is `(fut, dur)`, so the combinator was removed rather than half-fixed |

Confirmed against the source: `HierarchyHandle::signal(&str) -> Result<LogicHandle, HandleError>`,
`LogicHandle::{get_u64, set_u64, is_high}`, `rising_edge()/falling_edge() -> Edge`
(awaitable), `Queue::{unbounded, put, get, try_get}`, `Event::{new, set, wait}`,
`ConfigDb::{set, get}`, `Component::{build, connect, run, extract, check, report, new_comp}`
with `fn build(&mut self, ctx: &mut RustdvCtx)` and
`async fn run(&mut self, ctx: &mut RustdvCtx) -> Result<(), TestError>`.

## What is still unverified

The crate has not been through `rustc`, so type inference, trait imports and
borrow lifetimes are unchecked. If it does not build, the errors will be of that
kind rather than "this method does not exist" — the method surface was read from
the source.
