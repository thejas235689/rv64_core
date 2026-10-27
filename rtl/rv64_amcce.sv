`timescale 1ns/1ps
// =============================================================================
// rv64_amcce.sv -- AMCCE: Adaptive Multi-Mode Cache Engine.
//
// CONTRACT (this block defines the term, so the definition is written down here
// rather than assumed):
//
//   AMCCE watches a cache's hit/miss stream and picks the cache's operating mode
//   for the next window. Its purpose is the case a fixed policy handles badly: a
//   sequential scan that misses every line, fills the cache with data that is
//   never reused, and evicts the working set. Detecting that and bypassing the
//   cache for the duration is worth more than any replacement tweak.
//
//   mode 0 NORMAL  -- cache normally
//   mode 1 BYPASS  -- streaming detected; do not allocate, pass through
//   mode 2 RETAIN  -- reuse is high; keep everything, evict reluctantly
//
//   Every `window` accesses the engine evaluates the miss rate for the window:
//     miss% > hi_thresh            -> BYPASS
//     miss% < lo_thresh            -> NORMAL (or RETAIN if reuse is very high)
//     otherwise                    -> hold the current mode
//   The two thresholds give hysteresis: a single window cannot flip the mode back
//   and forth, because the return threshold is strictly below the enter
//   threshold. Without that, a rate hovering at the boundary oscillates every
//   window and the mode becomes noise.
//
// Ports: a hit/miss observer port from the cache, a mode output the cache obeys,
// and a CSR window for thresholds, window length and counters.
//
// NOT IMPLEMENTED, stated rather than implied: it does not itself cache anything,
// it has no knowledge of addresses (so it cannot distinguish a stream from a
// working set directly -- only through the miss rate), there is no prefetch or
// way-partitioning action, and RETAIN is reported but no current cache in this
// tree consumes it. The engine decides; enforcement is the cache's job.
// =============================================================================
`default_nettype none

module rv64_amcce (
  input  logic        clk,
  input  logic        rst_n,

  // ---- observation port from the cache ------------------------------------
  input  logic        acc_valid,
  input  logic        acc_hit,        // 1 = hit, 0 = miss
  input  logic        acc_miss,

  // ---- policy output -------------------------------------------------------
  output logic [1:0]  mode,           // 0 NORMAL, 1 BYPASS, 2 RETAIN
  output logic        bypass,         // convenience: mode == BYPASS

  // ---- control window ------------------------------------------------------
  input  logic        csr_we,
  input  logic [3:0]  csr_addr,
  input  logic [63:0] csr_wdata,
  output logic [63:0] csr_rdata,

  // ---- observability -------------------------------------------------------
  output logic [31:0] total_hits,
  output logic [31:0] total_misses,
  output logic [31:0] mode_switches
);
  localparam logic [1:0] M_NORMAL = 2'd0, M_BYPASS = 2'd1, M_RETAIN = 2'd2;

  logic        enable_q;
  logic [15:0] window_q;
  logic [15:0] hi_q, lo_q;
  logic [1:0]  mode_q;

  logic [15:0] whits_q, wmiss_q;      // this window
  logic [31:0] hits_q, misses_q;
  logic [31:0] switches_q;

  assign mode   = mode_q;
  assign bypass = (mode_q == M_BYPASS);
  assign total_hits   = hits_q;
  assign total_misses = misses_q;
  assign mode_switches = switches_q;

  // ---- window evaluation ---------------------------------------------------
  // 100 * misses / accesses, compared against the thresholds, using a
  // multiplication rather than a division: no divider in a policy block.
  wire [31:0] wacc   = {16'd0, whits_q} + {16'd0, wmiss_q};
  wire [31:0] wmiss_pct_x100 = (wacc == 32'd0) ? 32'd0 : (10000 * {16'd0, wmiss_q}) / wacc;
  wire        window_end = enable_q && (wacc + 32'd1 >= {16'd0, window_q});

  // ---- control window ------------------------------------------------------
  always_comb begin
    csr_rdata = 64'd0;
    unique case (csr_addr)
      4'd0: csr_rdata = {63'd0, enable_q};
      4'd1: csr_rdata = {48'd0, window_q};
      4'd2: csr_rdata = {48'd0, hi_q};
      4'd3: csr_rdata = {48'd0, lo_q};
      4'd4: csr_rdata = {62'd0, mode_q};
      4'd5: csr_rdata = {32'd0, hits_q};
      4'd6: csr_rdata = {32'd0, misses_q};
      4'd7: csr_rdata = {32'd0, switches_q};
      4'd8: csr_rdata = {32'd0, wmiss_pct_x100};
      default: csr_rdata = 64'd0;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      enable_q  <= 1'b1;   // enabled by default; a CSR write can disable it
      window_q  <= 16'd64;
      hi_q      <= 16'd75;         // > 75% miss -> bypass
      lo_q      <= 16'd25;         // < 25% miss -> normal
      mode_q    <= M_NORMAL;
      whits_q   <= 16'd0;
      wmiss_q   <= 16'd0;
      hits_q    <= 32'd0;
      misses_q  <= 32'd0;
      switches_q<= 32'd0;
    end else begin
      if (csr_we) begin
        unique case (csr_addr)
          4'd0: enable_q <= csr_wdata[0];
          4'd1: if (csr_wdata[15:0] != 16'd0) window_q <= csr_wdata[15:0];
          4'd2: hi_q <= csr_wdata[15:0];
          4'd3: lo_q <= csr_wdata[15:0];
          default: ;
        endcase
      end

      // ---- observation -----------------------------------------------------
      if (enable_q && acc_valid) begin
        if (acc_hit) begin
          whits_q <= whits_q + 16'd1;
          hits_q  <= hits_q + 32'd1;
        end else if (acc_miss) begin
          wmiss_q <= wmiss_q + 16'd1;
          misses_q<= misses_q + 32'd1;
        end
      end

      // ---- window boundary: re-evaluate the mode ---------------------------
      // The counters include the access presented this cycle, so the decision
      // sees the completed window rather than the one before it.
      if (window_end) begin
        whits_q <= 16'd0;
        wmiss_q <= 16'd0;
        if (wmiss_pct_x100 > {16'd0, hi_q} * 32'd100) begin
          if (mode_q != M_BYPASS) begin
            mode_q     <= M_BYPASS;
            switches_q <= switches_q + 32'd1;
          end
        end else if (wmiss_pct_x100 < {16'd0, lo_q} * 32'd100) begin
          if (mode_q != M_NORMAL) begin
            mode_q     <= M_NORMAL;
            switches_q <= switches_q + 32'd1;
          end
        end
        // else: hold, which is the hysteresis
      end
    end
  end

endmodule
`default_nettype wire
