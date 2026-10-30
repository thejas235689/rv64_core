`timescale 1ns/1ps
// Known-answer testbench for the RVC expander.
//
// Every expected 32-bit form is computed independently (an encoder written from the
// ISA, not from the DUT's output), so this grades the expansion against the spec
// rather than against itself.
module tb_rvc;
  logic [15:0] cin;
  logic [31:0] cout;
  logic        illegal, is_ebreak;

  rv64_rvc_expand u_dut (.cin(cin), .cout(cout), .illegal(illegal), .is_ebreak(is_ebreak));

  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic [15:0] c,
                     input logic [31:0] exp);
    begin
      cin = c; #1;
      checks++;
      if (cout !== exp || illegal) begin
        errors++;
        $display("MISMATCH %-18s cin=%04x got=%08x expected=%08x illegal=%b",
                 name, c, cout, exp, illegal);
      end
    end
  endtask

  task automatic chk_ill(input string name, input logic [15:0] c);
    begin
      cin = c; #1;
      checks++;
      if (!illegal) begin
        errors++;
        $display("MISMATCH %-18s cin=%04x should be illegal, got %08x", name, c, cout);
      end
    end
  endtask

  initial begin
    cin = 16'd0;
    // ---- register / immediate forms -------------------------------------
    chk("c.nop",       16'h0001, 32'h00000013);
    chk("c.addi x1,1", 16'h0085, 32'h00108093);
    chk("c.li x1,5",   16'h4095, 32'h00500093);
    chk("c.mv x1,x2",  16'h808a, 32'h002000b3);
    chk("c.add x1,x2", 16'h908a, 32'h002080b3);
    chk("c.jr x1",     16'h8082, 32'h00008067);
    chk("c.swsp x1,0", 16'hc006, 32'h00112023);

    // ---- control transfer: the immediates are scrambled, so these matter --
    chk("c.j +8",      16'ha021, 32'h0080006f);
    chk("c.beqz x8,+8",16'hc401, 32'h00040463);
    chk("c.bnez x9,+8",16'he481, 32'h00049463);

    // ---- ebreak is flagged as well as expanded ---------------------------
    cin = 16'h9002; #1;
    checks++;
    if (!is_ebreak || cout !== 32'h00100073) begin
      errors++; $display("MISMATCH c.ebreak flag");
    end

    // ---- reserved encodings must be illegal, not silently expanded ------
    chk_ill("all-zero (illegal)", 16'h0000);
    chk_ill("quadrant 3",         16'hFFFF);

    $display("tb_rvc: %0d checks, %0d mismatches", checks, errors);
    $display(errors == 0 ? "RESULT: PASS" : "RESULT: FAIL");
    $finish;
  end
endmodule
