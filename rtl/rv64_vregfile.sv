`timescale 1ns/1ps
// =============================================================================
// rv64_vregfile.sv -- 32 x VLEN vector register file for the RVV subset.
//
// VLEN is 64 bits. Two read ports (vs1, vs2) and one write port (vd), plus a
// byte-lane port so software can read or write one 64-bit word through a control
// window without moving a whole register.
//
// Stored as a FLAT 1-D array of 64-bit words. That is deliberate: a 512-bit array
// element read came back with lane 0 replicated under xezim, and a 2-D array
// truncated reads to 32 bits -- both cost this project a full session in XRV512.
// A flat 64-bit array with a computed index reads correctly in every tool used
// here.
// =============================================================================
`default_nettype none

module rv64_vregfile (
  input  logic        clk,
  input  logic        rst_n,

  input  logic [4:0]  raddr1,
  output logic [63:0] rdata1,
  input  logic [4:0]  raddr2,
  output logic [63:0] rdata2,
  input  logic [4:0]  raddr3,      // the destination, read so a tail is preserved
  output logic [63:0] rdata3,

  input  logic [4:0]  waddr,
  input  logic [63:0] wdata,
  input  logic        we,

  // control-window access to a single register
  input  logic [4:0]  caddr,
  output logic [63:0] cdata,
  input  logic [63:0] cwdata,
  input  logic        cwe
);
  localparam int NREG = 32;

  logic [63:0] regs [0:NREG-1];

  assign rdata1 = regs[raddr1];
  assign rdata2 = regs[raddr2];
  assign rdata3 = regs[raddr3];
  assign cdata  = regs[caddr];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int r = 0; r < NREG; r++) regs[r] <= 64'd0;
    end else begin
      if (we)  regs[waddr] <= wdata;
      if (cwe) regs[caddr] <= cwdata;
    end
  end

endmodule
`default_nettype wire
