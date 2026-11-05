`timescale 1ns/1ps
// =============================================================================
// rv64_fp_sqrt.sv -- IEEE-754 square root, binary32 AND binary64.
//
// The operand is normalised to M * 2**E with M an (FB+1)-bit integer, E is forced
// even (shift M left one place if needed), and then
//
//     S = floor(sqrt(M * 2**(2K)))
//
// is produced by the classic digit-by-digit restoring square root: two bits of
// the radicand are brought down per step, the trial root is (root<<1)|1, and a
// step subtracts it when the remainder is large enough.
//
// K is chosen per format so that S comes out FB+4 bits wide with its top bit set
// -- exactly the {implicit, fraction, G, R, S} format the rounder takes:
//
//     binary64  K = 29  ->  S in [2**55, 2**55.5)   56 bits
//     binary32  K = 15  ->  S in [2**26, 2**27)     27 bits
//
// The step count follows the format (56 or 27), so fsqrt.s is 27 iterations of
// the same loop fsqrt.d runs 56 of.  The final remainder folds into the sticky.
//
// `enable` gates the iteration for the same reason as in the divider: the block
// is combinational, and the operands change every cycle.
//
// Flags: NV for a negative operand (including -inf) and for a signalling NaN;
// OF/UF/NX from the rounder.  sqrt(-0) is -0 and is not invalid.
//
// Purely combinational: no state, no reset, no clock.
// =============================================================================
`default_nettype none

module rv64_fp_sqrt (
  input  logic        enable,
  input  logic        fmt,        // 1 = binary64, 0 = binary32
  input  logic [2:0]  rm,
  input  logic [63:0] a,
  output logic [63:0] result,
  output logic [4:0]  flags
);
  localparam logic [4:0] F_NV = 5'b1_0000;

  logic [6:0]         fbw;
  logic signed [12:0] bias;
  logic [10:0]        e_all;
  logic [63:0]        qnan;
  logic [51:0]        fm52;
  logic [6:0]         kk;         // K above: 29 / 15
  logic [6:0]         steps;      // FB+4: 56 / 27

  always_comb begin
    if (fmt) begin
      fbw   = 7'd52;
      bias  = 13'sd1023;
      e_all = 11'h7FF;
      qnan  = 64'h7FF8_0000_0000_0000;
      kk    = 7'd29;
      steps = 7'd56;
    end else begin
      fbw   = 7'd23;
      bias  = 13'sd127;
      e_all = 11'h0FF;
      qnan  = 64'h0000_0000_7FC0_0000;
      kk    = 7'd15;
      steps = 7'd27;
    end
    fm52 = 52'((64'd1 << fbw) - 64'd1);
  end

  wire        sa = fmt ? a[63] : a[31];
  wire [10:0] ea = fmt ? a[62:52] : {3'd0, a[30:23]};
  wire [51:0] fa = fmt ? a[51:0] : {29'd0, a[22:0]};

  wire a_nan  = (ea == e_all) && (fa != 52'd0);
  wire a_snan = a_nan && !fa[fbw-1];   // quiet bit is the MSB of the fraction, fbw-1
  wire a_inf  = (ea == e_all) && (fa == 52'd0);
  wire a_zero = (ea == 11'd0) && (fa == 52'd0);

  // ---- normalise to an (FB+1)-bit integer with an even exponent ------------
  logic [53:0]        m;                    // 54 bits: one left shift may be needed
  logic signed [12:0] e;
  always_comb begin
    if (ea == 11'd0) begin
      m = {30'd0, (fa & fm52)};
      e = 13'sd1 - bias - $signed({6'd0, fbw});
    end else begin
      m = {30'd0, (fa & fm52)} | (54'd1 << fbw);
      e = $signed({1'b0, ea}) - bias - $signed({6'd0, fbw});
    end
    for (int i = 0; i < 53; i++) begin
      if (!m[fbw] && (m != 54'd0)) begin m = m << 1; e = e - 13'sd1; end
    end
    if (e[0]) begin                         // force the exponent even
      m = m << 1;
      e = e - 13'sd1;
    end
  end

  // ---- digit-by-digit square root of m * 2**(2K) --------------------------
  //
  // `steps` = FB+5 root bits.  For binary64 the top bit always lands on FB+3 and
  // the extra bit is never used; for binary32 it is NOT always FB+3: forcing the
  // exponent even doubles M, so the root spans two binades (2**26.5 .. 2**27.5)
  // and can need one bit more.  Rather than special-case the parity, the loop
  // always produces one bit of headroom and the result is normalised afterwards
  // -- shifting right by one (folding the lost bit into the sticky and adding one
  // to the exponent) when the top bit came out at FB+4.
  logic [111:0]       v;
  logic [57:0]        root;
  logic [59:0]        rem, trial;
  logic [55:0]        sig56;
  logic signed [12:0] e_s;
  logic               rshift;
  always_comb begin
    v      = {58'd0, m} << (kk << 1);
    root   = 58'd0;
    rem    = 60'd0;
    sig56  = 56'd0;
    e_s    = 13'sd0;
    rshift = 1'b0;
    if (enable) begin
      for (int i = 55; i >= 0; i--) begin
        if (i <= (fbw + 7'd4)) begin
          rem   = (rem << 2) | {58'd0, v[2*i +: 2]};
          root  = root << 1;
          trial = ({2'b00, root} << 1) | 60'd1;
          if (rem >= trial) begin
            rem  = rem - trial;
            root = root | 58'd1;
          end
        end
      end
      rshift = root[fbw + 7'd4];
      sig56  = 56'((rshift ? (root >> 1) : root) |
                   {55'd0, (rem != 60'd0) | (rshift & root[0])});
      // value = S * 2**(E/2 - K), S = 1.f * 2**(FB+3)
      e_s   = (e >>> 1) - $signed({6'd0, kk}) + $signed({6'd0, fbw}) + 13'sd3 +
              (rshift ? 13'sd1 : 13'sd0);
    end
  end

  logic [63:0] rnd_result;
  logic [4:0]  rnd_flags;

  rv64_fp_round u_round (
    .fmt    (fmt),
    .sign   (1'b0),
    .exp_in (e_s),
    .sig    (sig56),
    .rm     (rm),
    .result (rnd_result),
    .flags  (rnd_flags)
  );

  // ---- specials override the datapath -------------------------------------
  always_comb begin
    result = rnd_result;
    flags  = rnd_flags;
    if (a_nan) begin
      result = qnan;
      flags  = a_snan ? F_NV : 5'd0;
    end else if (a_zero) begin
      result = a;                           // sqrt(+-0) = +-0, no flag
      flags  = 5'd0;
    end else if (sa) begin
      result = qnan;                        // sqrt of a negative is invalid
      flags  = F_NV;
    end else if (a_inf) begin
      result = fmt ? 64'h7FF0_0000_0000_0000 : 64'h0000_0000_7F80_0000;
      flags  = 5'd0;
    end
  end
endmodule

`default_nettype wire
