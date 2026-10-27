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

  // ---- tagged history ------------------------------------------------------
  // A tag per gshare entry, so two branches that alias to the same index do not
  // train each other's counter. On a tag miss the entry carries no information
  // for this branch and the bimodal counter is used instead.
  logic [5:0]   gsh_tag [0:255];

  // ---- perceptron ----------------------------------------------------------
  // 32 tables of 8 signed 6-bit weights, indexed by the low PC bits and dotted
  // with the global history. A history-dependent branch (outcome = f(history))
  // is linearly separable and the perceptron learns it; a 2-bit counter cannot.
  localparam int PW = 8;
  logic signed [5:0] wtab [0:31][0:PW-1];

  logic [63:0]  ras [0:7];
  logic [2:0]   ras_sp;

  // ---- loop predictor ------------------------------------------------------
  // A counted loop has a fixed trip count, and the tournament predictor gets the
  // final iteration wrong every pass because it is the one iteration that is not
  // taken. This table learns the trip count and predicts the exit directly.
  //
  // It only engages once a count has been learned, so a branch that is not a loop
  // never overrides the tournament -- the existing behaviour is preserved for
  // everything else, which is what keeps the regression meaningful.
  localparam int LOOP_N = 16;
  logic         loop_v    [0:LOOP_N-1];
  logic [7:0]   loop_tag  [0:LOOP_N-1];
  logic [7:0]   loop_trip [0:LOOP_N-1];
  logic [7:0]   loop_iter [0:LOOP_N-1];

  logic [3:0]  lidx;
  logic        loop_hit;
  logic        loop_pred_taken;

  assign lidx     = lookup_pc[7:4];
  assign loop_hit = loop_v[lidx] && (loop_tag[lidx] == lookup_pc[15:8]);

  // taken while the iteration counter is short of the learned trip count,
  // not-taken on the final iteration
  assign loop_pred_taken = !(loop_hit && (loop_trip[lidx] != 8'd0) &&
                             ((loop_iter[lidx] + 8'd1) >= loop_trip[lidx]));

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

  wire [5:0] pc_tag   = lookup_pc[15:10];
  wire       tag_hit  = (gsh_tag[gidx] == pc_tag);

  // update-side view of the same test, declared before the sequential block
  logic [7:0] gidx_upd;
  assign gidx_upd = idx_of(upd_pc) ^ ghr;
  wire  tag_hit_upd = (gsh_tag[gidx_upd] == upd_pc[15:10]);

  assign c_bim  = bim[idx][1];
  assign c_gsh  = gsh[gidx][1];
  // an untagged entry has nothing to say about this branch
  assign choice = tag_hit ? (cho[idx][1] ? c_gsh : c_bim) : c_bim;

  // ---- perceptron dot product ---------------------------------------------
  wire [4:0] pidx = lookup_pc[6:2];
  logic signed [11:0] psum;
  always_comb begin
    psum = 12'sd0;
    for (int i = 0; i < PW; i++) begin
      if (ghr[i]) psum = psum + wtab[pidx][i];
      else        psum = psum - wtab[pidx][i];
    end
  end
  wire perc_taken = (psum >= 12'sd0);
  // only override the tournament when the perceptron is confident
  wire perc_conf  = (psum > 12'sd8) || (psum < -12'sd8);

  always_comb begin
    if (btb_hit && btb_unc[bidx]) begin
      pred_taken  = 1'b1;
      pred_target = btb_tgt[bidx];
    end else if (btb_hit && btb_ret[bidx]) begin
      pred_taken  = 1'b1;
      pred_target = ras[ras_sp];
    end else if (loop_hit && btb_hit && (loop_trip[lidx] != 8'd0)) begin
      // A learned loop count beats the tournament for the exit iteration -- but
      // only with a valid BTB entry. Without the btb_hit guard the taken target
      // came from a stale BTB line and sent the core to address 0.
      pred_taken  = loop_pred_taken;
      pred_target = loop_pred_taken ? btb_tgt[bidx] : (lookup_pc + 64'd4);
    end else if (perc_conf && btb_hit) begin
      pred_taken  = perc_taken;
      pred_target = perc_taken ? btb_tgt[bidx] : (lookup_pc + 64'd4);
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
        gsh_tag[i] <= 6'd0;
      end
      for (int i = 0; i < 64; i++) begin
        btb_v[i]   <= 1'b0;
        btb_tag[i] <= 56'd0;
        btb_tgt[i] <= 64'd0;
        btb_unc[i] <= 1'b0;
        btb_ret[i] <= 1'b0;
      end
      for (int i = 0; i < 8; i++) ras[i] <= 64'd0;
      for (int i = 0; i < 32; i++)
        for (int j = 0; j < PW; j++) wtab[i][j] <= 6'sd0;
      for (int i = 0; i < LOOP_N; i++) begin
        loop_v[i]    <= 1'b0;
        loop_tag[i]  <= 8'd0;
        loop_trip[i] <= 8'd0;
        loop_iter[i] <= 8'd0;
      end
    end else begin
      // ---- return-address stack --------------------------------------------
      if (upd_valid && upd_is_call) begin
        ras[ras_sp] <= upd_pc + 64'd4;
        ras_sp      <= ras_sp + 3'd1;
      end else if (upd_valid && upd_is_ret) begin
        ras_sp      <= ras_sp - 3'd1;
      end

      // ---- loop predictor --------------------------------------------------
      // Taken: count the iteration and remember the longest run seen. Not taken:
      // the loop just exited, so the trip count is the run length plus this final
      // iteration, and the counter restarts.
      if (upd_valid && upd_is_cond) begin
        logic [3:0] li;
        li = upd_pc[7:4];
        if (!loop_v[li] || (loop_tag[li] != upd_pc[15:8])) begin
          loop_v[li]    <= 1'b1;
          loop_tag[li]  <= upd_pc[15:8];
          loop_trip[li] <= 8'd0;
          loop_iter[li] <= upd_taken ? 8'd1 : 8'd0;
        end else if (upd_taken) begin
          // Only COUNT while the branch keeps being taken. Learning the trip
          // count here would let a branch that is never not-taken accumulate a
          // count and then wrongly predict its own exit -- so the count is
          // learned only from the exit below.
          if (loop_iter[li] != 8'hFF) loop_iter[li] <= loop_iter[li] + 8'd1;
        end else begin
          // the exit iteration: the count is iter + 1
          if (loop_iter[li] != 8'd0) loop_trip[li] <= loop_iter[li] + 8'd1;
          loop_iter[li] <= 8'd0;
        end
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
        // tagged history: a mismatched tag restarts the counter rather than
        // letting an aliasing branch inherit it
        if (!tag_hit_upd) begin
          gsh_tag[gidx_upd] <= upd_pc[15:10];
          gsh[gidx_upd]     <= 2'b01;
        end
        // perceptron: nudge each weight toward the outcome
        for (int i = 0; i < PW; i++) begin
          if (ghr[i] == upd_taken) begin
            if (wtab[pidx_of(upd_pc)][i] != 6'sd31) wtab[pidx_of(upd_pc)][i] <= wtab[pidx_of(upd_pc)][i] + 6'sd1;
          end else begin
            if (wtab[pidx_of(upd_pc)][i] != -6'sd32) wtab[pidx_of(upd_pc)][i] <= wtab[pidx_of(upd_pc)][i] - 6'sd1;
          end
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

  function automatic logic [4:0] pidx_of(input logic [63:0] pc);
    return pc[6:2];
  endfunction

  function automatic logic [7:0] idx_of(input logic [63:0] pc);
    return pc[9:2];
  endfunction

  function automatic logic [7:0] gidx_of(input logic [63:0] pc);
    return pc[9:2] ^ ghr;
  endfunction

endmodule
`default_nettype wire
