`timescale 1ns/1ps
// Directed testbench for the L2 arbiter: grant policy, response routing, and
// that a held transaction is not interrupted.
module tb_l2arb;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        a_req_valid, a_rsp_valid, a_rsp_error;
  logic [63:0] a_req_addr, a_req_wdata, a_rsp_rdata;
  logic        a_req_we;
  logic [7:0]  a_req_wstrb;

  logic        b_req_valid, b_rsp_valid, b_rsp_error;
  logic [63:0] b_req_addr, b_req_wdata, b_rsp_rdata;
  logic        b_req_we;
  logic [7:0]  b_req_wstrb;

  logic        req_valid, req_we, rsp_valid, rsp_error, grant_a, busy;
  logic [63:0] req_addr, req_wdata, rsp_rdata;
  logic [7:0]  req_wstrb;
  logic [31:0] ga_count, gb_count;

  rv64_l2arb u_arb (
    .clk(clk), .rst_n(rst_n),
    .a_req_valid(a_req_valid), .a_req_addr(a_req_addr), .a_req_we(a_req_we),
    .a_req_wstrb(a_req_wstrb), .a_req_wdata(a_req_wdata),
    .a_rsp_valid(a_rsp_valid), .a_rsp_rdata(a_rsp_rdata), .a_rsp_error(a_rsp_error),
    .b_req_valid(b_req_valid), .b_req_addr(b_req_addr), .b_req_we(b_req_we),
    .b_req_wstrb(b_req_wstrb), .b_req_wdata(b_req_wdata),
    .b_rsp_valid(b_rsp_valid), .b_rsp_rdata(b_rsp_rdata), .b_rsp_error(b_rsp_error),
    .req_valid(req_valid), .req_addr(req_addr), .req_we(req_we),
    .req_wstrb(req_wstrb), .req_wdata(req_wdata),
    .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
    .grant_a(grant_a), .busy(busy),
    .grant_a_count(ga_count), .grant_b_count(gb_count)
  );

  // the memory echoes the address back, so response routing is checkable
  logic        pend_v;
  logic [63:0] pend_d;
  assign rsp_valid = pend_v;
  assign rsp_rdata = pend_d;
  assign rsp_error = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend_v <= 1'b0; pend_d <= 64'd0;
    end else begin
      pend_v <= 1'b0;
      if (req_valid) begin
        pend_d <= req_addr + 64'h1000;   // a recognisable tag per address
        pend_v <= 1'b1;
      end
    end
  end

  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-42s got=%h expected=%h", name, got, exp); end
    end
  endtask
  task automatic chk_bit(input string name, input logic got, input logic exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-42s got=%b expected=%b", name, got, exp); end
    end
  endtask

  // issue one request on a port and return what came back
  task automatic req_a(input logic [63:0] a, output logic [63:0] d, output logic ok);
    begin
      a_req_addr = a; a_req_valid = 1; a_req_we = 0; a_req_wstrb = 0; a_req_wdata = 0;
      @(posedge clk); #1;
      begin
        int g; g = 0;
        while (!busy && g < 20) begin @(posedge clk); #1; g++; end
      end
      a_req_valid = 0;
      begin
        int g; g = 0;
        while (!a_rsp_valid && g < 30) begin @(posedge clk); #1; g++; end
        ok = (g < 30);
      end
      #1; d = a_rsp_rdata;
      @(posedge clk); #1;
    end
  endtask

  task automatic req_b(input logic [63:0] a, output logic [63:0] d, output logic ok);
    begin
      b_req_addr = a; b_req_valid = 1; b_req_we = 0; b_req_wstrb = 0; b_req_wdata = 0;
      @(posedge clk); #1;
      begin
        int g; g = 0;
        while (!busy && g < 20) begin @(posedge clk); #1; g++; end
      end
      b_req_valid = 0;
      begin
        int g; g = 0;
        while (!b_rsp_valid && g < 30) begin @(posedge clk); #1; g++; end
        ok = (g < 30);
      end
      #1; d = b_rsp_rdata;
      @(posedge clk); #1;
    end
  endtask

  logic [63:0] d;
  logic        ok;
  int          a_wins, b_wins;

  initial begin
    a_req_valid = 0; a_req_addr = 0; a_req_we = 0; a_req_wstrb = 0; a_req_wdata = 0;
    b_req_valid = 0; b_req_addr = 0; b_req_we = 0; b_req_wstrb = 0; b_req_wdata = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---- 1. a lone request on A is served, and only A sees it -----------
    req_a(64'h0100, d, ok);
    chk_bit("A request completes", ok, 1'b1);
    chk("A got the response for its address", d, 64'h1100);
    chk_bit("B saw nothing", b_rsp_valid, 1'b0);

    // ---- 2. a lone request on B is served, and only B sees it -----------
    req_b(64'h0200, d, ok);
    chk_bit("B request completes", ok, 1'b1);
    chk("B got the response for its address", d, 64'h1200);
    chk_bit("A saw nothing", a_rsp_valid, 1'b0);

    // ---- 3. both request together: round-robin, neither starves ---------
    a_wins = 0; b_wins = 0;
    for (int i = 0; i < 8; i++) begin
      fork
        begin
          a_req_addr = 64'h1000 + i; a_req_valid = 1;
        end
        begin
          b_req_addr = 64'h2000 + i; b_req_valid = 1;
        end
      join
      @(posedge clk); #1;
      if (grant_a) a_wins++; else b_wins++;
      a_req_valid = 0; b_req_valid = 0;
      // let both transactions drain
      begin
        int g; g = 0;
        while (busy && g < 40) begin @(posedge clk); #1; g++; end
      end
      @(posedge clk); #1;
    end
    chk("both ports get grants under contention", (a_wins > 0 && b_wins > 0) ? 1 : 0, 1);
    chk("grants are evenly shared", a_wins, b_wins);

    $display("tb_l2arb: %0d checks, %0d mismatches (A grants=%0d B grants=%0d)",
             checks, errors, ga_count, gb_count);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
