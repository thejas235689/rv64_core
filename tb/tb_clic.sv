// Directed testbench for rv64_clic: arbitration, edge vs level, acknowledge.
`timescale 1ns/1ps
module tb_clic;
  localparam int NSRC = 8;
  logic clk = 0, rst_n = 0;
  logic [NSRC-1:0] src = '0;
  logic cfg_we = 0; logic [3:0] cfg_addr = 0; logic [15:0] cfg_wdata = 0;
  logic irq, cause_valid; logic [3:0] cause_id;
  logic ack = 0; logic [3:0] ack_id = 0;

  rv64_clic #(.NSRC(NSRC)) dut (
    .clk(clk), .rst_n(rst_n), .src(src),
    .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
    .irq(irq), .cause_id(cause_id), .cause_valid(cause_valid),
    .ack(ack), .ack_id(ack_id)
  );
  always #5 clk = ~clk;

  integer errors = 0, checks = 0;
  task automatic chk(input string nm, input logic cond);
    begin checks = checks + 1;
      if (!cond) begin errors = errors + 1; $display("CLIC_FAIL %s", nm); end
    end
  endtask

  task automatic set_level(input int i, input logic [2:0] lv);
    begin @(posedge clk); cfg_we = 1; cfg_addr = i[3:0]; cfg_wdata = {12'd0, lv};
          @(posedge clk); cfg_we = 0; end
  endtask
  task automatic set_edge(input int i, input logic e);
    begin @(posedge clk); cfg_we = 1; cfg_addr = 4'h8 | i[3:0]; cfg_wdata = {11'd0, 1'b0, e};
          @(posedge clk); cfg_we = 0; end
  endtask
  task automatic do_ack(input int i);
    begin @(posedge clk); ack = 1; ack_id = i[3:0]; @(posedge clk); ack = 0; end
  endtask

  initial begin
    repeat (3) @(posedge clk); rst_n = 1; @(posedge clk);

    // ---- level 0 everywhere: no interrupt ----------------------------------
    src = 8'b0000_0001; @(posedge clk); @(posedge clk);
    chk("level 0 does not raise irq", irq === 1'b0);

    // ---- give source 0 a priority, expect it delivered ---------------------
    set_level(0, 3'd2);
    @(posedge clk); @(posedge clk);
    chk("source 0 raises irq", irq === 1'b1);
    chk("cause_id is 0", cause_id === 4'd0);
    chk("cause_valid", cause_valid === 1'b1);
    src = '0;                       // level source: deassert, then ack
    @(posedge clk);
    do_ack(0);
    @(posedge clk); @(posedge clk);
    chk("deasserted level source clears", irq === 1'b0);

    // ---- priority: higher level wins --------------------------------------
    set_level(1, 3'd1);
    set_level(3, 3'd5);
    src = 8'b0000_1010; @(posedge clk); @(posedge clk);
    chk("higher level wins (3 over 1)", cause_id === 4'd3);
    src = 8'b0000_0010; do_ack(3); @(posedge clk); @(posedge clk);
    chk("lower source delivered after ack", cause_id === 4'd1);
    do_ack(1); src = '0; @(posedge clk); @(posedge clk);

    // ---- edge: a pulse sets pending and it STAYS after the source drops ---
    set_edge(5, 1'b1);
    set_level(5, 3'd4);
    @(posedge clk);
    src = 8'b0010_0000;
    @(posedge clk);                  // src_q captures the high level here
    @(posedge clk);                  // rising edge detected on this one
    src = '0;
    @(posedge clk); @(posedge clk);
    chk("edge source latches pending", irq === 1'b1);
    chk("edge cause_id is 5", cause_id === 4'd5);
    do_ack(5);
    @(posedge clk); @(posedge clk);
    chk("ack clears an edge source", irq === 1'b0);

    $display("CLIC_RESULT checks=%0d errors=%0d", checks, errors);
    if (errors == 0) $display("CLIC: PASS"); else $display("CLIC: FAIL");
    $finish;
  end
endmodule
