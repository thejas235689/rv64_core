`timescale 1ns/1ps
// Directed tests for FLIT packing: byte order within a flit, exact-fill, and a
// TLP spanning a flit boundary.
module tb_flit_pack
  import pcie_flit_pkg::*;
;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic in_valid = 1'b0, in_ready, in_last = 1'b0;
  logic [7:0] in_byte = 8'd0;
  logic flit_valid, flit_ready = 1'b0;
  pcie_flit_t flit;

  pcie_flit_pack u_dut (.clk(clk), .rst_n(rst_n),
                        .in_valid(in_valid), .in_ready(in_ready),
                        .in_byte(in_byte), .in_last(in_last),
                        .flit_valid(flit_valid), .flit_ready(flit_ready),
                        .flit(flit));

  int checks = 0, errors = 0;
  task automatic chk(input string n, input logic [63:0] got, input logic [63:0] exp);
    begin checks++; if (got !== exp) begin errors++;
      $display("MISMATCH %-26s got=%0h exp=%0h", n, got, exp); end end
  endtask

  // Push N bytes while draining flits as they appear. Doing these in one loop is
  // necessary: once a flit fills, in_ready drops, so a push-only loop deadlocks.
  pcie_flit_t captured [0:7];
  int n_cap;

  task automatic stream(input int n);
    int sent, cap;
    begin
      sent = 0; cap = 0;
      in_valid = 1'b0;
      flit_ready = 1'b1;     // always accept, so the DUT drains itself
      // Sample mid-cycle on the negedge: with flit_ready held high the flit is
      // valid for exactly one clock, and sampling after the posedge catches the
      // cycle in which it has already been consumed.
      while (sent < n || flit_valid) begin
        @(negedge clk);
        if (flit_valid) begin
          captured[cap] = flit;
          cap++;
        end
        @(posedge clk);
        // Keep in_valid asserted for the whole stream and let in_ready throttle.
        // Gating in_valid on in_ready dropped the byte in the cycle the DUT
        // deasserted ready, so the last byte of every flit was lost.
        if (sent < n) begin
          in_byte  = 8'(sent);
          in_valid = 1'b1;
          in_last  = (sent == n-1);
          if (in_ready) sent++;
        end else begin
          in_valid = 1'b0;
        end
      end
      // drain tail: the flit holding the last bytes appears a cycle after the
      // last byte is accepted, which is past the loop's exit condition
      in_valid = 1'b0;
      repeat (4) begin
        @(negedge clk);
        if (flit_valid) begin
          captured[cap] = flit;
          cap++;
        end
        @(posedge clk);
      end
      flit_ready = 1'b0;
      n_cap = cap;
    end
  endtask

  logic [7:0] top_byte, second_byte;

  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // ---- 1. a full flit: first byte lands in the TOP of the packed region --
    stream(FLIT_TLP_BYTES);
    chk("1 one flit produced", n_cap, 1);
    top_byte    = captured[0].tlp[FLIT_TLP_BYTES*8-1 -: 8];
    second_byte = captured[0].tlp[FLIT_TLP_BYTES*8-9 -: 8];
    chk("1 first byte in top",     {56'd0, top_byte},    64'd0);
    chk("1 second byte next down", {56'd0, second_byte}, 64'd1);
    chk("1 last byte in bottom",   {56'd0, captured[0].tlp[7:0]},
       64'(FLIT_TLP_BYTES-1));

    // ---- 2. a TLP spanning the boundary: 300 bytes = 236 + 64 -----------
    stream(300);
    chk("2 two flits produced", n_cap, 2);
    chk("2 flit0 top byte",  {56'd0, captured[0].tlp[FLIT_TLP_BYTES*8-1 -: 8]}, 64'd0);
    chk("2 flit0 last byte", {56'd0, captured[0].tlp[7:0]}, 64'(FLIT_TLP_BYTES-1));
    chk("2 flit1 first byte", {56'd0, captured[1].tlp[FLIT_TLP_BYTES*8-1 -: 8]},
        64'(FLIT_TLP_BYTES));
    chk("2 flit1 last byte",  {56'd0, captured[1].tlp[7:0]}, 64'd63);

    $display("tb_flit_pack: %0d checks, %0d mismatches", checks, errors);
    $display(errors == 0 ? "RESULT: PASS" : "RESULT: FAIL");
    $finish;
  end
endmodule
