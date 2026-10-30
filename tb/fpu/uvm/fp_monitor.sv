`timescale 1ns/1ps
class fp_monitor extends uvm_monitor;
  `uvm_component_utils(fp_monitor)
  virtual fp_if vif;
  uvm_analysis_port #(fp_txn) ap;
  function new(string name, uvm_component parent);
    super.new(name, parent); ap = new("ap", this);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fp_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no vif")
  endfunction
  task run_phase(uvm_phase phase);
    fp_txn t;
    forever begin
      @(posedge vif.clk); #1;
      t = fp_txn::type_id::create("obs");
      t.a = vif.a; t.b = vif.b; t.sub = vif.sub;
      t.got = vif.result;
      t.got_invalid = vif.flag_invalid;
      t.got_inexact = vif.flag_inexact;
      ap.write(t);
    end
  endtask
endclass
