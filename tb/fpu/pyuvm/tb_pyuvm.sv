`timescale 1ns/1ps
module tb_pyuvm;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic        sub;
  logic [63:0] a, b, result;
  logic        flag_invalid, flag_inexact;

  rv64_fp_add u_dut (.sub(sub), .a(a), .b(b), .result(result),
                     .flag_invalid(flag_invalid), .flag_inexact(flag_inexact));
endmodule
