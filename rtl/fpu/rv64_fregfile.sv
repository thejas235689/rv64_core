`timescale 1ns/1ps
// =============================================================================
// rv64_fregfile.sv -- 32 x 64-bit floating-point register file (RV64 F/D).
//
// NaN-boxing per the RISC-V F/D spec: a narrower value (binary32 in an FLW) is
// stored with all ones in the upper 32 bits. A read returns the full 64-bit
// contents; a consumer that expects binary32 must check the upper bits are all
// ones and otherwise treat the operand as the canonical NaN.
//
// This is deliberately a plain two-read/one-write register file: the FPU's
// multi-cycle operations hold their operands themselves, so no forwarding network
// is needed here yet.
// =============================================================================
`default_nettype none

module rv64_fregfile (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        we,
  input  logic [4:0]  waddr,
  input  logic [63:0] wdata,

  input  logic [4:0]  raddr_a,
  output logic [63:0] rdata_a,
  input  logic [4:0]  raddr_b,
  output logic [63:0] rdata_b
);
  logic [63:0] regs_q [32];

  // Write-through bypass. The integer file can rely on a forwarding network; the
  // FP side has none, and a dependent instruction reaches EX in the SAME cycle the
  // producer writes at WB -- so without this the reader gets the old value. That
  // is why `fadd.d f3,f1,f2` followed by `fmv.x.d x7,f3` read a stale f3.
  assign rdata_a = (we && (waddr == raddr_a)) ? wdata : regs_q[raddr_a];
  assign rdata_b = (we && (waddr == raddr_b)) ? wdata : regs_q[raddr_b];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 32; i++) regs_q[i] <= 64'd0;
    end else if (we && (waddr != 5'd0)) begin
      regs_q[waddr] <= wdata;
    end
  end
endmodule

`default_nettype wire
