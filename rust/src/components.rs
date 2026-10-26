//! Components: the memory agent, the retire monitor and the scoreboard.
//!
//! Work happens in `run`, not in a constructor: the agent and the monitor block
//! on the clock and on the BFM's queues concurrently, and each races the
//! objection-drained event on its own.

use std::rc::Rc;

use rustdv::prelude::*;

use crate::bfm::CoreBfm;
use crate::item::{MemBeat, RetireItem, TrapItem};

/// `LogicHandle::get_u64` returns `Result<u64, ValueError>`; a read of a signal
/// that exists cannot fail, so an unreadable value reads as 0 rather than
/// panicking mid-simulation.
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

/// Serves both of the core's ports with a one-cycle response, which is what the
/// core's handshake specifies. Reads come from the BFM's program image; writes
/// update it. Every beat is pushed to `served` so the scoreboard can see the
/// traffic the core actually generated.
#[derive(Component, Default)]
pub struct MemoryAgent;

impl Component for MemoryAgent {
    async fn run(&mut self, ctx: &mut RustdvCtx) -> Result<(), TestError> {
        let bfm: Rc<CoreBfm> = ConfigDb::get(Some(ctx), "", "BFM")?;
        bfm.reset().await;

        // ready held high: a request is accepted every cycle
        bfm.if_req_ready.set_u64(1);
        bfm.d_req_ready.set_u64(1);
        bfm.if_rsp_valid.set_u64(0);
        bfm.d_rsp_valid.set_u64(0);

        let mut if_pend = false;
        let mut if_addr: u64 = 0;
        let mut d_pend = false;
        let mut d_addr: u64 = 0;
        let mut d_we = false;

        loop {
            bfm.clk.rising_edge().await;

            // ---- respond with whatever was accepted last cycle --------------
            if if_pend {
                bfm.if_rsp_data.set_u64(bfm.read_word(if_addr) as u64);
                bfm.if_rsp_valid.set_u64(1);
            } else {
                bfm.if_rsp_valid.set_u64(0);
            }

            if d_pend {
                bfm.d_rsp_rdata.set_u64(bfm.read_word(d_addr) as u64);
                bfm.d_rsp_valid.set_u64(1);
            } else {
                bfm.d_rsp_valid.set_u64(0);
            }

            // ---- accept new requests ----------------------------------------
            if_pend = b(&bfm.if_req_valid);
            if if_pend {
                if_addr = u(&bfm.if_req_addr);
            }

            d_pend = b(&bfm.d_req_valid);
            if d_pend {
                d_addr = u(&bfm.d_req_addr);
                d_we = b(&bfm.d_req_we);
                if d_we {
                    // byte-lane writes, same semantics as the SV harness
                    let word = (d_addr >> 2) as usize;
                    let wstrb = u(&bfm.d_req_wstrb) as u8;
                    let wdata = u(&bfm.d_req_wdata) as u32;
                    if let Some(slot) = bfm.mem.borrow_mut().get_mut(word) {
                        let mut merged = *slot;
                        for lane in 0..4u32 {
                            if wstrb & (1 << lane) != 0 {
                                let sh = lane * 8;
                                merged = (merged & !(0xFFu32 << sh)) | (wdata & (0xFFu32 << sh));
                            }
                        }
                        *slot = merged;
                    }
                    bfm.served
                        .put(MemBeat { addr: d_addr, we: true, wdata: u(&bfm.d_req_wdata), wstrb })
                        .await;
                }
            }
        }
    }
}

// ===========================================================================
// Monitors
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

/// Compares the DUT's retirement stream against the golden vectors produced by
/// the Python ISA model.
///
/// **There is no second ISA model here**, deliberately. The SystemVerilog
/// scoreboard and this one read the same files from `sim/uvm_vectors/`, so the
/// two environments cannot disagree about what "correct" means, and there is
/// only one place for the oracle to be wrong.
#[derive(Component, Default)]
pub struct Scoreboard {
    // data, not a child component: no #[component] attribute here
    exp: Vec<u64>,
    n_compared: usize,
    errors: usize,
}

impl Scoreboard {
    pub fn load_vectors(&mut self, prefix: &str) -> std::io::Result<()> {
        let text = std::fs::read_to_string(format!("{prefix}.retire.hex"))?;
        self.exp = text.split_whitespace().filter_map(|t| u64::from_str_radix(t, 16).ok()).collect();
        Ok(())
    }
}

impl Scoreboard {
    fn build(&mut self, ctx: &mut RustdvCtx) {
        // self-contained: the prefix comes from the environment, so the
        // scoreboard does not depend on the test having run first
        let prefix = std::env::var("RUSTDV_VEC_PREFIX")
            .unwrap_or_else(|_| "sim/uvm_vectors/alu".to_string());
        if let Err(e) = self.load_vectors(&prefix) {
            ctx.error(&format!("cannot read vectors for {prefix}: {e}"));
        }
    }
}

impl Component for Scoreboard {
    async fn run(&mut self, ctx: &mut RustdvCtx) -> Result<(), TestError> {
        let bfm: Rc<CoreBfm> = ConfigDb::get(Some(ctx), "", "BFM")?;
        // five values per retirement: pc, insn, we, waddr, wdata
        let n_exp = self.exp.len() / 5;
        loop {
            let item = bfm.get_retire().await;
            if self.n_compared >= n_exp {
                continue;
            }
            if self.n_compared + 1 == n_exp {
                // last expected retirement compared: release the test
                bfm.done.set();
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
        }
    }
}
