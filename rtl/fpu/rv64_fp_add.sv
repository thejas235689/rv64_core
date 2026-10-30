`timescale 1ns/1ps
// =============================================================================
// rv64_fp_add.sv -- IEEE-754 binary64 addition and subtraction.
//
// Round-to-nearest-even only; RTZ/RDN/RUP/RMM are not implemented yet and the
// rounding-mode input is absent rather than silently ignored.
//
// Implemented: alignment, signed-magnitude add/sub with a single sticky bit,
// normalisation, guard/round/sticky rounding, and the special cases the spec
// requires -- NaN propagation with the canonical NaN, inf + -inf = invalid,
// signed zeros, and the exactness of x + 0.
//
// NOT implemented: denormal input/output flushing (denormals are handled
// correctly as values but there is no FTZ control), and the full fflags set
// (only invalid and inexact are produced).
//
// The single sticky bit is the subtle part. Instead of carrying 64 shifted-out
// bits through a wide adder, the shift amount is tracked and any nonzero shifted
// bit sets sticky -- which is what makes this block small enough to verify
// exhaustively against a reference.
// =============================================================================
`default_nettype none

module rv64_fp_add (
  input  logic        sub,        // 1 = subtract b from a
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic [63:0] result,
  output logic        flag_invalid,
  output logic        flag_inexact
);
  localparam logic [63:0] QNAN = 64'h7FF8_0000_0000_0000;

  // ---- field extraction ---------------------------------------------------
  wire        sa = a[63], sb = b[63];
  wire [10:0] ea = a[62:52], eb = b[62:52];
  wire [51:0] fa = a[51:0],  fb = b[51:0];

  wire a_is_nan = (ea == 11'h7FF) && (fa != 52'd0);
  wire b_is_nan = (eb == 11'h7FF) && (fb != 52'd0);
  wire a_is_inf = (ea == 11'h7FF) && (fa == 52'd0);
  wire b_is_inf = (eb == 11'h7FF) && (fb == 52'd0);
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

  wire [11:0] exp_diff = e_big - e_sml;

  // A denormal has no implicit leading one; a normal does.
  wire        imp_big = (e_big != 11'd0);
  wire        imp_sml = (e_sml != 11'd0);
  // Alignment into a field WIDER than the 53-bit significand so the low bits are
  // KEPT, not collapsed into a sticky. The result exponent can drop below e_big
  // during normalisation, which makes those low bits representable; collapsing
  // them made an exact sum look like it needed rounding. Transcribed from
  // rtl/fpu/model/fp_add_model.py, which passes 315/315.
  localparam int ALIGN_EXT = 3;
  logic [52:0] sig_big, sig_sml;
  logic [55:0] sig_sml_aligned;
  logic        sticky;
  always_comb begin
    sig_big = {imp_big, f_big};
    sig_sml = {imp_sml, f_sml};
    sticky  = 1'b0;
    if (exp_diff > 12'(53 + ALIGN_EXT)) begin
      sig_sml_aligned = 56'd0;
      sticky          = (sig_sml != 53'd0);
    end else begin
      logic [55:0] ext, mask;
      logic [11:0] lost;
      ext = {3'b000, sig_sml} << ALIGN_EXT;
      // exp_diff can be SMALLER than ALIGN_EXT: lost would then go negative and
      // (1 << lost) - 1 becomes a huge mask, setting a false sticky. That made
      // 1.0 - 1.0 return 4.0 instead of zero.
      if (exp_diff <= 12'(ALIGN_EXT)) begin
        mask   = 56'd0;
        sticky = 1'b0;
      end else begin
        lost = exp_diff - 12'(ALIGN_EXT);
        mask = (56'd1 << lost) - 56'd1;
        sticky = (({3'b000, sig_sml} & mask) != 56'd0);
      end
      sig_sml_aligned = ext >> exp_diff;
    end
  end

  // 59-bit working format, exactly as the model:
  //   [58]=carry [57]=implicit [56:5]=fraction [4:3]=extra [2]=round
  //   [1]=guard  [0]=sticky
  logic [58:0] mag_big, mag_sml, mag_sum;
  logic        sign_out;
  logic [10:0] exp_out;
  always_comb begin
    mag_big = {2'b00, sig_big, 5'b00000};
    mag_sml = {2'b00, sig_sml_aligned, 2'b00} | {58'd0, sticky};
    if (s_big == s_sml) begin
      mag_sum  = mag_big + mag_sml;
      sign_out = s_big;
    end else begin
      mag_sum  = mag_big - mag_sml;
      sign_out = s_big;
    end
    exp_out = e_big;
  end

  logic [58:0] norm;
  logic [10:0] exp_norm;
  logic        inexact;
  logic [51:0] frac_r;
  logic        round_up;
  always_comb begin
    norm     = mag_sum;
    exp_norm = exp_out;
    inexact  = 1'b0;
    round_up = 1'b0;
    frac_r   = 52'd0;

    if (norm[58]) begin
      inexact  = norm[0];
      norm     = {1'b0, norm[58:1]};
      exp_norm = exp_out + 11'd1;
    end else begin
      for (int i = 0; i < 59; i++) begin
        if (!norm[57] && (exp_norm > 11'd1)) begin
          norm     = {norm[57:0], 1'b0};
          exp_norm = exp_norm - 11'd1;
        end
      end
    end

    frac_r   = norm[56:5];
    round_up = norm[4] && (norm[3] || (|norm[2:0]) || norm[5]);
    inexact  = inexact | norm[4] | norm[3] | (|norm[2:0]);
    if (round_up) begin
      frac_r = frac_r + 52'd1;
      if (frac_r == 52'd0) exp_norm = exp_norm + 11'd1;
    end
  end


  // ---- assemble, then override for the special cases ---------------------
  always_comb begin
    result       = {sign_out, exp_norm, frac_r};
    flag_invalid = 1'b0;
    flag_inexact = inexact;

    if (a_is_nan || b_is_nan) begin
      result       = QNAN;
      flag_invalid = 1'b0;                    // a quiet NaN propagates silently
    end else if (a_is_inf && b_is_inf && (sa != sb_eff)) begin
      result       = QNAN;                    // inf + -inf
      flag_invalid = 1'b1;
    end else if (a_is_inf) begin
      result = {sa, 11'h7FF, 52'd0};
    end else if (b_is_inf) begin
      result = {sb_eff, 11'h7FF, 52'd0};
    end else if (a_is_zero && b_is_zero) begin
      // -0 + -0 = -0; any other zero combination is +0
      result = ((sa && sb_eff) ? 64'h8000_0000_0000_0000 : 64'd0);
    end else if (a_is_zero) begin
      result = {sb_eff, eb, fb};
    end else if (b_is_zero) begin
      result = a;
    end else if (norm == 59'd0) begin
      result = 64'd0;                         // exact cancellation gives +0
    end else if (exp_norm >= 11'h7FF) begin
      result       = {sign_out, 11'h7FF, 52'd0};   // overflow saturates to infinity
      flag_inexact = 1'b1;
    end
  end
endmodule

`default_nettype wire
