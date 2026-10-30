`timescale 1ns/1ps
class fp_env extends uvm_env;
  `uvm_component_utils(fp_env)
  fp_driver drv; fp_monitor mon; fp_scoreboard scb; uvm_sequencer #(fp_txn) seqr;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    drv  = fp_driver::type_id::create("drv", this);
    mon  = fp_monitor::type_id::create("mon", this);
    scb  = fp_scoreboard::type_id::create("scb", this);
    seqr = uvm_sequencer#(fp_txn)::type_id::create("seqr", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    mon.ap.connect(scb.imp);
    drv.seq_item_port.connect(seqr.seq_item_export);
  endfunction
endclass
