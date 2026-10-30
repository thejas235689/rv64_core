`timescale 1ns/1ps
interface flit_if (input logic clk);
  import pcie_flit_pkg::*;
  logic         rst_n;
  logic         in_valid, in_ready, in_last;
  logic [7:0]   in_byte;
  logic         flit_valid, flit_ready;
  pcie_flit_t   flit;

  clocking drv_cb @(posedge clk);
    output in_valid, in_byte, in_last, flit_ready;
    input  in_ready, flit_valid, flit;
  endclocking

  clocking mon_cb @(posedge clk);
    input in_valid, in_ready, in_last, in_byte, flit_valid, flit_ready, flit;
  endclocking
endinterface
