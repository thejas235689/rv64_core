`timescale 1ns/1ps
// =============================================================================
// rv64_num_wide.sv -- the four research numeric families.
//
//   RNS    residue number system, per-channel modular arithmetic (exact)
//   LNS    logarithmic number system, log-domain arithmetic (exact in-domain)
//   POSIT  posit<16,1>, decode -> operate in Q30.34 -> encode
//   FP32   IEEE-754 binary32 add and multiply, round-to-nearest-even
//
// Everything here is combinational and synthesizable: no tables, no
// simulation-only constructs. Where a family cannot be exact the semantics are
// stated at the point they are decided, and the flags report what was lost
// rather than the hardware pretending otherwise.
// =============================================================================
`default_nettype none

module rv64_num_wide (
  input  logic [4:0]  op,
  input  logic [2:0]  fmt,
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic [63:0] y,
  output logic [7:0]  flags
);

  import rv64_num_pkg::*;

  // ===========================================================================
  // Residue number system -- moduli 3, 5, 7, 11 (pairwise coprime, product 1155)
  //
  //   [1:0] mod 3   [4:2] mod 5   [7:5] mod 7   [11:8] mod 11
  //
  // Add and multiply are per-channel modular operations with no carry between
  // channels, which is the whole point of an RNS: no carry chain, exact, and
  // each channel independent.
  // ===========================================================================
  function automatic logic [1:0] mod3(input logic [2:0] v);
    logic [2:0] r;
    r = v % 3'd3;
    return r[1:0];
  endfunction

  function automatic logic [2:0] mod5(input logic [5:0] v);
    logic [5:0] r;
    r = v % 6'd5;
    return r[2:0];
  endfunction

  function automatic logic [2:0] mod7(input logic [6:0] v);
    logic [6:0] r;
    r = v % 7'd7;
    return r[2:0];
  endfunction

  function automatic logic [3:0] mod11(input logic [7:0] v);
    logic [7:0] r;
    r = v % 8'd11;
    return r[3:0];
  endfunction

  function automatic logic [3:0] mod13(input logic [8:0] v);
    logic [8:0] r;
    r = v % 9'd13;
    return r[3:0];
  endfunction

  logic [1:0] a3, b3;
  logic [2:0] a5, b5, a7, b7;
  logic [3:0] a11, b11;
  logic [63:0] rns_y;

  assign a3 = a[1:0];   assign b3 = b[1:0];
  assign a5 = a[4:2];   assign b5 = b[4:2];
  assign a7 = a[7:5];   assign b7 = b[7:5];
  assign a11 = a[11:8]; assign b11 = b[11:8];

  // fmt selects the modulus set, and with it the packed width:
  //   0 -> {3,5,7,11} in 12 bits    1 -> {3,5,7} in 8 bits
  //   2 -> {3,5,7,11,13} in 16 bits
  logic [3:0] a13, b13;

  assign a13 = a[15:12];
  assign b13 = b[15:12];

  always_comb begin
    rns_y = 64'd0;
    if (op == NUM_RADD) begin
      rns_y[1:0]  = mod3({1'b0, a3} + {1'b0, b3});
      rns_y[4:2]  = mod5({1'b0, a5} + {1'b0, b5});
      rns_y[7:5]  = mod7({1'b0, a7} + {1'b0, b7});
      if (fmt != 3'd1) rns_y[11:8] = mod11({1'b0, a11} + {1'b0, b11});
      if (fmt == 3'd2) rns_y[15:12] = mod13({1'b0, a13} + {1'b0, b13});
    end else if (op == NUM_RSUB) begin
      rns_y[1:0] = mod3(3'd3 + {1'b0, a3} - {1'b0, b3});
      rns_y[4:2] = mod5(6'd10 + 6'(a5) - 6'(b5));
      rns_y[7:5] = mod7(7'd7 + 7'(a7) - 7'(b7));
      if (fmt != 3'd1) rns_y[11:8] = mod11(8'd22 + 8'(a11) - 8'(b11));
      if (fmt == 3'd2) rns_y[15:12] = mod13(9'd26 + 9'(a13) - 9'(b13));
    end else begin
      rns_y[1:0]  = mod3(a3 * b3);
      rns_y[4:2]  = mod5(a5 * b5);
      rns_y[7:5]  = mod7(a7 * b7);
      if (fmt != 3'd1) rns_y[11:8] = mod11(a11 * b11);
      if (fmt == 3'd2) rns_y[15:12] = mod13(a13 * b13);
    end
  end

  // ===========================================================================
  // Logarithmic number system
  //
  // Encodes nonnegative values as signed base-2 logarithms. The minimum
  // code of each format represents zero. Multiply/divide add/subtract the
  // logarithms exactly. Add/subtract approximate the log-domain correction;
  // subtraction that would produce a negative value signals invalid.
  // ===========================================================================
  // fmt selects the log width and with it the Q format:
  //   0 -> Q16.16 in 32 bits   1 -> Q8.8 in 16 bits   2 -> Q32.32 in 64 bits
  // Formats 3 and 4 add a sign immediately above the Q16.16 or Q8.8 log.
  // The zero sentinel keeps its sign clear. Legacy formats retain their ABI.
  wire lns_signed = fmt == 3'd3 || fmt == 3'd4;
  wire [2:0] lns_fmt = fmt == 3'd3 ? 3'd0 : fmt == 3'd4 ? 3'd1 : fmt;
  wire lns_sign_a = lns_signed && (fmt == 3'd3 ? a[32] : a[16]);
  wire lns_sign_b = lns_signed && (fmt == 3'd3 ? b[32] : b[16]);
  wire lns_addsub = op == NUM_LNADD || op == NUM_LNSUB;
  wire lns_rhs_sign = lns_sign_b ^ (op == NUM_LNSUB);
  wire lns_sub_magnitude = lns_signed ? lns_sign_a ^ lns_rhs_sign
                                       : op == NUM_LNSUB;
  logic [6:0]          lns_w;
  logic signed [63:0]  lns_zero, lns_max, lns_min;
  logic signed [63:0]  la_w, lb_w;
  logic [63:0]         a_w, b_w;
  logic                la_zero, lb_zero;
  logic signed [64:0]  lsum;
  // A concatenation is UNSIGNED in Verilog, so {sign, min} compared as unsigned
  // made every result look below the minimum. The bounds are widened into
  // signed variables so the comparisons stay signed.
  logic signed [64:0]  lns_max65, lns_min65;
  logic [63:0]         lns_mask;
  logic [63:0]         lns_y;
  logic [7:0]          lns_flags;

  always_comb begin
    case (lns_fmt)
      3'd1:    lns_w = 7'd16;
      3'd2:    lns_w = 7'd64;
      default: lns_w = 7'd32;
    endcase
    lns_zero = $signed(64'd1) <<< (lns_w - 1);      // -infinity / zero code
    lns_max  = (64'sd1 <<< (lns_w - 1)) - 64'sd1;
    lns_min  = -(64'sd1 <<< (lns_w - 1));

    // sign-extend each operand at its own width, and zero-extend for the
    // zero-code comparison
    case (lns_fmt)
      3'd1: begin
        la_w = {{48{a[15]}}, a[15:0]};
        lb_w = {{48{b[15]}}, b[15:0]};
        a_w  = {48'd0, a[15:0]};
        b_w  = {48'd0, b[15:0]};
      end
      3'd2: begin
        la_w = $signed(a);
        lb_w = $signed(b);
        a_w  = a;
        b_w  = b;
      end
      default: begin
        la_w = {{32{a[31]}}, a[31:0]};
        lb_w = {{32{b[31]}}, b[31:0]};
        a_w  = {32'd0, a[31:0]};
        b_w  = {32'd0, b[31:0]};
      end
    endcase

    lns_mask  = (64'd1 << lns_w) - 64'd1;
    lns_max65 = {lns_max[63], lns_max};
    lns_min65 = {lns_min[63], lns_min};
    la_zero = (a_w == (lns_zero & lns_mask));
    lb_zero = (b_w == (lns_zero & lns_mask));
  end

  // Correction ROM in Q16.16, sampled at d=i/8, where d is the
  // absolute difference between the two log operands. Linear interpolation
  // uses the next 16 bits of d. Subtraction below d=1 uses a separate
  // normalized path because its correction tends to -infinity at d=0.
  function automatic logic signed [31:0] lns_rom(input logic [7:0] index,
                                                 input logic subtract);
    case (index)
      8'd0: lns_rom = subtract ? 32'sd0 : 32'sd65536;
      8'd1: lns_rom = subtract ? 32'sd0 : 32'sd61529;
      8'd2: lns_rom = subtract ? 32'sd0 : 32'sd57698;
      8'd3: lns_rom = subtract ? 32'sd0 : 32'sd54044;
      8'd4: lns_rom = subtract ? 32'sd0 : 32'sd50565;
      8'd5: lns_rom = subtract ? 32'sd0 : 32'sd47257;
      8'd6: lns_rom = subtract ? 32'sd0 : 32'sd44119;
      8'd7: lns_rom = subtract ? 32'sd0 : 32'sd41146;
      8'd8: lns_rom = subtract ? -32'sd65536 : 32'sd38336;
      8'd9: lns_rom = subtract ? -32'sd57998 : 32'sd35684;
      8'd10: lns_rom = subtract ? -32'sd51576 : 32'sd33184;
      8'd11: lns_rom = subtract ? -32'sd46048 : 32'sd30832;
      8'd12: lns_rom = subtract ? -32'sd41248 : 32'sd28623;
      8'd13: lns_rom = subtract ? -32'sd37051 : 32'sd26551;
      8'd14: lns_rom = subtract ? -32'sd33359 : 32'sd24610;
      8'd15: lns_rom = subtract ? -32'sd30096 : 32'sd22794;
      8'd16: lns_rom = subtract ? -32'sd27200 : 32'sd21098;
      8'd17: lns_rom = subtract ? -32'sd24620 : 32'sd19515;
      8'd18: lns_rom = subtract ? -32'sd22314 : 32'sd18040;
      8'd19: lns_rom = subtract ? -32'sd20248 : 32'sd16667;
      8'd20: lns_rom = subtract ? -32'sd18392 : 32'sd15391;
      8'd21: lns_rom = subtract ? -32'sd16722 : 32'sd14204;
      8'd22: lns_rom = subtract ? -32'sd15216 : 32'sd13103;
      8'd23: lns_rom = subtract ? -32'sd13856 : 32'sd12082;
      8'd24: lns_rom = subtract ? -32'sd12625 : 32'sd11136;
      8'd25: lns_rom = subtract ? -32'sd11511 : 32'sd10260;
      8'd26: lns_rom = subtract ? -32'sd10500 : 32'sd9450;
      8'd27: lns_rom = subtract ? -32'sd9583 : 32'sd8700;
      8'd28: lns_rom = subtract ? -32'sd8750 : 32'sd8008;
      8'd29: lns_rom = subtract ? -32'sd7992 : 32'sd7369;
      8'd30: lns_rom = subtract ? -32'sd7302 : 32'sd6778;
      8'd31: lns_rom = subtract ? -32'sd6674 : 32'sd6234;
      8'd32: lns_rom = subtract ? -32'sd6102 : 32'sd5732;
      8'd33: lns_rom = subtract ? -32'sd5580 : 32'sd5269;
      8'd34: lns_rom = subtract ? -32'sd5104 : 32'sd4843;
      8'd35: lns_rom = subtract ? -32'sd4670 : 32'sd4450;
      8'd36: lns_rom = subtract ? -32'sd4274 : 32'sd4089;
      8'd37: lns_rom = subtract ? -32'sd3911 : 32'sd3756;
      8'd38: lns_rom = subtract ? -32'sd3581 : 32'sd3450;
      8'd39: lns_rom = subtract ? -32'sd3278 : 32'sd3168;
      8'd40: lns_rom = subtract ? -32'sd3002 : 32'sd2909;
      8'd41: lns_rom = subtract ? -32'sd2749 : 32'sd2671;
      8'd42: lns_rom = subtract ? -32'sd2518 : 32'sd2452;
      8'd43: lns_rom = subtract ? -32'sd2306 : 32'sd2251;
      8'd44: lns_rom = subtract ? -32'sd2113 : 32'sd2066;
      8'd45: lns_rom = subtract ? -32'sd1936 : 32'sd1897;
      8'd46: lns_rom = subtract ? -32'sd1773 : 32'sd1741;
      8'd47: lns_rom = subtract ? -32'sd1625 : 32'sd1597;
      8'd48: lns_rom = subtract ? -32'sd1489 : 32'sd1466;
      8'd49: lns_rom = subtract ? -32'sd1365 : 32'sd1345;
      8'd50: lns_rom = subtract ? -32'sd1251 : 32'sd1234;
      8'd51: lns_rom = subtract ? -32'sd1146 : 32'sd1132;
      8'd52: lns_rom = subtract ? -32'sd1050 : 32'sd1039;
      8'd53: lns_rom = subtract ? -32'sd963 : 32'sd953;
      8'd54: lns_rom = subtract ? -32'sd883 : 32'sd874;
      8'd55: lns_rom = subtract ? -32'sd809 : 32'sd802;
      8'd56: lns_rom = subtract ? -32'sd742 : 32'sd736;
      8'd57: lns_rom = subtract ? -32'sd680 : 32'sd675;
      8'd58: lns_rom = subtract ? -32'sd623 : 32'sd619;
      8'd59: lns_rom = subtract ? -32'sd571 : 32'sd568;
      8'd60: lns_rom = subtract ? -32'sd524 : 32'sd521;
      8'd61: lns_rom = subtract ? -32'sd480 : 32'sd478;
      8'd62: lns_rom = subtract ? -32'sd440 : 32'sd438;
      8'd63: lns_rom = subtract ? -32'sd404 : 32'sd402;
      8'd64: lns_rom = subtract ? -32'sd370 : 32'sd369;
      8'd65: lns_rom = subtract ? -32'sd339 : 32'sd338;
      8'd66: lns_rom = subtract ? -32'sd311 : 32'sd310;
      8'd67: lns_rom = subtract ? -32'sd285 : 32'sd284;
      8'd68: lns_rom = subtract ? -32'sd262 : 32'sd261;
      8'd69: lns_rom = subtract ? -32'sd240 : 32'sd239;
      8'd70: lns_rom = subtract ? -32'sd220 : 32'sd219;
      8'd71: lns_rom = subtract ? -32'sd202 : 32'sd201;
      8'd72: lns_rom = subtract ? -32'sd185 : 32'sd184;
      8'd73: lns_rom = subtract ? -32'sd169 : 32'sd169;
      8'd74: lns_rom = subtract ? -32'sd155 : 32'sd155;
      8'd75: lns_rom = subtract ? -32'sd143 : 32'sd142;
      8'd76: lns_rom = subtract ? -32'sd131 : 32'sd130;
      8'd77: lns_rom = subtract ? -32'sd120 : 32'sd120;
      8'd78: lns_rom = subtract ? -32'sd110 : 32'sd110;
      8'd79: lns_rom = subtract ? -32'sd101 : 32'sd101;
      8'd80: lns_rom = subtract ? -32'sd92 : 32'sd92;
      8'd81: lns_rom = subtract ? -32'sd85 : 32'sd85;
      8'd82: lns_rom = subtract ? -32'sd78 : 32'sd78;
      8'd83: lns_rom = subtract ? -32'sd71 : 32'sd71;
      8'd84: lns_rom = subtract ? -32'sd65 : 32'sd65;
      8'd85: lns_rom = subtract ? -32'sd60 : 32'sd60;
      8'd86: lns_rom = subtract ? -32'sd55 : 32'sd55;
      8'd87: lns_rom = subtract ? -32'sd50 : 32'sd50;
      8'd88: lns_rom = subtract ? -32'sd46 : 32'sd46;
      8'd89: lns_rom = subtract ? -32'sd42 : 32'sd42;
      8'd90: lns_rom = subtract ? -32'sd39 : 32'sd39;
      8'd91: lns_rom = subtract ? -32'sd36 : 32'sd36;
      8'd92: lns_rom = subtract ? -32'sd33 : 32'sd33;
      8'd93: lns_rom = subtract ? -32'sd30 : 32'sd30;
      8'd94: lns_rom = subtract ? -32'sd27 : 32'sd27;
      8'd95: lns_rom = subtract ? -32'sd25 : 32'sd25;
      8'd96: lns_rom = subtract ? -32'sd23 : 32'sd23;
      8'd97: lns_rom = subtract ? -32'sd21 : 32'sd21;
      8'd98: lns_rom = subtract ? -32'sd19 : 32'sd19;
      8'd99: lns_rom = subtract ? -32'sd18 : 32'sd18;
      8'd100: lns_rom = subtract ? -32'sd16 : 32'sd16;
      8'd101: lns_rom = subtract ? -32'sd15 : 32'sd15;
      8'd102: lns_rom = subtract ? -32'sd14 : 32'sd14;
      8'd103: lns_rom = subtract ? -32'sd13 : 32'sd13;
      8'd104: lns_rom = subtract ? -32'sd12 : 32'sd12;
      8'd105: lns_rom = subtract ? -32'sd11 : 32'sd11;
      8'd106: lns_rom = subtract ? -32'sd10 : 32'sd10;
      8'd107: lns_rom = subtract ? -32'sd9 : 32'sd9;
      8'd108: lns_rom = subtract ? -32'sd8 : 32'sd8;
      8'd109: lns_rom = subtract ? -32'sd7 : 32'sd7;
      8'd110: lns_rom = subtract ? -32'sd7 : 32'sd7;
      8'd111: lns_rom = subtract ? -32'sd6 : 32'sd6;
      8'd112: lns_rom = subtract ? -32'sd6 : 32'sd6;
      8'd113: lns_rom = subtract ? -32'sd5 : 32'sd5;
      8'd114: lns_rom = subtract ? -32'sd5 : 32'sd5;
      8'd115: lns_rom = subtract ? -32'sd4 : 32'sd4;
      8'd116: lns_rom = subtract ? -32'sd4 : 32'sd4;
      8'd117: lns_rom = subtract ? -32'sd4 : 32'sd4;
      8'd118: lns_rom = subtract ? -32'sd3 : 32'sd3;
      8'd119: lns_rom = subtract ? -32'sd3 : 32'sd3;
      8'd120: lns_rom = subtract ? -32'sd3 : 32'sd3;
      8'd121: lns_rom = subtract ? -32'sd3 : 32'sd3;
      8'd122: lns_rom = subtract ? -32'sd2 : 32'sd2;
      8'd123: lns_rom = subtract ? -32'sd2 : 32'sd2;
      8'd124: lns_rom = subtract ? -32'sd2 : 32'sd2;
      8'd125: lns_rom = subtract ? -32'sd2 : 32'sd2;
      8'd126: lns_rom = subtract ? -32'sd2 : 32'sd2;
      8'd127: lns_rom = subtract ? -32'sd2 : 32'sd2;
      8'd128: lns_rom = subtract ? -32'sd1 : 32'sd1;
      default: lns_rom = 32'sd0;
    endcase
  endfunction

  function automatic logic signed [31:0] log_mantissa(input logic [4:0] index);
    case (index)
      5'd0: log_mantissa = 32'sd0;
      5'd1: log_mantissa = 32'sd5732;
      5'd2: log_mantissa = 32'sd11136;
      5'd3: log_mantissa = 32'sd16248;
      5'd4: log_mantissa = 32'sd21098;
      5'd5: log_mantissa = 32'sd25711;
      5'd6: log_mantissa = 32'sd30109;
      5'd7: log_mantissa = 32'sd34312;
      5'd8: log_mantissa = 32'sd38336;
      5'd9: log_mantissa = 32'sd42196;
      5'd10: log_mantissa = 32'sd45904;
      5'd11: log_mantissa = 32'sd49472;
      5'd12: log_mantissa = 32'sd52911;
      5'd13: log_mantissa = 32'sd56229;
      5'd14: log_mantissa = 32'sd59434;
      5'd15: log_mantissa = 32'sd62534;
      5'd16: log_mantissa = 32'sd65536;
      default: log_mantissa = 32'sd0;
    endcase
  endfunction

  function automatic logic signed [31:0] interpolate(
      input logic signed [31:0] lo, hi, input logic [15:0] frac);
    logic signed [48:0] product;
    product = (49'(hi) - 49'(lo)) *
              $signed({1'b0, frac});
    return lo + 32'(product >>> 16);
  endfunction

  function automatic logic signed [31:0] lns_correction(
      input logic [64:0] delta, input logic subtract);
    logic [7:0] index;
    logic [31:0] normalized, d;
    logic [31:0] square;
    logic [47:0] quadratic;
    int msb;
    if (delta >= (65'd16 << 32)) return 32'sd0;
    if (!subtract || delta >= (65'd1 << 32)) begin
      index = delta[36:29];
      return interpolate(lns_rom(index, subtract),
                         lns_rom(index + 8'd1, subtract), delta[28:13]);
    end

    // For 0 < d < 1, log2(1-2^-d) = log2(d) + log2(ln 2)
    // - d/2 + (ln 2)*d*d/24 + O(d^4). Normalize d before approximating
    // log2(d) to preserve resolution even for one Q32.32 input ULP.
    d = {16'd0, delta[31:16]};
    square = d * d;
    quadratic = square * 16'd1893; // round(65536 * ln(2) / 24)
    msb = 0;
    for (int bit_index = 0; bit_index < 32; bit_index++)
      if (delta[bit_index]) msb = bit_index;
    normalized = delta[31:0] << (31 - msb);
    return ((msb - 32) <<< 16) +
           interpolate(log_mantissa({1'b0, normalized[30:27]}),
                       log_mantissa({1'b0, normalized[30:27]} + 5'd1),
                       normalized[26:11]) - 32'sd34653 -
           $signed(d >> 1) + $signed({16'd0, quadratic[47:32]});
  endfunction

  logic signed [64:0] delta, lns_base, correction;
  logic signed [31:0] correction_q16;
  logic [64:0] delta_q32;
  always_comb begin
    delta = $signed({la_w[63], la_w}) - $signed({lb_w[63], lb_w});
    lns_base = delta < 0 ? $signed({lb_w[63], lb_w}) :
                           $signed({la_w[63], la_w});
    delta_q32 = delta < 0 ? $unsigned(-delta) : $unsigned(delta);
    // Clamp first to prevent a large fixed-point delta wrapping on conversion.
    case (lns_fmt)
      3'd0: delta_q32 = delta_q32 >= (65'd16 << 16) ? (65'd16 << 32) : delta_q32 << 16;
      3'd1: delta_q32 = delta_q32 >= (65'd16 << 8) ? (65'd16 << 32) : delta_q32 << 24;
      default: ;
    endcase
    correction_q16 = 32'sd0;
    if (lns_addsub && !la_zero && !lb_zero &&
        (!lns_sub_magnitude || (lns_signed ? delta != 0 : delta > 0)))
      correction_q16 = lns_correction(delta_q32, lns_sub_magnitude);
    case (lns_fmt)
      3'd1: correction = (65'($signed(correction_q16)) + 65'sd128) >>> 8;
      3'd2: correction = 65'($signed(correction_q16)) <<< 16;
      default: correction = 65'($signed(correction_q16));
    endcase
  end

  logic lns_result_sign;
  always_comb begin
    lns_result_sign = lns_sign_a ^ lns_sign_b;
    lsum      = 65'sd0;
    lns_y     = 64'd0;
    lns_flags = 8'd0;

    if (lns_addsub) begin
      lns_result_sign = lb_zero || (!la_zero && delta >= 0)
                      ? lns_sign_a : lns_rhs_sign;
      if (lns_fmt > 3'd2) begin
        lns_y = lns_zero;
        lns_flags[FLAG_INVALID] = 1'b1;
      end else if (lb_zero || ((lns_signed || op == NUM_LNADD) && la_zero)) begin
        lns_y = lb_zero ? a_w : b_w;
      end else if (!lns_signed && op == NUM_LNSUB && (la_zero || delta < 0)) begin
        lns_y = lns_zero;
        lns_flags[FLAG_INVALID] = 1'b1;
      end else if (lns_sub_magnitude && delta == 0) begin
        lns_y = lns_zero;
      end else begin
        lsum = lns_base + correction;
        lns_flags[FLAG_INEXACT] = delta != 0 &&
                                 !(lns_sub_magnitude && delta_q32 == (65'd1 << 32));
        if (lsum > lns_max65) begin
          lns_y = lns_max;
          lns_flags[FLAG_OVERFLOW] = 1'b1;
          lns_flags[FLAG_INEXACT] = 1'b1;
        end else if (lsum <= lns_min65) begin
          lns_y = lns_zero;
          lns_flags[FLAG_UNDERFLOW] = 1'b1;
          lns_flags[FLAG_INEXACT] = 1'b1;
        end else begin
          lns_y = lsum[63:0];
        end
      end
    end else if (op == NUM_LNMUL) begin
      if (la_zero || lb_zero) begin
        lns_y = lns_zero[63:0];
      end else begin
        lsum = $signed(la_w) + $signed(lb_w);
        if (lsum > lns_max65) begin
          lns_y = lns_max[63:0];
          lns_flags[FLAG_OVERFLOW] = 1'b1;
        end else if (lsum < lns_min65) begin
          lns_y = lns_zero[63:0];
          lns_flags[FLAG_OVERFLOW] = 1'b1;
        end else begin
          lns_y = lsum[63:0];
        end
      end
    end else begin
      if (lb_zero) begin
        lns_y = lns_max[63:0];
        lns_flags[FLAG_DIVZERO] = 1'b1;
      end else if (la_zero) begin
        lns_y = lns_zero[63:0];
      end else begin
        lsum = $signed(la_w) - $signed(lb_w);
        if (lsum > lns_max65) begin
          lns_y = lns_max[63:0];
          lns_flags[FLAG_OVERFLOW] = 1'b1;
        end else if (lsum < lns_min65) begin
          lns_y = lns_zero[63:0];
          lns_flags[FLAG_OVERFLOW] = 1'b1;
        end else begin
          lns_y = lsum[63:0];
        end
      end
    end
    if (lns_signed && (lns_y & lns_mask) != (lns_zero & lns_mask))
      lns_y = (lns_y & lns_mask) | (64'(lns_result_sign) << lns_w);
  end

  // ===========================================================================
  // IEEE-754 binary32
  //
  // Normal numbers round to nearest-even; infinity and NaN are handled;
  // subnormals are flushed to zero (documented, and the underflow flag says so)
  // because gradual underflow needs a variable shifter on the output path that
  // this design does not carry.
  // ===========================================================================
  logic        sa, sb;
  logic [7:0]  ea, eb;
  logic [22:0] fa, fb;
  logic        a_nan, b_nan, a_inf, b_inf, a_zero, b_zero;

  assign sa = a[31]; assign ea = a[30:23]; assign fa = a[22:0];
  assign sb = b[31]; assign eb = b[30:23]; assign fb = b[22:0];
  assign a_nan  = (ea == 8'hFF) && (fa != 23'd0);
  assign b_nan  = (eb == 8'hFF) && (fb != 23'd0);
  assign a_inf  = (ea == 8'hFF) && (fa == 23'd0);
  assign b_inf  = (eb == 8'hFF) && (fb == 23'd0);
  assign a_zero = (ea == 8'h00);
  assign b_zero = (eb == 8'h00);

  localparam logic [31:0] FP_QNAN = 32'h7FC0_0000;

  logic [63:0] fp_y;
  logic [7:0]  fp_flags;
  logic [47:0] fp_prod;
  logic [25:0] fp_man;
  logic signed [10:0] fp_exp;          // signed: a negative exponent must not wrap
  logic        fp_guard, fp_sticky;

  logic [27:0] add_big, add_small, add_small_s, add_sum;
  logic [9:0]  add_ebig, add_esmall, add_diff;
  logic [4:0]  add_shift;
  logic        add_sign, add_round;

  always_comb begin
    fp_y      = 64'd0;
    fp_flags  = 8'd0;
    fp_prod   = 48'd0;
    fp_man    = 26'd0;
    fp_exp    = 11'sd0;
    fp_guard  = 1'b0;
    fp_sticky = 1'b0;
    add_big   = 28'd0;
    add_small = 28'd0;
    add_small_s = 28'd0;
    add_sum   = 28'd0;
    add_ebig  = 10'd0;
    add_esmall= 10'd0;
    add_diff  = 10'd0;
    add_shift = 5'd0;
    add_sign  = 1'b0;
    add_round = 1'b0;

    if (op == NUM_FMUL) begin
      if (a_nan || b_nan) begin
        fp_y = {32'd0, FP_QNAN};
        fp_flags[FLAG_INVALID] = 1'b1;
      end else if ((a_inf && b_zero) || (b_inf && a_zero)) begin
        fp_y = {32'd0, FP_QNAN};
        fp_flags[FLAG_INVALID] = 1'b1;
      end else if (a_inf || b_inf) begin
        fp_y = {32'd0, sa ^ sb, 8'hFF, 23'd0};
      end else if (a_zero || b_zero) begin
        fp_y = {32'd0, sa ^ sb, 31'd0};
      end else begin
        fp_prod = {1'b1, fa} * {1'b1, fb};
        fp_exp  = $signed({3'b0, ea}) + $signed({3'b0, eb}) - 11'sd127;
        // prod = (1.fa * 1.fb) * 2^46. The left shift only moves the 24-bit
        // window so its leading one sits at bit 47; the value is unchanged, so
        // the exponent stays ea+eb-127.
        if (!fp_prod[47]) fp_prod = fp_prod << 1;
        fp_man    = {2'b0, fp_prod[47:24]};
        fp_guard  = fp_prod[23];
        fp_sticky = |fp_prod[22:0];
        if (fp_guard && (fp_sticky || fp_man[0])) fp_man = fp_man + 26'd1;
        if (fp_man[24]) begin
          fp_man = fp_man >> 1;
          fp_exp = fp_exp + 11'sd1;
        end
        if (fp_exp >= 11'sd255) begin
          fp_y = {32'd0, sa ^ sb, 8'hFF, 23'd0};
          fp_flags[FLAG_OVERFLOW] = 1'b1;
        end else if (fp_exp <= 11'sd0) begin
          fp_y = {32'd0, sa ^ sb, 31'd0};
          fp_flags[FLAG_UNDERFLOW] = 1'b1;
        end else begin
          fp_y = {32'd0, sa ^ sb, fp_exp[7:0], fp_man[22:0]};
        end
      end
    end else begin
      if (a_nan || b_nan) begin
        fp_y = {32'd0, FP_QNAN};
        fp_flags[FLAG_INVALID] = 1'b1;
      end else if (a_inf && b_inf && (sa != sb)) begin
        fp_y = {32'd0, FP_QNAN};
        fp_flags[FLAG_INVALID] = 1'b1;
      end else if (a_inf) begin
        fp_y = {32'd0, sa, 8'hFF, 23'd0};
      end else if (b_inf) begin
        fp_y = {32'd0, sb, 8'hFF, 23'd0};
      end else if (a_zero && b_zero) begin
        fp_y = {32'd0, sa & sb, 31'd0};
      end else if (a_zero) begin
        fp_y = {32'd0, sb, eb, fb};
      end else if (b_zero) begin
        fp_y = {32'd0, sa, ea, fa};
      end else begin
        if ({2'b0, ea} >= {2'b0, eb}) begin
          add_ebig = {2'b0, ea}; add_esmall = {2'b0, eb};
          add_big  = {1'b0, 1'b1, fa, 3'b000};
          add_small= {1'b0, 1'b1, fb, 3'b000};
          add_sign = sa;
        end else begin
          add_ebig = {2'b0, eb}; add_esmall = {2'b0, ea};
          add_big  = {1'b0, 1'b1, fb, 3'b000};
          add_small= {1'b0, 1'b1, fa, 3'b000};
          add_sign = sb;
        end
        // a part-select of an expression is not portable, so the difference is
        // computed once into a variable
        add_diff  = add_ebig - add_esmall;
        add_shift = (add_diff > 10'd26) ? 5'd26 : add_diff[4:0];
        add_small_s = add_small >> add_shift;
        if (add_diff > 10'd0)
          add_small_s[0] = add_small_s[0] |
                           (|(add_small & ((28'd1 << add_shift) - 28'd1)));

        if (sa == sb) add_sum = add_big + add_small_s;
        else          add_sum = add_big - add_small_s;
        fp_exp = $signed({1'b0, add_ebig});

        if (add_sum == 28'd0) begin
          fp_y = {32'd0, 31'd0};
        end else begin
          if (add_sum[27]) begin
            add_sum = add_sum >> 1;
            fp_exp  = fp_exp + 11'sd1;
          end else begin
            for (int i = 0; i < 27; i++) begin
              if (!add_sum[26] && (add_sum != 28'd0)) begin
                add_sum = add_sum << 1;
                fp_exp  = fp_exp - 11'sd1;
              end
            end
          end
          fp_man    = {2'b0, add_sum[26:3]};
          fp_guard  = add_sum[2];
          add_round = add_sum[1];
          fp_sticky = add_sum[0];
          if (fp_guard && (add_round || fp_sticky || fp_man[0]))
            fp_man = fp_man + 26'd1;
          if (fp_man[24]) begin
            fp_man = fp_man >> 1;
            fp_exp = fp_exp + 11'sd1;
          end
          if (fp_exp >= 11'sd255) begin
            fp_y = {32'd0, add_sign, 8'hFF, 23'd0};
            fp_flags[FLAG_OVERFLOW] = 1'b1;
          end else if (fp_exp <= 11'sd0) begin
            fp_y = {32'd0, add_sign, 31'd0};
            fp_flags[FLAG_UNDERFLOW] = 1'b1;
          end else begin
            fp_y = {32'd0, add_sign, fp_exp[7:0], fp_man[22:0]};
          end
        end
      end
    end
  end

  // ===========================================================================
  // posit family -- posit<8,1>, posit<16,1>, posit<32,1>
  //
  //   sign | regime | exponent(es=1) | fraction
  //   value = (-1)^sign * useed^k * 2^e * (1 + f),  useed = 2^(2^es) = 4
  //
  // `fmt` selects the width: 0 = 16 bits, 1 = 8 bits, 2 = 32 bits. Arithmetic
  // is done in a signed Q63.64 fixed point (128 bits), which is the smallest
  // format that holds posit32's range (about 2^60) as well as posit8's and
  // posit16's, so one datapath serves all three.
  // ===========================================================================
  localparam int POS_FRAC_BITS = 64;
  localparam int POS_W = 128;

  function automatic int posit_width(input logic [2:0] f);
    case (f)
      3'd1:    return 8;
      3'd2:    return 32;
      default: return 16;
    endcase
  endfunction

  // decode one posit of width n into Q63.64
  function automatic logic signed [127:0] posit_decode(input logic [31:0] p,
                                                       input int n);
    logic               sgn, stopped;
    logic [31:0]        body;
    int                 run, j, idx, k, n_frac, shift;
    logic [31:0]        frac;
    logic [127:0]       mant;
    logic signed [127:0] out;
    begin
      sgn  = p[n-1];
      body = p & ((32'd1 << (n-1)) - 32'd1);
      run = 0; stopped = 1'b0; frac = 32'd0; n_frac = 0; k = 0;
      if (body == 32'd0) begin
        out = 128'sd0;
      end else begin
        // length of the run of identical bits starting at bit n-2
        for (j = n - 2; j >= 0; j = j - 1) begin
          if (!stopped && (body[j] == body[n-2])) run = run + 1;
          else stopped = 1'b1;
        end
        if (body[n-2]) k = run - 1;
        else           k = -run;

        idx = (n - 2) - run - 1;          // the es exponent bit
        if (idx >= 0) begin
          n_frac = idx;
          frac   = body & ((32'd1 << idx) - 32'd1);
        end else begin
          n_frac = 0;
          frac   = 32'd0;
        end

        // variable part-selects are not portable, so the significand is built
        // with shifts: (2^(n-2) + frac) >> ((n-2) - n_frac)
        mant  = ((128'd1 << (n - 2)) + {96'd0, frac}) >> ((n - 2) - n_frac);
        shift = 2*k + ((idx >= 0) ? ((body >> idx) & 1) : 0) + POS_FRAC_BITS - n_frac;
        if (shift >= 0) out = mant <<< shift;
        else            out = mant >>> (-shift);
        if (sgn) out = -out;
      end
      return out;
    end
  endfunction

  // encode Q63.64 back into a posit of width n, round to nearest even
  function automatic logic [31:0] posit_encode(input logic signed [127:0] v,
                                               input int n);
    logic               sgn, round_up;
    logic [127:0]       mag, below, tail, body;
    int                 lead, e2, k, r, nfrac, rlen, disc, i;
    logic [127:0]       regime_val, fracbits;
    logic [31:0]        out;
    begin
      sgn = v[127];
      mag = sgn ? (~v + 128'd1) : v;
      out = 32'd0;
      if (mag == 128'd0) begin
        out = 32'd0;
      end else begin
        lead = 0;
        for (i = 0; i <= 127; i++) if (mag[i]) lead = i;
        e2 = lead - POS_FRAC_BITS;
        if (e2 >= 0) k = e2 >> 1;
        else         k = -(((-e2) + 1) >> 1);
        r = e2 - 2 * k;

        // k >= 0 is k+1 ones followed by a terminating zero, so the regime is
        // k+2 bits; k < 0 is |k| zeros followed by a terminating one
        if (k >= 0) begin
          rlen       = k + 2;
          regime_val = (128'd1 << (k + 2)) - 128'd2;
        end else begin
          rlen       = (-k) + 1;
          regime_val = 128'd1;
        end

        // body is n-1 bits: rlen + 1 (es) + nfrac
        nfrac = (n - 2) - rlen;
        if (nfrac < 0 || rlen > (n - 1)) begin
          out = sgn ? (32'd1 << (n-1)) | 32'd1 : ((32'd1 << (n-1)) - 32'd1);
        end else begin
          below    = (lead >= 1) ? (mag << (127 - lead)) : 128'd0;
          fracbits = (nfrac == 0) ? 128'd0
                                  : ((below >> (127 - nfrac)) & ((128'd1 << nfrac) - 128'd1));
          disc     = 127 - nfrac;
          tail     = (disc <= 0) ? 128'd0
                                 : ((disc >= 128) ? below : (below & ((128'd1 << disc) - 128'd1)));
          round_up = (nfrac > 0) && (disc >= 1) &&
                     (((below >> (disc - 1)) & 128'd1) == 128'd1) &&
                     ((tail != (128'd1 << (disc - 1))) || (fracbits[0] == 1'b1));
          if (round_up) begin
            fracbits = fracbits + 128'd1;
            if ((fracbits >> nfrac) != 128'd0) begin   // explicit: a vector is true if any bit is set
              fracbits = 128'd0;
              r = r + 1;
              if (r > 1) begin
                r = 0;
                k = k + 1;
                if (k >= 0) begin
                  rlen       = k + 2;
                  regime_val = (128'd1 << (k + 2)) - 128'd2;
                end else begin
                  rlen       = (-k) + 1;
                  regime_val = 128'd1;
                end
                nfrac = (n - 2) - rlen;
                if (nfrac < 0) nfrac = 0;
              end
            end
          end
          body = (regime_val << ((n - 1) - rlen)) |
                 ((r[0] ? 128'd1 : 128'd0) << ((n - 2) - rlen)) |
                 (fracbits & ((128'd1 << nfrac) - 128'd1));
          out = (sgn ? (32'd1 << (n - 1)) : 32'd0) |
                (body[31:0] & ((32'd1 << (n - 1)) - 32'd1));
        end
      end
      return out;
    end
  endfunction

  logic signed [127:0] pd_a, pd_b, pres;
  logic signed [255:0] pmul_wide;
  logic signed [255:0] pmul_shift;
  logic signed [255:0] pdiv_num;
  logic signed [255:0] pdiv_q;
  int                  pos_n;
  logic [63:0]         posit_y;
  logic [7:0]          posit_flags;

  always_comb begin
    posit_y     = 64'd0;
    posit_flags = 8'd0;
    pos_n       = posit_width(fmt);
    pd_a        = posit_decode(a[31:0], pos_n);
    pd_b        = posit_decode(b[31:0], pos_n);
    pres        = 128'sd0;
    pmul_wide   = 256'sd0;
    pmul_shift  = 256'sd0;
    pdiv_num    = 256'sd0;
    pdiv_q      = 256'sd0;

    case (op)
      NUM_PADD: pres = pd_a + pd_b;
      NUM_PSUB: pres = pd_a - pd_b;
      NUM_PMUL: begin
        pmul_wide  = pd_a * pd_b;
        pmul_shift = pmul_wide >>> POS_FRAC_BITS;
        // the shifted product can exceed the 128-bit range; narrowing it wraps
        // a large positive result negative
        if (pmul_shift > 256'sh7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF) begin
          pres = 128'sh7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
          posit_flags[FLAG_SATURATE] = 1'b1;
          posit_flags[FLAG_OVERFLOW] = 1'b1;
        end else if (pmul_shift < -256'sh8000_0000_0000_0000_0000_0000_0000_0000) begin
          pres = 128'sh8000_0000_0000_0000_0000_0000_0000_0000;
          posit_flags[FLAG_SATURATE] = 1'b1;
          posit_flags[FLAG_OVERFLOW] = 1'b1;
        end else begin
          pres = pmul_shift[127:0];
        end
      end
      default: begin
        if (pd_b == 128'sd0) begin
          pres = 128'sd0;
          posit_flags[FLAG_DIVZERO] = 1'b1;
        end else begin
          pdiv_num = $signed(pd_a) <<< POS_FRAC_BITS;
          pdiv_q   = pdiv_num / $signed(pd_b);
          if (pdiv_q > 256'sh7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF) begin
            pres = 128'sh7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
            posit_flags[FLAG_SATURATE] = 1'b1;
            posit_flags[FLAG_OVERFLOW] = 1'b1;
          end else if (pdiv_q < -256'sh8000_0000_0000_0000_0000_0000_0000_0000) begin
            pres = 128'sh8000_0000_0000_0000_0000_0000_0000_0000;
            posit_flags[FLAG_SATURATE] = 1'b1;
            posit_flags[FLAG_OVERFLOW] = 1'b1;
          end else begin
            pres = pdiv_q[127:0];
          end
        end
      end
    endcase

    posit_y = {32'd0, posit_encode(pres, pos_n)};
  end

  // BF16 operands widen exactly into binary32. Truncation plus the FP32
  // inexact flag preserves the sticky bit needed to round once to BF16.
  wire bf_mul = op == NUM_BFMUL;
  wire bf_active = bf_mul || op == NUM_BFADD || op == NUM_BFSUB;
  wire [63:0] bf_a = bf_active ? {32'b0, a[15:0], 16'b0} : 64'b0;
  wire [63:0] bf_b = bf_active ? {32'b0, b[15:0], 16'b0} : 64'b0;
  logic [63:0] bf_add_raw, bf_mul_raw;
  logic [4:0] bf_add_exc, bf_mul_exc;
  rv64_fp_add u_bf_add (
    .fmt(1'b0), .sub(op == NUM_BFSUB), .rm(3'd1),
    .a(bf_a), .b(bf_b), .result(bf_add_raw), .flags(bf_add_exc)
  );
  rv64_fp_mul u_bf_mul (
    .fmt(1'b0), .rm(3'd1), .a(bf_a), .b(bf_b),
    .result(bf_mul_raw), .flags(bf_mul_exc)
  );

  wire [31:0] bf_raw = bf_mul ? bf_mul_raw[31:0] : bf_add_raw[31:0];
  wire [4:0] bf_exc = bf_mul ? bf_mul_exc : bf_add_exc;
  wire bf_finite = bf_raw[30:23] != 8'hff;
  wire bf_lost = bf_exc[0] || (|bf_raw[15:0]);
  wire bf_up = bf_finite && bf_raw[15] &&
               (bf_raw[16] || (|bf_raw[14:0]) || bf_exc[0]);
  wire [15:0] bf_y = bf_raw[31:16] + {15'b0, bf_up};

  // Balanced radix-3 addition/subtraction. A digit sum outside [-1, 1]
  // is reduced by one radix unit and forwards a signed carry to the next trit.
  logic [31:0] sd_result;
  logic sd_invalid, sd_overflow;
  always_comb begin
    logic signed [2:0] carry, lhs, rhs, sum;
    carry = 3'sd0;
    sd_result = '0;
    sd_invalid = fmt != 0 || (|a[63:32]) || (|b[63:32]);
    for (int digit = 0; digit < 16; digit++) begin
      lhs = 3'($signed(a[2*digit +: 2]));
      rhs = 3'($signed(b[2*digit +: 2]));
      sd_invalid |= lhs == -3'sd2 || rhs == -3'sd2;
      sum = lhs + (op == NUM_SDSUB ? -rhs : rhs) + carry;
      if (sum > 3'sd1) begin
        sum = sum - 3'sd3;
        carry = 3'sd1;
      end else if (sum < -3'sd1) begin
        sum = sum + 3'sd3;
        carry = -3'sd1;
      end else begin
        carry = 3'sd0;
      end
      sd_result[2*digit +: 2] = sum[1:0];
    end
    sd_overflow = carry != 0;
  end

  // ===========================================================================
  // Select -- a single procedural block drives `flags`: two always_comb blocks
  // assigning the same variable is a multiple-driver conflict, and an arm can
  // silently take another arm's value.
  // ===========================================================================
  always_comb begin
    y     = 64'd0;
    flags = 8'd0;
    case (op)
      NUM_RADD, NUM_RMUL, NUM_RSUB: begin
        y = rns_y;
        // per-channel modular arithmetic is exact: no flags
      end
      NUM_LNMUL, NUM_LNDIV, NUM_LNADD, NUM_LNSUB: begin
        // the result is the width-truncated log field, not the widened one
        y     = lns_signed ? lns_y : lns_y & lns_mask;
        flags = lns_flags;
      end
      NUM_PADD, NUM_PSUB, NUM_PMUL, NUM_PDIV: begin
        y     = posit_y;
        flags = posit_flags;
      end
      NUM_SDADD, NUM_SDSUB: begin
        y = sd_invalid ? 64'd0 : {32'd0, sd_result};
        flags[FLAG_INVALID] = sd_invalid;
        flags[FLAG_OVERFLOW] = !sd_invalid && sd_overflow;
      end
      NUM_BFADD, NUM_BFSUB, NUM_BFMUL: begin
        y = {48'b0, bf_y};
        flags[FLAG_INVALID] = bf_exc[4];
        flags[FLAG_INEXACT] = bf_finite && bf_lost;
        flags[FLAG_OVERFLOW] = bf_exc[2] || (bf_finite && bf_y[14:7] == 8'hff);
        flags[FLAG_UNDERFLOW] = bf_finite && bf_lost && bf_y[14:7] == 8'b0;
      end
      NUM_FADD, NUM_FMUL: begin
        y     = fp_y;
        flags = fp_flags;
      end
      default: begin
        y = 64'd0;
        flags[FLAG_INVALID] = 1'b1;
      end
    endcase
  end


endmodule
`default_nettype wire
