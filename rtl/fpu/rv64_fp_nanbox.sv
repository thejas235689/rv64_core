`timescale 1ns/1ps
// =============================================================================
// rv64_fp_nanbox.sv -- NaN-boxing for the F extension.
//
// RISC-V F keeps binary32 values in the 64-bit f-registers with the upper 32 bits
// set to all ones ("NaN-boxed").  Two rules follow from that and both live here
// so neither the register file nor the datapath has to remember them:
//
//   write : a binary32 result is stored as {32'hFFFF_FFFF, value[31:0]}
//   read  : an operand of a single-precision operation is value[31:0] if the
//           upper half is all ones, and the canonical quiet NaN otherwise --
//           a value that was never boxed is not a valid binary32 operand, and
//           the spec says to treat it as the canonical NaN rather than as
//           whatever its low bits happen to look like.
//
// fmv.x.w is deliberately NOT unboxed here: it is a bit move, not a
// single-precision operation, so it sign-extends the low 32 bits as they are.
// =============================================================================
`default_nettype none

module rv64_fp_unbox (
  input  logic        fmt,        // 1 = binary64: pass through untouched
  input  logic [63:0] x,          // the raw f-register contents
  output logic [63:0] y          // binary32 in y[31:0] (zero-extended), or binary64
);
  localparam logic [31:0] BOX_HI  = 32'hFFFF_FFFF;
  localparam logic [31:0] CANON32 = 32'h7FC0_0000;   // canonical quiet NaN

  always_comb begin
    if (fmt)                        y = x;
    else if (x[63:32] == BOX_HI)    y = {32'd0, x[31:0]};
    else                            y = {32'd0, CANON32};
  end
endmodule

`default_nettype wire
