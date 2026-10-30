`timescale 1ns/1ps
class flit_env extends uvm_env;
  `uvm_component_utils(flit_env)
  flit_driver     drv;
  flit_monitor    mon;
  flit_scoreboard scb;
  uvm_sequencer #(flit_txn) seqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    drv = flit_driver::type_id::create("drv", this);
    mon = flit_monitor::type_id::create("mon", this);
    scb  = flit_scoreboard::type_id::create("scb", this);
    seqr = uvm_sequencer#(flit_txn)::type_id::create("seqr", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    mon.ap.connect(scb.imp);
    drv.seq_item_port.connect(seqr.seq_item_export);
  endfunction
endclass
