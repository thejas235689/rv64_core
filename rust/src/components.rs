//! Components: the memory agent, the retire monitor and the scoreboard.

use std::rc::Rc;

use rustdv::prelude::*;

use crate::bfm::CoreBfm;
use crate::item::{MemBeat, RetireItem, TrapItem};

/// `LogicHandle::get_u64` returns `Result<u64, ValueError>`; a read of a signal
/// that exists cannot fail, so an unreadable value reads as 0.
fn u(h: &LogicHandle) -> u64 {
    h.get_u64().unwrap_or(0)
}

/// Single-bit reads: `is_high()` is the idiomatic accessor and needs no Result.
fn b(h: &LogicHandle) -> bool {
    h.is_high()
}

// ===========================================================================
// Memory agent: the testbench *is* the core's memory
// ===========================================================================

/// Serves both ports with a one-cycle response, which is what the core's
/// handshake specifies. Reads come from the program image; writes update it
/// with byte lanes.
#[derive(Component, Default)]
pub struct MemoryAgent;

impl Component for MemoryAgent {
    async fn run(&mut self, ctx: &mut RustdvCtx) -> Result<(), TestError> {
        let bfm: Rc<CoreBfm> = ConfigDb::get(Some(ctx), "", "BFM")?;
        bfm.tie_off_idle_inputs();
        bfm.reset().await;

        bfm.if_req_ready.set_u64(1);
        bfm.d_req_ready.set_u64(1);
        bfm.if_rsp_valid.set_u64(0);
        bfm.d_rsp_valid.set_u64(0);

        let mut if_pend = false;
        let mut if_addr: u64 = 0;
        let mut d_pend = false;
        let mut d_addr: u64 = 0;

        loop {
            bfm.clk.rising_edge().await;

            if if_pend {
                bfm.if_rsp_data.set_u64(bfm.read_beat(if_addr));
                bfm.if_rsp_valid.set_u64(1);
            } else {
                bfm.if_rsp_valid.set_u64(0);
            }

            if d_pend {
                bfm.d_rsp_rdata.set_u64(bfm.read_beat(d_addr));
                bfm.d_rsp_valid.set_u64(1);
            } else {
                bfm.d_rsp_valid.set_u64(0);
            }

            if_pend = b(&bfm.if_req_valid);
            if if_pend {
                if_addr = u(&bfm.if_req_addr);
            }

            d_pend = b(&bfm.d_req_valid);
            if d_pend {
                d_addr = u(&bfm.d_req_addr);
                if b(&bfm.d_req_we) {
                    let wstrb = u(&bfm.d_req_wstrb) as u8;
                    let wdata = u(&bfm.d_req_wdata);
                    bfm.write_beat(d_addr, wdata, wstrb);
                    bfm.served
                        .put(MemBeat { addr: d_addr, we: true, wdata: u(&bfm.d_req_wdata), wstrb })
                        .await;
                }
            }
        }
    }
}

// ===========================================================================
// Monitor
// ===========================================================================

/// Turns the core's observability port into transactions.
#[derive(Component, Default)]
pub struct RetireMonitor;

impl Component for RetireMonitor {
    async fn run(&mut self, ctx: &mut RustdvCtx) -> Result<(), TestError> {
        let bfm: Rc<CoreBfm> = ConfigDb::get(Some(ctx), "", "BFM")?;
        loop {
            bfm.clk.rising_edge().await;
            if b(&bfm.retire_valid) {
                bfm.retire_q
                    .put(RetireItem {
                        pc: u(&bfm.retire_pc),
                        insn: u(&bfm.retire_insn) as u32,
                        gpr_we: b(&bfm.gpr_we),
                        gpr_waddr: u(&bfm.gpr_waddr) as u8,
                        gpr_wdata: u(&bfm.gpr_wdata),
                    })
                    .await;
            }
            if b(&bfm.trap_valid) {
                bfm.trap_q
                    .put(TrapItem { pc: u(&bfm.trap_pc), cause: u(&bfm.trap_cause) })
                    .await;
            }
        }
    }
}

// ===========================================================================
// Scoreboard
// ===========================================================================

