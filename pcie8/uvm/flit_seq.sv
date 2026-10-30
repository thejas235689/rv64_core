`timescale 1ns/1ps
class flit_seq extends uvm_sequence #(flit_txn);
  `uvm_object_utils(flit_seq)
  int unsigned n;
  function new(string name = "flit_seq"); super.new(name); n = 236; endfunction
  task body();
    flit_txn t;
    repeat (2) begin
      t = flit_txn::type_id::create("t");
      start_item(t);
      if (!t.randomize() with { n_bytes == n; last_asserted == 1'b1; })
        `uvm_error("SEQ", "randomize failed")
      finish_item(t);
    end
  endtask
endclass
