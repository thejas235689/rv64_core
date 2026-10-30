`timescale 1ns/1ps
// =============================================================================
// flit_pack.sv -- packs a byte stream into fixed-size FLITs.
//
// TLPs are byte-continuous across flit boundaries. Byte N of the stream belongs at
// byte position N of its flit, counting from the TOP, so the oldest byte is the
// most significant.
//
// The accumulator is an INDEXED byte array rather than one wide shift register.
// The shift version did not accumulate correctly -- byte 0 landed but the rest
// read back as zero -- and a wide part-select on a 1888-bit vector is exactly the
// kind of construct that differs between simulators. Indexing a byte array is
// unambiguous.
// =============================================================================
`default_nettype none

module pcie_flit_pack
  import pcie_flit_pkg::*;
(
  input  logic       clk,
  input  logic       rst_n,

  input  logic       in_valid,
  output logic       in_ready,
  input  logic [7:0] in_byte,
  input  logic       in_last,

  output logic       flit_valid,
  input  logic       flit_ready,
  output pcie_flit_t flit
);
  localparam int FULL = FLIT_TLP_BYTES;

  logic [7:0]  acc_q [FULL];
  logic [15:0] cnt_q;

  // Do not accept a byte in the cycle a flit is consumed: the always_ff gives the
  // consume branch priority, so that byte would be silently dropped.
  assign in_ready   = !flit_valid;
  assign flit_valid = (cnt_q == 16'(FULL));

  // oldest byte (index 0) goes to the top of the flit
  for (genvar i = 0; i < FULL; i++) begin : g_pack
    assign flit.tlp[(FULL-1-i)*8 +: 8] = acc_q[i];
  end
  assign flit.dlp = '0;               // FEC/CRC insertion is out of scope

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt_q <= 16'd0;
      for (int i = 0; i < FULL; i++) acc_q[i] <= 8'd0;
    end else if (flit_valid && flit_ready) begin
      cnt_q <= 16'd0;
      for (int i = 0; i < FULL; i++) acc_q[i] <= 8'd0;
    end else if (in_valid && in_ready && (cnt_q < 16'(FULL))) begin
      acc_q[cnt_q] <= in_byte;      // full-width index; a truncated slice kept hitting 0
      cnt_q <= cnt_q + 16'd1;
    end
  end
endmodule

`default_nettype wire
