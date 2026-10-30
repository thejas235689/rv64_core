`timescale 1ns/1ps
// =============================================================================
// rv64_clint.sv -- core-local interruptor: machine timer and software interrupt.
//
// Provides the two interrupt sources the core's mip expects but that nothing in
// this repository generated: MTIP from mtime >= mtimecmp, and MSIP from a
// software-written pending bit.
//
// Control port (CSR window):
//   0 MTIME_LO     read/write
//   1 MTIME_HI     read/write
//   2 MTIMECMP_LO  read/write
//   3 MTIMECMP_HI  read/write
//   4 MSIP         [0] software interrupt pending, write 1 to set, 0 to clear
//   5 STATUS       read: [0] timer pending, [1] software pending, [2] timer enable
//   6 CTRL         [0] timer enable (counter still runs; this gates the IRQ)
//
// A real CLINT is memory-mapped at 0x0200_0000; here it is a CSR window, like
// the other blocks in this core, because the core has no platform bus.
// =============================================================================
`default_nettype none

module rv64_clint (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        csr_we,
  input  logic [3:0]  csr_addr,
  input  logic [63:0] csr_wdata,
  output logic [63:0] csr_rdata,

  output logic        timer_irq,
  output logic        soft_irq
);

  logic [63:0] mtime;
  logic [63:0] mtimecmp;
  logic        msip;
  logic        timer_en;

  wire timer_pend = (mtime >= mtimecmp);

  assign timer_irq = timer_pend && timer_en;
  assign soft_irq  = msip;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mtime    <= 64'd0;
      mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;   // no timer interrupt until armed
      msip     <= 1'b0;
      timer_en <= 1'b0;
    end else begin
      mtime <= mtime + 64'd1;
      if (csr_we) begin
        case (csr_addr)
          4'd0: mtime[31:0]  <= csr_wdata[31:0];
          4'd1: mtime[63:32] <= csr_wdata[31:0];
          4'd2: mtimecmp[31:0]  <= csr_wdata[31:0];
          4'd3: mtimecmp[63:32] <= csr_wdata[31:0];
          4'd4: msip <= csr_wdata[0];
          4'd6: timer_en <= csr_wdata[0];
          default: ;
        endcase
      end
    end
  end

  always_comb begin
    csr_rdata = 64'd0;
    case (csr_addr)
      4'd0: csr_rdata = {32'd0, mtime[31:0]};
      4'd1: csr_rdata = {32'd0, mtime[63:32]};
      4'd2: csr_rdata = {32'd0, mtimecmp[31:0]};
      4'd3: csr_rdata = {32'd0, mtimecmp[63:32]};
      4'd4: csr_rdata = {63'd0, msip};
      4'd5: csr_rdata = {61'd0, timer_en, msip, timer_pend};
      4'd6: csr_rdata = {63'd0, timer_en};
      default: csr_rdata = 64'd0;
    endcase
  end

endmodule
`default_nettype wire
