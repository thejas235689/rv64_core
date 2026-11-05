`timescale 1ns/1ps
// =============================================================================
// rv64_fp_add.sv -- IEEE-754 addition and subtraction, binary32 AND binary64.
//
// One datapath for both formats: the significand is left-aligned to bit 63 of a
// 64-bit working field, so the implicit one of EITHER precision sits in the same
// place and the alignment/normalise code does not care which format is running.
// For binary64 the field leaves 11 bits below the significand, for binary32 40 --
// more than enough for guard/round/sticky, and enough headroom that catastrophic
// cancellation cannot push the guard bits into the result (which is the defect
// the old 53-bit field had; see rtl/fpu/model/README.md).
//
// All five rounding modes are supported.  The rounding decision itself lives in
// rv64_fp_round.sv and nowhere else: this block's only job is to hand that block
// an exact {implicit, fraction, G, R, S} and the exponent of the leading one.
// The old version rounded inline, which meant the adder was the one place in the
// FPU with its own copy of the five-mode decision.
//
// Implemented: alignment with a sticky, signed-magnitude add/sub, normalisation,
// and the special cases the spec requires -- NaN propagation with the canonical
// NaN, inf + -inf = invalid, signed zeros, and the exactness of x + 0.
//
// The sticky is the subtle part.  When the smaller operand's shifted-out bits are
// nonzero, the true result is (A - B - frac) for a subtraction, which is
// (A - B - 1) + (1 - frac): so the integer part loses one and the sticky stays
// set.  OR-ing the sticky into the low bit instead -- as the old code did -- is
// off by a whole field ulp whenever the integer part has a zero there.
//
// Purely combinational: no state, no reset, no clock.
// =============================================================================
`default_nettype none

