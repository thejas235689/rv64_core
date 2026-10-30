`timescale 1ns/1ps
import fp_golden_pkg::*;
class fp_golden_seq extends uvm_sequence #(fp_txn);
  `uvm_object_utils(fp_golden_seq)
  function new(string name = "fp_golden_seq"); super.new(name); endfunction
  task body();
    fp_txn t;
    for (int i = 0; i < NGOLD; i++) begin
      t = fp_txn::type_id::create("t");
      start_item(t);
      t.a = GA[i]; t.b = GB[i]; t.sub = GSUB[i]; t.exp_val = GEXP[i];
      t.tag = $sformatf("vec%0d", i);
      finish_item(t);
    end
  endtask
endclass