/// Compares the retirement stream against the golden vectors from the Python
/// ISA model.
///
/// **There is no second ISA model here**, deliberately. The SystemVerilog
/// scoreboard and this one read the same files, so the two environments cannot
/// disagree about what "correct" means. The numeric families are covered by
/// pointing `RUSTDV_VEC_PREFIX` at `sim/uvm_vectors/numeric`.
#[derive(Component, Default)]
pub struct Scoreboard {
    // data, not a child component: no #[component] attribute here
    exp: Vec<u64>,
    n_compared: usize,
    errors: usize,
    n_exp: usize,
}

impl Scoreboard {
    pub fn load_vectors(&mut self, prefix: &str) -> std::io::Result<()> {
        let text = std::fs::read_to_string(format!("{prefix}.retire.hex"))?;
        self.exp = text
            .split_whitespace()
            .filter_map(|t| u64::from_str_radix(t, 16).ok())
            .collect();
        Ok(())
    }
}

impl Component for Scoreboard {
    fn build(&mut self, ctx: &mut RustdvCtx) {
        let prefix = std::env::var("RUSTDV_VEC_PREFIX")
            .unwrap_or_else(|_| "sim/uvm_vectors/alu".to_string());
        if let Err(e) = self.load_vectors(&prefix) {
            ctx.error(&format!("cannot read vectors for {prefix}: {e}"));
        }
        self.n_exp = self.exp.len() / 5; // pc, insn, we, waddr, wdata
    }

    async fn run(&mut self, ctx: &mut RustdvCtx) -> Result<(), TestError> {
        let bfm: Rc<CoreBfm> = ConfigDb::get(Some(ctx), "", "BFM")?;
        let n_exp = self.n_exp;

        // An empty golden window is already over. Without this the test would
        // wait on `done` forever, because nothing here would ever set it.
        if n_exp == 0 {
            ctx.warning("no golden retirements: nothing to compare");
            bfm.done.set();
            return Ok(());
        }

        loop {
            let item = bfm.get_retire().await;
            if self.n_compared >= n_exp {
                // The window is compared. Returning is the whole point: the
                // old code `continue`d here, which re-armed a wait for an item
                // it could never use and left the run phase with no exit.
                break;
            }
            let i = self.n_compared * 5;
            let (pc, insn, we, waddr, wdata) =
                (self.exp[i], self.exp[i + 1], self.exp[i + 2], self.exp[i + 3], self.exp[i + 4]);
            if item.pc != pc || item.insn as u64 != insn {
                self.errors += 1;
                if self.errors <= 20 {
                    ctx.error(&format!(
                        "retirement {}: pc DUT={:#x} expected={:#x}, insn DUT={:#08x} expected={:#08x}",
                        self.n_compared, item.pc, pc, item.insn, insn
                    ));
                }
            } else if we != 0 && (item.gpr_waddr as u64 != waddr || item.gpr_wdata != wdata) {
                self.errors += 1;
                if self.errors <= 20 {
                    ctx.error(&format!(
                        "retirement {} (pc {:#x}): x{} DUT={:#x} expected x{}={:#x}",
                        self.n_compared, item.pc, item.gpr_waddr, item.gpr_wdata, waddr, wdata
                    ));
                }
            }
            self.n_compared += 1;

            // Release the test only once the *last* comparison is done. Setting
            // `done` one item early (the old `n_compared + 1 == n_exp`) both
            // reported a result nobody had checked and, because the loop never
            // exited, hung the regression right after a passing run.
            if self.n_compared == n_exp {
                bfm.done.set();
            }
        }
        Ok(())
    }

    /// A mismatch logged in `run` must also *fail* the test: the runner scores
    /// this sink, and a scoreboard that only printed would be the vacuous pass
    /// this testbench started out as.
    fn check(&mut self, ctx: &mut RustdvCtx, errors: &mut CheckSink) {
        let _ = ctx;
        if self.errors > 0 {
            errors.error(format!(
                "{} of {} compared retirements did not match the golden vectors",
                self.errors, self.n_compared
            ));
        }
        if self.n_compared < self.n_exp {
            errors.error(format!(
                "only {} of {} golden retirements were observed: the core stopped short",
                self.n_compared, self.n_exp
            ));
        }
    }

    fn report(&mut self, ctx: &mut RustdvCtx) {
        ctx.info(&format!(
            "scoreboard: {}/{} retirements compared, {} mismatch(es)",
            self.n_compared, self.n_exp, self.errors
        ));
    }
}