module rv64_fp_add (
  input  logic        fmt,        // 1 = binary64, 0 = binary32
  input  logic        sub,        // 1 = subtract b from a
  input  logic [2:0]  rm,
  input  logic [63:0] a,          // binary32 lives in a[31:0], binary64 in a[63:0]
  input  logic [63:0] b,
  output logic [63:0] result,
  output logic [4:0]  flags
);
  localparam logic [4:0] F_NV = 5'b1_0000;

  // ---- format constants ----------------------------------------------------
  logic [6:0]         fbw;      // fraction width  52 / 23
  logic [5:0]         pos;      // sign position   63 / 31
  logic [5:0]         lsh;      // left shift that puts the implicit one at bit 63
  logic signed [12:0] emin_b;   // 1 - bias        -1023 / -127
  logic signed [12:0] bias;
  logic [63:0]        fmask;

  always_comb begin
    if (fmt) begin
      fbw  = 7'd52;
      pos  = 6'd63;
      lsh  = 6'd11;                    // 63 - 52
      bias = 13'sd1023;
    end else begin
      fbw  = 7'd23;
      pos  = 6'd31;
      lsh  = 6'd40;                    // 63 - 23
      bias = 13'sd127;
    end
    emin_b = 13'sd1 - bias;            // unbiased exponent of the field's bit 63
    fmask  = (64'd1 << fbw) - 64'd1;
  end

  logic [63:0] qnan;
  always_comb qnan = fmt ? 64'h7FF8_0000_0000_0000 : 64'h0000_0000_7FC0_0000;

  // ---- field extraction ---------------------------------------------------
  wire        sa = fmt ? a[63] : a[31];
  wire        sb = fmt ? b[63] : b[31];
  wire [10:0] ea = fmt ? a[62:52] : {3'd0, a[30:23]};
  wire [10:0] eb = fmt ? b[62:52] : {3'd0, b[30:23]};
  wire [51:0] fa = fmt ? a[51:0] : {29'd0, a[22:0]};
  wire [51:0] fb = fmt ? b[51:0] : {29'd0, b[22:0]};

  // the format's own all-ones exponent field
  wire [10:0] e_all = fmt ? 11'h7FF : 11'h0FF;

  wire a_is_nan = (ea == e_all) && (fa != 52'd0);
  wire b_is_nan = (eb == e_all) && (fb != 52'd0);
  // the quiet bit sits at bit FB of the fraction, which is 51 for binary64 and
  // 22 for binary32 -- indexing by fbw keeps one expression for both
  wire a_is_snan = a_is_nan && !fa[fbw-1];
  wire b_is_snan = b_is_nan && !fb[fbw-1];
  wire a_is_inf = (ea == e_all) && (fa == 52'd0);
  wire b_is_inf = (eb == e_all) && (fb == 52'd0);
  wire a_is_zero = (ea == 11'd0) && (fa == 52'd0);
  wire b_is_zero = (eb == 11'd0) && (fb == 52'd0);

  wire sb_eff = sb ^ sub;

  // ---- which operand is larger in magnitude ------------------------------
  wire a_bigger = (ea > eb) || ((ea == eb) && (fa >= fb));

  wire [10:0] e_big = a_bigger ? ea : eb;
  wire [51:0] f_big = a_bigger ? fa : fb;
  wire        s_big = a_bigger ? sa : sb_eff;
  wire [10:0] e_sml = a_bigger ? eb : ea;
  wire [51:0] f_sml = a_bigger ? fb : fa;
  wire        s_sml = a_bigger ? sb_eff : sa;

  // A denormal has no implicit leading one; a normal does.
  wire imp_big = (e_big != 11'd0);
  wire imp_sml = (e_sml != 11'd0);

  // significands left-aligned so the implicit one sits at bit 63 in BOTH formats
  logic [63:0] sig_big, sig_sml;
  always_comb begin
    sig_big = (({12'd0, f_big} & fmask) | (imp_big ? (64'd1 << fbw) : 64'd0)) << lsh;
    sig_sml = (({12'd0, f_sml} & fmask) | (imp_sml ? (64'd1 << fbw) : 64'd0)) << lsh;
  end

  // The exponent difference is taken in the SAME scale the significands are
  // placed in.  A subnormal's field is 0 but its bits are scaled as if the field
  // were 1 (0.f x 2**(1-bias)), so the difference must use max(field,1) or a
  // subnormal is aligned one binade too far down and a value like
  // 1ulp - min_normal comes out as zero.
  wire [10:0] e_big_eff = (e_big == 11'd0) ? 11'd1 : e_big;
  wire [10:0] e_sml_eff = (e_sml == 11'd0) ? 11'd1 : e_sml;
  wire [11:0] exp_diff  = e_big_eff - e_sml_eff;

  // ---- alignment ----------------------------------------------------------
  logic [63:0] aligned;
  logic        sticky;
  always_comb begin
    aligned = 64'd0;
    sticky  = 1'b0;
    if (exp_diff >= 12'd64) begin
      aligned = 64'd0;
      sticky  = (sig_sml != 64'd0);
    end else if (exp_diff != 12'd0) begin
      logic [63:0] mask64;
      mask64  = (64'd1 << exp_diff) - 64'd1;
      aligned = sig_sml >> exp_diff;
      sticky  = ((sig_sml & mask64) != 64'd0);
    end else begin
      aligned = sig_sml;
    end
  end

  // ---- signed-magnitude add / subtract ------------------------------------
  logic [64:0] mag_sum;
  logic        stk_out;
  logic        s_out;
  always_comb begin
    s_out = s_big;
    if (s_big == s_sml) begin
      mag_sum = {1'b0, sig_big} + {1'b0, aligned};
      stk_out = sticky;
    end else begin
      // A - (B + frac) == (A - B - 1) + (1 - frac): the integer part loses one
      // and the sticky stays set.  exp_diff > 0 guarantees A - B >= 1.
      mag_sum = {1'b0, sig_big} - {1'b0, aligned} - {{64{1'b0}}, sticky};
      stk_out = sticky;
    end
  end

  // ---- normalise: put the leading one at bit 63 ---------------------------
  // mag_sum is 65 bits: a same-sign addition of two significands each >= 2**63
  // carries into bit 64.  Shift that back down and fold the lost bit into the
  // sticky rather than widening the field again.
  logic [64:0] pre;
  logic        carry;
  logic        stk_n;
  logic [6:0]  lz;
  logic [64:0] nrm;
  logic        nz;
  always_comb begin
    carry = mag_sum[64];
    pre   = carry ? (mag_sum >> 1) : mag_sum;
    stk_n = stk_out | (carry & mag_sum[0]);
    nz    = (pre != 65'd0);
    lz    = 7'd0;
    if (nz) begin
      logic found;
      found = 1'b0;
      for (int i = 63; i >= 0; i--) begin
        if (!found && pre[i]) found = 1'b1;
        else if (!found)      lz = lz + 7'd1;
      end
    end
    nrm = nz ? (pre << lz) : 65'd0;
  end

  logic signed [12:0] exp_in;
  always_comb begin
    exp_in = ((e_big == 11'd0) ? emin_b : ($signed({1'b0, e_big}) - bias))
             + (carry ? 13'sd1 : 13'sd0) - $signed({6'd0, lz});
  end

  // ---- hand the rounder {implicit, fraction, G, R, S} ---------------------
  logic [55:0] sig56;
  always_comb begin
    // nrm has the leading one at bit 63; drop (lsh - 3) so the fraction ends at
    // bit 3 and guard/round/sticky land on [2:0], then fold the rest in
    logic [63:0] below;
    below = nrm[63:0] & ((64'd1 << (lsh - 6'd3)) - 64'd1);
    sig56 = 56'((nrm[63:0] >> (lsh - 6'd3)) | {55'd0, (|below) | stk_n});
  end

  logic [63:0] rnd_result;
  logic [4:0]  rnd_flags;

  rv64_fp_round u_round (
    .fmt    (fmt),
    .sign   (s_out),
    .exp_in (exp_in),
    .sig    (sig56),
    .rm     (rm),
    .result (rnd_result),
    .flags  (rnd_flags)
  );

  // ---- assemble, then override for the special cases ---------------------
  // b with the sign flipped by the subtract, at the format's sign position
  logic [63:0] b_eff;
  always_comb b_eff = b ^ ({63'd0, sub} << pos);

  always_comb begin
    result = rnd_result;
    flags  = rnd_flags;
    if (a_is_nan || b_is_nan) begin
      result = qnan;
      flags  = (a_is_snan || b_is_snan) ? F_NV : 5'd0;
    end else if (a_is_inf && b_is_inf && (sa != sb_eff)) begin
      result = qnan;                          // inf + -inf
      flags  = F_NV;
    end else if (a_is_inf) begin
      result = fmt ? {sa, 11'h7FF, 52'd0} : {32'd0, sa, 8'hFF, 23'd0};
      flags  = 5'd0;
    end else if (b_is_inf) begin
      result = fmt ? {sb_eff, 11'h7FF, 52'd0} : {32'd0, sb_eff, 8'hFF, 23'd0};
      flags  = 5'd0;
    end else if (a_is_zero && b_is_zero) begin
      // -0 + -0 = -0; any other zero combination is +0
      result = {63'd0, (sa && sb_eff)} << pos;
      flags  = 5'd0;
    end else if (a_is_zero) begin
      result = b_eff;                         // x + 0 is exact
      flags  = 5'd0;
    end else if (b_is_zero) begin
      result = a;                             // 0 + y is exact
      flags  = 5'd0;
    end else if (!nz) begin
      // exact cancellation: +0, or -0 under round-down
      result = {63'd0, (rm == 3'd2)} << pos;
      flags  = 5'd0;
    end
  end
endmodule

`default_nettype wire
