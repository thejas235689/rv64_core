`timescale 1ns/1ps
// =============================================================================
// rv64_alu.sv -- 64-bit integer ALU: RV64I, RV64M-adjacent word ops, Zba, Zbb,
//                Zbc (clmul), Zbs and Zicond.  Purely combinational.
// =============================================================================
`default_nettype none

module rv64_alu (
  input  logic [63:0] a,
  input  logic [63:0] b,
  input  logic [5:0]  op,
  output logic [63:0] y
);
  import rv64_pkg::*;

  logic [5:0]  sh6;
  logic [4:0]  sh5;
  logic [31:0] a32, b32, y32;
  logic [63:0] rol64, ror64;
  logic [31:0] rolw_r, rorw_r;
  logic [6:0]  clz_r, ctz_r, cpop_r;
  logic [63:0] rev8_r, orcb_r;
  logic [127:0] prod128;
  logic [63:0] clmul_r, clmulh_r, clmulr_r;
  logic        eq_r;

  assign sh6 = b[5:0];
  assign sh5 = b[4:0];
  assign a32 = a[31:0];
  assign b32 = b[31:0];
  assign eq_r = (a == b);

  // ---- bit counts ------------------------------------------------------------
  always_comb begin
    clz_r  = 7'd64;
    for (int i = 0; i < 64; i++) begin
      if (a[63-i] && (clz_r == 7'd64)) clz_r = 7'(i);
    end
  end

  always_comb begin
    ctz_r = 7'd64;
    for (int i = 0; i < 64; i++) begin
      if (a[i] && (ctz_r == 7'd64)) ctz_r = 7'(i);
    end
  end

  always_comb begin
    cpop_r = 7'd0;
    for (int i = 0; i < 64; i++) begin
      cpop_r = cpop_r + 7'(a[i]);
    end
  end

  // ---- rotates ---------------------------------------------------------------
  always_comb begin
    if (sh6 == 6'd0) rol64 = a;
    else             rol64 = (a << sh6) | (a >> (64 - sh6));
  end

  always_comb begin
    if (sh6 == 6'd0) ror64 = a;
    else             ror64 = (a >> sh6) | (a << (64 - sh6));
  end

  // Word rotates: form the 32-bit result first, then sign-extend from the
  // result's own bit 31 (not from the input's).
  always_comb begin
    if (sh5 == 5'd0) rolw_r = a32;
    else             rolw_r = (a32 << sh5) | (a32 >> (32 - sh5));
  end

  always_comb begin
    if (sh5 == 5'd0) rorw_r = a32;
    else             rorw_r = (a32 >> sh5) | (a32 << (32 - sh5));
  end

  // ---- byte permutes ---------------------------------------------------------
  assign rev8_r = {a[7:0], a[15:8], a[23:16], a[31:24],
                   a[39:32], a[47:40], a[55:48], a[63:56]};

  always_comb begin
    orcb_r = 64'd0;
    for (int i = 0; i < 8; i++) begin
      orcb_r[8*i +: 8] = (a[8*i +: 8] != 8'd0) ? 8'hFF : 8'h00;
    end
  end

  // ---- carry-less multiply ---------------------------------------------------
  always_comb begin
    prod128 = 128'd0;
    for (int i = 0; i < 64; i++) begin
      if (b[i]) prod128 = prod128 ^ ({64'd0, a} << i);
    end
  end

  assign clmul_r  = prod128[63:0];
  assign clmulh_r = prod128[127:64];
  assign clmulr_r = prod128[126:63];

  // ---- word-result helper ----------------------------------------------------
  always_comb begin
    y32 = 32'd0;
    unique case (op)
      ALU_ADDW: y32 = a32 + b32;
      ALU_SUBW: y32 = a32 - b32;
      ALU_SLLW: y32 = a32 << sh5;
      ALU_SRLW: y32 = a32 >> sh5;
      ALU_SRAW: y32 = 32'($signed(a32) >>> sh5);
      default:  y32 = 32'd0;
    endcase
  end

  // ---- main mux --------------------------------------------------------------
  always_comb begin
    y = 64'd0;
    unique case (op)
      ALU_ADD:     y = a + b;
      ALU_SUB:     y = a - b;
      ALU_SLL:     y = a << sh6;
      ALU_SLT:     y = {63'd0, ($signed(a) < $signed(b))};
      ALU_SLTU:    y = {63'd0, (a < b)};
      ALU_XOR:     y = a ^ b;
      ALU_SRL:     y = a >> sh6;
      ALU_SRA:     y = 64'($signed(a) >>> sh6);
      ALU_OR:      y = a | b;
      ALU_AND:     y = a & b;
      ALU_ADDW:    y = {{32{y32[31]}}, y32};
      ALU_SUBW:    y = {{32{y32[31]}}, y32};
      ALU_SLLW:    y = {{32{y32[31]}}, y32};
      ALU_SRLW:    y = {{32{y32[31]}}, y32};
      ALU_SRAW:    y = {{32{y32[31]}}, y32};
      ALU_ANDN:    y = a & ~b;
      ALU_ORN:     y = a | ~b;
      ALU_XNOR:    y = ~(a ^ b);
      ALU_MAX:     y = ($signed(a) > $signed(b)) ? a : b;
      ALU_MAXU:    y = (a > b) ? a : b;
      ALU_MIN:     y = ($signed(a) < $signed(b)) ? a : b;
      ALU_MINU:    y = (a < b) ? a : b;
      ALU_SEXTB:   y = {{56{a[7]}}, a[7:0]};
      ALU_SEXTH:   y = {{48{a[15]}}, a[15:0]};
      ALU_ZEXTH:   y = {48'd0, a[15:0]};
      ALU_CLZ:     y = {57'd0, clz_r};
      ALU_CTZ:     y = {57'd0, ctz_r};
      ALU_CPOP:    y = {57'd0, cpop_r};
      ALU_ROL:     y = rol64;
      ALU_ROR:     y = ror64;
      ALU_ROLW:    y = {{32{rolw_r[31]}}, rolw_r};
      ALU_RORW:    y = {{32{rorw_r[31]}}, rorw_r};
      ALU_REV8:    y = rev8_r;
      ALU_ORCB:    y = orcb_r;
      ALU_BSET:    y = a | (64'd1 << sh6);
      ALU_BCLR:    y = a & ~(64'd1 << sh6);
      ALU_BINV:    y = a ^ (64'd1 << sh6);
      ALU_BEXT:    y = {63'd0, a[sh6]};
      ALU_SH1ADD:  y = (a << 1) + b;
      ALU_SH2ADD:  y = (a << 2) + b;
      ALU_SH3ADD:  y = (a << 3) + b;
      ALU_ADDUW:   y = {32'd0, a32} + b;
      ALU_SLLIUW:  y = {32'd0, a32} << sh6;
      ALU_CLMUL:   y = clmul_r;
      ALU_CLMULH:  y = clmulh_r;
      ALU_CLMULR:  y = clmulr_r;
      ALU_CZERO_EQZ: y = eq_r ? 64'd0 : b;
      ALU_CZERO_NEZ: y = eq_r ? b : 64'd0;
      ALU_PASS_A:  y = a;
      ALU_PASS_B:  y = b;
      default:     y = 64'd0;
    endcase
  end

endmodule
`default_nettype wire
