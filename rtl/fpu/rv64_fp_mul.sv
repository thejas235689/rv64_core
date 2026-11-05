`timescale 1ns/1ps
// =============================================================================
// rv64_fp_mul.sv -- IEEE-754 multiplication, binary32 AND binary64.
//
//     value = (M_a * M_b) * 2**(E_a + E_b)
//
// Both operands are normalised to an (FB+1)-bit integer M with bit FB set, so a
// subnormal input is normalised rather than flushed.  The product is then shifted
// so its top bit sits at 2*FB+1, the leading FB+1 bits become the significand and
// everything below is folded into guard/round/sticky -- which is more bits of
// "below" than a guard/round/sticky needs, so nothing is lost before the rounder
// sees it.
//
// One datapath, two formats: FB is 52 or 23 and every slice below is written in
// terms of it, so fmul.s is the same 53x53 multiplier doing a 24x24 product.
// The rounding decision is not here at all -- it is in rv64_fp_round.sv, which is
// the only place in the FPU that knows about rounding modes.
//
// Flags: NV for inf*0 and for a signalling NaN, plus OF/UF/NX from the rounder.
// A quiet NaN propagates silently as the canonical NaN, as the spec requires.
//
// Purely combinational: no state, no reset, no clock.
// =============================================================================
`default_nettype none

module rv64_fp_mul (
  input  logic        fmt,        // 1 = binary64, 0 = binary32
  input  logic [2:0]  rm,
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic [63:0] result,
  output logic [4:0]  flags
);
  localparam logic [4:0] F_NV = 5'b1_0000;

  logic [6:0]         fbw;
  logic signed [12:0] bias;
  logic [10:0]        e_all;
  logic [63:0]        fmask, qnan;
  logic [51:0]        fm52;

  always_comb begin
    if (fmt) begin
      fbw   = 7'd52;
      bias  = 13'sd1023;
      e_all = 11'h7FF;
      qnan  = 64'h7FF8_0000_0000_0000;
    end else begin
      fbw   = 7'd23;
      bias  = 13'sd127;
      e_all = 11'h0FF;
      qnan  = 64'h0000_0000_7FC0_0000;
    end
    fmask = (64'd1 << fbw) - 64'd1;
    fm52  = 52'(fmask);
  end

  // ---- field extraction ---------------------------------------------------
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
  wire a_inf  = (ea == e_all) && (fa == 52'd0);
  wire b_inf  = (eb == e_all) && (fb == 52'd0);
  wire a_zero = (ea == 11'd0) && (fa == 52'd0);
  wire b_zero = (eb == 11'd0) && (fb == 52'd0);

  // ---- normalise both operands to (FB+1)-bit integers ---------------------
  logic [52:0]        ma, mb;
  logic signed [12:0] e_a, e_b;
  always_comb begin
    if (ea == 11'd0) begin
      ma  = {29'd0, (fa & fm52)};                       // subnormal: no implicit one
      e_a = 13'sd1 - bias - $signed({6'd0, fbw});
    end else begin
      ma  = {29'd0, (fa & fm52)} | (53'd1 << fbw);
      e_a = $signed({1'b0, ea}) - bias - $signed({6'd0, fbw});
    end
    for (int i = 0; i < 53; i++) begin
      if (!ma[fbw] && (ma != 53'd0)) begin ma = ma << 1; e_a = e_a - 13'sd1; end
    end

    if (eb == 11'd0) begin
      mb  = {29'd0, (fb & fm52)};
      e_b = 13'sd1 - bias - $signed({6'd0, fbw});
    end else begin
      mb  = {29'd0, (fb & fm52)} | (53'd1 << fbw);
      e_b = $signed({1'b0, eb}) - bias - $signed({6'd0, fbw});
    end
    for (int i = 0; i < 53; i++) begin
      if (!mb[fbw] && (mb != 53'd0)) begin mb = mb << 1; e_b = e_b - 13'sd1; end
    end
  end

  // ---- product, normalised to bit 2*FB+1 ----------------------------------
  logic [105:0]       prod;
  logic signed [12:0] e_prod;
  logic [55:0]        sig56;
  logic [5:0]         drop;              // bits below guard/round/sticky
  always_comb begin
    drop   = 6'(fbw - 7'd2);             // double 50, single 21
    prod   = ma * mb;
    e_prod = e_a + e_b;
    if (!prod[2*fbw+1]) begin
      prod   = prod << 1;
      e_prod = e_prod - 13'sd1;
    end
    // leading FB+1 bits are the significand, the next three are G/R/S
    sig56 = 56'((prod >> drop) | {55'd0, (|(prod & ((106'd1 << drop) - 106'd1)))});
  end

  logic [63:0] rnd_result;
  logic [4:0]  rnd_flags;

  rv64_fp_round u_round (
    .fmt    (fmt),
    .sign   (sa ^ sb),
    .exp_in (e_prod + 13'sd1 + $signed({5'd0, fbw, 1'b0})),  // e_a+e_b+2*FB+1
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
      result = qnan;                        // canonical quiet NaN
      flags  = (a_snan || b_snan) ? F_NV : 5'd0;
    end else if ((a_inf && b_zero) || (a_zero && b_inf)) begin
      result = qnan;                        // inf * 0 is invalid
      flags  = F_NV;
    end else if (a_inf || b_inf) begin
      result = fmt ? {sa ^ sb, 11'h7FF, 52'd0} : {32'd0, sa ^ sb, 8'hFF, 23'd0};
      flags  = 5'd0;
    end else if (a_zero || b_zero) begin
      result = {63'd0, (sa ^ sb)} << (fmt ? 6'd63 : 6'd31);
      flags  = 5'd0;
    end
  end
endmodule

`default_nettype wire
