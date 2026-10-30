`timescale 1ns/1ps
// Boot sequence test: the core is built with BOOT_ROM=1, so the ROM owns the reset
// vector and fetch is held until the image authenticates.
module tb_bootseq;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        if_req_valid, if_req_ready, if_rsp_valid, if_rsp_error;
  logic [63:0] if_req_addr, if_rsp_data;
  logic        d_req_valid, d_req_we, d_req_ready, d_rsp_valid, d_rsp_error;
  logic [63:0] d_req_addr, d_req_wdata, d_rsp_data;
  logic [7:0]  d_req_wstrb;

  riscv_core_top #(
    .RESET_PC (64'h0),
    .BOOT_ROM (1'b1)
  ) u_core (
    .clk(clk), .rst_n(rst_n),
    .if_req_valid(if_req_valid), .if_req_addr(if_req_addr), .if_req_ready(if_req_ready),
    .if_rsp_valid(if_rsp_valid), .if_rsp_data(if_rsp_data), .if_rsp_error(if_rsp_error),
    .d_req_valid(d_req_valid), .d_req_addr(d_req_addr), .d_req_we(d_req_we),
    .d_req_wstrb(d_req_wstrb), .d_req_wdata(d_req_wdata), .d_req_ready(d_req_ready),
    .d_rsp_valid(d_rsp_valid), .d_rsp_rdata(d_rsp_data), .d_rsp_error(d_rsp_error),
    .irq_ext(1'b0), .irq_timer(1'b0), .irq_soft(1'b0),
    .dbg_halt_req(1'b0), .dbg_resume_req(1'b0), .dbg_step(1'b0),
    .dbg_halted(), .dbg_reg_addr(5'd0), .dbg_reg_data(),
    .wp_en(1'b0), .wp_addr(64'd0), .wp_hit(),
    .retire_valid(), .retire_pc(), .retire_insn(),
    .gpr_we(), .gpr_waddr(), .gpr_wdata(),
    .trap_valid_o(), .trap_cause_o(), .trap_pc_o(), .irq_taken_o(),
    .priv_o(), .debug_event_o(), .mcycle_o(), .minstret_o(),
    .task_start_valid(), .task_start_slot(), .task_start_token(),
    .task_start_timeout(), .task_done_valid(), .task_done_slot(),
    .task_done_result(), .task_irq_o()
  );

  // a bus that answers with a recognisable word, so a fetch from the bus is
  // distinguishable from a fetch from the ROM
  assign if_req_ready = 1'b1;
  assign d_req_ready  = 1'b1;
  assign if_rsp_data  = 64'hDEAD_DEAD_DEAD_DEAD;
  assign if_rsp_error = 1'b0;
  assign d_rsp_data   = 64'd0;
  assign d_rsp_error  = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      if_rsp_valid <= 1'b0;
      d_rsp_valid  <= 1'b0;
    end else begin
      if_rsp_valid <= if_req_valid && if_req_ready;
      d_rsp_valid  <= d_req_valid && d_req_ready && !d_req_we;
    end
  end

  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-40s got=%h expected=%h", name, got, exp); end
    end
  endtask
  task automatic chk_bit(input string name, input logic got, input logic exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-40s got=%b expected=%b", name, got, exp); end
    end
  endtask

  logic [63:0] bus_beats_seen;

  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    // ---- 1. before the image is authorised the core must not fetch -------
    @(posedge clk); #1;
    chk_bit("fetch held before boot release", u_core.boot_released, 1'b0);
    chk_bit("fetch_stopped while unauthenticated", u_core.fetch_stopped, 1'b1);

    // ---- 2. the digest is checked and the core is released ---------------
    begin
      int g; g = 0;
      while (!u_core.boot_released && g < 40000) begin @(posedge clk); #1; g++; end
      if (g >= 40000) begin errors++; $display("MISMATCH boot never released"); end
    end
    chk_bit("boot released after authentication", u_core.boot_released, 1'b1);
    chk("authenticator produced a MAC", (u_core.auth_digest == 256'd0) ? 32'd0 : 32'd1, 32'd1);

    // ---- 3. after release the reset vector comes from the ROM ------------
    // the stub's first word must be the ROM's, not the bus's 0xDEAD...
    @(posedge clk); #1;
    begin
      int g; g = 0;
      while (!(u_core.ic_resp_valid) && g < 40) begin @(posedge clk); #1; g++; end
    end
    chk("fetch after boot comes from the ROM stub",
        u_core.ic_resp_data, 64'h0000011300000117);
    chk_bit("ROM answered, not the bus", u_core.rom_sel_q, 1'b1);

    $display("tb_bootseq: %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
