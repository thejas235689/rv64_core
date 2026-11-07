`timescale 1ns/1ps
// =============================================================================
// rv64_fregfile.sv -- 32 x 64-bit floating-point register file (RV64 F/D).
//
// NaN-boxing per the RISC-V F/D spec: a narrower value (binary32) is stored with
// all ones in the upper 32 bits.  `w_single` says the instruction being retired
// produced a binary32 result, and the boxing is applied HERE so that every
// producer gets it for free and none of them can forget:
//
//     flw / fadd.s / fsub.s / fmul.s / fdiv.s / fsqrt.s / fcvt.s.* / fmv.w.x
//
// A read returns the full 64-bit contents; unboxing is the consumer's job and
// lives in rv64_fp_unbox, because only the consumer knows whether it is running a
// single- or double-precision operation.
//
// This is deliberately a plain two-read/one-write register file: the FPU's
// operations hold their operands themselves, so no forwarding network is needed
// here yet.
// =============================================================================
`default_nettype none

module rv64_fregfile (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        we,
  input  logic [4:0]  waddr,
  input  logic [63:0] wdata,
  input  logic        w_single,     // 1 = NaN-box wdata[31:0] before storing

  input  logic [4:0]  raddr_a,
  output logic [63:0] rdata_a,
  input  logic [4:0]  raddr_b,
  output logic [63:0] rdata_b
);
  localparam logic [31:0] BOX_HI = 32'hFFFF_FFFF;

  logic [63:0] regs_q [32];
  logic [63:0] wdata_boxed;

  always_comb wdata_boxed = w_single ? {BOX_HI, wdata[31:0]} : wdata;

  // Write-through bypass. The integer file can rely on a forwarding network; the
  // FP side has none, and a dependent instruction reaches EX in the SAME cycle the
  // producer writes at WB -- so without this the reader gets the old value. That
  // is why `fadd.d f3,f1,f2` followed by `fmv.x.d x7,f3` read a stale f3.
  assign rdata_a = (we && (waddr == raddr_a)) ? wdata_boxed : regs_q[raddr_a];
  assign rdata_b = (we && (waddr == raddr_b)) ? wdata_boxed : regs_q[raddr_b];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 32; i++) regs_q[i] <= 64'd0;
    end else if (we) begin
      // No `waddr != 0` guard here.  That rule belongs to the INTEGER file, where
      // x0 is hardwired to zero; the F/D register file has no such register and
      // f0 is an ordinary one.  Copying the integer idiom in silently discarded
      // every write to f0: `fadd.d f0,f1,f2` left f0 at its old value, so the
      // test_fpu_integration f0 cases read 0 and `fadd.d f4,f0,f2` returned a
      // stale operand.  Measured on riscv_core_top before the fix: all 8 f0
      // cases failed.
      regs_q[waddr] <= wdata_boxed;
    end
  end
endmodule

`default_nettype wire
