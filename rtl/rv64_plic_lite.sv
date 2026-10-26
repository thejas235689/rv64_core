// =============================================================================
// rv64_plic_lite.sv -- four-source platform-level interrupt controller (lite).
//   Per-source priority, global enable mask and priority threshold, with
//   claim/complete so a handler owns a source until it signals completion.
//   Sources are level-sensitive: the pending bit follows the input.
// =============================================================================
`default_nettype none

module rv64_plic_lite (
  input  logic        clk,
  input  logic        rst_n,

  input  logic [3:0]  src,          // level-sensitive sources, bit 0 = source 1

  // ---- configuration port (memory-mapped by the platform) -------------------
  input  logic        cfg_we,
  input  logic [4:0]  cfg_addr,
  input  logic [31:0] cfg_wdata,
  output logic [31:0] cfg_rdata,

  // ---- claim / complete -----------------------------------------------------
  input  logic        claim,
  output logic [3:0]  claim_id,
  output logic        claim_valid,
  input  logic        complete,
  input  logic [3:0]  complete_id,

  output logic        irq
);
  logic [2:0] prio [0:3];
  logic [3:0] enable_q;
  logic [3:0] in_service;
  logic [2:0] threshold;

  logic [3:0] eligible;
  logic [3:0] above_thr;
  logic [3:0] claimable;

  assign eligible  = src & enable_q;
  assign claimable = eligible & ~in_service;

  // ---- priority selection (higher index wins ties) --------------------------
  logic [3:0] best_id;
  logic       best_v;
  logic [2:0] best_prio;

  always_comb begin
    best_id   = 4'd0;
    best_v    = 1'b0;
    best_prio = 3'd0;
    for (int i = 3; i >= 0; i--) begin
      if (claimable[i] && prio[i] > best_prio) begin
        best_id   = i[3:0];
        best_prio = prio[i];
        best_v    = 1'b1;
      end
    end
  end

  always_comb begin
    above_thr = 4'd0;
    for (int i = 0; i < 4; i++) above_thr[i] = eligible[i] && (prio[i] > threshold);
  end

  assign irq        = |above_thr;
  assign claim_id   = best_id;
  assign claim_valid= best_v;

  // ---- config read ----------------------------------------------------------
  always_comb begin
    unique case (cfg_addr)
      5'd0:    cfg_rdata = {29'd0, prio[0]};
      5'd1:    cfg_rdata = {29'd0, prio[1]};
      5'd2:    cfg_rdata = {29'd0, prio[2]};
      5'd3:    cfg_rdata = {29'd0, prio[3]};
      5'd4:    cfg_rdata = {28'd0, enable_q};
      5'd5:    cfg_rdata = {29'd0, threshold};
      5'd6:    cfg_rdata = {28'd0, in_service};
      default: cfg_rdata = 32'd0;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 4; i++) prio[i] <= 3'd0;
      enable_q    <= 4'd0;
      in_service  <= 4'd0;
      threshold   <= 3'd0;
    end else begin
      if (cfg_we) begin
        unique case (cfg_addr)
          5'd0: prio[0] <= cfg_wdata[2:0];
          5'd1: prio[1] <= cfg_wdata[2:0];
          5'd2: prio[2] <= cfg_wdata[2:0];
          5'd3: prio[3] <= cfg_wdata[2:0];
          5'd4: enable_q <= cfg_wdata[3:0];
          5'd5: threshold <= cfg_wdata[2:0];
          default: ;
        endcase
      end

      if (claim && best_v) in_service[best_id] <= 1'b1;
      if (complete)        in_service[complete_id] <= 1'b0;
    end
  end

endmodule
`default_nettype wire
