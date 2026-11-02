`timescale 1ns/1ps
// =============================================================================
// rv64_fp_cvt.sv -- conversions between binary64 and the integer register file.
//
//     integer -> double : fcvt.d.w  fcvt.d.wu  fcvt.d.l  fcvt.d.lu
//     double -> integer : fcvt.w.d  fcvt.wu.d  fcvt.l.d  fcvt.lu.d
//
// Integer -> double normalises the magnitude to a 53-bit significand; anything
// below bit 52 becomes guard/round/sticky and goes through the shared rounder,
// so fcvt.d.l of a value wider than 2**53 rounds instead of truncating.  The
// .w/.wu forms are exact by construction and simply never round.
//
// Double -> integer rounds M*2**E to an integer, then range-checks THE ROUNDED
// VALUE.  That ordering matters: -0.5 under RTZ rounds to 0, which is
// representable, so it must not raise invalid.  Out of range gives invalid plus
// the largest positive or most negative value (NaN gives the largest positive),
// which is what the spec asks for.  A 32-bit result is sign- or zero-extended
// to XLEN on the way out, per the spec's rule for the .w forms.
//
// Transcribed from rtl/fpu/model/fp_cvt_model.py (1656 int->dbl vectors against
// CPython float(), 6584 int->dbl mode checks, 14560 dbl->int conversions against
// an exact Fraction reference across all five rounding modes).
//
// Purely combinational: no state, no reset, no clock.
// =============================================================================
`default_nettype none

