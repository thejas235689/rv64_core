`timescale 1ns/1ps
class flit_monitor extends uvm_monitor;
  `uvm_component_utils(flit_monitor)
  virtual flit_if vif;
  uvm_analysis_port #(flit_txn) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual flit_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "virtual interface not set")
  endfunction

  task run_phase(uvm_phase phase);
    flit_txn t;
    int unsigned got;
    bit [7:0] b;
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.flit_valid) begin
        t = flit_txn::type_id::create("observed");
        t.flit_bytes.delete();
        for (int i = 0; i < 236; i++) begin
          b = vif.mon_cb.flit.tlp[(235-i)*8 +: 8];   // top byte first
          if (i == 0) begin t.flit_bytes.push_back({}); end
          t.flit_bytes[0].push_back(b);
        end
        got = t.flit_bytes.size();
        ap.write(t);
      end
    end
  endtask
endclass
