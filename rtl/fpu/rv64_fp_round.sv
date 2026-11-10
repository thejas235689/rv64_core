`timescale 1ns/1ps
// =============================================================================
// rv64_fp_round.sv -- rounding and packing, binary32 AND binary64.
//
// One rounder, used by add, mul, div, sqrt and every fcvt form in both formats.
// That is deliberate: the five rounding modes are the easiest thing in an FPU to
// get subtly wrong, and a copy per operation would be a copy per chance to
// disagree.  Single precision did NOT get its own rounder -- it got a format
// input on this one.
//
// The working format is identical for both precisions:
//
//     sig = {implicit 1, fraction[FB-1:0], guard, round, sticky}     (FB+4 bits)
//     value = sig * 2**(exp_in - (FB+3))
//
// FB is 52 for binary64 and 23 for binary32, so `sig` is 56 bits for double and
// 27 bits for single, right-aligned in the port.  Guard/round/sticky therefore
// sit at bits [2:0] in BOTH formats, which is what lets the round decision stay
// a single expression.
//
// The subnormal case is handled HERE rather than by each caller: when
// exp_in < emin the significand is shifted right until the exponent is emin and
// every bit shifted out is folded into the sticky.  A shift of 56 or more leaves
// a zero significand with sticky set, which is what makes a value far below the
// subnormal range round to +-0 under RTZ and to the smallest subnormal under
// RUP/RDN.  emin is -1022 for double and -126 for single.
//
// A binary32 result is returned in bits [31:0] with the upper half zero; the
// NaN-boxing that turns it into a legal f-register value is the register file's
// job, not the rounder's.
//
// Purely combinational, like the adder.  No reset: there is no state.
// =============================================================================
`default_nettype none

module rv64_fp_round (
  input  logic               fmt,      // 1 = binary64, 0 = binary32
  input  logic               sign,
  input  logic signed [12:0] exp_in,   // unbiased exponent of the pre-round value
  input  logic [55:0]        sig,      // {implicit, frac, G, R, S}, right-aligned
  input  logic [2:0]         rm,       // 000 RNE, 001 RTZ, 010 RDN, 011 RUP, 100 RMM
  output logic [63:0]        result,
  output logic [4:0]         flags     // {NV, DZ, OF, UF, NX} -- NV/DZ never set here
);
  localparam logic [4:0] F_OF = 5'b0_0100;
  localparam logic [4:0] F_UF = 5'b0_0010;
  localparam logic [4:0] F_NX = 5'b0_0001;

  // ---- format constants ----------------------------------------------------
  logic [6:0]         fbw;    // fraction width         52 / 23
  logic [11:0]        bias;   // 1023 / 127
  logic [11:0]        emax;   // 2047 / 255
  logic signed [12:0] emin;   // -1022 / -126
  logic [5:0]         pos;    // sign bit position      63 / 31
  logic [63:0]        maxf;   // largest finite
  logic [63:0]        infv;   // +infinity
  logic [63:0]        fmask;  // fbw ones in the low bits

  always_comb begin
    if (fmt) begin
      fbw  = 7'd52;
      bias = 12'd1023;
      emax = 12'd2047;
      emin = -13'sd1022;
      pos  = 6'd63;
      maxf = 64'h7FEF_FFFF_FFFF_FFFF;
      infv = 64'h7FF0_0000_0000_0000;
    end else begin
      fbw  = 7'd23;
      bias = 12'd127;
      emax = 12'd255;
      emin = -13'sd126;
      pos  = 6'd31;
      maxf = 64'h0000_0000_7F7F_FFFF;
      infv = 64'h0000_0000_7F80_0000;
    end
    fmask = (64'd1 << fbw) - 64'd1;
  end

  // ---- subnormal alignment -------------------------------------------------
  // shift = max(0, emin - exp_in), clamped at 56 (the port width): a shift of 56
  // already removes every significand bit of either format and leaves the sticky.
  logic signed [12:0] shift_s;
  logic [6:0]         shift;
  always_comb begin
    shift_s = emin - exp_in;
    if (shift_s <= 13'sd0)       shift = 7'd0;
    else if (shift_s > 13'sd56)  shift = 7'd56;
    else                         shift = shift_s[6:0];
  end

  logic [55:0] sig_s, lost, mask;
  always_comb begin
    sig_s = sig;
    mask = '0;
    lost = '0;
    if (shift != 7'd0) begin
      mask  = (56'd1 << shift) - 56'd1;      // shift == 56 -> all ones
      lost  = sig & mask;
      sig_s = (sig >> shift) | {55'd0, (|lost)};
    end
  end

  logic [63:0] frac;
  logic        g, r, s, any;
  always_comb begin
    // guard/round/sticky are at [2:0] in both formats, so only the fraction mask
    // depends on fmt -- this is what keeps one rounder rather than two
    frac = ({8'd0, sig_s} >> 3) & fmask;
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
  logic [63:0]        frac_r;
  logic [11:0]        e_field_u;
  always_comb begin
    e_field   = (shift != 7'd0) ? 13'sd0 : (exp_in + $signed({1'b0, bias}));
    frac_r    = frac + {63'd0, up};
    if (up && (frac == fmask)) begin        // carry out of the fraction
      frac_r  = 64'd0;
      e_field = e_field + 13'sd1;
    end
    e_field_u = e_field[11:0];
  end

  // ---- overflow result depends on the rounding mode ------------------------
  // The sign goes in at `pos`, not at bit 63: a binary32 result carries its sign
  // at bit 31, and forcing it to bit 63 produced 0x800000007F800000 for -inf.
  logic [63:0] inf_s, max_s, ovf;
  always_comb begin
    inf_s = infv | ({63'd0, sign} << pos);
    max_s = maxf | ({63'd0, sign} << pos);
    unique case (rm)
      3'd0, 3'd4: ovf = inf_s;                              // nearest -> infinity
      3'd1:       ovf = max_s;                              // toward zero -> max
      3'd2:       ovf = sign ? inf_s : max_s;               // down
      default:    ovf = sign ? max_s : inf_s;               // up
    endcase
  end

  always_comb begin
    if (e_field_u >= emax) begin
      result = ovf;
      flags  = F_OF | F_NX;
    end else begin
      // assembled with integer shifts so the field widths follow fmt
      result = ({63'd0, sign} << pos) | ({52'd0, e_field_u} << fbw) |
               (frac_r & fmask);
      flags  = (any ? F_NX : 5'd0) |
               ((any && (e_field_u == 12'd0)) ? F_UF : 5'd0);
    end
  end
endmodule

`default_nettype wire