module rv64_fp_cvt (
  input  logic        to_int,        // 1 = double -> integer
  input  logic        is_unsigned,
  input  logic        is_32,         // 1 = .w/.wu, 0 = .l/.lu
  input  logic [2:0]  rm,
  input  logic [63:0] src,           // the FP value or the integer value
  output logic [63:0] result,
  output logic [4:0]  flags
);
  localparam logic [4:0] F_NV = 5'b1_0000;
  localparam logic [4:0] F_NX = 5'b0_0001;

  // =========================================================================
  // integer -> double
  // =========================================================================
  logic [63:0] isrc;
  logic        neg_i;
  logic [63:0] mag_i;

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

  // bit length of the magnitude: 0 for zero, else 1..64
  logic [6:0] p_i;
  always_comb begin
    p_i = 7'd0;
    for (int i = 0; i < 64; i++) begin
      if (mag_i[i]) p_i = 7'(i + 1);
    end
  end

  logic [6:0]  sh_i;
  logic [52:0] sig53;
  logic        g_i, r_i, s_i;
  logic [55:0] sig56_i;
  logic signed [12:0] e_i;

  always_comb begin
    sh_i = (p_i > 7'd53) ? (p_i - 7'd53) : 7'd0;
    g_i  = 1'b0;
    r_i  = 1'b0;
    s_i  = 1'b0;
    if (p_i == 7'd0) begin
      sig53 = 53'd0;                        // zero: handled by the mux below
    end else if (sh_i == 7'd0) begin
      sig53 = 53'(mag_i << (7'd53 - p_i));  // exact, no bits dropped
    end else begin
      logic [63:0] dropped;
      dropped = mag_i & ((64'd1 << sh_i) - 64'd1);
      sig53   = 53'(mag_i >> sh_i);
      g_i     = dropped[sh_i - 7'd1];
      r_i     = (sh_i >= 7'd2) ? dropped[sh_i - 7'd2] : 1'b0;
      s_i     = (sh_i >= 7'd3) ?
                (|(dropped & ((64'd1 << (sh_i - 7'd2)) - 64'd1))) : 1'b0;
    end
    sig56_i = {sig53, g_i, r_i, s_i};
    e_i     = $signed({6'd0, p_i}) - 13'sd1;   // value = 1.f * 2**(p-1)
  end

  logic [63:0] rnd_i_result;
  logic [4:0]  rnd_i_flags;

  rv64_fp_round u_round_int (
    .sign   (neg_i),
    .exp_in (e_i),
    .sig    (sig56_i),
    .rm     (rm),
    .result (rnd_i_result),
    .flags  (rnd_i_flags)
  );

  // =========================================================================
  // double -> integer
  // =========================================================================
  wire        sa   = src[63];
  wire [10:0] ea   = src[62:52];
  wire [51:0] fa   = src[51:0];
  wire        d_nan  = (ea == 11'h7FF) && (fa != 52'd0);
  wire        d_inf  = (ea == 11'h7FF) && (fa == 52'd0);

  logic [52:0]        m_d;
  logic signed [12:0] e_d;
  always_comb begin
    if (ea == 11'd0) begin m_d = {1'b0, fa}; e_d = -13'sd1074; end
    else             begin m_d = {1'b1, fa}; e_d = $signed({1'b0, ea}) - 13'sd1075; end
  end

  logic [63:0] q_mag;        // magnitude of the ROUNDED integer
  logic        q_ovf;        // magnitude >= 2**64
  logic        q_exact;

  always_comb begin
    q_mag   = 64'd0;
    q_ovf   = 1'b0;
    q_exact = 1'b1;
    if (m_d != 53'd0) begin
      if (e_d >= 13'sd12) begin
        q_ovf = 1'b1;                       // |value| >= 2**64: out of range
      end else if (e_d >= 13'sd0) begin
        q_mag = {11'd0, m_d} << e_d[5:0];   // exact: no fractional bits
      end else if (-e_d > 13'sd53) begin
        // strictly less than one half: the integer part is 0 and the direction
        // of the (nonzero) remainder decides between 0 and 1
        q_exact = 1'b0;
        if (((rm == 3'd3) && !sa) || ((rm == 3'd2) && sa)) q_mag = 64'd1;
      end else begin
        logic [6:0]  sh;
        logic [63:0] dropped, half;
        logic        up;
        sh      = 7'(-e_d);
        q_mag   = {11'd0, m_d} >> sh;
        dropped = {11'd0, m_d} & ((64'd1 << sh) - 64'd1);
        half    = 64'd1 << (sh - 7'd1);
        q_exact = (dropped == 64'd0);
        unique case (rm)
          3'd0:    up = (dropped > half) || ((dropped == half) && q_mag[0]);
          3'd1:    up = 1'b0;
          3'd2:    up = (dropped != 64'd0) &&  sa;
          3'd3:    up = (dropped != 64'd0) && !sa;
          3'd4:    up = (dropped >= half);
          default: up = 1'b0;
        endcase
        if (up) q_mag = q_mag + 64'd1;
      end
    end
  end

  // limits for the target format
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
      hi_ext  = {{32{1'b0}}, 32'h7FFF_FFFF};
      lo_ext  = {{32{1'b1}}, 32'h8000_0000};
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
    iv      = sa ? (~q_mag + 64'd1) : q_mag;
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
    if (d_nan) begin
      cvt_int_result = hi_ext;              // NaN converts to the largest positive
      cvt_int_flags  = F_NV;
    end else if (d_inf) begin
      cvt_int_result = sa ? lo_ext : hi_ext;
      cvt_int_flags  = F_NV;
    end else if (!sa && pos_bad) begin
      cvt_int_result = hi_ext;
      cvt_int_flags  = F_NV;
    end else if (sa && neg_bad) begin
      cvt_int_result = lo_ext;
      cvt_int_flags  = F_NV;
    end
  end

  // =========================================================================
  // output select
  // =========================================================================
  always_comb begin
    if (to_int) begin
      result = cvt_int_result;
      flags  = cvt_int_flags;
    end else if (p_i == 7'd0) begin
      result = 64'd0;                       // integer zero -> +0, no flags
      flags  = 5'd0;
    end else begin
      result = rnd_i_result;
      flags  = rnd_i_flags;
    end
  end
endmodule

`default_nettype wire
