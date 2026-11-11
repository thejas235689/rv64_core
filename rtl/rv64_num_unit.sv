`timescale 1ns/1ps
// =============================================================================
// rv64_num_unit.sv -- arithmetic datapath for the custom numeric ABI.
//
// Fixed-point Q32.32 (value = x / 2^32) and an exact 128-bit quire accumulator
// are implemented and verified. Adaptive-precision truncation and error-bound
// tracking are implemented. The posit / logarithmic / residue / IEEE families
// have reserved opcodes and currently raise `invalid`.
//
// Rounding and saturation are controlled by the ncfg word (see rv64_num_pkg):
//   cfg[1:0] 0 = truncate toward zero on the shifted-out bits, 1 = round half up
//   cfg[2]   1 = saturate on overflow, 0 = wrap
//   cfg[13:8] adaptive mantissa width (8..64)
//   cfg[21]  apply adaptive truncation to both operands of QADD/QSUB/QMUL
//
// The quire is a Q64.64 accumulator: the exact product of two Q32.32 values is
// a Q64.64 value and fits in 128 bits with no rounding, which is the property
// the quire exists to provide.
// =============================================================================
`default_nettype none

module rv64_num_unit (
  input  logic        clk,
  input  logic        rst_n,

  input  logic [4:0]  op,
  input  logic [2:0]  fmt,
  input  logic [63:0] a,
  input  logic [63:0] b,
  input  logic [63:0] cfg,
  input  logic        op_valid,   // one-cycle pulse: execute this operation once

  output logic [63:0] y,
  output logic [7:0]  flags,      // per-operation flags, not sticky
  output logic [63:0] err,        // error bound of this operation

  output logic [127:0] quire      // exact accumulator
);
  import rv64_num_pkg::*;

  logic [1:0]  cfg_round;
  logic        cfg_sat;
  logic [CFG_PREC_W-1:0] cfg_prec;
  logic        cfg_adapt;
  logic        cfg_erren;

  assign cfg_round = cfg[CFG_ROUND_SHIFT +: 2];
  assign cfg_sat   = cfg[CFG_SAT_SHIFT];
  assign cfg_prec  = cfg[CFG_PREC_SHIFT +: CFG_PREC_W];
  assign cfg_adapt = cfg[CFG_ADAPT_SHIFT];
  assign cfg_erren = cfg[CFG_ERREN_SHIFT];

  // ---- adaptive precision: truncate an operand to cfg_prec bits ------------
  // Functions may only take input arguments (both simulators agree here), so
  // the value and the lost-bits flag are separate functions.
  function automatic logic [63:0] adapt_val(input logic [63:0] v,
                                            input logic [CFG_PREC_W-1:0] prec,
                                            input logic        round_up);
    int drop;
    if (prec >= 7'd64) return v;
    drop = 64 - prec;
    if (round_up) return (v + (64'd1 << (drop - 1))) & ~((64'd1 << drop) - 64'd1);
    else          return v & ~((64'd1 << drop) - 64'd1);
  endfunction

  function automatic logic adapt_lost(input logic [63:0] v,
                                      input logic [CFG_PREC_W-1:0] prec);
    int drop;
    if (prec >= 7'd64) return 1'b0;
    drop = 64 - prec;
    return (v & ((64'd1 << drop) - 64'd1)) != 64'd0;
  endfunction

  // ---- fixed-Q arithmetic --------------------------------------------------
  logic [63:0] opa, opb;
  logic        adapt_lost_a, adapt_lost_b;
  logic        add_ovf, sub_ovf, mul_ovf;
  logic [64:0] add_ext, sub_ext;
  logic [127:0] mul_prod;
  logic [63:0] qadd_y, qsub_y, qmul_y;
  logic [63:0] qmul_dropped;

  always_comb begin
    opa = a;
    opb = b;
    adapt_lost_a = 1'b0;
    adapt_lost_b = 1'b0;
    if (cfg_adapt && (op == NUM_QADD || op == NUM_QSUB || op == NUM_QMUL)) begin
      opa = adapt_val(a, cfg_prec, cfg_round[0]);
      opb = adapt_val(b, cfg_prec, cfg_round[0]);
      adapt_lost_a = adapt_lost(a, cfg_prec);
      adapt_lost_b = adapt_lost(b, cfg_prec);
    end
  end

  // signed add/subtract with overflow detection on the extended result
  always_comb begin
    add_ext = {opa[63], opa} + {opb[63], opb};
    add_ovf = (add_ext[64] != add_ext[63]);
    sub_ext = {opa[63], opa} - {opb[63], opb};
    sub_ovf = (sub_ext[64] != sub_ext[63]);
  end

  always_comb begin
    // the sign bit of the truncated result says which rail to saturate to
    if (add_ovf && cfg_sat) qadd_y = add_ext[63] ? 64'h8000_0000_0000_0000
                                                 : 64'h7FFF_FFFF_FFFF_FFFF;
    else qadd_y = add_ext[63:0];

    if (sub_ovf && cfg_sat) qsub_y = sub_ext[63] ? 64'h8000_0000_0000_0000
                                                 : 64'h7FFF_FFFF_FFFF_FFFF;
    else qsub_y = sub_ext[63:0];
  end

  // Q32.32 multiply: full 128-bit product, then shift out the 32 fractional bits
  logic signed [127:0] mul_signed;
  assign mul_signed = $signed(opa) * $signed(opb);

  always_comb begin
    mul_prod = mul_signed;
    if (cfg_round[0]) qmul_y = (mul_signed + 128'sh0000_0000_8000_0000) >>> 32;
    else              qmul_y = mul_signed >>> 32;
    qmul_dropped = mul_prod[31:0];
  end

  logic signed [127:0] mul_shifted;
  assign mul_shifted = mul_signed >>> 32;
  // fits in 64 bits iff the high half is a pure sign extension of bit 63
  assign mul_ovf = (mul_shifted != {{64{mul_shifted[63]}}, mul_shifted[63:0]});

  // ---- quire ---------------------------------------------------------------
  logic [127:0] quire_q;
  logic [127:0] acc_prod;
  logic [127:0] quire_next;
  logic         quire_ovf;
  logic [63:0]  qget_y;
  logic [63:0]  qget_dropped;

  assign acc_prod = $signed(a) * $signed(b);      // exact Q64.64 product

  always_comb begin
    quire_next = quire_q;
    quire_ovf  = 1'b0;
    case (op)
      NUM_QCLR: quire_next = 128'd0;
      NUM_QACC: begin
        {quire_ovf, quire_next} = {1'b0, quire_q} + {1'b0, acc_prod};
      end
      default: ;
    endcase
  end

  // read the quire back as Q32.32, rounding per cfg
  always_comb begin
    // the quire is a two's-complement Q64.64 accumulator, so the read-back must
    // shift arithmetically, not logically
    if (cfg_round[0]) qget_y = ($signed(quire_q) + 128'sh0000_0000_8000_0000) >>> 32;
    else              qget_y = $signed(quire_q) >>> 32;
    qget_dropped = quire_q[31:0];
  end

  // The quire is stateful, so it must advance exactly once per instruction.
  // Gating on op_valid matters: an instruction can sit in EX for several cycles
  // behind a stall, and an ungated accumulator adds the product every cycle.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)          quire_q <= 128'd0;
    else if (op_valid)   quire_q <= quire_next;
  end
  assign quire = quire_q;

  // ---- error bound of the last operation -----------------------------------
  logic [63:0] err_q;
  logic [63:0] err_now;

  always_comb begin
    err_now = 64'd0;
    case (op)
      // half an LSB of the Q32.32 result when rounding, the dropped bits otherwise
      NUM_QMUL: err_now = cfg_round[0] ? 64'd1 : {32'd0, qmul_dropped};
      NUM_QGET: err_now = cfg_round[0] ? 64'd1 : {32'd0, qget_dropped};
      NUM_ADAPT: begin
        if (cfg_prec >= 7'd64) err_now = 64'd0;
        else                   err_now = a & ((64'd1 << (64 - cfg_prec)) - 64'd1);
      end
      default: err_now = 64'd0;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) err_q <= 64'd0;
    else if (cfg_erren && op_valid) err_q <= err_now;
  end
  assign err = err_q;

  // ---- standalone adaptive truncation --------------------------------------
  logic [63:0] adapt_y;
  logic        adapt_lost_self;
  always_comb begin
    adapt_y         = adapt_val(a, cfg_prec, cfg_round[0]);
    adapt_lost_self = adapt_lost(a, cfg_prec);
  end

  // For es=1, 2*(width-2) fractional bits represent minpos exactly.
  // The sign-extended operand gives a two's-complement encoding across widths.
  function automatic logic signed [57:0] posit_fixed(
    input logic signed [15:0] value, input int width
  );
    logic [15:0] magnitude;
    logic [57:0] significand;
    logic regime, scanning;
    int run, fraction_bits, exponent, scale;
    magnitude = value[15] ? -value : value;
    regime = magnitude[width-2];
    run = 0;
    scanning = 1'b1;
    for (int bit_index = 14; bit_index >= 0; bit_index--) begin
      if (bit_index <= width-2) begin
        if (scanning && magnitude[bit_index] == regime) run++;
        else scanning = 1'b0;
      end
    end
    exponent = 0;
    fraction_bits = 0;
    if (run < width-2) begin
      fraction_bits = width-3-run;
      exponent = int'(magnitude[fraction_bits]);
    end
    significand = (58'd1 << fraction_bits)
                | (58'(magnitude) & ((58'd1 << fraction_bits) - 58'd1));
    scale = 2 * (width-2) + 2 * (regime ? run-1 : -run) + exponent - fraction_bits;
    if (magnitude == 0) return '0;
    significand = significand << scale;
    return value[15] ? -$signed(significand) : $signed(significand);
  endfunction

  function automatic logic signed [25:0] posit8_q12(input logic [7:0] value);
    return 26'(posit_fixed(16'($signed(value)), 8));
  endfunction

  logic signed [63:0] posit_quire_q;
  wire pq8_format = fmt == FMT_P8;
  wire pq16_format = fmt == FMT_P16;
  wire pq_operands_ok = !(|a[63:8]) && !(|b[63:8]) &&
                        a[7:0] != 8'h80 && b[7:0] != 8'h80;
  wire signed [51:0] pq_product = posit8_q12(a[7:0]) * posit8_q12(b[7:0]);
  wire signed [64:0] pq_sum = 65'(posit_quire_q) + 65'(pq_product);
  wire pq_overflow = pq_sum[64] != pq_sum[63];

  // Posit16 spans 2^-28 to 2^28. Its exact products use 56 fractional bits.
  logic signed [127:0] posit16_quire_q;
  wire pq16_operands_ok = !(|a[63:16]) && !(|b[63:16]) &&
                         a[15:0] != 16'h8000 && b[15:0] != 16'h8000;
  wire signed [115:0] pq16_product =
      posit_fixed($signed(a[15:0]), 16) * posit_fixed($signed(b[15:0]), 16);
  wire signed [128:0] pq16_sum = 129'(posit16_quire_q) + 129'(pq16_product);
  wire pq16_overflow = pq16_sum[128] != pq16_sum[127];

  // Positive posit encodings are monotonic. Find the largest encoding whose
  // exact value does not exceed the quire magnitude, then compare against the
  // next encoding's midpoint. Ties select an even encoding, including zero.
  function automatic logic [63:0] posit8_magnitude_q24(input logic [6:0] code);
    return {26'd0, $unsigned(posit8_q12({1'b0, code})), 12'd0};
  endfunction

  logic [7:0] pq_rounded;
  logic pq_inexact, pq_saturate;
  always_comb begin : round_posit_quire
    logic [63:0] magnitude, lower_value, upper_value;
    logic [7:0] low, high, mid;
    logic [6:0] selected;
    logic [64:0] twice_value, twice_midpoint;

    magnitude = posit_quire_q[63] ? -$unsigned(posit_quire_q) : $unsigned(posit_quire_q);
    low = 8'd0;
    high = 8'd127;
    for (int step = 0; step < 7; step++) begin
      mid = (low + high + 8'd1) >> 1;
      if (posit8_magnitude_q24(mid[6:0]) <= magnitude)
        low = mid;
      else
        high = mid - 8'd1;
    end

    lower_value = posit8_magnitude_q24(low[6:0]);
    upper_value = posit8_magnitude_q24(low == 8'd127 ? 7'd127 : low[6:0] + 7'd1);
    twice_value = {magnitude, 1'b0};
    twice_midpoint = {1'b0, lower_value} + {1'b0, upper_value};
    selected = low[6:0];
    if (low != 8'd127 &&
        (twice_value > twice_midpoint || (twice_value == twice_midpoint && low[0])))
      selected = low[6:0] + 7'd1;

    pq_rounded = posit_quire_q[63] ? -{1'b0, selected} : {1'b0, selected};
    pq_inexact = magnitude != posit8_magnitude_q24(selected);
    pq_saturate = low == 8'd127 && magnitude > lower_value;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      posit_quire_q <= '0;
      posit16_quire_q <= '0;
    end else if (op_valid) begin
      if (op == NUM_PQCLR) begin
        if (pq8_format) posit_quire_q <= '0;
        if (pq16_format) posit16_quire_q <= '0;
      end else if (op == NUM_PQACC) begin
        if (pq8_format && pq_operands_ok && !pq_overflow)
          posit_quire_q <= pq_sum[63:0];
        if (pq16_format && pq16_operands_ok && !pq16_overflow)
          posit16_quire_q <= pq16_sum[127:0];
      end
    end
  end

  // ---- research families: RNS / LNS / POSIT / FP32 -------------------------
  logic [63:0] wide_y;
  logic [7:0]  wide_flags;

  rv64_num_wide u_wide (
    .op    (op),
    .fmt   (fmt),
    .a     (a),
    .b     (b),
    .y     (wide_y),
    .flags (wide_flags)
  );

  logic [63:0] unum_result;
  logic unum_invalid, unum_overflow, unum_inexact;
  rv64_num_unum u_unum (
    .fmt(fmt), .a(a), .b(b), .result(unum_result), .invalid(unum_invalid),
    .overflow(unum_overflow), .inexact(unum_inexact)
  );

  // ---- result and flags ----------------------------------------------------
  always_comb begin
    y     = 64'd0;
    flags = 8'd0;

    case (op)
      NUM_QADD: begin
        y = qadd_y;
        if (add_ovf) begin
          flags[FLAG_OVERFLOW] = 1'b1;
          if (cfg_sat) flags[FLAG_SATURATE] = 1'b1;
        end
        if (adapt_lost_a || adapt_lost_b) flags[FLAG_PRECISION] = 1'b1;
      end

      NUM_QSUB: begin
        y = qsub_y;
        if (sub_ovf) begin
          flags[FLAG_OVERFLOW] = 1'b1;
          if (cfg_sat) flags[FLAG_SATURATE] = 1'b1;
        end
        if (adapt_lost_a || adapt_lost_b) flags[FLAG_PRECISION] = 1'b1;
      end

      NUM_QMUL: begin
        y = qmul_y;
        if (qmul_dropped != 64'd0) flags[FLAG_INEXACT] = 1'b1;
        if (mul_ovf) begin
          flags[FLAG_OVERFLOW] = 1'b1;
          if (cfg_sat) flags[FLAG_SATURATE] = 1'b1;
        end
        if (adapt_lost_a || adapt_lost_b) flags[FLAG_PRECISION] = 1'b1;
      end

      NUM_QGET: begin
        y = qget_y;
        if (qget_dropped != 64'd0) flags[FLAG_INEXACT] = 1'b1;
      end

      NUM_QACC: begin
        y = 64'd0;
        if (quire_ovf) flags[FLAG_QUIRE_OVF] = 1'b1;
      end

      NUM_PQCLR: flags[FLAG_INVALID] = !(pq8_format || pq16_format);

      NUM_PQGET: begin
        if (pq8_format) y = posit_quire_q;
        else if (pq16_format) y = posit16_quire_q[63:0];
        else if (fmt == FMT_PQ_HIGH_P16) y = posit16_quire_q[127:64];
        else if (fmt == FMT_PQ_ROUND_P8) begin
          y = {56'd0, pq_rounded};
          flags[FLAG_INEXACT] = pq_inexact;
          flags[FLAG_SATURATE] = pq_saturate;
        end else flags[FLAG_INVALID] = 1'b1;
      end

      NUM_PQACC: begin
        if (pq8_format) begin
          flags[FLAG_INVALID] = !pq_operands_ok;
          flags[FLAG_QUIRE_OVF] = pq_operands_ok && pq_overflow;
        end else if (pq16_format) begin
          flags[FLAG_INVALID] = !pq16_operands_ok;
          flags[FLAG_QUIRE_OVF] = pq16_operands_ok && pq16_overflow;
        end else flags[FLAG_INVALID] = 1'b1;
      end

      NUM_QCLR: y = 64'd0;

      NUM_ADAPT: begin
        y = adapt_y;
        if (adapt_lost_self) flags[FLAG_PRECISION] = 1'b1;
        if (adapt_lost_self) flags[FLAG_INEXACT]   = 1'b1;
      end

      NUM_ERR: y = err_q;

      // bridge ops carry data between the banks; the unit itself does nothing
      NUM_TOINT, NUM_FROMINT: y = 64'd0;

      NUM_PADD, NUM_PSUB, NUM_PMUL, NUM_PDIV,
      NUM_LNMUL, NUM_LNDIV, NUM_LNADD, NUM_LNSUB, NUM_RADD, NUM_RMUL, NUM_RSUB,
      NUM_FADD, NUM_FMUL, NUM_BFADD, NUM_BFSUB, NUM_BFMUL,
      NUM_SDADD, NUM_SDSUB: begin
        y     = wide_y;
        flags = wide_flags;
      end

      NUM_UNUM: begin
        y = unum_result;
        flags[FLAG_INVALID] = unum_invalid;
        flags[FLAG_OVERFLOW] = unum_overflow;
        flags[FLAG_INEXACT] = unum_inexact;
      end

      default: begin
        y = 64'd0;
        flags[FLAG_INVALID] = 1'b1;
      end
    endcase
  end

  // fmt is unused by the implemented families; keep it referenced so lint is quiet
  logic unused_fmt;
  assign unused_fmt = ^fmt;

endmodule
`default_nettype wire
