`timescale 1ns/1ps
module tb_dmi;
  logic clk = 0;
  always #5 clk = !clk;
  logic tms = 1, tdi = 0, rst_n = 0;
  logic tdo, halt, resume, step, ndmreset;
  logic [4:0] reg_addr;
  logic saw_resume = 0, saw_step = 0;
  logic unused_bit;
  logic [40:0] reply;

  rv64_dmi dut (
    .tck(clk), .tms(tms), .tdi(tdi), .tdo(tdo), .trst_n(rst_n),
    .dbg_halt_req(halt), .dbg_resume_req(resume), .dbg_step(step),
    .dbg_halted(halt), .dbg_reg_addr(reg_addr),
    .dbg_reg_data({59'd0, reg_addr}), .ndmreset(ndmreset)
  );
  always @(posedge clk) begin
    if (resume) saw_resume <= 1'b1;
    if (step) saw_step <= 1'b1;
  end

  task automatic tick(input logic mode, data, output logic sample);
    @(negedge clk);
    tms = mode;
    tdi = data;
    @(posedge clk);
    #1;
    sample = tdo;
  endtask

  task automatic advance(input logic mode);
    tick(mode, 0, unused_bit);
  endtask

  task automatic access_dmi(input logic [40:0] request, output logic [40:0] response);
    logic sample;
    advance(1); advance(0); advance(0);
    for (int i = 0; i < 41; i++) begin
      tick(i == 40, request[i], sample);
      response[i] = sample;
    end
    advance(1); advance(0); advance(0);
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    advance(0);
    advance(1); advance(1); advance(0); advance(0);
    for (int i = 0; i < 5; i++)
      tick(i == 4, (5'h11 >> i) & 5'd1 ? 1'b1 : 1'b0, unused_bit);
    advance(1); advance(0);
    access_dmi({2'b10, 32'h80000000, 7'h10}, reply);
    if (!halt) $fatal(1, "halt request missing");
    access_dmi({2'b10, 32'd17, 7'h20}, reply);
    if (reg_addr != 17) $fatal(1, "REGSEL write missing");
    access_dmi({2'b01, 32'd0, 7'h04}, reply);
    access_dmi(41'd0, reply);
    if (reply !== {2'b00, 32'd17, 7'h04}) $fatal(1, "DATA0 reply %h", reply);
    access_dmi({2'b10, 32'h44000000, 7'h10}, reply);
    advance(0);
    if (halt || !saw_resume || !saw_step) $fatal(1, "resume/step missing");
    $display("DMI transport checks passed");
    $finish;
  end
endmodule
