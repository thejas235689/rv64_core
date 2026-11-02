`timescale 1ns/1ps
// =============================================================================
// rv64_fp_sqrt.sv -- IEEE-754 binary64 square root.
//
// The operand is normalised to M * 2**E with M a 53-bit integer, E is forced
// even (shift M left one place if needed), and then
//
//     S = floor(sqrt(M * 2**58))
//
// is produced by the classic digit-by-digit restoring square root: two bits of
// the radicand are brought down per step, the trial root is (root<<1)|1, and a
// step subtracts it when the remainder is large enough.  M*2**58 lies in
// [2**110, 2**112), so S is 56 bits with bit 55 set -- exactly the
// {implicit, fraction52, G, R, S} format the rounder takes.  The final
// remainder folds into the sticky bit.
//
// `enable` gates the 56-step iteration for the same reason as in the divider:
// the block is combinational, and the operands change every cycle.
//
// Flags: NV for a negative operand (including -inf) and for a signalling NaN;
// OF/UF/NX from the rounder.  sqrt(-0) is -0 and is not invalid.  Transcribed
// from rtl/fpu/model/fp_sqrt_model.py (536 vectors against math.sqrt, 895
// against a 600-bit exact reference across all five rounding modes).
//
// Purely combinational: no state, no reset, no clock.
// =============================================================================
`default_nettype none

module rv64_fp_sqrt (
  input  logic        enable,
  input  logic [2:0]  rm,
  input  logic [63:0] a,
  output logic [63:0] result,
  output logic [4:0]  flags
);
  localparam logic [63:0] QNAN = 64'h7FF8_0000_0000_0000;
  localparam logic [4:0]  F_NV = 5'b1_0000;

  wire        sa = a[63];
  wire [10:0] ea = a[62:52];
  wire [51:0] fa = a[51:0];

  wire a_nan  = (ea == 11'h7FF) && (fa != 52'd0);
  wire a_snan = a_nan && !fa[51];
  wire a_inf  = (ea == 11'h7FF) && (fa == 52'd0);
  wire a_zero = (ea == 11'd0) && (fa == 52'd0);

  // ---- normalise to a 53-bit integer with an even exponent -----------------
  logic [53:0]        m;                    // 54 bits: one left shift may be needed
  logic signed [12:0] e;
  always_comb begin
    if (ea == 11'd0) begin m = {2'b00, fa}; e = -13'sd1074; end
    else             begin m = {1'b0, 1'b1, fa}; e = $signed({1'b0, ea}) - 13'sd1075; end
    for (int i = 0; i < 53; i++) begin
      if (!m[52] && (m != 54'd0)) begin m = m << 1; e = e - 13'sd1; end
    end
    if (e[0]) begin                         // force the exponent even
      m = m << 1;
      e = e - 13'sd1;
    end
  end

  // ---- digit-by-digit square root of m * 2**58 ----------------------------
  logic [111:0]       v;
  logic [55:0]        root;
  logic [57:0]        rem, trial;
  logic [55:0]        sig56;
  logic signed [12:0] e_s;
  always_comb begin
    v     = {58'd0, m} << 58;
    root  = 56'd0;
    rem   = 58'd0;
    sig56 = 56'd0;
    e_s   = 13'sd0;
    if (enable) begin
      for (int i = 55; i >= 0; i--) begin
        rem   = (rem << 2) | {56'd0, v[2*i +: 2]};
        root  = root << 1;
        trial = ({2'b00, root} << 1) | 58'd1;
        if (rem >= trial) begin
          rem  = rem - trial;
          root = root | 56'd1;
        end
      end
      sig56 = root | {55'd0, (rem != 58'd0)};
      // value = S * 2**(E/2 - 29) and S = 1.f * 2**55, so exp_in = E/2 + 26
      e_s   = (e >>> 1) + 13'sd26;
    end
  end

  logic [63:0] rnd_result;
  logic [4:0]  rnd_flags;

  rv64_fp_round u_round (
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
      result = QNAN;
      flags  = a_snan ? F_NV : 5'd0;
    end else if (a_zero) begin
      result = a;                           // sqrt(+-0) = +-0, no flag
      flags  = 5'd0;
    end else if (sa) begin
      result = QNAN;                        // sqrt of a negative is invalid
      flags  = F_NV;
    end else if (a_inf) begin
      result = {1'b0, 11'h7FF, 52'd0};
      flags  = 5'd0;
    end
  end
endmodule

`default_nettype wire
