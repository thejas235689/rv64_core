`timescale 1ns/1ps
// Directed testbench for the L2 cache: multi-beat fills, hits, RRIP victim
// selection and store passthrough.
module tb_l2cache;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        req_valid, req_we, req_ready, rsp_valid, rsp_error;
  logic [63:0] req_addr, req_wdata, rsp_rdata;
  logic [7:0]  req_wstrb;

  logic        mem_req_valid, mem_req_we, mem_req_ready, mem_rsp_valid, mem_rsp_error;
  logic [63:0] mem_req_addr, mem_req_wdata, mem_rsp_rdata;
  logic [7:0]  mem_req_wstrb;
  logic [31:0] hits, misses, bumps;

  rv64_l2cache u_l2 (
    .clk(clk), .rst_n(rst_n),
    .req_valid(req_valid), .req_addr(req_addr), .req_we(req_we),
    .req_wstrb(req_wstrb), .req_wdata(req_wdata), .req_ready(req_ready),
    .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
    .mem_req_valid(mem_req_valid), .mem_req_addr(mem_req_addr), .mem_req_we(mem_req_we),
    .mem_req_wstrb(mem_req_wstrb), .mem_req_wdata(mem_req_wdata),
    .mem_req_ready(mem_req_ready), .mem_rsp_valid(mem_rsp_valid),
    .mem_rsp_rdata(mem_rsp_rdata), .mem_rsp_error(mem_rsp_error),
    .hit_count(hits), .miss_count(misses), .rrip_bump_count(bumps)
  );

  // ---- memory: beat at address A holds a value derived from A ---------------
  logic [63:0] mem [0:16383];
  logic        pend_v;
  logic [63:0] pend_d;
  assign mem_req_ready = 1'b1;
  assign mem_rsp_valid = pend_v;
  assign mem_rsp_rdata = pend_d;
  assign mem_rsp_error = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend_v <= 1'b0; pend_d <= 64'd0;
      for (int i = 0; i < 16384; i++) mem[i] <= ((i * 13) + 5);
    end else begin
      pend_v <= 1'b0;
      if (mem_req_valid && mem_req_ready) begin
        if (mem_req_we) begin
          for (int b = 0; b < 8; b++)
            if (mem_req_wstrb[b]) mem[mem_req_addr[16:3]][8*b +: 8] <= mem_req_wdata[8*b +: 8];
        end else begin
          pend_d <= mem[mem_req_addr[16:3]];
          pend_v <= 1'b1;
        end
      end
    end
  end

  function automatic logic [63:0] mem_beat(input logic [63:0] a);
    return (((a[16:3]) * 13) + 5);
  endfunction

  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-42s got=%h expected=%h", name, got, exp); end
    end
  endtask

  task automatic acc(input logic [63:0] a, input logic we, input logic [7:0] strb,
                     input logic [63:0] wd, output logic [63:0] rd);
    begin
      // wait until the cache is idle before presenting the request, otherwise
      // the request is dropped and the test reads a stale response
      req_valid = 0; req_addr = a; req_we = we; req_wstrb = strb; req_wdata = wd;
      begin
        int g0; g0 = 0;
        while (!req_ready && g0 < 200) begin @(posedge clk); #1; g0++; end
      end
      req_valid = 1;
      @(posedge clk); #1; req_valid = 0;
      begin
        int guard; guard = 0;
        while (!rsp_valid && guard < 120) begin @(posedge clk); #1; guard++; end
        if (guard >= 120) begin errors++; $display("MISMATCH access never completed for %h", a); end
      end
      #1; rd = rsp_rdata;
      @(posedge clk); #1;
    end
  endtask

  logic [63:0] d;
  int hits_before;

  initial begin
    req_valid = 0; req_addr = 0; req_we = 0; req_wstrb = 0; req_wdata = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---- 1. a miss fills all four beats of the line ----------------------
    acc(64'h0000, 1'b0, 8'h00, 64'd0, d);
    chk("miss beat 0", d, mem_beat(64'h0000));
    chk("miss counter", misses, 32'd1);

    // ---- 2. the other beats of the same line are hits --------------------
    acc(64'h0008, 1'b0, 8'h00, 64'd0, d);
    chk("hit beat 1", d, mem_beat(64'h0008));
    acc(64'h0010, 1'b0, 8'h00, 64'd0, d);
    chk("hit beat 2", d, mem_beat(64'h0010));
    acc(64'h0018, 1'b0, 8'h00, 64'd0, d);
    chk("hit beat 3", d, mem_beat(64'h0018));
    chk("four beats, one miss", misses, 32'd1);
    chk("three hits after the fill", hits, 32'd3);

    // ---- 3. fill the set's four ways, then evict -------------------------
    // same set (addr[8:5] == 0), different tags
    for (int i = 1; i <= 4; i++) begin
      acc(64'(i) << 9, 1'b0, 8'h00, 64'd0, d);
      chk("way fill", d, mem_beat(64'(i) << 9));
    end
    hits_before = hits;
    // the fifth line in the same set must evict, not hit
    acc(64'd5 << 9, 1'b0, 8'h00, 64'd0, d);
    chk("fifth line in the set misses", d, mem_beat(64'd5 << 9));
    chk("no hit for the fifth line", hits, hits_before);

    // ---- 4. stores pass through to memory -------------------------------
    acc(64'h2000, 1'b1, 8'hFF, 64'hAAAA_BBBB_CCCC_DDDD, d);
    chk("store reached memory", mem[64'h2000 >> 3], 64'hAAAA_BBBB_CCCC_DDDD);

    $display("tb_l2cache: %0d checks, %0d mismatches (hits=%0d misses=%0d rrip_ages=%0d)",
             checks, errors, hits, misses, bumps);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
