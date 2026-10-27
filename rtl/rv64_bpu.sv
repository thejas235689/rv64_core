`timescale 1ns/1ps
// =============================================================================
// rv64_bpu.sv -- branch prediction unit.
//   Tournament selection between a gshare predictor (8-bit GHR) and a bimodal
//   BHT, both 256-entry 2-bit counters, plus a 64-entry BTB carrying target,
//   unconditional and return classification, and an 8-entry return-address
//   stack used for return-target prediction.
//   Lookup is combinational in the fetch stage; updates are applied when a
//   control-flow instruction resolves in EX.
// =============================================================================
`default_nettype none

module rv64_bpu (
  input  logic        clk,
  input  logic        rst_n,

  // ---- fetch-stage lookup ---------------------------------------------------
  input  logic [63:0] lookup_pc,
  output logic        pred_taken,
  output logic [63:0] pred_target,

  // ---- EX-stage update ------------------------------------------------------
  input  logic        upd_valid,
  input  logic [63:0] upd_pc,
  input  logic        upd_taken,
  input  logic [63:0] upd_target,
  input  logic        upd_is_cond,     // conditional branch
  input  logic        upd_is_uncond,   // jal / jalr
  input  logic        upd_is_call,
  input  logic        upd_is_ret
);
  // ---- state ----------------------------------------------------------------
  logic [7:0]   ghr;
  logic [1:0]   bim [0:255];
  logic [1:0]   gsh [0:255];
  logic [1:0]   cho [0:255];

  logic         btb_v    [0:63];
  logic [55:0]  btb_tag  [0:63];
  logic [63:0]  btb_tgt  [0:63];
  logic         btb_unc  [0:63];
  logic         btb_ret  [0:63];

  logic [63:0]  ras [0:7];
  logic [2:0]   ras_sp;

  // ---- lookup ---------------------------------------------------------------
  logic [7:0]  idx;
  logic [7:0]  gidx;
  logic [5:0]  bidx;
  logic        btb_hit;
  logic        c_bim, c_gsh, choice;

  assign idx   = lookup_pc[9:2];
  assign gidx  = idx ^ ghr;
  assign bidx  = lookup_pc[7:2];
  assign btb_hit = btb_v[bidx] && (btb_tag[bidx] == lookup_pc[63:8]);

  assign c_bim  = bim[idx][1];
  assign c_gsh  = gsh[gidx][1];
  assign choice = cho[idx][1] ? c_gsh : c_bim;

  always_comb begin
    if (btb_hit && btb_unc[bidx]) begin
      pred_taken  = 1'b1;
      pred_target = btb_tgt[bidx];
    end else if (btb_hit && btb_ret[bidx]) begin
      pred_taken  = 1'b1;
      pred_target = ras[ras_sp];
    end else if (btb_hit && choice) begin
      pred_taken  = 1'b1;
      pred_target = btb_tgt[bidx];
    end else begin
      pred_taken  = 1'b0;
      pred_target = lookup_pc + 64'd4;
    end
  end

  // ---- counter update helper ------------------------------------------------
  function automatic logic [1:0] sat_inc(input logic [1:0] c);
    return (c == 2'b11) ? 2'b11 : c + 2'b01;
  endfunction

  function automatic logic [1:0] sat_dec(input logic [1:0] c);
    return (c == 2'b00) ? 2'b00 : c - 2'b01;
  endfunction

  // ---- sequential -----------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ghr    <= 8'd0;
      ras_sp <= 3'd0;
      for (int i = 0; i < 256; i++) begin
        bim[i] <= 2'b01;
        gsh[i] <= 2'b01;
        cho[i] <= 2'b10;      // start slightly favouring gshare
      end
      for (int i = 0; i < 64; i++) begin
        btb_v[i]   <= 1'b0;
        btb_tag[i] <= 56'd0;
        btb_tgt[i] <= 64'd0;
        btb_unc[i] <= 1'b0;
        btb_ret[i] <= 1'b0;
      end
      for (int i = 0; i < 8; i++) ras[i] <= 64'd0;
    end else begin
      // ---- return-address stack --------------------------------------------
      if (upd_valid && upd_is_call) begin
        ras[ras_sp] <= upd_pc + 64'd4;
        ras_sp      <= ras_sp + 3'd1;
      end else if (upd_valid && upd_is_ret) begin
        ras_sp      <= ras_sp - 3'd1;
      end

      // ---- predictors ------------------------------------------------------
      if (upd_valid && upd_is_cond) begin
        bim[idx_of(upd_pc)]  <= upd_taken ? sat_inc(bim[idx_of(upd_pc)])
                                          : sat_dec(bim[idx_of(upd_pc)]);
        gsh[gidx_of(upd_pc)] <= upd_taken ? sat_inc(gsh[gidx_of(upd_pc)])
                                          : sat_dec(gsh[gidx_of(upd_pc)]);
        // tournament: reward the predictor that was right
        if (gsh[gidx_of(upd_pc)][1] != bim[idx_of(upd_pc)][1]) begin
          cho[idx_of(upd_pc)] <= gsh[gidx_of(upd_pc)][1] ? sat_inc(cho[idx_of(upd_pc)])
                                                         : sat_dec(cho[idx_of(upd_pc)]);
        end
        ghr <= {ghr[6:0], upd_taken};
      end else if (upd_valid && upd_is_uncond) begin
        ghr <= {ghr[6:0], 1'b1};
      end

      // ---- BTB -------------------------------------------------------------
      if (upd_valid && (upd_is_cond || upd_is_uncond) && upd_taken) begin
        btb_v[upd_pc[7:2]]   <= 1'b1;
        btb_tag[upd_pc[7:2]] <= upd_pc[63:8];
        btb_tgt[upd_pc[7:2]] <= upd_target;
        btb_unc[upd_pc[7:2]] <= upd_is_uncond;
        btb_ret[upd_pc[7:2]] <= upd_is_ret;
      end
    end
  end

  function automatic logic [7:0] idx_of(input logic [63:0] pc);
    return pc[9:2];
  endfunction

  function automatic logic [7:0] gidx_of(input logic [63:0] pc);
    return pc[9:2] ^ ghr;
  endfunction

endmodule
`default_nettype wire
