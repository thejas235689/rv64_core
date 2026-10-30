// =============================================================================
// rv64_clic.sv -- CLIC-lite core-local interrupt controller.
//
// AIA/CLIC differs from PLIC in the thing that matters to a CPU: PLIC delivers a
// single external-interrupt line and software then claims a source; CLIC delivers
// the interrupt CAUSE NUMBER directly, so the trap handler knows what fired without
// a claim round-trip. That removes a CSR access and a serialisation point from
// every interrupt.
//
// Eight sources, each with:
//   level  0..7            priority, 7 highest
//   edge   level-sensitive or rising-edge
//   shv     selective hardware vectoring -- if set, the core jumps straight to
//           mtvt + 4*cause instead of the common handler
//
// Outputs:
//   irq        level to the core (the core still sees one line, as RISC-V requires)
//   cause_id   which source won, for the trap handler to read
//   cause_val  asserted with irq so the core can latch the id
//
// This is deliberately NOT the full CLIC spec: no mtvt/mnxti/mintthresh CSRs, no
// privilege-level stacking, no tail-chaining. It is the arbitration and vectored
// delivery, which is the part that changes behaviour.
// =============================================================================
`ifndef RV64_CLIC_SV
`define RV64_CLIC_SV

module rv64_clic #(
  parameter int NSRC = 8
) (
  input  logic            clk,
  input  logic            rst_n,

  // interrupt sources, bit 0 = source 0
  input  logic [NSRC-1:0] src,

  // configuration: one write port, addressed by source
  input  logic            cfg_we,
  input  logic [3:0]      cfg_addr,      // {src[3:0]} for the config word
  input  logic [15:0]     cfg_wdata,     // {shv[8], edge[7], level[6:0]}

  // delivered interrupt
  output logic            irq,
  output logic [3:0]      cause_id,
  output logic            cause_valid,

  // software acknowledgement -- clears the pending bit for a source
  input  logic            ack,
  input  logic [3:0]      ack_id
);

  logic [2:0]  level_q  [0:NSRC-1];
  logic [NSRC-1:0] edge_q;
  logic [NSRC-1:0] shv_q;
  logic [NSRC-1:0] pending_q;
  logic [NSRC-1:0] src_q;

  // ---- configuration write -------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NSRC; i++) level_q[i] <= 3'd0;
      edge_q <= '0;
      shv_q  <= '0;
    end else if (cfg_we) begin
      if (cfg_addr[3] == 1'b0) begin
        for (int i = 0; i < NSRC; i++)
          if (cfg_addr[2:0] == 3'(i)) level_q[i] <= cfg_wdata[2:0];
      end else begin
        for (int i = 0; i < NSRC; i++)
          if (cfg_addr[2:0] == 3'(i)) begin
            edge_q[i] <= cfg_wdata[3];
            shv_q[i]  <= cfg_wdata[4];
          end
      end
    end
  end

  // ---- edge detection and pending ------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      src_q     <= '0;
      pending_q <= '0;
    end else begin
      src_q <= src;
      for (int i = 0; i < NSRC; i++) begin
        if (ack && (ack_id == 4'(i))) begin
          pending_q[i] <= 1'b0;
        end else if (edge_q[i]) begin
          // rising edge sets pending; it stays until acknowledged
          if (src[i] && !src_q[i]) pending_q[i] <= 1'b1;
        end else begin
          // level-sensitive: pending follows the source
          pending_q[i] <= src[i];
        end
      end
    end
  end

  // ---- arbitration: highest level wins, lowest index breaks ties -----------
  always_comb begin
    irq         = 1'b0;
    cause_id    = 4'd0;
    cause_valid = 1'b0;
    for (int i = NSRC-1; i >= 0; i--) begin
      if (pending_q[i] && (level_q[i] != 3'd0)) begin
        // iterate high-to-low so the highest level, then lowest index, survives
        if (!irq || (level_q[i] >= level_q[cause_id[3:0]])) begin
          irq         = 1'b1;
          cause_id    = 4'(i);
          cause_valid = 1'b1;
        end
      end
    end
  end

endmodule
`endif
