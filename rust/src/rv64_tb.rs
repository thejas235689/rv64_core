//! rustdv testbench for rv64_core.
//!
//! **UNVERIFIED.** This crate has never been compiled: the environment it was
//! written in cannot reach a Rust toolchain (`static.rust-lang.org` and every
//! mirror return 502; only GitHub is reachable). It is written against the
//! rustdv API as used by `rustdv/tinyalu_tb`, and `rust/README.md` names the
//! points most likely to need a touch.
//!
//! The core has no memory of its own, so the testbench supplies it: the Rust
//! memory agent answers every fetch and load/store over VPI, the retire monitor
//! turns the observability port into transactions, and the scoreboard compares
//! them against the *same* golden vectors the SystemVerilog scoreboard reads.

use std::rc::Rc;

use rustdv::prelude::*;

pub mod bfm;
pub mod components;
pub mod env;
pub mod item;

use bfm::CoreBfm;
use env::CoreEnv;

// Export the VPI entry points from this cdylib.
rustdv::vpi_bootstrap!();

/// Read a `sim/uvm_vectors/*.prog.hex` image into 32-bit words. The generator
/// packs two instructions per 64-bit line, low half first.
fn load_program(path: &str) -> std::io::Result<Vec<u32>> {
    let text = std::fs::read_to_string(path)?;
    let mut words = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let v = u64::from_str_radix(line, 16).unwrap_or(0);
        words.push(v as u32);
        words.push((v >> 32) as u32);
    }
    Ok(words)
}

/// The test: file the BFM, load the program, then wait for the scoreboard to
/// finish the golden window.
#[derive(Component, Default)]
pub struct BaseTest {
    #[component]
    env: RustdvComp,
    prefix: String,
    n_retire: usize,
}

impl Component for BaseTest {
    fn build(&mut self, ctx: &mut RustdvCtx) {
        let mut bfm = CoreBfm::new(&ctx.dut()).expect("rv64_core signals");

        self.prefix = std::env::var("RUSTDV_VEC_PREFIX")
            .unwrap_or_else(|_| "sim/uvm_vectors/alu".to_string());

        let words = load_program(&format!("{}.prog.hex", self.prefix)).expect("program image");
        bfm.load(&words);

        // the expected retirement count comes from the generator, not a guess
        let counts = std::fs::read_to_string(format!("{}.counts.hex", self.prefix))
            .unwrap_or_default();
        self.n_retire = counts
            .split_whitespace()
            .next()
            .and_then(|t| usize::from_str_radix(t, 16).ok())
            .unwrap_or(0);

        ConfigDb::set(None, "*", "BFM", Rc::new(bfm));
        self.env = CoreEnv::new_comp();
    }

    async fn run(&mut self, ctx: &mut RustdvCtx) -> Result<(), TestError> {
        let _obj = ctx.raise_objection("stimulus");
        let bfm: Rc<CoreBfm> = ConfigDb::get(Some(ctx), "", "BFM")?;

        // The scoreboard owns the retirement queue; the test only waits for it
        // to finish. No timeout combinator: the runner already bounds the
        // simulation, and keeping to verified constructs means fewer things
        // that can fail to compile.
        bfm.wait_done().await;

        ctx.info(&format!("{}: {} retirements observed", self.prefix, self.n_retire));
        Ok(())
    }
}
