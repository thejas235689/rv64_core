// =============================================================================
// tb_uvm_top.sv -- UVM testbench top level.
//   clock, interface, DUT, and the config_db hand-off of the virtual interface.
//   The memory model lives in the driver, so there is no separate memory here.
// =============================================================================
`timescale 1ns/1ps

module tb_uvm_top;
  import uvm_pkg::*;
  import rv64_uvm_pkg::*;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  rv64_uvm_if intf (.clk(clk));

  // ---- DUT ------------------------------------------------------------------
  riscv_core_top u_core (
    .clk            (clk),
    .rst_n          (intf.rst_n),
    .if_req_valid   (intf.if_req_valid),
    .if_req_addr    (intf.if_req_addr),
    .if_req_ready   (intf.if_req_ready),
    .if_rsp_valid   (intf.if_rsp_valid),
    .if_rsp_data    (intf.if_rsp_data),
    .if_rsp_error   (intf.if_rsp_error),
    .d_req_valid    (intf.d_req_valid),
    .d_req_addr     (intf.d_req_addr),
    .d_req_we       (intf.d_req_we),
    .d_req_wdata    (intf.d_req_wdata),
    .d_req_wstrb    (intf.d_req_wstrb),
    .d_req_ready    (intf.d_req_ready),
    .d_rsp_valid    (intf.d_rsp_valid),
    .d_rsp_rdata    (intf.d_rsp_rdata),
    .d_rsp_error    (intf.d_rsp_error),
    .irq_soft       (intf.irq_soft),
    .irq_timer      (intf.irq_timer),
    .irq_ext        (intf.irq_ext),
    .dbg_halt_req   (intf.dbg_halt_req),
    .dbg_resume_req (intf.dbg_resume_req),
    .dbg_step       (intf.dbg_step),
    .dbg_halted     (intf.dbg_halted),
    .dbg_reg_addr   (intf.dbg_reg_addr),
    .dbg_reg_data   (intf.dbg_reg_data),
    .wp_en          (intf.wp_en),
    .wp_addr        (intf.wp_addr),
    .wp_hit         (intf.wp_hit),
    .retire_valid   (intf.retire_valid),
    .retire_pc      (intf.retire_pc),
    .retire_insn    (intf.retire_insn),
    .gpr_we         (intf.gpr_we),
    .gpr_waddr      (intf.gpr_waddr),
    .gpr_wdata      (intf.gpr_wdata),
    .trap_valid_o   (intf.trap_valid),
    .trap_cause_o   (intf.trap_cause),
    .trap_pc_o      (intf.trap_pc),
    .irq_taken_o    (intf.irq_taken),
    .priv_o         (intf.priv),
    .debug_event_o  (intf.debug_event),
    .mcycle_o       (intf.mcycle),
    .minstret_o     (intf.minstret)
  );

  initial begin
    uvm_config_db#(virtual rv64_uvm_if)::set(null, "*", "vif", intf);
    run_test();
  end

endmodule
