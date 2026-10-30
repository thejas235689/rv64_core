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
  logic        sha_start, sha_init, sha_busy, sha_done;
  logic [511:0] sha_block;
  logic [255:0] sha_digest;
  logic        hmac_start, hmac_busy, hmac_done;
  logic [255:0] hmac_key, hmac_mac;
  logic [511:0] hmac_msg;
  logic [3:0]  plic_src;
  logic        plic_cfg_we;
  logic [4:0]  plic_cfg_addr;
  logic [31:0] plic_cfg_wdata, plic_cfg_rdata;
  logic        plic_claim, plic_claim_valid, plic_complete;
  logic [3:0]  plic_claim_id, plic_complete_id;
  initial begin
    plic_src = 4'd0; plic_cfg_we = 1'b0; plic_cfg_addr = 5'd0;
    plic_cfg_wdata = 32'd0; plic_claim = 1'b0; plic_complete = 1'b0;
    plic_complete_id = 4'd0;
    sha_start = 1'b0; sha_init = 1'b0; sha_block = 512'd0;
    hmac_start = 1'b0; hmac_key = 256'd0; hmac_msg = 512'd0;
  end

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

  // ---- vector interface -----------------------------------------------------
  logic        v_req_valid;
  logic [63:0] v_req_addr;
  logic        v_req_we;
  logic [63:0] v_req_wdata;
  logic [7:0]  v_req_wstrb;
  logic        v_req_ready;
  logic        v_rsp_valid;
  logic [63:0] v_rsp_data;
  logic        v_rsp_error;

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

  // ---- task engine side (driven by the test) -------------------------------
  logic        task_start_valid;
  logic [1:0]  task_start_slot;
  logic [63:0] task_start_token;
  logic [31:0] task_start_timeout;
  logic        task_done_valid;
  logic [1:0]  task_done_slot;
  logic [63:0] task_done_result;
  logic        task_irq;

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

  // Real memory powers up as zeros, not X. Initialising also keeps an
  // out-of-range fetch decoding as an illegal instruction instead of
  // propagating X into the core.
  //
  // The zeroing happens inside the same always_ff that serves the bus: an
  // `initial` block plus an always_ff would make `mem` a multiply-driven
  // variable, which is legal Verilog but a real hazard (and slang rejects it).
  logic mem_first = 1'b1;

  function automatic logic [63:0] mem_rd(input logic [63:0] a);
    return mem[a[16:3]];
  endfunction

  function automatic logic err_hit(input logic [63:0] a);
    return err_en && (a == err_addr);
  endfunction

  assign if_req_ready = !i_bp;
  assign d_req_ready  = !d_bp;

  always_ff @(posedge clk) begin
    if (mem_first) begin
      mem_first <= 1'b0;
      for (int i = 0; i < MEM_WORDS; i++) mem[i] <= 64'd0;
    end else if (host_clear) begin
      for (int i = 0; i < MEM_WORDS; i++) mem[i] <= 64'd0;
    end else begin
    // host program load: one 32-bit parcel per beat, selected by addr[2]
    if (host_we) begin
      if (host_addr[2]) mem[host_addr[16:3]][63:32] <= host_wdata[31:0];
      else              mem[host_addr[16:3]][31:0]  <= host_wdata[31:0];
    end

    // vector port stores: fire-and-forget, same array
    if (v_req_valid && v_req_ready && v_req_we) begin
      for (int b = 0; b < 8; b++)
        if (v_req_wstrb[b]) mem[v_req_addr[16:3]][8*b +: 8] <= v_req_wdata[8*b +: 8];
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
    .v_req_valid    (v_req_valid),
    .v_req_addr     (v_req_addr),
    .v_req_we       (v_req_we),
    .v_req_wdata    (v_req_wdata),
    .v_req_wstrb    (v_req_wstrb),
    .v_req_ready    (v_req_ready),
    .v_rsp_valid    (v_rsp_valid),
    .v_rsp_data     (v_rsp_data),
    .v_rsp_error    (v_rsp_error),
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
    .sha_start       (sha_start),
    .sha_init        (sha_init),
    .sha_block       (sha_block),
    .sha_busy        (sha_busy),
    .sha_done        (sha_done),
    .sha_digest      (sha_digest),
    .hmac_start      (hmac_start),
    .hmac_key        (hmac_key),
    .hmac_msg        (hmac_msg),
    .hmac_busy       (hmac_busy),
    .hmac_done       (hmac_done),
    .hmac_mac        (hmac_mac),
    .plic_src        (plic_src),
    .plic_cfg_we     (plic_cfg_we),
    .plic_cfg_addr   (plic_cfg_addr),
    .plic_cfg_wdata  (plic_cfg_wdata),
    .plic_cfg_rdata  (plic_cfg_rdata),
    .plic_claim      (plic_claim),
    .plic_claim_id   (plic_claim_id),
    .plic_claim_valid(plic_claim_valid),
    .plic_complete   (plic_complete),
    .plic_complete_id(plic_complete_id),
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
    .minstret_o     (minstret),
    .task_start_valid   (task_start_valid),
    .task_start_slot    (task_start_slot),
    .task_start_token   (task_start_token),
    .task_start_timeout (task_start_timeout),
    .task_done_valid    (task_done_valid),
    .task_done_slot     (task_done_slot),
    .task_done_result   (task_done_result),
    .task_irq_o         (task_irq)
  );


  // vector port: same memory array, one cycle, no backpressure. Stores are
  // fire-and-forget exactly as on the data port.
  assign v_req_ready = 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_rsp_valid <= 1'b0;
      v_rsp_data  <= 64'd0;
      v_rsp_error <= 1'b0;
    end else begin
      v_rsp_valid <= v_req_valid && v_req_ready && !v_req_we;
      if (v_req_valid && v_req_ready) begin
        v_rsp_data  <= mem_rd(v_req_addr);
        v_rsp_error <= err_hit(v_req_addr);
      end
    end
  end


endmodule
`default_nettype wire
