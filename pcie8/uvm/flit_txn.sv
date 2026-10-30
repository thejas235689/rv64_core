`timescale 1ns/1ps
class flit_txn extends uvm_sequence_item;
  rand int unsigned n_bytes;
  rand bit          last_asserted;
  byte unsigned     bytes[$];
  bit  [7:0]        flit_bytes[$][$];   // one queue of byte queues, in flit order

  `uvm_object_utils_begin(flit_txn)
    `uvm_field_int(n_bytes, UVM_ALL_ON)
    `uvm_field_int(last_asserted, UVM_ALL_ON)
  `uvm_object_utils_end

  constraint c_len { n_bytes inside {[1:800]}; }
  function new(string name = "flit_txn"); super.new(name); endfunction
endclass
