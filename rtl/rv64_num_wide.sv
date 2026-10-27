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

  logic [1:0] a3, b3;
  logic [2:0] a5, b5, a7, b7;
  logic [3:0] a11, b11;
  logic [63:0] rns_y;

  assign a3 = a[1:0];   assign b3 = b[1:0];
  assign a5 = a[4:2];   assign b5 = b[4:2];
  assign a7 = a[7:5];   assign b7 = b[7:5];
  assign a11 = a[11:8]; assign b11 = b[11:8];

  always_comb begin
    rns_y = 64'd0;
    if (op == NUM_RADD) begin
      rns_y[1:0]  = mod3({1'b0, a3} + {1'b0, b3});
      rns_y[4:2]  = mod5({1'b0, a5} + {1'b0, b5});
      rns_y[7:5]  = mod7({1'b0, a7} + {1'b0, b7});
      rns_y[11:8] = mod11({1'b0, a11} + {1'b0, b11});
    end else begin
      rns_y[1:0]  = mod3(a3 * b3);
      rns_y[4:2]  = mod5(a5 * b5);
      rns_y[7:5]  = mod7(a7 * b7);
      rns_y[11:8] = mod11(a11 * b11);
    end
  end

  // ===========================================================================
  // Logarithmic number system
  //
  // Operand is a base-2 logarithm in signed Q16.16 in the low 32 bits;
  // 32'h8000_0000 is -infinity and encodes zero. Multiply is addition, divide
  // is subtraction, and both are exact in the log domain.
  // ===========================================================================
  localparam logic [31:0] LNS_ZERO = 32'h8000_0000;

  logic signed [31:0] la, lb;
  logic signed [32:0] lsum;
  logic               la_zero, lb_zero;
  logic [31:0]        lns_y;
  logic [7:0]         lns_flags;

  assign la = $signed(a[31:0]);
  assign lb = $signed(b[31:0]);
  assign la_zero = (a[31:0] == LNS_ZERO);
  assign lb_zero = (b[31:0] == LNS_ZERO);

  always_comb begin
    lsum      = 33'sd0;
    lns_y     = LNS_ZERO;
    lns_flags = 8'd0;

    if (op == NUM_LNMUL) begin
      if (la_zero || lb_zero) begin
        lns_y = LNS_ZERO;
      end else begin
        lsum = {la[31], la} + {lb[31], lb};
        if (lsum > 33'sh7FFF_FFFF) begin
          lns_y = 32'h7FFF_FFFF;
          lns_flags[FLAG_OVERFLOW] = 1'b1;
        end else if (lsum < -33'sh8000_0000) begin
          lns_y = LNS_ZERO;
          lns_flags[FLAG_OVERFLOW] = 1'b1;
        end else begin
          lns_y = lsum[31:0];
        end
      end
    end else begin
      if (lb_zero) begin
        lns_y = 32'h7FFF_FFFF;
        lns_flags[FLAG_DIVZERO] = 1'b1;
      end else if (la_zero) begin
        lns_y = LNS_ZERO;
      end else begin
        lsum = {la[31], la} - {lb[31], lb};
        if (lsum > 33'sh7FFF_FFFF) begin
          lns_y = 32'h7FFF_FFFF;
          lns_flags[FLAG_OVERFLOW] = 1'b1;
        end else if (lsum < -33'sh8000_0000) begin
          lns_y = LNS_ZERO;
          lns_flags[FLAG_OVERFLOW] = 1'b1;
        end else begin
          lns_y = lsum[31:0];
        end
      end
    end
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
  logic [9:0]  add_ebig, add_esmall;
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
        add_shift = (add_ebig - add_esmall > 10'd26) ? 5'd26
                                                     : (add_ebig - add_esmall)[4:0];
        add_small_s = add_small >> add_shift;
        if ((add_ebig - add_esmall) > 10'd0)
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
  // posit<16,1>
  //
  //   sign | regime | exponent(es=1) | fraction
  //   value = (-1)^sign * useed^k * 2^e * (1 + f),  useed = 2^(2^es) = 4
  //
  // Arithmetic is done in signed Q30.34: 30 integer bits hold posit16's maximum
  // magnitude (just under 2^30) and 34 fraction bits hold its smallest (about
  // 2^-31). Decode, operate, encode.
  // ===========================================================================
  localparam int POS_FRAC_BITS = 34;

  function automatic logic signed [63:0] posit_decode(input logic [15:0] p);
    logic        sgn;
    logic [14:0] body;
    logic [4:0]  run;
    logic        stopped;
    int          j, idx, k, n_frac, shift;
    logic [14:0] frac;
    logic [63:0] mant;
    logic signed [63:0] out;
    begin
      sgn  = p[15];
      body = p[14:0];
      run = 5'd0; stopped = 1'b0; frac = 15'd0; n_frac = 0; k = 0;
      if (body == 15'd0) begin
        out = 64'sd0;
      end else begin
        // length of the run of identical bits starting at bit 14 (fixed bound:
        // variable-bound loops and `break` are not portable across simulators)
        for (j = 14; j >= 0; j = j - 1) begin
          if (!stopped && (body[j] == body[14])) run = run + 5'd1;
          else stopped = 1'b1;
        end
        if (body[14]) k = run - 1;
        else          k = -run;

        // the regime's terminating bit is at 14-run; the es exponent follows it
        idx = 14 - run - 1;
        if (idx >= 0) begin
          n_frac = idx;
          frac   = body & ((15'd1 << idx) - 15'd1);
        end else begin
          n_frac = 0;
          frac   = 15'd0;
        end

        mant  = ({49'd0, 1'b1, frac[13:0]}) >> (14 - n_frac);
        shift = 2*k + ((idx >= 0) ? ((body >> idx) & 1) : 0) + POS_FRAC_BITS - n_frac;
        if (shift >= 0) out = mant <<< shift;
        else            out = mant >>> (-shift);
        if (sgn) out = -out;
      end
      return out;
    end
  endfunction

  // The regime has a variable length, so the fields are placed with one shift
  // rather than a bit loop: build `regime | exponent | fraction` as a binary
  // number and position it from bit 14 downwards.
  function automatic logic [15:0] posit_encode(input logic signed [63:0] v);
    logic        sgn, round_up;
    logic [63:0] mag, below, tail, body;
    int          lead, e2, k, r, nfrac, rlen, disc, i;
    logic [63:0] regime_val, fracbits;
    logic [15:0] out;
    begin
      sgn = v[63];
      mag = sgn ? (~v + 64'd1) : v;
      out = 16'd0;
      if (mag == 64'd0) begin
        out = 16'd0;
      end else begin
        // highest set bit, found with a mask-based loop (no break)
        lead = 0;
        for (i = 0; i <= 63; i++) if (mag[i]) lead = i;
        e2 = lead - POS_FRAC_BITS;
        if (e2 >= 0) k = e2 >> 1;
        else         k = -(((-e2) + 1) >> 1);
        r = e2 - 2 * k;

        // k >= 0 is k+1 ones followed by a terminating zero, so the regime is
        // k+2 bits wide; k < 0 is |k| zeros followed by a terminating one.
        if (k >= 0) begin
          rlen       = k + 2;
          regime_val = (64'd1 << (k + 2)) - 64'd2;
        end else begin
          rlen       = (-k) + 1;
          regime_val = 64'd1;
        end

        // body is 15 bits: rlen + 1 (es) + nfrac, so nfrac = 14 - rlen
        nfrac = 14 - rlen;
        if (nfrac < 0 || rlen > 15) begin
          // the regime alone no longer fits: saturate to the largest magnitude
          out = sgn ? 16'h8001 : 16'h7FFF;
        end else begin
          // put the leading one at bit 63: shifting by 64-lead would push it
          // off the end of the word and lose the whole significand
          below    = (lead >= 1) ? (mag << (63 - lead)) : 64'd0;
          fracbits = (nfrac == 0) ? 64'd0
                                  : ((below >> (63 - nfrac)) & ((64'd1 << nfrac) - 64'd1));
          disc     = 63 - nfrac;
          tail     = (disc <= 0) ? 64'd0
                                 : ((disc >= 64) ? below : (below & ((64'd1 << disc) - 64'd1)));
          round_up = (nfrac > 0) && (disc >= 1) &&
                     (((below >> (disc - 1)) & 64'd1) == 64'd1) &&
                     ((tail != (64'd1 << (disc - 1))) || (fracbits[0] == 1'b1));
          if (round_up) begin
            fracbits = fracbits + 64'd1;
            if (fracbits >> nfrac) begin
              fracbits = 64'd0;
              r = r + 1;
              if (r > 1) begin
                r = 0;
                k = k + 1;
                if (k >= 0) begin
                  rlen       = k + 2;
                  regime_val = (64'd1 << (k + 2)) - 64'd2;
                end else begin
                  rlen       = (-k) + 1;
                  regime_val = 64'd1;
                end
                nfrac = 14 - rlen;
                if (nfrac < 0) nfrac = 0;
              end
            end
          end
          // regime at the top of the 15-bit body, then the es bit, then the
          // fraction: shifts are measured from bit 14 downwards
          body = (regime_val << (15 - rlen)) |
                 ((r[0] ? 64'd1 : 64'd0) << (14 - rlen)) |
                 (fracbits & ((64'd1 << nfrac) - 64'd1));
          out = {sgn, body[14:0]};
        end
      end
      return out;
    end
  endfunction

  logic signed [63:0] pd_a, pd_b, pres;
  logic signed [127:0] pmul_wide;
  logic signed [127:0] pdiv_num;
  logic signed [127:0] pmul_shift;
  logic signed [127:0] pdiv_q;
  logic [63:0] posit_y;
  logic [7:0]  posit_flags;

  always_comb begin
    posit_y     = 64'd0;
    posit_flags = 8'd0;
    pd_a        = posit_decode(a[15:0]);
    pd_b        = posit_decode(b[15:0]);
    pres        = 64'sd0;
    pmul_wide   = 128'sd0;
    pdiv_num    = 128'sd0;
    pmul_shift  = 128'sd0;
    pdiv_q      = 128'sd0;

    case (op)
      NUM_PADD: begin
        pres = pd_a + pd_b;
        if (pd_a[63] == pd_b[63] && pres[63] != pd_a[63]) begin
          pres = pd_a[63] ? {1'b1, 63'd0} : {1'b0, {63{1'b1}}};
          posit_flags[FLAG_SATURATE] = 1'b1;
          posit_flags[FLAG_OVERFLOW] = 1'b1;
        end
      end
      NUM_PSUB: begin
        pres = pd_a - pd_b;
        if (pd_a[63] != pd_b[63] && pres[63] != pd_a[63]) begin
          pres = pd_a[63] ? {1'b1, 63'd0} : {1'b0, {63{1'b1}}};
          posit_flags[FLAG_SATURATE] = 1'b1;
          posit_flags[FLAG_OVERFLOW] = 1'b1;
        end
      end
      NUM_PMUL: begin
        pmul_wide  = pd_a * pd_b;
        pmul_shift = pmul_wide >>> POS_FRAC_BITS;
        // A 128-bit product shifted down can still exceed 64 bits. Truncating it
        // wraps a large positive product negative, which then encodes to the
        // negative rail -- so clamp before the narrowing.
        if (pmul_shift > 128'sh0000_0000_7FFF_FFFF_FFFF_FFFF) begin
          pres = 64'sh7FFF_FFFF_FFFF_FFFF;
          posit_flags[FLAG_SATURATE] = 1'b1;
          posit_flags[FLAG_OVERFLOW] = 1'b1;
        end else if (pmul_shift < -128'sh0000_0000_8000_0000_0000_0000) begin
          pres = 64'sh8000_0000_0000_0000;
          posit_flags[FLAG_SATURATE] = 1'b1;
          posit_flags[FLAG_OVERFLOW] = 1'b1;
        end else begin
          pres = pmul_shift[63:0];
        end
      end
      default: begin
        if (pd_b == 64'sd0) begin
          pres = 64'sd0;
          posit_flags[FLAG_DIVZERO] = 1'b1;
        end else begin
          // the numerator must be widened before the shift: (pd_a << 34) in a
          // 64-bit word overflows for any value above 2^30, which is most of
          // the posit range
          pdiv_num = $signed(pd_a) <<< POS_FRAC_BITS;
          pdiv_q   = pdiv_num / $signed(pd_b);
          // the quotient of two Q30.34 values can exceed the 64-bit range, and
          // narrowing it wraps a large positive quotient negative
          if (pdiv_q > 128'sh0000_0000_7FFF_FFFF_FFFF_FFFF) begin
            pres = 64'sh7FFF_FFFF_FFFF_FFFF;
            posit_flags[FLAG_SATURATE] = 1'b1;
            posit_flags[FLAG_OVERFLOW] = 1'b1;
          end else if (pdiv_q < -128'sh0000_0000_8000_0000_0000_0000) begin
            pres = 64'sh8000_0000_0000_0000;
            posit_flags[FLAG_SATURATE] = 1'b1;
            posit_flags[FLAG_OVERFLOW] = 1'b1;
          end else begin
            pres = pdiv_q[63:0];
          end
        end
      end
    endcase

    posit_y = {48'd0, posit_encode(pres)};
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
      NUM_RADD, NUM_RMUL: begin
        y = rns_y;
        // per-channel modular arithmetic is exact: no flags
      end
      NUM_LNMUL, NUM_LNDIV: begin
        y     = {32'd0, lns_y};
        flags = lns_flags;
      end
      NUM_PADD, NUM_PSUB, NUM_PMUL, NUM_PDIV: begin
        y     = posit_y;
        flags = posit_flags;
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

  logic unused_fmt;
  assign unused_fmt = ^fmt;

endmodule
`default_nettype wire
