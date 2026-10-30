`timescale 1ns/1ps
class fp_txn extends uvm_sequence_item;
  rand bit [63:0] a, b;
  rand bit        sub;
  bit [63:0]      exp_val;      // from the golden table, not from the DUT
  bit [63:0]      got;
  bit             got_invalid, got_inexact;
  string          tag;

  `uvm_object_utils_begin(fp_txn)
    `uvm_field_int(a, UVM_ALL_ON)
    `uvm_field_int(b, UVM_ALL_ON)
    `uvm_field_int(sub, UVM_ALL_ON)
  `uvm_object_utils_end
  function new(string name = "fp_txn"); super.new(name); endfunction
endclass
