`timescale 1ns/1ps
class flit_driver extends uvm_driver #(flit_txn);
  `uvm_component_utils(flit_driver)
  virtual flit_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual flit_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "virtual interface not set")
  endfunction

  task run_phase(uvm_phase phase);
    flit_txn t;
    int sent;
    forever begin
      seq_item_port.get_next_item(t);
      sent = 0;
      vif.drv_cb.flit_ready <= 1'b1;      // always accept, so the DUT self-drains
      while (sent < t.n_bytes) begin
        @(vif.drv_cb);
        if (vif.drv_cb.in_ready) begin
          vif.drv_cb.in_byte  <= 8'(sent);
          vif.drv_cb.in_valid <= 1'b1;
          vif.drv_cb.in_last  <= (sent == t.n_bytes-1) && t.last_asserted;
          sent++;
        end else begin
          vif.drv_cb.in_valid <= 1'b0;
        end
      end
      @(vif.drv_cb);
      vif.drv_cb.in_valid <= 1'b0;
      repeat (4) @(vif.drv_cb);
      vif.drv_cb.flit_ready <= 1'b0;
      seq_item_port.item_done();
    end
  endtask
endclass
