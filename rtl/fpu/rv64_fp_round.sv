`timescale 1ns/1ps
// =============================================================================
// rv64_fp_round.sv -- binary64 rounding and packing.
//
// One rounder, used by fmul, fdiv, fsqrt and both directions of fcvt.  That is
// deliberate: the five rounding modes are the easiest thing in an FPU to get
// subtly wrong, and four separate copies of the decision would be four chances
// to disagree.  Every operation hands this block the same working format:
//
//     sig = {implicit 1, fraction[51:0], guard, round, sticky}       (56 bits)
//     value = sig * 2**(exp_in - 55)
//
// and gets back a packed binary64 word plus the OF/UF/NX flags.
//
// The subnormal case is handled HERE rather than by each caller: when
// exp_in < -1022 the significand is shifted right until the exponent is -1022
// and every bit shifted out is folded into the sticky bit.  A shift of 56 or
// more leaves a zero significand with sticky set, which is what makes a value
// far below the subnormal range round to +-0 under RTZ and to the smallest
// subnormal under RUP/RDN.
//
// Purely combinational, like the adder.  No reset: there is no state.
// =============================================================================
`default_nettype none

module rv64_fp_round (
  input  logic               sign,
  input  logic signed [12:0] exp_in,   // unbiased exponent of the pre-round value
  input  logic [55:0]        sig,      // {implicit, frac[51:0], G, R, S}
  input  logic [2:0]         rm,       // 000 RNE, 001 RTZ, 010 RDN, 011 RUP, 100 RMM
  output logic [63:0]        result,
  output logic [4:0]         flags     // {NV, DZ, OF, UF, NX} -- NV/DZ never set here
);
  localparam logic [4:0] F_OF = 5'b0_0100;
  localparam logic [4:0] F_UF = 5'b0_0010;
  localparam logic [4:0] F_NX = 5'b0_0001;
  localparam logic [63:0] MAXF = 64'h7FEF_FFFF_FFFF_FFFF;

  // ---- subnormal alignment -------------------------------------------------
  // shift = max(0, -1022 - exp_in), clamped at 56 (a shift of 56 already
  // removes every significand bit and leaves only the sticky).
  logic signed [12:0] shift_s;
  logic [6:0]         shift;
  always_comb begin
    shift_s = -13'sd1022 - exp_in;
    if (shift_s <= 13'sd0)       shift = 7'd0;
    else if (shift_s > 13'sd56)  shift = 7'd56;
    else                         shift = shift_s[6:0];
  end

  logic [55:0] sig_s, lost, mask;
  always_comb begin
    sig_s = sig;
    if (shift != 7'd0) begin
      mask  = (56'd1 << shift) - 56'd1;      // shift == 56 -> all ones
      lost  = sig & mask;
      sig_s = (sig >> shift) | {55'd0, (|lost)};
    end
  end

  logic [51:0] frac;
  logic        g, r, s, any;
  always_comb begin
    frac = sig_s[54:3];
    g    = sig_s[2];
    r    = sig_s[1];
    s    = sig_s[0];
    any  = g | r | s;
  end

  // ---- round decision ------------------------------------------------------
  logic up;
  always_comb begin
    unique case (rm)
      3'd0:    up = g & (r | s | frac[0]);   // round to nearest, ties to even
      3'd1:    up = 1'b0;                    // round toward zero
      3'd2:    up = any &  sign;             // round down
      3'd3:    up = any & ~sign;             // round up
      3'd4:    up = g;                       // round to nearest, ties away
      default: up = 1'b0;                    // reserved encodings behave as RTZ
    endcase
  end

  logic signed [12:0] e_field;
  logic [51:0]        frac_r;
  always_comb begin
    e_field = (shift != 7'd0) ? 13'sd0 : (exp_in + 13'sd1023);
    frac_r  = frac + {51'd0, up};
    if (up && (frac == 52'hF_FFFF_FFFF_FFFF)) begin
      frac_r  = 52'd0;
      e_field = e_field + 13'sd1;
    end
  end

  // ---- overflow result depends on the rounding mode ------------------------
  logic [63:0] ovf;
  always_comb begin
    unique case (rm)
      3'd0, 3'd4: ovf = {sign, 11'h7FF, 52'd0};              // nearest -> infinity
      3'd1:       ovf = {sign, MAXF[62:0]};                  // toward zero -> max
      3'd2:       ovf = sign ? {1'b1, 11'h7FF, 52'd0} : MAXF;  // down
      default:    ovf = sign ? {1'b1, MAXF[62:0]} : {1'b0, 11'h7FF, 52'd0};
    endcase
  end

  always_comb begin
    if (e_field >= 13'sd2047) begin
      result = ovf;
      flags  = F_OF | F_NX;
    end else begin
      result = {sign, e_field[10:0], frac_r};
      flags  = (any ? F_NX : 5'd0) |
               ((any && (e_field == 13'sd0)) ? F_UF : 5'd0);
    end
  end
endmodule

`default_nettype wire
