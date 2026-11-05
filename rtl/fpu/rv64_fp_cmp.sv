`timescale 1ns/1ps
// =============================================================================
// rv64_fp_cmp.sv -- feq / flt / fle, binary32 AND binary64.
//
// The comparison works on the sign-magnitude encoding directly rather than
// unpacking to a float, because the encoding is already ordered: with the same
// sign, a larger magnitude field is a larger magnitude, and with different signs
// the negative one is smaller.  -0.0 == +0.0 falls out of treating the two zero
// magnitude fields as equal instead of being a special case.  Because the
// magnitude field is the bits below the sign, the same code works for both
// formats -- only the width of the "everything except the sign" field changes.
//
// Only a SIGNALLING NaN raises invalid.  A quiet NaN compares false and is
// silent -- that is the spec's rule and it is the opposite of what a naive
// "any NaN is invalid" implementation does.
//
// funct3 encoding: 0 = fle, 1 = flt, 2 = feq.
//
// Purely combinational: no state, no reset, no clock.
// =============================================================================
`default_nettype none

module rv64_fp_cmp (
  input  logic        fmt,        // 1 = binary64, 0 = binary32
  input  logic [2:0]  f3,
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic [63:0] result,     // 0 or 1, zero-extended
  output logic [4:0]  flags
);
  localparam logic [4:0] F_NV = 5'b1_0000;

  logic [6:0]  fbw;
  logic [10:0] e_all;
  logic [63:0] fmask;

  always_comb begin
    // fmask keeps everything EXCEPT the sign: exponent and fraction together are
    // the magnitude field, and the magnitude field is what is ordered.
    if (fmt) begin fbw = 7'd52; e_all = 11'h7FF; fmask = 64'h7FFF_FFFF_FFFF_FFFF; end
    else     begin fbw = 7'd23; e_all = 11'h0FF; fmask = 64'h0000_0000_7FFF_FFFF; end
  end

  wire        sa = fmt ? a[63] : a[31];
  wire        sb = fmt ? b[63] : b[31];
  wire [10:0] ea = fmt ? a[62:52] : {3'd0, a[30:23]};
  wire [10:0] eb = fmt ? b[62:52] : {3'd0, b[30:23]};
  wire [51:0] fa = fmt ? a[51:0] : {29'd0, a[22:0]};
  wire [51:0] fb = fmt ? b[51:0] : {29'd0, b[22:0]};

  wire a_nan  = (ea == e_all) && (fa != 52'd0);
  wire b_nan  = (eb == e_all) && (fb != 52'd0);
  wire a_snan = a_nan && !fa[fbw-1];   // quiet bit is the MSB of the fraction, fbw-1
  wire b_snan = b_nan && !fb[fbw-1];

  // the value with the sign stripped, at the format's width
  wire [63:0] ma = a & fmask;
  wire [63:0] mb = b & fmask;

  wire both_zero = (ma == 64'd0) && (mb == 64'd0);
  wire eq, lt;
  assign eq = both_zero ? 1'b1 : (ma == mb) && (sa == sb);
  assign lt = both_zero ? 1'b0 :
              (sa != sb) ? sa :                       // different signs
              (ma == mb) ? 1'b0 :
              sa ? (mb < ma) : (ma < mb);             // same sign: compare magnitude

  always_comb begin
    unique case (f3)
      3'd2:    result = {63'd0, eq};                  // feq
      3'd1:    result = {63'd0, lt};                  // flt
      3'd0:    result = {63'd0, lt | eq};             // fle
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
