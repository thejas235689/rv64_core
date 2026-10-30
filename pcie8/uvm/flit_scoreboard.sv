`timescale 1ns/1ps
// Independently predicts what each flit must contain and compares.
//
// The prediction is written from the SPECIFICATION of the packing, not from the
// DUT: byte N of the stream belongs at position N within the flit, counting from
// the TOP. That is the property the RTL has to satisfy.
class flit_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(flit_scoreboard)
  uvm_analysis_imp #(flit_txn, flit_scoreboard) imp;

  int unsigned flits_seen;
  int unsigned errors;
  int unsigned expect_stream_start;   // first stream byte for the next flit

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp = new("imp", this);
    flits_seen = 0;
    errors = 0;
    expect_stream_start = 0;
  endfunction

  function void write(flit_txn t);
    bit [7:0] exp_b;
    flits_seen++;
    for (int i = 0; i < 236; i++) begin
      exp_b = 8'(expect_stream_start + i);
      if (t.flit_bytes[0][i] !== exp_b) begin
        errors++;
        if (errors <= 4)
          `uvm_error("FLIT_ORDER",
            $sformatf("flit %0d byte %0d: got %02h expected %02h",
                      flits_seen-1, i, t.flit_bytes[0][i], exp_b))
      end
    end
    expect_stream_start += 236;
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SCOREBOARD",
      $sformatf("flits=%0d byte-errors=%0d", flits_seen, errors), UVM_LOW)
    if (errors != 0) `uvm_error("SCOREBOARD", "flit byte ordering mismatch")
  endfunction
endclass
