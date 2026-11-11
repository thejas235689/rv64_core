`timescale 1ns/1ps
module tb_icache_hit_under_miss;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0, invalidate = 0;
  logic req_valid = 0, req_ready;
  logic [63:0] req_addr = 0, resp_data, fill_addr;
  logic [3:0] req_id = 0, resp_id;
  logic resp_valid, resp_miss, resp_error, fill_valid;
  logic fill_rsp_valid = 0, fill_rsp_error = 0;
  logic [63:0] fill_rsp_data = 0;
  logic [31:0] hits, misses;

  rv64_icache #(.ENABLE_HIT_UNDER_MISS(1'b1)) dut (
    .clk(clk), .rst_n(rst_n), .invalidate(invalidate), .prefetch_enable(1'b0),
    .req_valid(req_valid), .req_ready(req_ready), .req_addr(req_addr), .req_id(req_id),
    .resp_valid(resp_valid), .resp_data(resp_data), .resp_id(resp_id),
    .resp_miss(resp_miss), .resp_error(resp_error),
    .fill_valid(fill_valid), .fill_addr(fill_addr), .fill_ready(1'b1),
    .fill_rsp_valid(fill_rsp_valid), .fill_rsp_data(fill_rsp_data), .fill_rsp_error(fill_rsp_error),
    .hit_count(hits), .miss_count(misses)
  );

  task automatic cycle;
    @(posedge clk);
    #1;
  endtask

  task automatic request(input logic [63:0] address, input logic [3:0] id);
    req_valid = 1;
    req_addr = address;
    req_id = id;
    #1;
    if (!req_ready) $fatal(1, "expected ready for ID %0d", id);
    cycle();
    req_valid = 0;
  endtask

  task automatic check_response(input logic [3:0] id, input logic [63:0] data,
                                 input logic miss, input logic err);
    if (!resp_valid || resp_id !== id || resp_data !== data ||
        resp_miss !== miss || resp_error !== err)
      $fatal(1, "unexpected response valid=%b id=%0d data=%h miss=%b err=%b",
             resp_valid, resp_id, resp_data, resp_miss, resp_error);
  endtask

  initial begin
    repeat (2) cycle();
    rst_n = 1;
    request(64'h1000, 4'd1);
    if (!fill_valid || fill_addr != 64'h1000) $fatal(1, "warmup refill");
    cycle();
    fill_rsp_valid = 1;
    fill_rsp_data = 64'h1234;
    cycle();
    fill_rsp_valid = 0;
    check_response(4'd1, 64'h1234, 1, 0);
    cycle();

    // An aliasing refill leaves the previous cache line readable until commit.
    request(64'h1200, 4'd2);
    if (!fill_valid || fill_addr != 64'h1200) $fatal(1, "demand refill");
    cycle();
    req_addr = 64'h1008;
    #1;
    if (req_ready) $fatal(1, "second miss accepted");
    request(64'h1000, 4'd3);
    check_response(4'd3, 64'h1234, 0, 0);
    request(64'h1000, 4'd4);
    check_response(4'd4, 64'h1234, 0, 0);

    fill_rsp_valid = 1;
    fill_rsp_error = 1;
    fill_rsp_data = 64'hdead;
    #1;
    if (req_ready) $fatal(1, "hit accepted on refill completion");
    cycle();
    fill_rsp_valid = 0;
    fill_rsp_error = 0;
    check_response(4'd2, 64'hdead, 1, 1);
    cycle();

    request(64'h1200, 4'd5);
    cycle();
    request(64'h1000, 4'd6);
    check_response(4'd6, 64'h1234, 0, 0);
    invalidate = 1;
    #1;
    if (resp_valid || req_ready) $fatal(1, "invalidation exposed stale transaction");
    cycle();
    invalidate = 0;
    fill_rsp_valid = 1;
    cycle();
    fill_rsp_valid = 0;
    if (resp_valid || hits != 3 || misses != 3)
      $fatal(1, "invalidated refill returned or counters incorrect");

    $display("I-cache tagged hit-under-miss checks passed");
    $finish;
  end
endmodule
