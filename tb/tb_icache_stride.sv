`timescale 1ns/1ps
module tb_icache_stride;
  logic clk = 0, rst_n = 0, req_valid = 0, invalidate = 0;
  logic req_ready, resp_valid, resp_miss, resp_error, fill_valid;
  logic fill_ready = 1, rsp_valid = 0, rsp_error = 0;
  logic [63:0] req_addr = 0, resp_data, fill_addr, rsp_data = 0;
  logic [31:0] hits, misses;
  int requests = 0;
  always #5 clk = !clk;

  rv64_icache #(.ENABLE_STRIDE_PREFETCH(1), .PREFETCH_BASE(64'h1000),
                .PREFETCH_LIMIT(64'h1100)) dut (
    .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_addr(req_addr),
    .req_ready(req_ready), .resp_valid(resp_valid), .resp_data(resp_data),
    .resp_miss(resp_miss), .resp_error(resp_error), .fill_valid(fill_valid),
    .fill_addr(fill_addr), .fill_ready(fill_ready), .fill_rsp_valid(rsp_valid),
    .fill_rsp_data(rsp_data), .fill_rsp_error(rsp_error), .invalidate(invalidate),
    .prefetch_enable(1'b1), .hit_count(hits), .miss_count(misses)
  );

  task automatic fetch(input logic [63:0] addr, input logic expect_miss);
    @(negedge clk);
    while (!req_ready) @(negedge clk);
    req_addr = addr;
    req_valid = 1;
    @(negedge clk);
    req_valid = 0;
    while (!resp_valid) @(negedge clk);
    if (resp_error || resp_miss !== expect_miss || resp_data !== ~addr)
      $fatal(1, "unexpected demand response for %h", addr);
  endtask

  // A response one cycle after acceptance; the directed sequence can withhold
  // acceptance or suppress responses to exercise the drain path.
  logic hold_response = 0, pending = 0;
  logic error_response = 0;
  logic [63:0] pending_addr;
  always @(posedge clk) begin
    rsp_valid <= 0;
    if (fill_valid && fill_ready) begin
      requests <= requests + 1;
      if (pending) $fatal(1, "duplicate outstanding request");
      pending_addr <= fill_addr;
      pending <= 1;
    end
    if (pending && !hold_response) begin
      rsp_valid <= 1;
      rsp_error <= error_response;
      rsp_data <= ~pending_addr;
      pending <= 0;
    end
  end

  initial begin
    repeat (2) @(negedge clk);
    rst_n = 1;
    fetch(64'h1000, 1);
    fetch(64'h1010, 1);
    fetch(64'h1020, 1);
    // 0x1030 is a speculative fill; it must not appear as a demand response.
    @(negedge clk);
    fill_ready = 0;
    wait (fill_valid && fill_addr == 64'h1030);
    repeat (3) begin
      @(negedge clk);
      if (!fill_valid || fill_addr != 64'h1030)
        $fatal(1, "prefetch address changed under backpressure");
    end
    fill_ready = 1;
    @(negedge clk);
    hold_response = 1;
    repeat (3) begin
      @(negedge clk);
      if (resp_valid || req_ready) $fatal(1, "speculative response escaped");
    end
    hold_response = 0;
    wait (req_ready);
    fetch(64'h1030, 0);
    if (hits != 1 || misses != 3 || requests != 4)
      $fatal(1, "prefetch incorrectly counted as a demand or repeated");

    // Start the next prefetch, invalidate it in flight, and ensure the stale
    // response drains before the subsequent demand refill.
    @(negedge clk);
    wait (fill_valid && fill_addr == 64'h1040);
    @(negedge clk);
    hold_response = 1;
    @(negedge clk);
    invalidate = 1;
    @(negedge clk);
    invalidate = 0;
    if (req_ready) $fatal(1, "accepted stale fill did not enter drain");
    hold_response = 0;
    fetch(64'h1040, 1);
    if (requests != 6) $fatal(1, "stale prefetch was reused");

    // Re-train near the configured boundary. 0x1100 is excluded.
    fetch(64'h10d0, 1);
    fetch(64'h10e0, 1);
    fetch(64'h10f0, 1);
    repeat (8) begin
      @(negedge clk);
      if (fill_valid) $fatal(1, "prefetch exceeded configured limit");
    end
    fetch(64'h1080, 1);
    fetch(64'h1070, 1);
    fetch(64'h1060, 1);
    @(negedge clk);
    wait (fill_valid && fill_addr == 64'h1050);
    error_response = 1;
    @(negedge clk);
    while (!req_ready) begin
      if (resp_valid) $fatal(1, "speculative fault escaped");
      @(negedge clk);
    end
    error_response = 0;
    fetch(64'h1050, 1);
    $display("I-cache stride prefetch checks passed");
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "timeout");
  end
endmodule
