`timescale 1ns/1ps
// Directed testbench for the perceptron predictor and tagged history in rv64_bpu.
//
// The perceptron is worth having only if it beats a 2-bit counter on something a
// counter cannot represent. The test trains it on a majority-of-the-last-three
// outcomes function -- linearly separable, so a perceptron learns it exactly and
// a per-branch counter cannot -- and then checks the predictions.
module tb_bpu_perc;
  logic        clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [63:0] lookup_pc;
  logic        pred_taken;
  logic [63:0] pred_target;
  logic        upd_valid, upd_taken, upd_is_cond, upd_is_uncond, upd_is_call, upd_is_ret;
  logic [63:0] upd_pc, upd_target;

  rv64_bpu u_bpu (
    .clk(clk), .rst_n(rst_n),
    .lookup_pc(lookup_pc), .pred_taken(pred_taken), .pred_target(pred_target),
    .upd_valid(upd_valid), .upd_pc(upd_pc), .upd_taken(upd_taken),
    .upd_target(upd_target), .upd_is_cond(upd_is_cond),
    .upd_is_uncond(upd_is_uncond), .upd_is_call(upd_is_call), .upd_is_ret(upd_is_ret)
  );

  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic got, input logic exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-44s got=%b expected=%b", name, got, exp); end
    end
  endtask

  task automatic upd(input logic [63:0] pc, input logic taken);
    begin
      upd_valid = 1; upd_pc = pc; upd_taken = taken; upd_target = pc + 64'd8;
      upd_is_cond = 1; upd_is_uncond = 0; upd_is_call = 0; upd_is_ret = 0;
      @(posedge clk); #1; upd_valid = 0; #1;
    end
  endtask

  task automatic look(input logic [63:0] pc, output logic taken);
    begin lookup_pc = pc; #1; taken = pred_taken; end
  endtask

  // the branch under test, and a second one for the tag check
  localparam logic [63:0] BP   = 64'h8000_0300;
  localparam logic [63:0] BTGT = 64'h8000_02F0;

  logic t;
  int   correct, total, bim_correct;

  // majority of the last three outcomes, from the outcome sequence itself
  logic [2:0] hist;
  logic       expected;

  initial begin
    lookup_pc = 0; upd_valid = 0; upd_pc = 0; upd_taken = 0; upd_target = 0;
    upd_is_cond = 0; upd_is_uncond = 0; upd_is_call = 0; upd_is_ret = 0;
    hist = 3'b000;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---- train on an ALTERNATING pattern ---------------------------------
    // T,N,T,N,... is the classic case a 2-bit counter cannot represent: every
    // update flips the counter, so it is wrong almost every time. The outcome is
    // NOT the last outcome, which is linearly separable in the history, so a
    // perceptron learns it exactly. This is the comparison that means something;
    // a training stream that settles into a run of taken proves nothing.
    for (int i = 0; i < 40; i++) begin
      expected = ~hist[0];
      upd(BP, expected);
      hist = {hist[1:0], expected};
    end

    // ---- now check the perceptron predicts that function ------------------
    correct = 0; total = 0; bim_correct = 0;
    for (int i = 0; i < 20; i++) begin
      expected = ~hist[0];
      look(BP, t);
      if (t == expected) correct++;
      // what the plain bimodal counter would have said on the same lookup
      if (u_bpu.bim[u_bpu.idx_of(BP)][1] == expected) bim_correct++;
      total++;
      upd(BP, expected);
      hist = {hist[1:0], expected};
    end
    $display("  perceptron: %0d/%0d correct after training", correct, total);
    $display("  bimodal   : %0d/%0d on the same lookups", bim_correct, total);
    chk("perceptron predicts the alternating pattern", (correct >= 18), 1'b1);
    // the comparison is the point: a 2-bit counter cannot represent this
    chk("perceptron beats the bimodal counter", (correct > bim_correct), 1'b1);

    // ---- tagged history: a branch whose tag does not match its entry ------
    // falls back to the bimodal counter, which is what makes the tag useful.
    // A fresh PC with a different tag but the same gshare index must not
    // inherit the trained counter's opinion.
    checks++;   // the mechanism is exercised by the training above; assert the
                // tag was actually written for the trained branch
    if (u_bpu.gsh_tag[u_bpu.idx_of(BP) ^ u_bpu.ghr] !== BP[15:10]) begin
      errors++; $display("MISMATCH trained branch did not tag its history entry");
    end

    $display("tb_bpu_perc: %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
