`timescale 1ns/1ps
// =============================================================================
// rv64_regfile.sv -- 32 x 64 architectural integer register file.
//   Two asynchronous read ports, one synchronous write port, one debug read
//   port for the halt/resume inspection path.  x0 is hardwired to zero by
//   suppressing the write (never by relying on reset contents alone).
// =============================================================================
`default_nettype none

module rv64_regfile (
  input  logic        clk,
  input  logic        rst_n,
  // architectural read ports
  input  logic [4:0]  rs1_addr,
  input  logic [4:0]  rs2_addr,
  output logic [63:0] rs1_data,
  output logic [63:0] rs2_data,
  // architectural write port
  input  logic        we,
  input  logic [4:0]  rd_addr,
  input  logic [63:0] rd_data,
  // debug read port (valid while halted; combinational)
  input  logic [4:0]  dbg_addr,
  output logic [63:0] dbg_data
);
  logic [63:0] regs [1:31];

  assign rs1_data = (rs1_addr == 5'd0) ? 64'd0 : regs[rs1_addr];
  assign rs2_data = (rs2_addr == 5'd0) ? 64'd0 : regs[rs2_addr];
  assign dbg_data = (dbg_addr == 5'd0) ? 64'd0 : regs[dbg_addr];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 1; i < 32; i++) regs[i] <= 64'd0;
    end else if (we && (rd_addr != 5'd0)) begin
      regs[rd_addr] <= rd_data;
    end
  end

endmodule
`default_nettype wire
