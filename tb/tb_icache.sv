`timescale 1ns/1ps
// Directed testbench for the direct-mapped instruction cache.
module tb_icache;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        req_valid;
  logic [63:0] req_addr;
  logic        req_ready, resp_valid, resp_miss;
  logic [63:0] resp_data;

  logic        fill_valid, fill_ready, fill_rsp_valid, fill_rsp_error;
  logic [63:0] fill_addr, fill_rsp_data;
  logic [31:0] hit_count, miss_count;

  rv64_icache u_cache (
    .clk(clk), .rst_n(rst_n),
    .req_valid(req_valid), .req_addr(req_addr), .req_ready(req_ready),
    .resp_valid(resp_valid), .resp_data(resp_data), .resp_miss(resp_miss),
    .fill_valid(fill_valid), .fill_addr(fill_addr), .fill_ready(fill_ready),
    .fill_rsp_valid(fill_rsp_valid), .fill_rsp_data(fill_rsp_data),
    .fill_rsp_error(fill_rsp_error),
    .hit_count(hit_count), .miss_count(miss_count)
  );

  // ---- backing memory: line data is derived from the line address ---------
  logic        err_next;
  logic        pend;
  assign fill_ready = 1'b1;
  assign fill_rsp_data = {fill_addr[63:8], fill_addr[7:3], 3'b000} ^ 64'hA5A5_0000_0000_0000;
  assign fill_rsp_valid = pend;
  assign fill_rsp_error = err_next;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pend <= 1'b0;
    else begin
      pend <= 1'b0;
      if (fill_valid && fill_ready) pend <= 1'b1;
    end
  end

  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-34s got=%h expected=%h", name, got, exp); end
    end
  endtask

  task automatic fetch(input logic [63:0] a, output logic [63:0] d, output logic m);
    begin
      req_valid = 1; req_addr = a;
      @(posedge clk); #1; req_valid = 0;
      begin
        int guard; guard = 0;
        while (!resp_valid && guard < 50) begin @(posedge clk); #1; guard++; end
        if (guard >= 50) begin errors++; $display("MISMATCH fetch never completed for %h", a); end
      end
      #1; d = resp_data; m = resp_miss;
      @(posedge clk); #1;
    end
  endtask

  function automatic logic [63:0] expected_data(input logic [63:0] a);
    return {a[63:8], a[7:3], 3'b000} ^ 64'hA5A5_0000_0000_0000;
  endfunction

  logic [63:0] d;
  logic        m;

  initial begin
    req_valid = 0; req_addr = 0; err_next = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---- 1. first access misses and fills --------------------------------
    fetch(64'h0000_0000_0000_0100, d, m);
    chk("cold access misses", m, 1'b1);
    chk("cold access data", d, expected_data(64'h100));
    chk("miss counter", miss_count, 32'd1);
    chk("hit counter", hit_count, 32'd0);

    // ---- 2. the same line now hits ---------------------------------------
    fetch(64'h0000_0000_0000_0100, d, m);
    chk("warm access hits", m, 1'b0);
    chk("warm access data", d, expected_data(64'h100));
    chk("hit counter after hit", hit_count, 32'd1);
    chk("miss counter after hit", miss_count, 32'd1);

    // ---- 3. a different line misses --------------------------------------
    fetch(64'h0000_0000_0000_0200, d, m);
    chk("second line misses", m, 1'b1);
    chk("second line data", d, expected_data(64'h200));

    // ---- 4. direct-mapped eviction: same index, different tag ------------
    // 0x100 and 0x300 both map to index 0x100>>3 & 0x3F = 0x20 -- wait, the
    // index is [8:3]; pick two addresses that differ only above bit 8.
    fetch(64'h0000_0000_0000_0500, d, m);
    chk("aliasing line misses (evicts)", m, 1'b1);
    chk("aliasing line data", d, expected_data(64'h500));
    // 0x100 shares index with 0x500 only if their [8:3] match, so use 0x400
    fetch(64'h0000_0000_0000_0400, d, m);
    // 0x400 and 0x500 differ in [8] -> different index; the eviction case is
    // 0x100 vs 0x100 + 0x2000 (same [8:3], different tag)
    fetch(64'h0000_0000_0000_2100, d, m);
    chk("same index different tag misses", m, 1'b1);
    fetch(64'h0000_0000_0000_0100, d, m);
    chk("original line evicted -> misses again", m, 1'b1);
    chk("re-fetched data correct", d, expected_data(64'h100));

    // ---- 5. an errored fill is not cached --------------------------------
    err_next = 1;
    fetch(64'h0000_0000_0000_0300, d, m);
    chk("errored fill misses", m, 1'b1);
    err_next = 0;
    fetch(64'h0000_0000_0000_0300, d, m);
    chk("errored line not cached -> misses again", m, 1'b1);
    fetch(64'h0000_0000_0000_0300, d, m);
    chk("good fill now hits", m, 1'b0);

    $display("tb_icache: %0d checks, %0d mismatches", checks, errors);
    $display("  hits=%0d misses=%0d", hit_count, miss_count);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
