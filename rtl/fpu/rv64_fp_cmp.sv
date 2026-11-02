`timescale 1ns/1ps
// =============================================================================
// rv64_fp_cmp.sv -- feq.d / flt.d / fle.d.
//
// The comparison works on the sign-magnitude encoding directly rather than
// unpacking to a float, because the encoding is already ordered: with the same
// sign, a larger magnitude field is a larger magnitude, and with different
// signs the negative one is smaller.  -0.0 == +0.0 falls out of treating the
// two zero magnitude fields as equal instead of being a special case.
//
// Only a SIGNALLING NaN raises invalid.  A quiet NaN compares false and is
// silent -- that is the spec's rule and it is the opposite of what a naive
// "any NaN is invalid" implementation does.
//
// funct3 encoding: 0 = fle.d, 1 = flt.d, 2 = feq.d.
//
// Transcribed from rtl/fpu/model/fp_cmp_model.py (198147 comparisons against
// Python's own float comparison operators).
//
// Purely combinational: no state, no reset, no clock.
// =============================================================================
`default_nettype none

module rv64_fp_cmp (
  input  logic [2:0]  f3,
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic [63:0] result,     // 0 or 1, zero-extended
  output logic [4:0]  flags
);
  localparam logic [4:0] F_NV = 5'b1_0000;

  wire        sa = a[63], sb = b[63];
  wire [10:0] ea = a[62:52], eb = b[62:52];
  wire [51:0] fa = a[51:0],  fb = b[51:0];

  wire a_nan  = (ea == 11'h7FF) && (fa != 52'd0);
  wire b_nan  = (eb == 11'h7FF) && (fb != 52'd0);
  wire a_snan = a_nan && !fa[51];
  wire b_snan = b_nan && !fb[51];

  wire [62:0] ma = a[62:0];
  wire [62:0] mb = b[62:0];

  wire both_zero = (ma == 63'd0) && (mb == 63'd0);
  wire eq, lt;
  assign eq = both_zero ? 1'b1 : (a == b);
  assign lt = both_zero ? 1'b0 :
              (sa != sb) ? sa :                       // different signs
              (ma == mb) ? 1'b0 :
              sa ? (mb < ma) : (ma < mb);             // same sign: compare magnitude

  always_comb begin
    unique case (f3)
      3'd2:    result = {63'd0, eq};                  // feq.d
      3'd1:    result = {63'd0, lt};                  // flt.d
      3'd0:    result = {63'd0, lt | eq};             // fle.d
      default: result = 64'd0;
    endcase
    flags = 5'd0;
    if (a_nan || b_nan) begin
      result = 64'd0;                                 // unordered: all three are false
      flags  = (a_snan || b_snan) ? F_NV : 5'd0;
    end
  end
endmodule

`default_nettype wire
