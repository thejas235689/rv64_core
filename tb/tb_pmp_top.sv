// =============================================================================
// tb_pmp_top.sv -- unit harness for the PMP matcher.
//   Drives the configuration and the access descriptor directly, so TOR, NA4
//   and NAPOT boundaries and the M-mode lock rule can be checked without
//   running a program through the core.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_pmp_top ();
  logic [8*8-1:0]  cfg;
  logic [8*64-1:0] addr_cfg;
  logic [63:0]     addr;
  logic            is_write;
  logic            is_exec;
  logic            priv_m;
  logic            allow;

  rv64_pmp u_pmp (
    .cfg      (cfg),
    .addr_cfg (addr_cfg),
    .addr     (addr),
    .is_write (is_write),
    .is_exec  (is_exec),
    .priv_m   (priv_m),
    .allow    (allow)
  );

endmodule
`default_nettype wire
