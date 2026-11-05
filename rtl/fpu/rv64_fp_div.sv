`timescale 1ns/1ps
// =============================================================================
// rv64_fp_div.sv -- IEEE-754 division, binary32 AND binary64.
//
// Restoring long division of the two (FB+1)-bit significands, 56 quotient bits:
//
//     N = M_a         if M_a >= M_b    (quotient in [1,2), exp = E_a - E_b)
//     N = M_a << 1    otherwise        (quotient in [1,2), exp = E_a - E_b - 1)
//     q = floor(N * 2**55 / M_b),  r = remainder
//
// The one-step pre-division (the `if (r >= mb)` before the loop) is what makes
// q exactly 56 bits with bit 55 set, which is the {implicit, fraction, G, R, S}
// format the rounder wants.  The remainder folds into the sticky bit.
//
// The quotient is always computed to 56 bits, for BOTH formats.  binary32 only
// needs 27 of them; the extra 29 are simply more precision below the guard bits,
// which costs a few gates and saves a second divider.  For binary32 the top 27
// bits become the rounder's significand and the 29 below fold into the sticky.
//
// `enable` gates the iteration.  The block is combinational, so without it the
// 55-step subtract/shift chain would re-evaluate on every cycle the operands
// change, which is every cycle.  With it, the chain only runs while a divide is
// actually in EX.
//
// Flags: NV for 0/0 and inf/inf and signalling NaN, DZ for finite/0, OF/UF/NX
// from the rounder.  Rounding itself is not here: rv64_fp_round.sv owns it.
//
// Purely combinational: no state, no reset, no clock.
// =============================================================================
`default_nettype none

module rv64_fp_div (
  input  logic        enable,
  input  logic        fmt,        // 1 = binary64, 0 = binary32
  input  logic [2:0]  rm,
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic [63:0] result,
  output logic [4:0]  flags
);
  localparam logic [4:0] F_NV = 5'b1_0000;
  localparam logic [4:0] F_DZ = 5'b0_1000;

  logic [6:0]         fbw;
  logic signed [12:0] bias;
  logic [10:0]        e_all;
  logic [63:0]        qnan;
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
    fm52 = 52'((64'd1 << fbw) - 64'd1);
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
      ma  = {29'd0, (fa & fm52)};
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

  // ---- long division -------------------------------------------------------
  logic [55:0]        q;
  logic [53:0]        r;
  logic [55:0]        sig56;
  logic signed [12:0] e_q;
  logic [5:0]         drop;
  always_comb begin
    q     = 56'd0;
    r     = 54'd0;
    sig56 = 56'd0;
    e_q   = 13'sd0;
    drop  = 6'(56 - (fbw + 7'd4));         // double 0, single 29
    if (enable) begin
      logic [53:0] n;
      if (ma >= mb) begin
        n   = {1'b0, ma};
        e_q = e_a - e_b;
      end else begin
        n   = {1'b0, ma} << 1;             // force the quotient into [1,2)
        e_q = e_a - e_b - 13'sd1;
      end
      r = n;
      // one pre-step: n is in [mb, 2*mb), so a single subtract normalises the
      // remainder and sets the quotient's implicit bit
      if (r >= {1'b0, mb}) begin
        r = r - {1'b0, mb};
        q = 56'd1;
      end
      for (int i = 0; i < 55; i++) begin
        r    = r << 1;
        q    = q << 1;
        if (r >= {1'b0, mb}) begin
          r    = r - {1'b0, mb};
          q[0] = 1'b1;
        end
      end
      // remainder -> sticky, plus everything below the rounder's G/R/S
      sig56 = 56'((q >> drop) |
                  {55'd0, (|(q & ((56'd1 << drop) - 56'd1))) | (r != 54'd0)});
    end
  end

  logic [63:0] rnd_result;
  logic [4:0]  rnd_flags;

  rv64_fp_round u_round (
    .fmt    (fmt),
    .sign   (sa ^ sb),
    .exp_in (e_q),
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
      result = qnan;
      flags  = (a_snan || b_snan) ? F_NV : 5'd0;
    end else if (a_inf && b_inf) begin
      result = qnan;                        // inf / inf
      flags  = F_NV;
    end else if (a_zero && b_zero) begin
      result = qnan;                        // 0 / 0
      flags  = F_NV;
    end else if (b_zero) begin
      result = fmt ? {sa ^ sb, 11'h7FF, 52'd0} : {32'd0, sa ^ sb, 8'hFF, 23'd0};
      flags  = F_DZ;                        // finite / 0
    end else if (a_inf) begin
      result = fmt ? {sa ^ sb, 11'h7FF, 52'd0} : {32'd0, sa ^ sb, 8'hFF, 23'd0};
      flags  = 5'd0;
    end else if (b_inf || a_zero) begin
      result = {63'd0, (sa ^ sb)} << (fmt ? 6'd63 : 6'd31);
      flags  = 5'd0;
    end
  end
endmodule

`default_nettype wire
