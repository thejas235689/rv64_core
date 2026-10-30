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

  // Stored as 64-bit lane elements rather than 512-bit words: reading a 512-bit
  // array element returned lane 0 replicated under xezim, so every lane of the
  // full-width read held the first lane's value. Concatenating eight 64-bit
  // elements with constant lane indices reads correctly.
  // flat 1-D array of 64-bit words: a 2-D read (regs[reg][lane]) truncated to
  // 32 bits under xezim, while a variable ARRAY index works correctly
  logic [63:0] regs [0:NREG*8-1];

  wire [7:0] abase = {raddr_a, 3'b000};
  wire [7:0] bbase = {raddr_b, 3'b000};
  assign rdata_a = {regs[abase+7], regs[abase+6], regs[abase+5], regs[abase+4],
                    regs[abase+3], regs[abase+2], regs[abase+1], regs[abase]};
  assign rdata_b = {regs[bbase+7], regs[bbase+6], regs[bbase+5], regs[bbase+4],
                    regs[bbase+3], regs[bbase+2], regs[bbase+1], regs[bbase]};
  // constant lane indices, not `64*llane +: 64`: a computed part-select base
  // evaluated as lane 0 under xezim
  always_comb begin
    unique case (llane)
      default: ldata = regs[{laddr, llane}];
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int r = 0; r < NREG*8; r++) regs[r] <= 64'd0;
    end else begin
      if (we) begin
        for (int l = 0; l < 8; l++) regs[{waddr, 3'(l)}] <= wdata >> (64*l);
      end
      if (lwe) begin
        unique case (llane)
          default: regs[{laddr, llane}] <= lwdata;
        endcase
      end
    end
  end

endmodule
`default_nettype wire
