// =============================================================================
// tb_core_top.sv -- verification harness for riscv_core_top.
//   * 128 KiB behavioural memory, 64-bit beats, byte-strobe writes
//   * host port so the testbench can load programs before releasing reset
//   * programmable request backpressure on both ports
//   * programmable error injection on a single aligned address
//   * every core observability output is brought to the top level so the
//     cocotb test can sample it directly
//   Testbench only: not synthesizable, not part of rtl/.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_core_top #(
  parameter int MEM_WORDS = 16384        // 64-bit words => 128 KiB
) ();
  // ---- clock / reset (driven by cocotb) -------------------------------------
  logic clk;
  logic rst_n;

  // ---- host load port -------------------------------------------------------
  logic        host_we;
  logic        host_clear;
  logic [63:0] host_addr;
  logic [63:0] host_wdata;

  // ---- stimulus -------------------------------------------------------------
  logic        i_bp, d_bp;
  logic        err_en;
  logic [63:0] err_addr;
  logic        irq_soft, irq_timer, irq_ext;
  logic        dbg_halt_req, dbg_resume_req, dbg_step;
  logic [4:0]  dbg_reg_addr;
  logic [63:0] dbg_reg_data;
  logic        wp_en;
  logic [63:0] wp_addr;

  // ---- instruction interface ------------------------------------------------
  logic        if_req_valid;
  logic [63:0] if_req_addr;
  logic        if_req_ready;
  logic        if_rsp_valid;
  logic [63:0] if_rsp_data;
  logic        if_rsp_error;

  // ---- data interface -------------------------------------------------------
  logic        d_req_valid;
  logic [63:0] d_req_addr;
  logic        d_req_we;
  logic [63:0] d_req_wdata;
  logic [7:0]  d_req_wstrb;
  logic        d_req_ready;
  logic        d_rsp_valid;
  logic [63:0] d_rsp_rdata;
  logic        d_rsp_error;

  // ---- observability --------------------------------------------------------
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
  logic        dbg_halted;
  logic        wp_hit;
  logic [63:0] mcycle;
  logic [63:0] minstret;

  // ---- memory ---------------------------------------------------------------
  logic [63:0] mem [0:MEM_WORDS-1];

  // Real memory powers up as zeros, not X.  Initialising also keeps an
  // out-of-range fetch decoding as an illegal instruction instead of
  // propagating X into the core.
  initial begin
    for (int i = 0; i < MEM_WORDS; i++) mem[i] = 64'd0;
  end

  function automatic logic [63:0] mem_rd(input logic [63:0] a);
    return mem[a[16:3]];
  endfunction

  function automatic logic err_hit(input logic [63:0] a);
    return err_en && (a == err_addr);
  endfunction

  assign if_req_ready = !i_bp;
  assign d_req_ready  = !d_bp;

  always_ff @(posedge clk) begin
    if (host_clear) begin
      for (int i = 0; i < MEM_WORDS; i++) mem[i] <= 64'd0;
    end else begin
    // host program load: one 32-bit parcel per beat, selected by addr[2]
    if (host_we) begin
      if (host_addr[2]) mem[host_addr[16:3]][63:32] <= host_wdata[31:0];
      else              mem[host_addr[16:3]][31:0]  <= host_wdata[31:0];
    end

    // instruction response (one cycle after accept)
    if_rsp_valid <= if_req_valid && if_req_ready;
    if (if_req_valid && if_req_ready) begin
      if_rsp_data  <= mem_rd(if_req_addr);
      if_rsp_error <= err_hit(if_req_addr);
    end

    // data response (loads only) and byte-strobed writes
    d_rsp_valid <= d_req_valid && d_req_ready && !d_req_we;
    if (d_req_valid && d_req_ready) begin
      d_rsp_rdata <= mem_rd(d_req_addr);
      d_rsp_error <= err_hit(d_req_addr);
      if (d_req_we) begin
        for (int b = 0; b < 8; b++) begin
          if (d_req_wstrb[b]) mem[d_req_addr[16:3]][8*b +: 8] <= d_req_wdata[8*b +: 8];
        end
      end
    end
    end
  end

  // ---- DUT ------------------------------------------------------------------
  riscv_core_top #(
    .RESET_PC (64'h0000_0000_0000_0000)
  ) u_core (
    .clk            (clk),
    .rst_n          (rst_n),
    .if_req_valid   (if_req_valid),
    .if_req_addr    (if_req_addr),
    .if_req_ready   (if_req_ready),
    .if_rsp_valid   (if_rsp_valid),
    .if_rsp_data    (if_rsp_data),
    .if_rsp_error   (if_rsp_error),
    .d_req_valid    (d_req_valid),
    .d_req_addr     (d_req_addr),
    .d_req_we       (d_req_we),
    .d_req_wdata    (d_req_wdata),
    .d_req_wstrb    (d_req_wstrb),
    .d_req_ready    (d_req_ready),
    .d_rsp_valid    (d_rsp_valid),
    .d_rsp_rdata    (d_rsp_rdata),
    .d_rsp_error    (d_rsp_error),
    .irq_soft       (irq_soft),
    .irq_timer      (irq_timer),
    .irq_ext        (irq_ext),
    .dbg_halt_req   (dbg_halt_req),
    .dbg_resume_req (dbg_resume_req),
    .dbg_step       (dbg_step),
    .dbg_halted     (dbg_halted),
    .dbg_reg_addr   (dbg_reg_addr),
    .dbg_reg_data   (dbg_reg_data),
    .wp_en          (wp_en),
    .wp_addr        (wp_addr),
    .wp_hit         (wp_hit),
    .retire_valid   (retire_valid),
    .retire_pc      (retire_pc),
    .retire_insn    (retire_insn),
    .gpr_we         (gpr_we),
    .gpr_waddr      (gpr_waddr),
    .gpr_wdata      (gpr_wdata),
    .trap_valid_o   (trap_valid),
    .trap_cause_o   (trap_cause),
    .trap_pc_o      (trap_pc),
    .irq_taken_o    (irq_taken),
    .priv_o         (priv),
    .debug_event_o  (debug_event),
    .mcycle_o       (mcycle),
    .minstret_o     (minstret)
  );

endmodule
`default_nettype wire
