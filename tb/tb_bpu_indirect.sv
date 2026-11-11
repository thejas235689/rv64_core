`timescale 1ns/1ps

module tb_bpu_indirect;
  logic clk = 0;
  always #5 clk = !clk;
  logic rst_n = 0;
  logic [63:0] lookup_pc, pred_target;
  logic pred_taken;
  logic upd_valid, upd_taken, upd_is_cond, upd_is_uncond, upd_is_indirect;
  logic [63:0] upd_pc, upd_target;

  localparam logic [63:0] JALR_PC = 64'h1002;
  localparam logic [63:0] TARGET_A = 64'h2000;
  localparam logic [63:0] TARGET_B = 64'h3000;
  localparam logic [63:0] TARGET_C = 64'h4000;

  rv64_bpu dut (
    .clk(clk), .rst_n(rst_n),
    .lookup_pc(lookup_pc), .pred_taken(pred_taken), .pred_target(pred_target),
    .upd_valid(upd_valid), .upd_pc(upd_pc), .upd_taken(upd_taken), .upd_target(upd_target),
    .upd_is_cond(upd_is_cond), .upd_is_uncond(upd_is_uncond),
    .upd_is_indirect(upd_is_indirect), .upd_is_call(1'b0), .upd_is_ret(1'b0)
  );

  task automatic resolve_branch(input logic [63:0] pc, target,
                                input logic taken, conditional, indirect);
    @(negedge clk);
    upd_valid = 1;
    upd_pc = pc;
    upd_target = target;
    upd_taken = taken;
    upd_is_cond = conditional;
    upd_is_uncond = !conditional;
    upd_is_indirect = indirect;
    @(negedge clk);
    upd_valid = 0;
  endtask

  task automatic set_history(input logic [7:0] history);
    for (int i = 7; i >= 0; i--)
      resolve_branch(64'h10c, 64'h120, history[i], 1, 0);
  endtask

  task automatic train(input logic [7:0] history, input logic [63:0] target);
    set_history(history);
    resolve_branch(JALR_PC, target, 1, 0, 1);
  endtask

  task automatic expect_target(input logic [63:0] target);
    lookup_pc = JALR_PC;
    #1;
    if (!pred_taken || pred_target !== target)
      $fatal(1, "expected target %h, got taken=%b target=%h", target, pred_taken, pred_target);
  endtask

  initial begin
    lookup_pc = JALR_PC;
    upd_valid = 0;
    upd_taken = 0;
    upd_pc = 0;
    upd_target = 0;
    upd_is_cond = 0;
    upd_is_uncond = 0;
    upd_is_indirect = 0;
    repeat (2) @(negedge clk);
    rst_n = 1;

    // A cold or unconfident context falls back to the last resolved target.
    train(8'h00, TARGET_A);
    train(8'hff, TARGET_B);
    set_history(8'h00);
    expect_target(TARGET_B);

    train(8'h00, TARGET_A);
    train(8'hff, TARGET_B);
    set_history(8'h00);
    expect_target(TARGET_A);
    set_history(8'hff);
    expect_target(TARGET_B);

    // A changed target needs to earn confidence again.
    train(8'h00, TARGET_C);
    train(8'hff, TARGET_B);
    set_history(8'h00);
    expect_target(TARGET_B);
    train(8'h00, TARGET_C);
    train(8'hff, TARGET_B);
    set_history(8'h00);
    expect_target(TARGET_C);

    // An adjacent halfword PC cannot reuse the learned JALR target.
    lookup_pc = JALR_PC - 64'd2;
    #1;
    if (pred_taken) $fatal(1, "adjacent halfword PC hit a stale target");

    // A direct jump at a rewritten site uses its own target.
    resolve_branch(JALR_PC, TARGET_A, 1, 0, 0);
    set_history(8'h00);
    expect_target(TARGET_A);

    $display("PASS: indirect target context, confidence, halfword tags, direct fallback");
    $finish;
  end
endmodule
