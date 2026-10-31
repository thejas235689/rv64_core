`timescale 1ns/1ps
// rv64_modexp -- modular exponentiation over rv64_montmul. Mirrors modexp_model.py.
module rv64_modexp #(parameter int WORDS = 64) (
  input  logic clk, rst_n, start,
  output logic busy, done,
  input  logic n0inv_we, input logic [63:0] n0inv_wdata,
  input  logic [15:0] e_bits,
  input  logic ld_we, input logic [2:0] ld_sel, input logic [7:0] ld_addr,
  input  logic [63:0] ld_wdata,
  output logic [63:0] r_rdata, input logic [7:0] r_addr,
  output logic [15:0] probe_op, output logic probe_op_valid,
  output logic m_start, output logic [63:0] m_n0inv, input logic m_done,
  output logic m_a_we, output logic [7:0] m_a_addr, output logic [63:0] m_a_wdata,
  output logic m_b_we, output logic [7:0] m_b_addr, output logic [63:0] m_b_wdata,
  output logic m_n_we, output logic [7:0] m_n_addr, output logic [63:0] m_n_wdata,
  input  logic [63:0] m_r_rdata, output logic [7:0] m_r_addr
);
  localparam int AW = (WORDS <= 1) ? 1 : $clog2(WORDS);
  logic [63:0] basem [0:WORDS-1], r2m [0:WORDS-1], nmem [0:WORDS-1];
  logic [63:0] acc [0:WORDS-1], emem [0:WORDS-1];
  logic [63:0] n0inv_q;
  always_ff @(posedge clk) begin
    if (ld_we) case (ld_sel)
      3'd0: basem[ld_addr[AW-1:0]] <= ld_wdata;
      3'd1: r2m  [ld_addr[AW-1:0]] <= ld_wdata;
      3'd2: nmem [ld_addr[AW-1:0]] <= ld_wdata;
      3'd3: acc  [ld_addr[AW-1:0]] <= ld_wdata;
      3'd4: emem [ld_addr[AW-1:0]] <= ld_wdata;
      default: ;
    endcase
    if (n0inv_we) n0inv_q <= n0inv_wdata;
  end
  assign r_rdata = acc[r_addr[AW-1:0]];
  typedef enum logic [3:0] {IDLE, LA, LB, LN, RUN, WAIT, RD, NEXT, FIN} st_e;
  typedef enum logic [1:0] {PH_CONV, PH_SQ, PH_MUL, PH_OUT} ph_e;
  st_e st_q; ph_e ph_q;
  logic [AW-1:0] w_q;
  logic [15:0] bit_q, op_q;
  assign busy = (st_q != IDLE) && (st_q != FIN);
  assign done = (st_q == FIN);
  assign probe_op = op_q;
  assign probe_op_valid = (st_q == RUN);
  logic expbit;
  always_comb expbit = emem[int'(bit_q) / 64][bit_q[5:0]];
  always_comb begin
    m_start   = (st_q == RUN);
    m_a_we    = 1'b0; m_b_we = 1'b0; m_n_we = 1'b0;
    m_a_addr  = {{(8-AW){1'b0}}, w_q};
    m_b_addr  = {{(8-AW){1'b0}}, w_q};
    m_n_addr  = {{(8-AW){1'b0}}, w_q};
    m_r_addr  = {{(8-AW){1'b0}}, w_q};
    m_a_wdata = 64'd0; m_b_wdata = 64'd0; m_n_wdata = 64'd0;
    m_n0inv   = n0inv_q;
  end
  logic [63:0] b_word;
  always_comb begin
    unique case (ph_q)
      PH_CONV: b_word = r2m[w_q];
      PH_SQ:   b_word = acc[w_q];
      PH_MUL:  b_word = basem[w_q];
      default: b_word = (w_q == '0) ? 64'd1 : 64'd0;
    endcase
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q <= IDLE; w_q <= '0; bit_q <= '0; op_q <= '0; ph_q <= PH_CONV;
    end else begin
      case (st_q)
        IDLE: if (start) begin
          w_q <= '0; op_q <= '0; ph_q <= PH_CONV;
          bit_q <= (e_bits == 16'd0) ? 16'd0 : e_bits - 1'b1;
          st_q <= LA;
        end
        LA: begin
          m_a_we = 1'b1;
          m_a_wdata = (ph_q == PH_CONV) ? basem[w_q] : acc[w_q];
          if (w_q == AW'(WORDS-1)) begin w_q <= '0; st_q <= LB; end
          else w_q <= w_q + 1'b1;
        end
        LB: begin
          m_b_we = 1'b1; m_b_wdata = b_word;
          if (w_q == AW'(WORDS-1)) begin w_q <= '0; st_q <= LN; end
          else w_q <= w_q + 1'b1;
        end
        LN: begin
          m_n_we = 1'b1; m_n_wdata = nmem[w_q];
          if (w_q == AW'(WORDS-1)) begin w_q <= '0; st_q <= RUN; end
          else w_q <= w_q + 1'b1;
        end
        RUN:  st_q <= WAIT;
        WAIT: if (m_done) begin w_q <= '0; st_q <= RD; end
        RD: begin
          acc[w_q] <= m_r_rdata;
          if (w_q == AW'(WORDS-1)) begin w_q <= '0; st_q <= NEXT; end
          else w_q <= w_q + 1'b1;
        end
        NEXT: begin
          op_q <= op_q + 1'b1;
          unique case (ph_q)
            PH_CONV: begin
              for (int k = 0; k < WORDS; k++) basem[k] <= acc[k];
              ph_q <= PH_SQ; st_q <= LA;
            end
            PH_OUT: st_q <= FIN;
            PH_SQ: begin
              if (expbit) begin ph_q <= PH_MUL; st_q <= LA; end
              else if (bit_q == 16'd0) begin ph_q <= PH_OUT; st_q <= LA; end
              else begin bit_q <= bit_q - 1'b1; ph_q <= PH_SQ; st_q <= LA; end
            end
            default: begin
              if (bit_q == 16'd0) begin ph_q <= PH_OUT; st_q <= LA; end
              else begin bit_q <= bit_q - 1'b1; ph_q <= PH_SQ; st_q <= LA; end
            end
          endcase
        end
        FIN: st_q <= IDLE;
        default: st_q <= IDLE;
      endcase
    end
  end
endmodule
