`timescale 1ns/1ps
// =============================================================================
// rv64_fp_cvt.sv -- every conversion the F and D extensions define.
//
//     fp -> integer : fcvt.w.s  fcvt.wu.s  fcvt.l.s  fcvt.lu.s
//                     fcvt.w.d  fcvt.wu.d  fcvt.l.d  fcvt.lu.d
//     integer -> fp : fcvt.s.w  fcvt.s.wu  fcvt.s.l  fcvt.s.lu
//                     fcvt.d.w  fcvt.d.wu  fcvt.d.l  fcvt.d.lu
//     fp -> fp      : fcvt.s.d   fcvt.d.s
//
// One block, three modes, both precisions: `op` selects the direction and
// src_fmt/dst_fmt select the precision, so the only thing that changes between
// fcvt.w.s and fcvt.w.d is which fields the source is unpacked from.  Every
// rounding decision goes through rv64_fp_round.sv -- this file contains no
// rounding logic at all beyond the integer-directed neighbour choice, which is
// the same five-mode decision expressed on the sign of the remainder.
//
// integer -> fp normalises the magnitude so its leading one sits where the
// rounder expects, with everything below folded into G/R/S, so fcvt.d.l of a
// value wider than 2**53 rounds instead of truncating, and fcvt.s.l of anything
// above 2**24 does too.
//
// fp -> integer rounds the value to an integer and THEN range-checks THE ROUNDED
// VALUE.  That ordering matters: -0.5 under RTZ rounds to 0, which is
// representable, so it must not raise invalid.  Out of range gives invalid plus
// the largest positive or most negative value (NaN gives the largest positive),
// which is what the spec asks for.  A 32-bit result is sign- or zero-extended to
// XLEN on the way out, per the spec's rule for the .w forms.
//
// Purely combinational: no state, no reset, no clock.
// =============================================================================
`default_nettype none

