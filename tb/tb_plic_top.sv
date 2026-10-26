// =============================================================================
// tb_plic_top.sv -- verification harness for the four-source PLIC-lite.
//   Exposes the configuration port, claim/complete handshake and the level
//   sensitive sources directly to cocotb.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_plic_top ();
  logic        clk;
  logic        rst_n;

  logic [3:0]  src;
  logic        cfg_we;
  logic [4:0]  cfg_addr;
  logic [31:0] cfg_wdata;
  logic [31:0] cfg_rdata;
  logic        claim;
  logic [3:0]  claim_id;
  logic        claim_valid;
  logic        complete;
  logic [3:0]  complete_id;
  logic        irq;

  rv64_plic_lite u_plic (
    .clk         (clk),
    .rst_n       (rst_n),
    .src         (src),
    .cfg_we      (cfg_we),
    .cfg_addr    (cfg_addr),
    .cfg_wdata   (cfg_wdata),
    .cfg_rdata   (cfg_rdata),
    .claim       (claim),
    .claim_id    (claim_id),
    .claim_valid (claim_valid),
    .complete    (complete),
    .complete_id (complete_id),
    .irq         (irq)
  );

endmodule
`default_nettype wire
