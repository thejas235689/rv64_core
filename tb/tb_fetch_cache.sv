`timescale 1ns/1ps
// Isolated testbench for the fetch unit driving the instruction cache.
//
// This is the handshake that broke the core: the fetch unit issues an aligned
// 64-bit beat request and expects a response with the beat for THAT address. The
// test walks a PC sequence through the pair and checks the instruction returned
// matches memory, with redirects and cache misses in the mix.
module tb_fetch_cache;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        redirect, consume, pause;
  logic [63:0] pc_i;
  logic        req_valid, req_ready, rsp_valid, rsp_error;
  logic [63:0] req_addr, rsp_data;
  logic        insn_valid, fault_valid;
  logic [63:0] insn_pc, fault_pc;
  logic [31:0] insn;
  logic        tag_control, tag_writes_rd, tag_fusion_valid;
  logic [1:0]  tag_fusion_kind;

  // cache core-side
  logic        c_req_valid, c_resp_valid, c_resp_miss, c_resp_error;
  logic [63:0] c_req_addr, c_resp_data;
  logic        fill_valid, fill_ready, fill_rsp_valid, fill_rsp_error;
  logic [63:0] fill_addr, fill_rsp_data;
  logic [31:0] hits, misses;

  rv64_fetch u_fetch (
    .clk(clk), .rst_n(rst_n),
    .redirect(redirect), .pc_i(pc_i), .consume(consume), .pause(pause),
    .req_valid(req_valid), .req_addr(req_addr), .req_ready(req_ready),
    .rsp_valid(rsp_valid), .rsp_data(rsp_data), .rsp_error(rsp_error),
    .insn_valid(insn_valid), .insn_pc(insn_pc), .insn(insn),
    .fault_valid(fault_valid), .fault_pc(fault_pc),
    .tag_is_control(tag_control), .tag_writes_rd(tag_writes_rd),
    .tag_fusion_valid(tag_fusion_valid), .tag_fusion_kind(tag_fusion_kind)
  );

  rv64_icache u_cache (
    .clk(clk), .rst_n(rst_n),
    .req_valid(req_valid), .req_addr(req_addr),
    .resp_valid(rsp_valid), .resp_data(rsp_data),
    .resp_miss(c_resp_miss), .resp_error(rsp_error),
    .fill_valid(fill_valid), .fill_addr(fill_addr),
    .fill_ready(fill_ready), .fill_rsp_valid(fill_rsp_valid),
    .fill_rsp_data(fill_rsp_data), .fill_rsp_error(fill_rsp_error),
    .hit_count(hits), .miss_count(misses)
  );

  // ---- memory: word at address A is (A*7)+1, so any misread shows up -------
  logic [63:0] mem [0:8191];
  assign req_ready = 1'b1;
  assign fill_ready = 1'b1;
  assign fill_rsp_error = 1'b0;

  logic        pend;
  logic [63:0] pend_d;
  assign fill_rsp_valid = pend;
  assign fill_rsp_data  = pend_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend <= 1'b0; pend_d <= 64'd0;
      for (int i = 0; i < 8192; i++) mem[i] <= ((i * 7) + 1);
    end else begin
      pend <= 1'b0;
      if (fill_valid && fill_ready) begin
        pend_d <= mem[fill_addr[15:3]];
        pend   <= 1'b1;
      end
    end
  end

  // explicit zero-extension: the 64'(...) size cast does not behave under Icarus
  function automatic logic [63:0] mem_beat(input logic [63:0] a);
    begin
      return (((a[15:3]) * 7) + 1);
    end
  endfunction

  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-40s got=%h expected=%h", name, got, exp); end
    end
  endtask

  // fetch the instruction at pc, letting the fetch unit settle
  task automatic fetch_at(input logic [63:0] pc, output logic [31:0] got, output logic ok);
    begin
      // Wait a fixed number of cycles rather than spinning on insn_valid: the
      // fetch keeps the previous instruction valid while the new address is in
      // the same beat, so a spin returns a stale value.
      pc_i = pc;
      consume = 1'b0;
      repeat (12) @(posedge clk);
      #1;
      got = insn;
      ok = insn_valid;
    end
  endtask

  function automatic logic [31:0] expect_insn(input logic [63:0] pc);
    logic [63:0] b;
    begin
      b = mem_beat({pc[63:3], 3'b000});
      expect_insn = pc[2] ? b[63:32] : b[31:0];
    end
  endfunction

  logic [31:0] got;
  logic        ok;
  int          fails_before;

  initial begin
    redirect = 0; consume = 0; pause = 0; pc_i = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---- 1. sequential walk over several beats (cold misses) -------------
    for (int i = 0; i < 8; i++) begin
      fetch_at((i*4), got, ok);
      if (ok) chk("sequential fetch", got, expect_insn((i*4)));
    end

    // ---- 2. re-fetch a warm line (hits) ----------------------------------
    for (int i = 0; i < 8; i++) begin
      fetch_at((i*4), got, ok);
      if (ok) chk("warm fetch", got, expect_insn((i*4)));
    end

    // ---- 3. a redirect mid-stream ----------------------------------------
    pc_i = 64'h1000; redirect = 1'b1; @(posedge clk); #1; redirect = 1'b0;
    fetch_at(64'h1000, got, ok);
    if (ok) chk("after redirect", got, expect_insn(64'h1000));

    // ---- 4. back and forth between two lines that share a cache index ----
    // 0x000 and 0x2000 share addr[8:3] but differ in the tag
    fetch_at(64'h0000, got, ok);
    if (ok) chk("line A", got, expect_insn(64'h0000));
    fetch_at(64'h2000, got, ok);
    if (ok) chk("line B (evicts A)", got, expect_insn(64'h2000));
    fetch_at(64'h0000, got, ok);
    if (ok) chk("line A again (misses)", got, expect_insn(64'h0000));

    // ---- 5. back-to-back with no gap -------------------------------------
    for (int i = 0; i < 6; i++) begin
      fetch_at((i*8), got, ok);
      if (ok) chk("back-to-back", got, expect_insn((i*8)));
    end

    $display("tb_fetch_cache: %0d checks, %0d mismatches (hits=%0d misses=%0d)",
             checks, errors, hits, misses);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
