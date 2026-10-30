`timescale 1ns/1ps
// =============================================================================
// rv64_bootrom.sv -- boot ROM at the reset vector.
//
// A read-only 64-bit-beat ROM the fetch path reads from at reset. It holds a
// short boot stub: the reset vector jumps here, the stub sets up the stack and
// then jumps to the payload (the firmware entry point, by default the RAM at
// 0x8000_0000).
//
// The image is initialised in an always block, which is what ROM inference
// expects -- there is no write port and no way to change the contents at run
// time. A build that needs a different image should regenerate the array rather
// than add a port.
//
// The stub is four instructions:
//   0x00  auipc x2, 0        -- x2 = pc, then add the stack offset
//   0x04  addi  x2, x2, 0x7F0
//   0x08  lui   x1, 0x80000  -- x1 = 0x8000_0000, the payload entry
//   0x0C  jalr  x0, 0(x1)
// =============================================================================
`default_nettype none

module rv64_bootrom (
  input  logic        clk,        // unused; kept so the port matches a memory
  input  logic        rst_n,

  input  logic        req_valid,
  input  logic [63:0] req_addr,
  output logic        req_ready,
  output logic        rsp_valid,
  output logic [63:0] rsp_rdata,
  output logic        rsp_error,

  // ---- observability -------------------------------------------------------
  output logic [63:0] reset_vector
);
  localparam int WORDS = 256;      // 2 KB

  logic [63:0] rom [0:WORDS-1];

  // the beat holding the reset vector is word 0
  assign reset_vector = rom[0];

  assign req_ready = 1'b1;

  wire [63:0] beat_addr = {req_addr[63:3], 3'b000};
  wire [7:0]  idx       = req_addr[10:3];      // 256 beats
  wire        in_range  = (req_addr[63:11] == 53'd0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsp_valid <= 1'b0;
      rsp_rdata <= 64'd0;
      rsp_error <= 1'b0;
    end else begin
      rsp_valid <= req_valid && req_ready;
      if (req_valid) begin
        rsp_rdata <= in_range ? rom[idx] : 64'd0;
        rsp_error <= !in_range;
      end
    end
  end

  // ---- image ---------------------------------------------------------------
  // Encoding of the four stub instructions above.
  localparam logic [63:0] W0 = {32'h00000113, 32'h00000117};  // addi x2,x2,0x7F0 / auipc x2,0
  localparam logic [63:0] W1 = {32'h000080E7, 32'h800000B7};  // jalr x0,0(x1) / lui x1,0x80000

  initial begin
    for (int i = 0; i < WORDS; i++) rom[i] = 64'd0;
    rom[0] = W0;
    rom[1] = W1;
  end

endmodule
`default_nettype wire
