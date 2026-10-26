// =============================================================================
// rv64_num_csr.sv -- configuration and sticky-flag CSRs for the numeric ABI.
//
//   ncfg   (0x7C0)  rounding, saturation, adaptive precision, posit es, enables
//   nflags (0x7C1)  sticky status: writing a one to a bit clears it
//   nerr   (0x7C2)  read-only error bound of the last operation
//
// The sticky behaviour is what makes a numeric unit usable in a test flow: a
// single lost bit anywhere in a long computation is still visible at the end,
// without checking after every operation.
// =============================================================================
`default_nettype none

module rv64_num_csr (
  input  logic        clk,
  input  logic        rst_n,

  // CSR access port
  input  logic [11:0] csr_addr,
  input  logic [1:0]  csr_op,        // 1 = write, 2 = set bits, 3 = clear bits
  input  logic [63:0] csr_wdata,
  input  logic        csr_we,
  output logic [63:0] csr_rdata,
  output logic        csr_valid,

  // operation flags to accumulate (one-cycle pulse per numeric operation)
  input  logic [7:0]  op_flags,
  input  logic        op_valid,
  input  logic [63:0] op_err,

  output logic [63:0] ncfg_o
);
  import rv64_num_pkg::*;

  logic [63:0] ncfg_q;
  logic [7:0]  nflags_q;
  logic [63:0] nerr_q;

  // ---- read path -----------------------------------------------------------
  always_comb begin
    csr_rdata = 64'd0;
    csr_valid = 1'b1;
    case (csr_addr)
      CSR_NCFG:   csr_rdata = ncfg_q;
      CSR_NFLAGS: csr_rdata = {56'd0, nflags_q};
      CSR_NERR:   csr_rdata = nerr_q;
      default: begin
        csr_valid = 1'b0;
        csr_rdata = 64'd0;
      end
    endcase
  end

  // ---- write value ---------------------------------------------------------
  logic [63:0] wval;
  always_comb begin
    case (csr_op)
      2'd1:    wval = csr_wdata;
      2'd2:    wval = csr_rdata | csr_wdata;
      2'd3:    wval = csr_rdata & ~csr_wdata;
      default: wval = csr_rdata;
    endcase
  end

  logic do_write;
  assign do_write = csr_we && csr_valid &&
                    ((csr_op == 2'd1) ||
                     ((csr_op == 2'd2) && (csr_wdata != 64'd0)) ||
                     ((csr_op == 2'd3) && (csr_wdata != 64'd0)));

  // ---- sequential ----------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ncfg_q   <= CFG_RESET;
      nflags_q <= 8'd0;
      nerr_q   <= 64'd0;
    end else begin
      // sticky accumulation: set on operation, cleared only by software
      if (op_valid) nflags_q <= nflags_q | op_flags;
      if (op_valid) nerr_q   <= op_err;

      if (do_write) begin
        case (csr_addr)
          CSR_NCFG: begin
            // reserved bits read back as zero
            ncfg_q <= {42'd0, wval[CFG_RSV_SHIFT-1:0]};
          end
          CSR_NFLAGS: begin
            // write-one-to-clear
            nflags_q <= nflags_q & ~wval[7:0];
          end
          default: ;
        endcase
      end
    end
  end

  assign ncfg_o = ncfg_q;

endmodule
`default_nettype wire
