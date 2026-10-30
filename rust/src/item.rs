//! Transaction types, mirroring `rv64_retire_item` / `rv64_trap_item` in the
//! SystemVerilog environment so a failure is legible in either testbench.

/// One beat on either bus. The core has separate instruction and data ports
/// with identical handshakes, so one type serves both.
#[derive(Clone, Debug, Default)]
pub struct MemBeat {
    pub addr: u64,
    pub we: bool,
    pub wdata: u64,
    pub wstrb: u8,
}

/// One retired instruction, as observed at the core's observability port.
#[derive(Clone, Debug, Default)]
pub struct RetireItem {
    pub pc: u64,
    pub insn: u32,
    pub gpr_we: bool,
    pub gpr_waddr: u8,
    pub gpr_wdata: u64,
}

/// One trap, as observed at `trap_valid_o`.
#[derive(Clone, Debug, Default)]
pub struct TrapItem {
    pub pc: u64,
    pub cause: u64,
}
