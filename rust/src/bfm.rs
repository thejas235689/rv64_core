//! The BFM: typed handles on the DUT, plus the queues the components share.
//!
//! `riscv_core_top` has no memory of its own -- it exposes an instruction port
//! and a data port with valid/ready handshakes -- so the testbench *is* the
//! memory. Every fetch the core performs is served from Rust over VPI, which is
//! what makes this a real VPI testbench rather than a wrapper.

use std::cell::RefCell;

use rustdv::prelude::*;

use crate::item::{MemBeat, RetireItem, TrapItem};

/// Memory size in 64-bit words, matching `tb/tb_core_top.sv`'s `MEM_WORDS`.
pub const MEM_WORDS: usize = 16384;

/// 64-bit word index for a beat address: `addr[16:3]`, wrapping like the
/// SystemVerilog memory rather than truncating the program.
fn word_index(addr: u64) -> usize {
    ((addr >> 3) as usize) & (MEM_WORDS - 1)
}

/// Parcel (32-bit) index for an arbitrary byte address.
fn parcel_index(addr: u64) -> usize {
    word_index(addr & !7u64) * 2 + (((addr >> 2) & 1) as usize)
}

pub struct CoreBfm {
    pub clk: LogicHandle,
    pub rst_n: LogicHandle,

    pub if_req_valid: LogicHandle,
    pub if_req_addr: LogicHandle,
    pub if_req_ready: LogicHandle,
    pub if_rsp_valid: LogicHandle,
    pub if_rsp_data: LogicHandle,
    pub if_rsp_error: LogicHandle,

    pub d_req_valid: LogicHandle,
    pub d_req_addr: LogicHandle,
    pub d_req_we: LogicHandle,
    pub d_req_wdata: LogicHandle,
    pub d_req_wstrb: LogicHandle,
    pub d_req_ready: LogicHandle,
    pub d_rsp_valid: LogicHandle,
    pub d_rsp_rdata: LogicHandle,
    pub d_rsp_error: LogicHandle,

    pub retire_valid: LogicHandle,
    pub retire_pc: LogicHandle,
    pub retire_insn: LogicHandle,
    pub gpr_we: LogicHandle,
    pub gpr_waddr: LogicHandle,
    pub gpr_wdata: LogicHandle,
    pub trap_valid: LogicHandle,
    pub trap_pc: LogicHandle,
    pub trap_cause: LogicHandle,

    /// Program image, word-addressed. `RefCell` because the memory agent holds
    /// the BFM as `Rc<CoreBfm>` and still has to store into it on a write beat;
    /// the borrow is short and never held across an `await`.
    pub mem: RefCell<Vec<u32>>,

