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

      NUM_QCLR: y = 64'd0;

      NUM_ADAPT: begin
        y = adapt_y;
        if (adapt_lost_self) flags[FLAG_PRECISION] = 1'b1;
        if (adapt_lost_self) flags[FLAG_INEXACT]   = 1'b1;
      end

      NUM_ERR: y = err_q;

      // bridge ops carry data between the banks; the unit itself does nothing
      NUM_TOINT, NUM_FROMINT: y = 64'd0;

      default: begin
        // reserved families (posit / log / residue / IEEE) are not implemented
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
