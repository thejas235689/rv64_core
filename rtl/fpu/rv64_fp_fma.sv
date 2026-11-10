`timescale 1ns/1ps
`default_nettype none

module rv64_fp_fma (
  input  logic        fmt,
  input  logic [2:0]  rm,
  input  logic        negate_product, negate_addend,
  input  logic [63:0] a, b, c,
  output logic [63:0] result,
  output logic [4:0]  flags
);
  typedef struct packed {
    logic sign, nan, snan, inf;
    logic [52:0] sig;
    logic signed [12:0] scale;
  } operand_t;

  function automatic operand_t unpack(input logic [63:0] x, input logic double_fmt);
    operand_t o;
    logic [10:0] e;
    logic [51:0] f;
    logic special;
    o = '0;
    e = double_fmt ? x[62:52] : {3'b0, x[30:23]};
    f = double_fmt ? x[51:0] : {29'b0, x[22:0]};
    special = double_fmt ? e == 11'h7ff : e == 11'h0ff;
    o.sign = double_fmt ? x[63] : x[31];
    o.nan = special && f != 0;
    o.snan = o.nan && !(double_fmt ? f[51] : f[22]);
    o.inf = special && f == 0;
    o.sig = {1'b0, f};
    if (e != 0)
      o.sig[double_fmt ? 52 : 23] = 1'b1;
    o.scale = $signed({2'b0, (e == 0 ? 11'd1 : e)})
              - (double_fmt ? 13'sd1075 : 13'sd150);
    return o;
  endfunction

  // Put the leading bit of each term at bit 158. Close terms align exactly,
  // including all 106 product bits. Far terms retain a sticky bit.
  localparam int LEAD = 158;
  function automatic logic [159:0] shift_jam(input logic [159:0] x, input int n);
    logic [159:0] shifted;
    if (n >= 160) return {159'b0, |x};
    shifted = x >> n;
    shifted[0] = shifted[0] | (|(x << (160 - n)));
    return shifted;
  endfunction

  operand_t x, y, z;
  logic [105:0] product;
  logic [159:0] p, q, magnitude;
  logic product_sign, addend_sign, sign;
  logic invalid_product, infinite_product;
  int p_msb, q_msb, mag_msb, p_exp, q_exp, base_exp, drop;
  logic signed [12:0] exponent;
  logic [55:0] sig;
  logic [63:0] rounded;
  logic [4:0] round_flags;

  always_comb begin
    x = unpack(a, fmt);
    y = unpack(b, fmt);
    z = unpack(c, fmt);
    product_sign = x.sign ^ y.sign ^ negate_product;
    addend_sign = z.sign ^ negate_addend;
    invalid_product = (x.inf && !y.inf && !y.nan && y.sig == 0) ||
                      (y.inf && !x.inf && !x.nan && x.sig == 0);
    infinite_product = (x.inf || y.inf) && !(x.nan || y.nan || invalid_product);
    product = x.sig * y.sig;

    p_msb = 0;
    q_msb = 0;
    for (int i = 0; i < 106; i++)
      if (product[i]) p_msb = i;
    for (int i = 0; i < 53; i++)
      if (z.sig[i]) q_msb = i;
    p_exp = product == 0 ? -4096 : int'(x.scale) + int'(y.scale) + p_msb;
    q_exp = z.sig == 0 ? -4096 : int'(z.scale) + q_msb;
    base_exp = p_exp > q_exp ? p_exp : q_exp;
    p = shift_jam(160'(product) << (LEAD - p_msb), base_exp - p_exp);
    q = shift_jam(160'(z.sig) << (LEAD - q_msb), base_exp - q_exp);
    if (product_sign == addend_sign) begin
      magnitude = p + q;
      sign = product_sign;
    end else if (p > q) begin
      magnitude = p - q;
      sign = product_sign;
    end else if (q > p) begin
      magnitude = q - p;
      sign = addend_sign;
    end else begin
      magnitude = '0;
      sign = rm == 3'd2;
    end

    mag_msb = 0;
    for (int i = 0; i < 160; i++)
      if (magnitude[i]) mag_msb = i;
    exponent = 13'(base_exp + mag_msb - LEAD);
    drop = mag_msb - (fmt ? 55 : 26);
    sig = drop > 0 ? 56'(shift_jam(magnitude, drop)) : 56'(magnitude << -drop);
  end

  rv64_fp_round u_round (
    .fmt(fmt), .sign(sign), .exp_in(exponent), .sig(sig), .rm(rm),
    .result(rounded), .flags(round_flags)
  );

  always_comb begin
    result = rounded;
    flags = round_flags;
    if (invalid_product || x.nan || y.nan || z.nan ||
        (infinite_product && z.inf && product_sign != addend_sign)) begin
      result = fmt ? 64'h7ff8_0000_0000_0000 : 64'h0000_0000_7fc0_0000;
      flags = {invalid_product || x.snan || y.snan || z.snan ||
               (infinite_product && z.inf && product_sign != addend_sign), 4'b0};
    end else if (infinite_product || z.inf) begin
      result = fmt ? {infinite_product ? product_sign : addend_sign, 11'h7ff, 52'b0}
                   : {32'b0, infinite_product ? product_sign : addend_sign, 8'hff, 23'b0};
      flags = '0;
    end else if (magnitude == 0) begin
      result = fmt ? {sign, 63'b0} : {32'b0, sign, 31'b0};
      flags = '0;
    end
  end
endmodule

`default_nettype wire
