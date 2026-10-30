`timescale 1ns/1ps
// Directed testbench for the loop predictor inside rv64_bpu.
//
// A counted loop is taken N-1 times and not taken on the last iteration. The
// tournament predictor cannot learn that from per-branch history, so it
// mispredicts the exit every pass. The loop predictor learns the trip count and
// predicts the exit directly. This checks it does that, and -- just as important
// -- that it does NOT override the tournament for a branch that is not a loop.
module tb_bpu_loop;

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
      if (got !== exp) begin errors++; $display("MISMATCH %-30s got=%b expected=%b", name, got, exp); end
    end
  endtask

  // one conditional-branch update
  task automatic upd(input logic [63:0] pc, input logic taken, input logic [63:0] tgt);
    begin
      upd_valid = 1; upd_pc = pc; upd_taken = taken; upd_target = tgt;
      upd_is_cond = 1; upd_is_uncond = 0; upd_is_call = 0; upd_is_ret = 0;
      @(posedge clk); #1; upd_valid = 0; #1;
    end
  endtask

  // one lookup
  task automatic look(input logic [63:0] pc, output logic taken, output logic [63:0] tgt);
    begin lookup_pc = pc; #1; taken = pred_taken; tgt = pred_target; end
  endtask

  // The BTB is indexed by pc[7:2], so these must not collide there or one
  // branch trains the other's entry.
  localparam logic [63:0] LOOP_PC = 64'h8000_0100;      // btb idx 0
  localparam logic [63:0] LOOP_TGT = 64'h8000_00F0;     // backwards: a real loop
  localparam logic [63:0] STRAIGHT_PC = 64'h8000_0144;  // btb idx 0x11
  localparam logic [63:0] STRAIGHT_TGT = 64'h8000_0300;
  localparam logic [63:0] TRIP3_PC = 64'h8000_0480;     // btb idx 0x20

  int n;
  logic t;
  logic [63:0] tg;
  int mispred;

  initial begin
    lookup_pc = 0; upd_valid = 0; upd_pc = 0; upd_taken = 0; upd_target = 0;
    upd_is_cond = 0; upd_is_uncond = 0; upd_is_call = 0; upd_is_ret = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---- 1. before training, the exit is not predicted -------------------
    look(LOOP_PC, t, tg);
    chk("untrained: no loop engagement", t, 1'b0);

    // ---- 2. train a 5-iteration loop three times -------------------------
    // each pass: 4 taken (iterations 1..4), then the 5th is not taken
    for (int pass = 0; pass < 3; pass++) begin
      for (int i = 0; i < 4; i++) upd(LOOP_PC, 1'b1, LOOP_TGT);
      upd(LOOP_PC, 1'b0, LOOP_TGT);
    end

    // ---- 3. now the predictor must call the exit -------------------------
    // The pipeline looks up before it updates the same instruction, so the two
    // are interleaved here as well: a lookup on its own never advances the
    // iteration counter.
    mispred = 0;
    for (int i = 0; i < 4; i++) begin
      look(LOOP_PC, t, tg);
      if (t !== 1'b1) mispred++;
      if (tg !== LOOP_TGT) mispred++;
      upd(LOOP_PC, 1'b1, LOOP_TGT);
    end
    chk("loop: 4 taken iterations predicted taken at the loop head", (mispred == 0), 1'b1);

    look(LOOP_PC, t, tg);
    chk("loop: exit predicted not-taken", t, 1'b0);
    chk("loop: exit target is pc+4", (tg == LOOP_PC + 64'd4), 1'b1);
    upd(LOOP_PC, 1'b0, LOOP_TGT);

    // ---- 4. a branch that is never not-taken must not engage the loop table
    // (no not-taken update means no trip count is ever learned)
    for (int i = 0; i < 8; i++) upd(STRAIGHT_PC, 1'b1, STRAIGHT_TGT);
    look(STRAIGHT_PC, t, tg);
    chk("straight: still predicted taken", t, 1'b1);
    chk("straight: target from the BTB", (tg == STRAIGHT_TGT), 1'b1);

    // ---- 5. a different trip count is relearned --------------------------
    // train a 3-iteration loop on another PC
    for (int pass = 0; pass < 3; pass++) begin
      upd(TRIP3_PC, 1'b1, 64'h8000_03F0);
      upd(TRIP3_PC, 1'b1, 64'h8000_03F0);
      upd(TRIP3_PC, 1'b0, 64'h8000_03F0);
    end
    look(TRIP3_PC, t, tg);
    chk("trip3: first iteration taken", t, 1'b1);
    upd(TRIP3_PC, 1'b1, 64'h8000_03F0);
    look(TRIP3_PC, t, tg);
    chk("trip3: second iteration taken", t, 1'b1);
    upd(TRIP3_PC, 1'b1, 64'h8000_03F0);
    look(TRIP3_PC, t, tg);
    chk("trip3: third iteration is the exit", t, 1'b0);

    $display("tb_bpu_loop: %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