    pub served: Queue<MemBeat>,
    pub retire_q: Queue<RetireItem>,
    pub trap_q: Queue<TrapItem>,
    /// DUT inputs this testbench does not model, with the value each is held
    /// at. They must be driven: an undriven input reads X, and an X on a
    /// control input does not fail loudly -- it makes `if`/`case` fall through.
    /// `if_rsp_error` is the one that matters: `rv64_fetch` accepts a beat in
    /// `else if (!rsp_error)`, and `!x` is x, so every fetched instruction was
    /// silently dropped and the core retried the same fetch forever.
    pub idle_inputs: Vec<(&'static str, LogicHandle, u64)>,

    /// Set by the scoreboard once the whole golden window is compared. The test
    /// waits on this rather than draining `retire_q`: two consumers on one
    /// queue steal each other's items.
    pub done: Event,
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
            idle_inputs: [
                // vector port: not modelled (no vector vectors in this flow).
                ("v_req_ready", 1), ("v_rsp_valid", 0), ("v_rsp_data", 0), ("v_rsp_error", 0),
                // interrupts
                ("irq_soft", 0), ("irq_timer", 0), ("irq_ext", 0),
                // crypto blocks
                ("sha_start", 0), ("sha_init", 0), ("sha_block", 0),
                ("hmac_start", 0), ("hmac_key", 0), ("hmac_msg", 0),
                // RSA / Montgomery
                ("modexp_start", 0), ("modexp_n0inv_we", 0), ("modexp_n0inv", 0),
                ("modexp_e_bits", 0), ("modexp_ld_we", 0), ("modexp_ld_sel", 0),
                ("modexp_ld_addr", 0), ("modexp_ld_wdata", 0), ("modexp_r_addr", 0),
                // serial: an idle UART line is high, not low
                ("uart_rx", 1),
                // CLIC / PLIC configuration ports
                ("clic_src", 0), ("clic_cfg_we", 0), ("clic_cfg_addr", 0),
                ("clic_cfg_wdata", 0), ("clic_ack", 0), ("clic_ack_id", 0),
                ("plic_src", 0), ("plic_cfg_we", 0), ("plic_cfg_addr", 0),
                ("plic_cfg_wdata", 0), ("plic_claim", 0), ("plic_complete", 0),
                ("plic_complete_id", 0),
                // debug / watchpoint
                ("dbg_halt_req", 0), ("dbg_resume_req", 0), ("dbg_step", 0),
                ("dbg_reg_addr", 0), ("wp_en", 0), ("wp_addr", 0),
                // Xcetask engine side
                ("task_done_valid", 0), ("task_done_slot", 0), ("task_done_result", 0),
            ]
            .iter()
            .filter_map(|(n, v)| dut.signal(n).ok().map(|h| (*n, h, *v)))
            .collect(),
            mem: RefCell::new(Vec::new()),
            served: Queue::unbounded(),
            retire_q: Queue::unbounded(),
            trap_q: Queue::unbounded(),
            done: Event::new(),
        })
    }

    /// Load a program image into a memory sized like the SystemVerilog
    /// testbench's (`tb_core_top`: 16384 64-bit words = 128 KiB, addressed by
    /// `a[16:3]`). Sizing the image to the program instead would make every
    /// store above the last instruction a silent no-op -- `write_beat` skips a
    /// parcel that is not there -- and a load of a just-stored value would read
    /// zero.
    pub fn load(&mut self, words: &[u32]) {
        let mut mem = vec![0u32; MEM_WORDS * 2];
        let n = words.len().min(mem.len());
        mem[..n].copy_from_slice(&words[..n]);
        *self.mem.borrow_mut() = mem;
    }

    /// The 32-bit instruction/data parcel at `addr`.
    ///
    /// Addressing mirrors `tb/tb_core_top.sv` exactly, aliasing included: the
    /// memory is `MEM_WORDS` 64-bit words indexed by `addr[16:3]`, so bits
    /// above 16 wrap rather than fall off the end. A plain `Vec` that stops at
    /// the last instruction instead silently swallows every store above it, and
    /// a load of that address then reads zero -- which is what made the `mem`
    /// and `memwidth` programs fail.
    pub fn read_word(&self, addr: u64) -> u32 {
        *self.mem.borrow().get(parcel_index(addr)).unwrap_or(&0)
    }

    /// One 64-bit bus beat: the parcel at `addr` in the low half, the one at
    /// `addr + 4` in the high half. Both ports are 64 bits wide and the core
    /// takes two parcels per fetch, so serving a single 32-bit word leaves the
    /// upper half reading zero -- which decodes as an illegal instruction and
    /// traps to mtvec. That is exactly what it did before this existed.
    pub fn read_beat(&self, addr: u64) -> u64 {
        // A beat is 8-byte aligned whatever the access width: the core selects
        // the byte or half inside the beat from addr[2:0], exactly as
        // `mem[a[16:3]]` does. Serving the beat at the unaligned address
        // instead shifts the lane the core picks from.
        let w = word_index(addr & !7u64);
        let mem = self.mem.borrow();
        (mem.get(w * 2).copied().unwrap_or(0) as u64)
            | ((mem.get(w * 2 + 1).copied().unwrap_or(0) as u64) << 32)
    }

    /// Apply a byte-strobed 64-bit store. `wstrb` lanes are relative to the
    /// 8-byte-aligned beat, as on the DUT's data port.
    pub fn write_beat(&self, addr: u64, wdata: u64, wstrb: u8) {
        let w = word_index(addr & !7u64);
        let mut mem = self.mem.borrow_mut();
        for lane in 0..8usize {
            if wstrb & (1 << lane) == 0 {
                continue;
            }
            let Some(slot) = mem.get_mut(w * 2 + (lane >> 2)) else { continue };
            let sh = (lane & 3) * 8;
            let byte = (wdata >> (lane * 8)) & 0xFF;
            *slot = (*slot & !(0xFFu32 << sh)) | ((byte as u32) << sh);
        }
    }

    /// Drive every input the testbench does not otherwise use. Called once,
    /// before reset, so the DUT never sees X on a control input.
    pub fn tie_off_idle_inputs(&self) {
        for (_, h, v) in &self.idle_inputs {
            h.set_u64(*v);
        }
    }

    /// Hold reset for a few edges, then release.
    pub async fn reset(&self) {
        self.rst_n.set_u64(0);
        self.if_rsp_valid.set_u64(0);
        self.if_rsp_error.set_u64(0);
        self.d_rsp_valid.set_u64(0);
        self.d_rsp_error.set_u64(0);
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

    pub async fn wait_done(&self) {
        self.done.wait().await
    }
}