module rv64_fp_cvt (
  input  logic [1:0]  op,            // 0 fp->int, 1 int->fp, 2 fp->fp
  input  logic        src_fmt,       // 1 = binary64 source
  input  logic        dst_fmt,       // 1 = binary64 destination
  input  logic        is_unsigned,
  input  logic        is_32,         // 1 = .w/.wu, 0 = .l/.lu
  input  logic [2:0]  rm,
  input  logic [63:0] src,           // the FP value or the integer value
  output logic [63:0] result,
  output logic [4:0]  flags
);
  localparam logic [1:0] OP_TO_INT = 2'd0, OP_FROM_INT = 2'd1, OP_FP2FP = 2'd2;
  localparam logic [4:0] F_NV = 5'b1_0000;
  localparam logic [4:0] F_NX = 5'b0_0001;

  // ---- format constants for the destination -------------------------------
  logic [6:0]         fbw;      // destination fraction width
  logic signed [12:0] bias;
  logic [63:0]        qnan, fmask;

  always_comb begin
    if (dst_fmt) begin
      fbw  = 7'd52;
      bias = 13'sd1023;
      qnan = 64'h7FF8_0000_0000_0000;
    end else begin
      fbw  = 7'd23;
      bias = 13'sd127;
      qnan = 64'h0000_0000_7FC0_0000;
    end
    fmask = (64'd1 << fbw) - 64'd1;
  end

  // ---- source unpacking ----------------------------------------------------
  logic [6:0]  sfbw;                  // source fraction width
  logic [10:0] se_all;
  logic [63:0] sfmask;

  always_comb begin
    if (src_fmt) begin sfbw = 7'd52; se_all = 11'h7FF; end
    else         begin sfbw = 7'd23; se_all = 11'h0FF; end
    sfmask = (64'd1 << sfbw) - 64'd1;
  end

  wire        s_sign = src_fmt ? src[63] : src[31];
  wire [10:0] s_exp  = src_fmt ? src[62:52] : {3'd0, src[30:23]};
  wire [51:0] s_frac = src_fmt ? src[51:0] : {29'd0, src[22:0]};
  wire        s_nan  = (s_exp == se_all) && (s_frac != 52'd0);
  wire        s_snan = s_nan && !s_frac[sfbw-1];  // quiet bit is bit FB
  wire        s_inf  = (s_exp == se_all) && (s_frac == 52'd0);
  wire        s_zero = (s_exp == 11'd0) && (s_frac == 52'd0);

  logic [52:0]        s_m;
  logic signed [12:0] s_e;
  always_comb begin
    if (s_exp == 11'd0) begin
      s_m = {29'd0, (s_frac & 52'(sfmask))};
      s_e = 13'sd1 - (src_fmt ? 13'sd1023 : 13'sd127) - $signed({6'd0, sfbw});
    end else begin
      s_m = {29'd0, (s_frac & 52'(sfmask))} | (53'd1 << sfbw);
      s_e = $signed({1'b0, s_exp}) - (src_fmt ? 13'sd1023 : 13'sd127) -
            $signed({6'd0, sfbw});
    end
  end

  // =========================================================================
  // fp -> integer
  // =========================================================================
  logic [63:0] q_mag;        // magnitude of the ROUNDED integer
  logic        q_ovf;        // magnitude >= 2**64
  logic        q_exact;

  logic signed [12:0] ovf_th;          // largest exponent that still fits
  always_comb ovf_th = 13'sd63 - $signed({6'd0, sfbw});

  always_comb begin
    q_mag   = 64'd0;
    q_ovf   = 1'b0;
    q_exact = 1'b1;
    if (s_m != 53'd0) begin
      if (s_e > ovf_th) begin
        q_ovf = 1'b1;                       // |value| >= 2**64: out of range
      end else if (s_e >= 13'sd0) begin
        q_mag = ({11'd0, s_m}) << s_e[5:0]; // exact: no fractional bits
      end else if (-s_e > $signed({6'd0, sfbw}) + 13'sd1) begin
        // strictly less than one half: the integer part is 0 and the direction
        // of the (nonzero) remainder decides between 0 and 1
        q_exact = 1'b0;
        if (((rm == 3'd3) && !s_sign) || ((rm == 3'd2) && s_sign)) q_mag = 64'd1;
      end else begin
        logic [6:0]  sh;
        logic [63:0] dropped, half;
        logic        up;
        sh      = 7'(-s_e);
        q_mag   = {11'd0, s_m} >> sh;
        dropped = {11'd0, s_m} & ((64'd1 << sh) - 64'd1);
        half    = 64'd1 << (sh - 7'd1);
        q_exact = (dropped == 64'd0);
        unique case (rm)
          3'd0:    up = (dropped > half) || ((dropped == half) && q_mag[0]);
          3'd1:    up = 1'b0;
          3'd2:    up = (dropped != 64'd0) &&  s_sign;
          3'd3:    up = (dropped != 64'd0) && !s_sign;
          3'd4:    up = (dropped >= half);
          default: up = 1'b0;
        endcase
        if (up) q_mag = q_mag + 64'd1;
      end
    end
  end

  // limits for the target width
  logic [63:0] hi_val, neg_lim, hi_ext, lo_ext;
  always_comb begin
    if (is_unsigned) begin
      hi_val  = is_32 ? 64'h0000_0000_FFFF_FFFF : 64'hFFFF_FFFF_FFFF_FFFF;
      neg_lim = 64'd0;
      hi_ext  = hi_val;
      lo_ext  = 64'd0;
    end else if (is_32) begin
      hi_val  = 64'h0000_0000_7FFF_FFFF;
      neg_lim = 64'h0000_0000_8000_0000;
      hi_ext  = 64'h0000_0000_7FFF_FFFF;
      lo_ext  = 64'hFFFF_FFFF_8000_0000;
    end else begin
      hi_val  = 64'h7FFF_FFFF_FFFF_FFFF;
      neg_lim = 64'h8000_0000_0000_0000;
      hi_ext  = 64'h7FFF_FFFF_FFFF_FFFF;
      lo_ext  = 64'h8000_0000_0000_0000;
    end
  end

  logic [63:0] iv, iv_ext;
  logic        pos_bad, neg_bad;
  always_comb begin
    iv      = s_sign ? (~q_mag + 64'd1) : q_mag;
    pos_bad = q_ovf || (q_mag > hi_val);
    neg_bad = q_ovf || (q_mag > neg_lim);
    if (is_32) begin
      if (is_unsigned) iv_ext = {32'd0, iv[31:0]};
      else             iv_ext = {{32{iv[31]}}, iv[31:0]};
    end else begin
      iv_ext = iv;
    end
  end

  logic [63:0] cvt_int_result;
  logic [4:0]  cvt_int_flags;
  always_comb begin
    cvt_int_result = iv_ext;
    cvt_int_flags  = q_exact ? 5'd0 : F_NX;
    if (s_nan) begin
      cvt_int_result = hi_ext;              // NaN converts to the largest positive
      cvt_int_flags  = F_NV;
    end else if (s_inf) begin
      cvt_int_result = s_sign ? lo_ext : hi_ext;
      cvt_int_flags  = F_NV;
    end else if (!s_sign && pos_bad) begin
      cvt_int_result = hi_ext;
      cvt_int_flags  = F_NV;
    end else if (s_sign && neg_bad) begin
      cvt_int_result = lo_ext;
      cvt_int_flags  = F_NV;
    end
  end

  // =========================================================================
  // integer -> fp  and  fp -> fp
  //
  // Both reduce to "pack the exact value (-1)**sign * mag * 2**esc": the integer
  // form has esc = 0, the fp->fp form takes mag/esc straight out of the source.
  // =========================================================================
  logic [63:0] isrc;
  logic        neg_i;
  logic [63:0] mag_i;
  logic [6:0]  p_i;

  always_comb begin
    if (is_32) begin
      if (is_unsigned) isrc = {32'd0, src[31:0]};
      else             isrc = {{32{src[31]}}, src[31:0]};
    end else begin
      isrc = src;
    end
  end
  assign neg_i = !is_unsigned && isrc[63];
  assign mag_i = neg_i ? (~isrc + 64'd1) : isrc;

  always_comb begin
    p_i = 7'd0;
    for (int i = 0; i < 64; i++) begin
      if (mag_i[i]) p_i = 7'(i + 1);
    end
  end

  logic [63:0]        pm;         // magnitude to pack
  logic signed [12:0] pe;         // its scale
  logic               psign;
  logic               p_is_zero;

  always_comb begin
    pm        = 64'd0;
    pe        = 13'sd0;
    psign     = 1'b0;
    p_is_zero = 1'b1;
    if (op == OP_FROM_INT) begin
      pm        = mag_i;
      pe        = 13'sd0;
      psign     = neg_i;
      p_is_zero = (mag_i == 64'd0);
    end else if (op == OP_FP2FP) begin
      pm        = {11'd0, s_m};
      pe        = s_e;
      psign     = s_sign;
      p_is_zero = s_zero;
    end
  end

  logic [6:0]         p_len;
  logic signed [12:0] p_exp_in;
  logic [55:0]        p_sig;
  always_comb begin
    p_len    = 7'd0;
    p_exp_in = 13'sd0;
    p_sig    = 56'd0;
    if (!p_is_zero && (pm != 64'd0)) begin
      logic [6:0] sh_l, sh_r;
      logic [63:0] lost;
      p_len = 7'd0;
      for (int i = 0; i < 64; i++) begin
        if (pm[i]) p_len = 7'(i + 1);
      end
      p_exp_in = pe + $signed({6'd0, p_len}) - 13'sd1;
      // place the leading one at bit fbw+3 of the (fbw+4)-bit significand
      if (p_len <= (fbw + 7'd4)) begin
        sh_l = (fbw + 7'd4) - p_len;
        p_sig = 56'(pm << sh_l);
      end else begin
        sh_r = p_len - (fbw + 7'd4);
        lost = pm & ((64'd1 << sh_r) - 64'd1);
        p_sig = 56'((pm >> sh_r) | {55'd0, (|lost)});
      end
    end
  end

  logic [63:0] rnd_result;
  logic [4:0]  rnd_flags;

  rv64_fp_round u_round (
    .fmt    (dst_fmt),
    .sign   (psign),
    .exp_in (p_exp_in),
    .sig    (p_sig),
    .rm     (rm),
    .result (rnd_result),
    .flags  (rnd_flags)
  );

  logic [63:0] cvt_fp_result;
  logic [4:0]  cvt_fp_flags;
  always_comb begin
    cvt_fp_result = rnd_result;
    cvt_fp_flags  = rnd_flags;
    if (op == OP_FP2FP) begin
      if (s_nan) begin
        cvt_fp_result = qnan;               // canonical NaN of the destination
        cvt_fp_flags  = s_snan ? F_NV : 5'd0;
      end else if (s_inf) begin
        cvt_fp_result = dst_fmt ? {s_sign, 11'h7FF, 52'd0}
                                : {32'd0, s_sign, 8'hFF, 23'd0};
        cvt_fp_flags  = 5'd0;
      end else if (s_zero) begin
        cvt_fp_result = {63'd0, s_sign} << (dst_fmt ? 6'd63 : 6'd31);
        cvt_fp_flags  = 5'd0;
      end
    end else if (p_is_zero) begin
      cvt_fp_result = 64'd0;                // integer zero -> +0, no flags
      cvt_fp_flags  = 5'd0;
    end
  end

  // =========================================================================
  // output select
  // =========================================================================
  always_comb begin
    if (op == OP_TO_INT) begin
      result = cvt_int_result;
      flags  = cvt_int_flags;
    end else begin
      result = cvt_fp_result;
      flags  = cvt_fp_flags;
    end
  end
endmodule

`default_nettype wire
