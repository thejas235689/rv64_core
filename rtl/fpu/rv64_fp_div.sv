`timescale 1ns/1ps
// =============================================================================
// rv64_fp_div.sv -- IEEE-754 binary64 division.
//
// Restoring long division of the two 53-bit significands, 56 quotient bits:
//
//     N = M_a         if M_a >= M_b    (quotient in [1,2), exp = E_a - E_b)
//     N = M_a << 1    otherwise        (quotient in [1,2), exp = E_a - E_b - 1)
//     q = floor(N * 2**55 / M_b),  r = remainder
//
// The one-step pre-division (the `if (r >= mb)` before the loop) is what makes
// q exactly 56 bits with bit 55 set, which is the {implicit, fraction52, G, R, S}
// format the rounder wants.  The remainder folds into the sticky bit -- 56 bits
// of quotient is the whole precision a binary64 needs, and everything below it
// is by definition a tie-breaker.
//
// `enable` gates the iteration.  The block is combinational, so without it the
// 55-step subtract/shift chain would re-evaluate on every cycle the operands
// change, which is every cycle.  With it, the chain only runs while a divide is
// actually in EX.
//
// Flags: NV for 0/0 and inf/inf and signalling NaN, DZ for finite/0, OF/UF/NX
// from the rounder.  Transcribed from rtl/fpu/model/fp_div_model.py (15390
// vectors against CPython's float divide, 11700 against an exact reference
// covering all five rounding modes).
//
// Purely combinational: no state, no reset, no clock.
// =============================================================================
`default_nettype none

module rv64_fp_div (
  input  logic        enable,
  input  logic [2:0]  rm,
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic [63:0] result,
  output logic [4:0]  flags
);
  localparam logic [63:0] QNAN = 64'h7FF8_0000_0000_0000;
  localparam logic [4:0]  F_NV = 5'b1_0000;
  localparam logic [4:0]  F_DZ = 5'b0_1000;

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

  // ---- long division -------------------------------------------------------
  logic [55:0]        q;
  logic [53:0]        r;
  logic [55:0]        sig56;
  logic signed [12:0] e_q;
  always_comb begin
    q     = 56'd0;
    r     = 54'd0;
    sig56 = 56'd0;
    e_q   = 13'sd0;
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
      sig56 = q | {55'd0, (r != 54'd0)};   // remainder -> sticky
    end
  end

  logic [63:0] rnd_result;
  logic [4:0]  rnd_flags;

  rv64_fp_round u_round (
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
      result = QNAN;
      flags  = (a_snan || b_snan) ? F_NV : 5'd0;
    end else if (a_inf && b_inf) begin
      result = QNAN;                        // inf / inf
      flags  = F_NV;
    end else if (a_zero && b_zero) begin
      result = QNAN;                        // 0 / 0
      flags  = F_NV;
    end else if (b_zero) begin
      result = {sa ^ sb, 11'h7FF, 52'd0};   // finite / 0
      flags  = F_DZ;
    end else if (a_inf) begin
      result = {sa ^ sb, 11'h7FF, 52'd0};
      flags  = 5'd0;
    end else if (b_inf || a_zero) begin
      result = {sa ^ sb, 63'd0};
      flags  = 5'd0;
    end
  end
endmodule

`default_nettype wire
