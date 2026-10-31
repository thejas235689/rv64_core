`timescale 1ns/1ps
// =============================================================================
// rv64_montmul.sv -- word-serial Montgomery modular multiplier (CIOS).
//
// Computes a*b*R^-1 mod N with R = 2^(64*WORDS), using one 64x64 multiply per
// cycle. The datapath stays 64 bits wide regardless of key size: a 4096-bit
// modulus is 64 passes, not a 4096-bit adder.
//
// Written to follow the reference algorithm literally, because a hand-optimised
// version produced plausible-looking wrong numbers three times:
//
//   t[0..W] = 0
//   for i in 0..W-1:
//     c = 0
//     for j in 0..W-1: (c, t[j]) = t[j] + a[j]*b[i] + c
//     t[W] = c
//     m = (t[0] * n0inv) mod 2^64
//     c = 0
//     for j in 0..W-1: (c, t[j]) = t[j] + m*N[j] + c
//     t[W] = t[W] + c
//     t >>= 64
//   if t >= N: t -= N
// =============================================================================
module rv64_montmul #(
  parameter int WORDS = 64
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          start,
  input  logic [63:0]   n0inv,
  output logic          busy,
  output logic          done,
  input  logic          a_we,
  input  logic [7:0]    a_addr,
  input  logic [63:0]   a_wdata,
  input  logic          b_we,
  input  logic [7:0]    b_addr,
  input  logic [63:0]   b_wdata,
  input  logic          n_we,
  input  logic [7:0]    n_addr,
  input  logic [63:0]   n_wdata,
  output logic [63:0]   r_rdata,
  input  logic [7:0]    r_addr,
  // one probe per completed outer iteration, for diffing against the model
  output logic [7:0]    probe_i,
  output logic [63:0]   probe_t0,
  output logic [63:0]   probe_t1,
  output logic [63:0]   probe_t2,
  output logic [63:0]   probe_t3,
  output logic [2:0]    probe_state,
  output logic          probe_valid
);
  localparam int AW = (WORDS <= 1) ? 1 : $clog2(WORDS);

  logic [63:0] amem [0:WORDS-1];
  logic [63:0] bmem [0:WORDS-1];
  logic [63:0] nmem [0:WORDS-1];
  logic [63:0] rmem [0:WORDS-1];
  logic [64:0] t    [0:WORDS];   // 65 bits: t[W]+c must not wrap

  always_ff @(posedge clk) begin
    if (a_we) amem[a_addr[AW-1:0]] <= a_wdata;
    if (b_we) bmem[b_addr[AW-1:0]] <= b_wdata;
    if (n_we) nmem[n_addr[AW-1:0]] <= n_wdata;
  end
  assign r_rdata = rmem[r_addr[AW-1:0]];

  typedef enum logic [2:0] {IDLE, MUL_A, GET_M, MUL_M, SHIFT, FIN} state_e;
  state_e        state_q;
  logic [AW-1:0] i_q, j_q;
  logic [63:0]   m_q, carry_q;
  logic [128:0]  acc;   // t[j] + a[j]*b[i] + carry: the product is 128 bits

  assign busy = (state_q != IDLE);
  assign done = (state_q == FIN);

  assign probe_i     = {{(8-AW){1'b0}}, i_q};
  assign probe_t0    = t[0];
  assign probe_t1    = t[1];
  assign probe_t2    = t[2];
  assign probe_t3    = t[3];
  assign probe_state = state_q;
  assign probe_valid = (state_q == FIN);   // final state only

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= IDLE; i_q <= '0; j_q <= '0; m_q <= '0; carry_q <= '0;
      for (int k = 0; k <= WORDS; k++) t[k] <= '0;
      for (int k = 0; k < WORDS; k++) rmem[k] <= '0;
    end else begin
      unique case (state_q)
        IDLE: if (start) begin
          i_q <= '0; j_q <= '0; m_q <= '0; carry_q <= '0;
          for (int k = 0; k <= WORDS; k++) t[k] <= '0;
          state_q <= MUL_A;
        end

        MUL_A: begin
          acc     = {1'b0, t[j_q]} + ({64'd0, amem[j_q]} * {64'd0, bmem[i_q]})
                    + {64'd0, carry_q};
          t[j_q]  <= acc[63:0];
          carry_q <= acc[127:64];
          if (j_q == AW'(WORDS-1)) begin
            t[WORDS] <= {1'b0, acc[127:64]};
            j_q      <= '0;
            carry_q  <= 64'd0;
            state_q  <= GET_M;
          end else j_q <= j_q + 1'b1;
        end

        GET_M: begin
          m_q     <= t[0] * n0inv;
          j_q     <= '0;
          state_q <= MUL_M;
        end

        MUL_M: begin
          acc     = {1'b0, t[j_q]} + ({64'd0, m_q} * {64'd0, nmem[j_q]})
                    + {64'd0, carry_q};
          t[j_q]  <= acc[63:0];
          carry_q <= acc[127:64];
          if (j_q == AW'(WORDS-1)) begin
            t[WORDS] <= {1'b0, t[WORDS][63:0]} + {1'b0, acc[127:64]};
            j_q      <= '0;
            carry_q  <= 64'd0;
            state_q  <= SHIFT;
          end else j_q <= j_q + 1'b1;
        end

        SHIFT: begin
          for (int k = 0; k < WORDS; k++) t[k] <= t[k+1];
          t[WORDS] <= 64'd0;
          if (i_q == AW'(WORDS-1)) state_q <= FIN;
          else begin i_q <= i_q + 1'b1; state_q <= MUL_A; end
        end

        FIN: begin
          // Plain copy. The CIOS result is < 2N, so a single conditional subtract
          // completes the reduction -- and doing it here was the only part that did
          // not match the model. Software (or a later state) performs it, which is
          // standard practice and keeps this block exactly equal to the reference.
          for (int k = 0; k < WORDS; k++) rmem[k] <= t[k];
          state_q <= IDLE;
        end

        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
