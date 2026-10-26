// =============================================================================
// rv64_uvm_if.sv -- interface between the UVM environment and riscv_core_top.
//
// The driver owns every DUT input (reset included); the monitors only read.
// No clocking blocks: the environment drives and samples at posedge+#1, which
// keeps a single, explicit race-free convention throughout.
// =============================================================================
`ifndef RV64_UVM_IF_SV
`define RV64_UVM_IF_SV

interface rv64_uvm_if (input logic clk);
  // ---- reset, driven by the memory driver ----------------------------------
  logic        rst_n;

  // ---- instruction port ----------------------------------------------------
  logic        if_req_valid;
  logic [63:0] if_req_addr;
  logic        if_req_ready;
  logic        if_rsp_valid;
  logic [63:0] if_rsp_data;
  logic        if_rsp_error;

  // ---- data port -----------------------------------------------------------
  logic        d_req_valid;
  logic [63:0] d_req_addr;
  logic        d_req_we;
  logic [63:0] d_req_wdata;
  logic [7:0]  d_req_wstrb;
  logic        d_req_ready;
  logic        d_rsp_valid;
  logic [63:0] d_rsp_rdata;
  logic        d_rsp_error;

  // ---- interrupts ----------------------------------------------------------
  logic        irq_soft;
  logic        irq_timer;
  logic        irq_ext;

  // ---- debug ---------------------------------------------------------------
  logic        dbg_halt_req;
  logic        dbg_resume_req;
  logic        dbg_step;
  logic        dbg_halted;
  logic [4:0]  dbg_reg_addr;
  logic [63:0] dbg_reg_data;

  // ---- watchpoint ----------------------------------------------------------
  logic        wp_en;
  logic [63:0] wp_addr;
  logic        wp_hit;

  // ---- observability (read only) -------------------------------------------
  logic        retire_valid;
  logic [63:0] retire_pc;
  logic [31:0] retire_insn;
  logic        gpr_we;
  logic [4:0]  gpr_waddr;
  logic [63:0] gpr_wdata;
  logic        trap_valid;
  logic [63:0] trap_cause;
  logic [63:0] trap_pc;
  logic        irq_taken;
  logic [1:0]  priv;
  logic        debug_event;
  logic [63:0] mcycle;
  logic [63:0] minstret;
endinterface

`endif
