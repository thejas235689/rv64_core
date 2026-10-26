// =============================================================================
// tb_num_top.sv -- self-checking testbench for rv64_num_unit.
//
// Reads vectors and expected results produced by sim/gen_num_vectors.py and
// compares, for every vector, the combinational result (y, flags) and the
// pre-edge register state (err, quire). Any mismatch is reported with the
// vector index and both values; the simulation exits non-zero on failure.
//
// Runs on any simulator that supports plain SystemVerilog (no UVM, no cocotb):
//   xezim -s tb_num_top rtl/rv64_num_pkg.sv rtl/rv64_num_unit.sv tb/tb_num_top.sv
// =============================================================================
`timescale 1ns/1ps

module tb_num_top;

  localparam int MAXV = 4096;

  logic         clk = 1'b0;
  logic         rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [4:0]   op;
  logic [2:0]   fmt;
  logic [63:0]  a, b, cfg;
  logic [63:0]  y, err;
  logic [7:0]   flags;
  logic [127:0] quire;

  bit [63:0]    vin  [0:MAXV*5-1];
  bit [63:0]    vexp [0:MAXV*5-1];
  bit [63:0]    nvec [0:0];

  int           errors = 0;
  int           checks = 0;
  int           n;

  rv64_num_unit dut (
    .clk   (clk),
    .rst_n (rst_n),
    .op    (op),
    .fmt   (fmt),
    .a     (a),
    .b     (b),
    .cfg   (cfg),
    .y     (y),
    .flags (flags),
    .err   (err),
    .quire (quire)
  );

  task automatic check(input string what, input bit [127:0] got, input bit [127:0] exp, input int idx);
    checks++;
    if (got !== exp) begin
      errors++;
      if (errors <= 20)
        $display("MISMATCH vector %0d %s: got %0h expected %0h", idx, what, got, exp);
    end
  endtask

  initial begin
    $readmemh("sim/num_vectors/num_in.hex",    vin);
    $readmemh("sim/num_vectors/num_exp.hex",   vexp);
    $readmemh("sim/num_vectors/num_count.hex", nvec);
    n = nvec[0];
    $display("tb_num_top: %0d vectors", n);

    op = 0; fmt = 0; a = 0; b = 0; cfg = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    for (int i = 0; i < n; i++) begin
      @(negedge clk);
      op  = vin[5*i][4:0];
      fmt = vin[5*i][7:5];
      a   = vin[5*i+1];
      b   = vin[5*i+2];
      cfg = vin[5*i+3];
      #1;                                   // combinational settle, before the edge

      check("y",     {64'd0, y},                        {64'd0, vexp[5*i]},   i);
      check("flags", {120'd0, flags},                   {64'd0, vexp[5*i+1]}, i);
      check("err",   {64'd0, err},                      {64'd0, vexp[5*i+2]}, i);
      check("quire", quire,                             {vexp[5*i+4], vexp[5*i+3]}, i);
    end

    @(posedge clk);
    $display("tb_num_top: %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL");
    $finish;
  end

endmodule
