`timescale 1ns/1ps
// =============================================================================
// pcie_flit_pack.sv -- packs a byte stream into fixed-size FLITs.
//
// TLPs are byte-continuous across flit boundaries: a TLP that does not fit in the
// remaining space continues in the next flit. That continuity is the property
// worth testing -- getting it wrong silently corrupts the TLP rather than
// producing an obvious error.
//
// The accumulator is a left-shifting byte register, so the FIRST byte consumed
// after a flit is emitted lands in the TOP of the next flit. The testbench checks
// exactly that ordering, because a right-shifting version passes a naive
// "count the bytes" test and reverses every flit.
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

  logic [FULL*8-1:0] acc_q;
  logic [15:0]       cnt_q;

  // Do NOT accept a byte in the cycle a flit is consumed: the always_ff gives
  // the consume branch priority, so that byte would be silently dropped.
  assign in_ready   = !flit_valid;
  assign flit_valid = (cnt_q == 16'(FULL));
  assign flit.tlp   = acc_q;
  assign flit.dlp   = '0;            // FEC/CRC insertion is out of scope

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_q <= '0;
      cnt_q <= 16'd0;
    end else if (flit_valid && flit_ready) begin
      acc_q <= '0;
      cnt_q <= 16'd0;
    end else if (in_valid && in_ready) begin
      // Left shift: the first byte consumed walks up to the TOP of the flit
      // over the 236 accepts, so flit[top] is the oldest byte.
      acc_q <= {acc_q[FULL*8-9:0], in_byte};
      cnt_q <= cnt_q + 16'd1;
    end
  end
endmodule

`default_nettype wire
