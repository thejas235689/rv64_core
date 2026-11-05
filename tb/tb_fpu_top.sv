`timescale 1ns/1ps
// =============================================================================
// tb_fpu_top.sv -- unit-level harness for the scalar FPU blocks.
//
// Wraps the combinational FPU datapaths and exposes one result port, so a cocotb
// test can push thousands of vectors through them without paying for the whole
// core's pipeline.  Every block is combinational, so a vector is applied, a delta
// settles, and the result is read -- there is no clock domain to wait for.  The
// clock port exists only because cocotb's harness expects one.
//
// `fmt` (1 = binary64, 0 = binary32) reaches every block, so the same harness
// sweeps both precisions through the same datapath -- which is the point of the
// single-precision extension: there is one FPU, not two.
//
// This is the exhaustive side of the FPU verification; test_fpu_core.py and
// test_fpu_core_single.py are the end-to-end side that prove the same blocks are
// actually reachable from software.
// =============================================================================
`default_nettype none

module tb_fpu_top (
  input  logic        clk,
  input  logic [3:0]  op,        // 0 add, 1 sub, 2 mul, 3 div, 4 sqrt, 5 cvt, 6 cmp
  input  logic        fmt,       // 1 = binary64, 0 = binary32
  input  logic [2:0]  rm,
  input  logic [63:0] a,
  input  logic [63:0] b,
  input  logic [1:0]  cvt_op,    // 0 fp->int, 1 int->fp, 2 fp->fp
  input  logic        cvt_unsigned,
  input  logic        cvt_32,
  input  logic [2:0]  cmp_f3,
  output logic [63:0] result,
  output logic [4:0]  flags
);
  localparam logic [3:0] OP_ADD = 4'd0, OP_SUB = 4'd1, OP_MUL = 4'd2,
                         OP_DIV = 4'd3, OP_SQRT = 4'd4, OP_CVT = 4'd5,
                         OP_CMP = 4'd6;

  logic [63:0] add_y, mul_y, div_y, sqrt_y, cvt_y, cmp_y;
  logic [4:0]  add_f, mul_f, div_f, sqrt_f, cvt_f, cmp_f;

  rv64_fp_add u_add (
    .fmt    (fmt),
    .sub    (op == OP_SUB),
    .rm     (rm),
    .a      (a),
    .b      (b),
    .result (add_y),
    .flags  (add_f)
  );

  rv64_fp_mul u_mul (
    .fmt (fmt), .rm (rm), .a (a), .b (b), .result (mul_y), .flags (mul_f)
  );

  rv64_fp_div u_div (
    .enable (1'b1), .fmt (fmt), .rm (rm), .a (a), .b (b),
    .result (div_y), .flags (div_f)
  );

  rv64_fp_sqrt u_sqrt (
    .enable (1'b1), .fmt (fmt), .rm (rm), .a (a),
    .result (sqrt_y), .flags (sqrt_f)
  );

  rv64_fp_cvt u_cvt (
    .op          (cvt_op),
    .src_fmt     (fmt),
    .dst_fmt     (fmt),
    .is_unsigned (cvt_unsigned),
    .is_32       (cvt_32),
    .rm          (rm),
    .src         (a),
    .result      (cvt_y),
    .flags       (cvt_f)
  );

  rv64_fp_cmp u_cmp (
    .fmt (fmt), .f3 (cmp_f3), .a (a), .b (b), .result (cmp_y), .flags (cmp_f)
  );

  always_comb begin
    result = 64'd0;
    flags  = 5'd0;
    unique case (op)
      OP_ADD,
      OP_SUB:  begin result = add_y;  flags = add_f;  end
      OP_MUL:  begin result = mul_y;  flags = mul_f;  end
      OP_DIV:  begin result = div_y;  flags = div_f;  end
      OP_SQRT: begin result = sqrt_y; flags = sqrt_f; end
      OP_CVT:  begin result = cvt_y;  flags = cvt_f;  end
      OP_CMP:  begin result = cmp_y;  flags = cmp_f;  end
      default: begin result = 64'd0;  flags = 5'd0;   end
    endcase
  end
endmodule

`default_nettype wire
