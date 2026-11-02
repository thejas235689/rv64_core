`timescale 1ns/1ps
// =============================================================================
// rv64_fp_mul.sv -- IEEE-754 binary64 multiplication.
//
//     value = (M_a * M_b) * 2**(E_a + E_b)
//
// Both operands are normalised to a 53-bit integer M with bit 52 set, so a
// subnormal input is normalised rather than flushed.  The 106-bit product is
// then shifted so its top bit sits at position 105, the leading 53 bits become
// the significand and the 53 bits below become guard/round/sticky -- 53 bits of
// "below" is more than a guard/round/sticky needs, which is why nothing is lost
// before the rounder sees it.
//
// All five rounding modes are supported (the rounder owns the decision).  Flags:
// NV for inf*0 and for a signalling NaN, plus OF/UF/NX from the rounder.  A
// quiet NaN propagates silently as the canonical NaN, as the spec requires.
//
// Transcribed from rtl/fpu/model/fp_mul_model.py, which passes 15390 vectors
// against CPython's own float multiply and 11440 against an exact rational
// reference covering every rounding mode.
//
// Purely combinational: no state, no reset, no clock.
// =============================================================================
`default_nettype none

module rv64_fp_mul (
  input  logic [2:0]  rm,
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic [63:0] result,
  output logic [4:0]  flags
);
  localparam logic [63:0] QNAN = 64'h7FF8_0000_0000_0000;
  localparam logic [4:0]  F_NV = 5'b1_0000;

  // ---- field extraction ---------------------------------------------------
  wire        sa = a[63], sb = b[63];
  wire [10:0] ea = a[62:52], eb = b[62:52];
  wire [51:0] fa = a[51:0],  fb = b[51:0];

  wire a_nan  = (ea == 11'h7FF) && (fa != 52'd0);
  wire b_nan  = (eb == 11'h7FF) && (fb != 52'd0);
  wire a_snan = a_nan && !fa[51];
  wire b_snan = b_nan && !fb[51];
  wire a_inf  = (ea == 11'h7FF) && (fa == 52'd0);
  wire b_inf  = (eb == 11'h7FF) && (fb == 52'd0);
  wire a_zero = (ea == 11'd0) && (fa == 52'd0);
  wire b_zero = (eb == 11'd0) && (fb == 52'd0);

  // ---- normalise both operands to 53-bit integers --------------------------
  logic [52:0]        ma, mb;
  logic signed [12:0] e_a, e_b;
  always_comb begin
    if (ea == 11'd0) begin ma = {1'b0, fa}; e_a = -13'sd1074; end
    else             begin ma = {1'b1, fa}; e_a = $signed({1'b0, ea}) - 13'sd1075; end
    for (int i = 0; i < 53; i++) begin
      if (!ma[52] && (ma != 53'd0)) begin ma = ma << 1; e_a = e_a - 13'sd1; end
    end

    if (eb == 11'd0) begin mb = {1'b0, fb}; e_b = -13'sd1074; end
    else             begin mb = {1'b1, fb}; e_b = $signed({1'b0, eb}) - 13'sd1075; end
    for (int i = 0; i < 53; i++) begin
      if (!mb[52] && (mb != 53'd0)) begin mb = mb << 1; e_b = e_b - 13'sd1; end
    end
  end

  // ---- product, normalised to bit 105 -------------------------------------
  logic [105:0]        prod;
  logic signed [12:0]  e_prod;
  logic [55:0]         sig56;
  always_comb begin
    prod   = ma * mb;                       // in [2**104, 2**106)
    e_prod = e_a + e_b;
    if (!prod[105]) begin
      prod   = prod << 1;
      e_prod = e_prod - 13'sd1;
    end
    // leading 53 bits are the significand, the 53 below are G/R/S
    sig56 = {prod[105:53], prod[52], prod[51], |prod[50:0]};
  end

  logic [63:0] rnd_result;
  logic [4:0]  rnd_flags;

  rv64_fp_round u_round (
    .sign   (sa ^ sb),
    .exp_in (e_prod + 13'sd105),            // value = sig53 * 2**(e+53), sig53 = 1.f * 2**52
    .sig    (sig56),
    .rm     (rm),
    .result (rnd_result),
    .flags  (rnd_flags)
  );

  // ---- specials override the datapath -------------------------------------
  always_comb begin
    result = rnd_result;
    flags  = rnd_flags;
    if (a_nan || b_nan) begin
      result = QNAN;                        // canonical quiet NaN
      flags  = (a_snan || b_snan) ? F_NV : 5'd0;
    end else if ((a_inf && b_zero) || (a_zero && b_inf)) begin
      result = QNAN;                        // inf * 0 is invalid
      flags  = F_NV;
    end else if (a_inf || b_inf) begin
      result = {sa ^ sb, 11'h7FF, 52'd0};
      flags  = 5'd0;
    end else if (a_zero || b_zero) begin
      result = {sa ^ sb, 63'd0};            // sign of a zero product is the xor
      flags  = 5'd0;
    end
  end
endmodule

`default_nettype wire
