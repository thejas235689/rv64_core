// =============================================================================
// rv64_numfile.sv -- 32 x 64-bit numeric register bank for the custom numeric
// ABI. Separate from the integer register file: every entry is writable (there
// is no architectural zero register on this side) and it has its own debug port.
// =============================================================================
`default_nettype none

module rv64_numfile (
  input  logic        clk,
  input  logic        rst_n,

  // two asynchronous read ports
  input  logic [4:0]  rs1_addr,
  input  logic [4:0]  rs2_addr,
  output logic [63:0] rs1_data,
  output logic [63:0] rs2_data,

  // one synchronous write port
  input  logic        we,
  input  logic [4:0]  rd_addr,
  input  logic [63:0] rd_data,

  // debug read port
  input  logic [4:0]  dbg_addr,
  output logic [63:0] dbg_data
);
  logic [63:0] nregs [0:31];

  assign rs1_data = nregs[rs1_addr];
  assign rs2_data = nregs[rs2_addr];
  assign dbg_data = nregs[dbg_addr];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 32; i++) nregs[i] <= 64'd0;
    end else if (we) begin
      nregs[rd_addr] <= rd_data;
    end
  end

endmodule
`default_nettype wire
