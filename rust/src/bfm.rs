//! The BFM: typed handles on the DUT, plus the queues the components share.
//!
//! The core has no memory of its own — `riscv_core_top` exposes an instruction
//! port and a data port with a valid/ready handshake and a one-cycle response,
//! so the testbench *is* the memory. That is what makes this a real VPI
//! testbench rather than a wrapper: every fetch the core performs is served
//! from Rust.

use std::collections::HashMap;

use rustdv::prelude::*;

use crate::item::{MemBeat, RetireItem, TrapItem};

pub struct CoreBfm {
    // clock and reset
    pub clk: LogicHandle,
    pub rst_n: LogicHandle,

    // instruction port
    pub if_req_valid: LogicHandle,
    pub if_req_addr: LogicHandle,
    pub if_req_ready: LogicHandle,
    pub if_rsp_valid: LogicHandle,
    pub if_rsp_data: LogicHandle,
    pub if_rsp_error: LogicHandle,

    // data port
    pub d_req_valid: LogicHandle,
    pub d_req_addr: LogicHandle,
    pub d_req_we: LogicHandle,
    pub d_req_wdata: LogicHandle,
    pub d_req_wstrb: LogicHandle,
    pub d_req_ready: LogicHandle,
    pub d_rsp_valid: LogicHandle,
    pub d_rsp_rdata: LogicHandle,
    pub d_rsp_error: LogicHandle,

    // observability
    pub retire_valid: LogicHandle,
    pub retire_pc: LogicHandle,
    pub retire_insn: LogicHandle,
    pub gpr_we: LogicHandle,
    pub gpr_waddr: LogicHandle,
    pub gpr_wdata: LogicHandle,
    pub trap_valid: LogicHandle,
    pub trap_pc: LogicHandle,
    pub trap_cause: LogicHandle,

    /// Program image, word-addressed: `mem[addr >> 2]`.
    pub mem: Vec<u32>,

    /// Beats the memory agent served, for the scoreboard and for coverage.
    pub served: Queue<MemBeat>,
    /// Retirements seen at the observability port.
    pub retire_q: Queue<RetireItem>,
    /// Traps seen.
    pub trap_q: Queue<TrapItem>,
}

impl std::fmt::Debug for CoreBfm {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("CoreBfm")
    }
}

impl CoreBfm {
    pub fn new(dut: &HierarchyHandle) -> Result<CoreBfm, HandleError> {
        Ok(CoreBfm {
            clk: dut.signal("clk")?,
            rst_n: dut.signal("rst_n")?,

            if_req_valid: dut.signal("if_req_valid")?,
            if_req_addr: dut.signal("if_req_addr")?,
            if_req_ready: dut.signal("if_req_ready")?,
            if_rsp_valid: dut.signal("if_rsp_valid")?,
            if_rsp_data: dut.signal("if_rsp_data")?,
            if_rsp_error: dut.signal("if_rsp_error")?,

            d_req_valid: dut.signal("d_req_valid")?,
            d_req_addr: dut.signal("d_req_addr")?,
            d_req_we: dut.signal("d_req_we")?,
            d_req_wdata: dut.signal("d_req_wdata")?,
            d_req_wstrb: dut.signal("d_req_wstrb")?,
            d_req_ready: dut.signal("d_req_ready")?,
            d_rsp_valid: dut.signal("d_rsp_valid")?,
            d_rsp_rdata: dut.signal("d_rsp_rdata")?,
            d_rsp_error: dut.signal("d_rsp_error")?,

            retire_valid: dut.signal("retire_valid")?,
            retire_pc: dut.signal("retire_pc")?,
            retire_insn: dut.signal("retire_insn")?,
            gpr_we: dut.signal("gpr_we")?,
            gpr_waddr: dut.signal("gpr_waddr")?,
            gpr_wdata: dut.signal("gpr_wdata")?,
            trap_valid: dut.signal("trap_valid_o")?,
            trap_pc: dut.signal("trap_pc_o")?,
            trap_cause: dut.signal("trap_cause_o")?,

            mem: Vec::new(),
            served: Queue::unbounded(),
            retire_q: Queue::unbounded(),
            trap_q: Queue::unbounded(),
        })
    }

    /// Load a program image, one 32-bit word per element.
    pub fn load(&mut self, words: &[u32]) {
        self.mem.clear();
        self.mem.extend_from_slice(words);
    }

    /// Hold reset for a few edges, then release. The core samples `rst_n`
    /// synchronously, so the BFM resets on falling edges like the reference
    /// testbench does.
    pub async fn reset(&self) {
        self.rst_n.set_u64(0);
        self.if_rsp_valid.set_u64(0);
        self.d_rsp_valid.set_u64(0);
        for _ in 0..5 {
            self.clk.falling_edge().await;
        }
        self.rst_n.set_u64(1);
        self.clk.falling_edge().await;
        while self.retire_q.try_get().is_some() {}
        while self.trap_q.try_get().is_some() {}
        while self.served.try_get().is_some() {}
    }

    pub async fn get_retire(&self) -> RetireItem {
        self.retire_q.get().await
    }

    pub async fn get_trap(&self) -> TrapItem {
        self.trap_q.get().await
    }
}
