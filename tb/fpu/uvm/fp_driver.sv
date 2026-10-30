`timescale 1ns/1ps
class fp_driver extends uvm_driver #(fp_txn);
  `uvm_component_utils(fp_driver)
  virtual fp_if vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fp_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no vif")
  endfunction
  task run_phase(uvm_phase phase);
    fp_txn t;
    forever begin
      seq_item_port.get_next_item(t);
      vif.a   <= t.a;
      vif.b   <= t.b;
      vif.sub <= t.sub;
      @(posedge vif.clk); #1;
      seq_item_port.item_done();
    end
  endtask
endclass
