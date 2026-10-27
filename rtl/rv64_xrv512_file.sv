`timescale 1ns/1ps
// =============================================================================
// rv64_xrv512_file.sv -- 32 x 512-bit register file for XRV512.
//
// Two full-width read ports and one full-width write port, plus a lane port so
// software can read or write a single 64-bit lane through the CSR window without
// moving the whole register.
//
// Reads are combinational, writes are synchronous -- the usual register-file
// shape. A write and a read of the same register in one cycle returns the OLD
// value on both read ports, which is what the pipeline that drives it expects.
// =============================================================================
`default_nettype none

module rv64_xrv512_file (
  input  logic         clk,
  input  logic         rst_n,

  // ---- full-width read ports ----------------------------------------------
  input  logic [4:0]   raddr_a,
  output logic [511:0] rdata_a,
  input  logic [4:0]   raddr_b,
  output logic [511:0] rdata_b,

  // ---- full-width write port ----------------------------------------------
  input  logic [4:0]   waddr,
  input  logic [511:0] wdata,
  input  logic         we,

  // ---- single-lane port ----------------------------------------------------
  input  logic [4:0]   laddr,
  input  logic [2:0]   llane,
  output logic [63:0]  ldata,
  input  logic [63:0]  lwdata,
  input  logic         lwe
);
  localparam int NREG = 32;

  logic [511:0] regs [0:NREG-1];

  assign rdata_a = regs[raddr_a];
  assign rdata_b = regs[raddr_b];
  // constant lane indices, not `64*llane +: 64`: a computed part-select base
  // evaluated as lane 0 under xezim
  always_comb begin
    unique case (llane)
      3'd0: ldata = regs[laddr][63:0];
      3'd1: ldata = regs[laddr][127:64];
      3'd2: ldata = regs[laddr][191:128];
      3'd3: ldata = regs[laddr][255:192];
      3'd4: ldata = regs[laddr][319:256];
      3'd5: ldata = regs[laddr][383:320];
      3'd6: ldata = regs[laddr][447:384];
      default: ldata = regs[laddr][511:448];
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int r = 0; r < NREG; r++) regs[r] <= 512'd0;
    end else begin
      if (we) regs[waddr] <= wdata;
      if (lwe) begin
        unique case (llane)
          3'd0: regs[laddr][63:0]    <= lwdata;
          3'd1: regs[laddr][127:64]  <= lwdata;
          3'd2: regs[laddr][191:128] <= lwdata;
          3'd3: regs[laddr][255:192] <= lwdata;
          3'd4: regs[laddr][319:256] <= lwdata;
          3'd5: regs[laddr][383:320] <= lwdata;
          3'd6: regs[laddr][447:384] <= lwdata;
          default: regs[laddr][511:448] <= lwdata;
        endcase
      end
    end
  end

endmodule
`default_nettype wire
