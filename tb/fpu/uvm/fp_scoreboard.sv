`timescale 1ns/1ps
import fp_golden_pkg::*;   // file scope: an import inside the class is not honoured here

// The monitor observes the DUT and cannot know the expected value, so the oracle
// comes from the golden table by index: the sequence drives the vectors in order,
// so observation N must equal GEXP[N].
class fp_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(fp_scoreboard)
  uvm_analysis_imp #(fp_txn, fp_scoreboard) imp;
  int unsigned checked;
  int unsigned errors;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp = new("imp", this);
    checked = 0;
    errors  = 0;
  endfunction

  function void write(fp_txn t);
    bit [63:0] exp_val;
    if (checked >= NGOLD) return;
    exp_val = GEXP[checked];
    checked++;
    if (t.got !== exp_val) begin
      errors++;
      if (errors <= 6)
        `uvm_error("FP_MISMATCH",
          $sformatf("vec%0d: %016h %s %016h -> got %016h expected %016h",
                    checked-1, GA[checked-1], GSUB[checked-1] ? "-" : "+",
                    GB[checked-1], t.got, exp_val))
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SCOREBOARD",
      $sformatf("checked=%0d of %0d errors=%0d", checked, NGOLD, errors), UVM_LOW)
    if (errors != 0) `uvm_error("SCOREBOARD", "FP adder mismatches")
    else if (checked != NGOLD) `uvm_error("SCOREBOARD", "not all vectors observed")
  endfunction
endclass
