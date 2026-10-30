`timescale 1ns/1ps
interface fp_if (input logic clk);
  logic        sub;
  logic [63:0] a, b;
  logic [63:0] result;
  logic        flag_invalid, flag_inexact;
endinterface
