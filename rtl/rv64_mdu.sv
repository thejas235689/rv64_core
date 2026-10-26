// =============================================================================
// rv64_mdu.sv -- RV64M multiply/divide unit.
//   MUL*  : single-cycle combinational product, registered, done next cycle.
//   DIV*  : 64-step restoring shift/subtract loop, one quotient bit per cycle.
// Special cases per the RISC-V M specification:
//   div/0  -> quotient all ones, remainder = dividend
//   divu/0 -> quotient all ones, remainder = dividend
//   rem/0  -> remainder = dividend
//   signed overflow (INT64_MIN / -1) -> quotient = INT64_MIN, remainder = 0
// =============================================================================
`default_nettype none

module rv64_mdu (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,      // one-cycle pulse: begin operation
  input  logic [2:0]  op,
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic        busy,       // operation in flight (core stalls)
  output logic        done,       // one-cycle pulse: result valid
  output logic [63:0] result
);
  import rv64_pkg::*;

  typedef enum logic [1:0] {S_IDLE, S_DIV, S_FIN} state_e;

  state_e      state;
  logic [2:0]  op_q;
  logic [63:0] a_q, b_q;
  logic [63:0] quo, rem, divisor, dividend;
  logic [6:0]  cnt;
  logic [63:0] res_q;
  logic        done_q;

  // ---- product (all three sign combinations) --------------------------------
  logic signed [127:0] prod_ss, prod_su;
  logic        [127:0] prod_uu;
  logic        [63:0]  mul_res;

  assign prod_ss = $signed(a_q) * $signed(b_q);
  assign prod_su = $signed(a_q) * $signed({1'b0, b_q});
  assign prod_uu = a_q * b_q;

  always_comb begin
    unique case (op_q)
      MDU_MUL:    mul_res = prod_ss[63:0];
      MDU_MULH:   mul_res = prod_ss[127:64];
      MDU_MULHSU: mul_res = prod_su[127:64];
      MDU_MULHU:  mul_res = prod_uu[127:64];
      default:    mul_res = prod_ss[63:0];
    endcase
  end

  // ---- magnitude / sign handling -------------------------------------------
  logic        a_neg, b_neg, div_signed, is_rem;

  assign div_signed = (op_q == MDU_DIV) || (op_q == MDU_REM);
  assign is_rem     = (op_q == MDU_REM) || (op_q == MDU_REMU);
  assign a_neg      = div_signed && a_q[63];
  assign b_neg      = div_signed && b_q[63];

  // ---- sequential -----------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= S_IDLE;
      op_q    <= 3'd0;
      a_q     <= 64'd0;
      b_q     <= 64'd0;
      quo     <= 64'd0;
      rem     <= 64'd0;
      divisor <= 64'd0;
      dividend<= 64'd0;
      cnt     <= 7'd0;
      res_q   <= 64'd0;
      done_q  <= 1'b0;
    end else begin
      done_q <= 1'b0;

      unique case (state)
        S_IDLE: begin
          if (start) begin
            op_q <= op;
            a_q  <= a;
            b_q  <= b;
            if (op <= MDU_MULHU) begin
              state <= S_FIN;                 // multiply: one cycle
            end else begin
              state    <= S_DIV;
              quo      <= 64'd0;
              rem      <= 64'd0;
              divisor  <= (b == 64'd0) ? 64'd1 : ((b[63] && (op == MDU_DIV || op == MDU_REM))
                                                  ? (~b + 64'd1) : b);
              dividend <= (a[63] && (op == MDU_DIV || op == MDU_REM))
                          ? (~a + 64'd1) : a;
              cnt      <= 7'd64;
            end
          end
        end

        S_DIV: begin
          // one restoring-division step: shift in the next dividend bit
          logic [64:0] shifted;
          shifted = {rem, dividend[63]} ;
          if (shifted >= {1'b0, divisor}) begin
            rem          <= shifted[63:0] - divisor;
            quo          <= {quo[62:0], 1'b1};
          end else begin
            rem          <= shifted[63:0];
            quo          <= {quo[62:0], 1'b0};
          end
          dividend <= {dividend[62:0], 1'b0};
          cnt      <= cnt - 7'd1;
          if (cnt == 7'd1) state <= S_FIN;
        end

        S_FIN: begin
          // resolve final result (multiply or divide/remainder with sign fixup)
          if (op_q <= MDU_MULHU) begin
            res_q <= mul_res;
          end else if (b_q == 64'd0) begin
            res_q <= is_rem ? a_q : 64'hFFFF_FFFF_FFFF_FFFF;
          end else if (div_signed && a_q == 64'h8000_0000_0000_0000 && b_q == 64'hFFFF_FFFF_FFFF_FFFF) begin
            res_q <= is_rem ? 64'd0 : 64'h8000_0000_0000_0000;
          end else if (is_rem) begin
            // remainder takes the sign of the dividend (RISC-V M spec)
            res_q <= a_neg ? (~rem + 64'd1) : rem;
          end else begin
            res_q <= (a_neg ^ b_neg) ? (~quo + 64'd1) : quo;
          end
          done_q <= 1'b1;
          state  <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  assign busy   = (state != S_IDLE);
  assign done   = done_q;
  assign result = res_q;

endmodule
`default_nettype wire
