`timescale 1ns/1ps
// =============================================================================
// rv64_csr.sv -- machine-mode CSR file.
//   Implements mstatus, misa, mie, mtvec, mcounteren, mscratch, mepc, mcause,
//   mtval, mip, pmpcfg0, pmpaddr0-7, mcycle(h), minstret(h) and the read-only
//   ID registers.  Unimplemented addresses raise illegal-instruction.
//   Trap entry and MRET are single-cycle, driven from the MEM stage.
// =============================================================================
`default_nettype none

module rv64_csr (
  input  logic        clk,
  input  logic        rst_n,

  // ---- CSR instruction port (EX stage) --------------------------------------
  input  logic [11:0] csr_addr,
  input  logic [1:0]  csr_op,
  input  logic [63:0] csr_wdata,
  input  logic        csr_we,        // qualified write strobe from the core
  output logic [63:0] csr_rdata,
  output logic        csr_valid,     // address is implemented

  // ---- trap / return --------------------------------------------------------
  input  logic        trap_valid,
  input  logic [63:0] trap_cause,
  input  logic [63:0] trap_pc,
  input  logic [63:0] trap_tval,
  input  logic        mret_valid,
  output logic [63:0] mtvec_o,
  output logic [63:0] mepc_o,

  // ---- interrupt inputs -----------------------------------------------------
  input  logic        irq_soft,
  input  logic        irq_timer,
  input  logic        irq_ext,
  output logic        mstatus_mie,
  output logic        irq_pending,   // enabled and pending, MIE masked out

  // ---- retirement / timing --------------------------------------------------
  input  logic        retire_valid,
  output logic [63:0] mcycle_o,
  output logic [63:0] minstret_o,

  // ---- PMP configuration out ------------------------------------------------
  output logic [8*8-1:0]  pmp_cfg,
  output logic [8*64-1:0] pmp_addr,

  // ---- observability --------------------------------------------------------
  output logic [63:0] mcause_o
);
  import rv64_pkg::*;

  // ---- architectural state --------------------------------------------------
  logic        mstatus_mie_q, mstatus_mpie_q;
  logic [1:0]  mstatus_mpp_q;
  logic [63:0] mtvec_q, mepc_q, mcause_q, mtval_q, mscratch_q;
  logic [2:0]  mie_q;                // MSIE, MTIE, MEIE
  logic [2:0]  mip_q;                // pending, read-only from the platform
  logic [63:0] mcounteren_q;
  logic [7:0]  pmpcfg_q [0:7];
  logic [63:0] pmpaddr_q [0:7];
  logic [63:0] mcycle_q, minstret_q;

  logic [2:0]  irq_in;

  assign irq_in = {irq_ext, irq_timer, irq_soft};

  // ---- read path ------------------------------------------------------------
  always_comb begin
    csr_rdata = 64'd0;
    csr_valid = 1'b1;
    unique case (csr_addr)
      CSR_MSTATUS:    csr_rdata = {51'd0, mstatus_mpp_q, 3'd0, mstatus_mpie_q, 3'd0, mstatus_mie_q, 3'd0};
      CSR_MISA:       csr_rdata = {2'b10, 49'd0, 1'b1, 3'd0, 1'b1, 8'd0};  // RV64IM
      CSR_MIE:        csr_rdata = {52'd0, mie_q[2], 3'd0, mie_q[1], 3'd0, mie_q[0], 3'd0};
      CSR_MTVEC:      csr_rdata = mtvec_q;
      CSR_MCOUNTEREN: csr_rdata = mcounteren_q;
      CSR_MSCRATCH:   csr_rdata = mscratch_q;
      CSR_MEPC:       csr_rdata = mepc_q;
      CSR_MCAUSE:     csr_rdata = mcause_q;
      CSR_MTVAL:      csr_rdata = mtval_q;
      CSR_MIP:        csr_rdata = {52'd0, mip_q[2], 3'd0, mip_q[1], 3'd0, mip_q[0], 3'd0};
      CSR_PMPCFG0:    csr_rdata = {pmpcfg_q[7], pmpcfg_q[6], pmpcfg_q[5], pmpcfg_q[4],
                                   pmpcfg_q[3], pmpcfg_q[2], pmpcfg_q[1], pmpcfg_q[0]};
      CSR_MCYCLE:     csr_rdata = mcycle_q;
      CSR_MINSTRET:   csr_rdata = minstret_q;
      CSR_MCYCLEH:    csr_rdata = {32'd0, mcycle_q[63:32]};
      CSR_MINSTRETH:  csr_rdata = {32'd0, minstret_q[63:32]};
      CSR_MVENDORID:  csr_rdata = 64'd0;
      CSR_MARCHID:    csr_rdata = 64'h5256_3634;   // "RV64"
      CSR_MIMPID:     csr_rdata = 64'h0000_0001;
      CSR_MHARTID:    csr_rdata = 64'd0;
      default: begin
        if (csr_addr >= CSR_PMPADDR0 && csr_addr <= (CSR_PMPADDR0 + 12'd7)) begin
          csr_rdata = pmpaddr_q[csr_addr[2:0]];
        end else begin
          csr_valid = 1'b0;
          csr_rdata = 64'd0;
        end
      end
    endcase
  end

  // ---- write value ----------------------------------------------------------
  logic [63:0] csr_wval;

  always_comb begin
    unique case (csr_op)
      CSR_RW:  csr_wval = csr_wdata;
      CSR_RS:  csr_wval = csr_rdata | csr_wdata;
      CSR_RC:  csr_wval = csr_rdata & ~csr_wdata;
      default: csr_wval = csr_rdata;
    endcase
  end

  logic csr_do_write;
  assign csr_do_write = csr_we && csr_valid &&
                        ((csr_op == CSR_RW) ||
                         ((csr_op == CSR_RS) && (csr_wdata != 64'd0)) ||
                         ((csr_op == CSR_RC) && (csr_wdata != 64'd0)));

  // ---- interrupt aggregation ------------------------------------------------
  logic [2:0] irq_enabled;
  assign irq_enabled = mie_q & mip_q;
  assign irq_pending = |irq_enabled;
  assign mstatus_mie = mstatus_mie_q;

  // ---- sequential -----------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mstatus_mie_q  <= 1'b0;
      mstatus_mpie_q <= 1'b0;
      mstatus_mpp_q  <= 2'b11;
      mtvec_q        <= 64'd0;
      mepc_q         <= 64'd0;
      mcause_q       <= 64'd0;
      mtval_q        <= 64'd0;
      mscratch_q     <= 64'd0;
      mie_q          <= 3'd0;
      mip_q          <= 3'd0;
      mcounteren_q   <= 64'd0;
      mcycle_q       <= 64'd0;
      minstret_q     <= 64'd0;
      for (int i = 0; i < 8; i++) begin
        pmpcfg_q[i]  <= 8'd0;
        pmpaddr_q[i] <= 64'd0;
      end
    end else begin
      // counters
      mcycle_q <= mcycle_q + 64'd1;
      if (retire_valid) minstret_q <= minstret_q + 64'd1;

      // pending bits follow the platform (read-only)
      mip_q <= irq_in;

      // ---- trap entry has priority over any CSR instruction in EX ----------
      if (trap_valid) begin
        mstatus_mpie_q <= mstatus_mie_q;
        mstatus_mie_q  <= 1'b0;
        mstatus_mpp_q  <= 2'b11;         // only M-mode is implemented
        mepc_q         <= trap_pc;
        mcause_q       <= trap_cause;
        mtval_q        <= trap_tval;
      end else if (mret_valid) begin
        mstatus_mie_q  <= mstatus_mpie_q;
        mstatus_mpie_q <= 1'b1;
        mstatus_mpp_q  <= 2'b11;
      end else if (csr_do_write) begin
        unique case (csr_addr)
          CSR_MSTATUS: begin
            mstatus_mie_q  <= csr_wval[3];
            mstatus_mpie_q <= csr_wval[7];
            mstatus_mpp_q  <= csr_wval[12:11];
          end
          CSR_MIE:        mie_q        <= {csr_wval[11], csr_wval[7], csr_wval[3]};
          CSR_MTVEC:      mtvec_q      <= {csr_wval[63:2], 2'b00};   // direct mode only
          CSR_MCOUNTEREN: mcounteren_q <= csr_wval;
          CSR_MSCRATCH:   mscratch_q   <= csr_wval;
          CSR_MEPC:       mepc_q       <= {csr_wval[63:2], 2'b00};   // IALIGN = 32
          CSR_MCAUSE:     mcause_q     <= csr_wval;
          CSR_MTVAL:      mtval_q      <= csr_wval;
          CSR_MCYCLE:     mcycle_q     <= csr_wval;
          CSR_MINSTRET:   minstret_q   <= csr_wval;
          CSR_MCYCLEH:    mcycle_q     <= {csr_wval[31:0], mcycle_q[31:0]};
          CSR_MINSTRETH:  minstret_q   <= {csr_wval[31:0], minstret_q[31:0]};
          CSR_PMPCFG0: begin
            // a locked entry ignores further configuration writes until reset
            for (int i = 0; i < 8; i++) begin
              if (!pmpcfg_q[i][7]) pmpcfg_q[i] <= csr_wval[8*i +: 8];
            end
          end
          default: begin
            if (csr_addr >= CSR_PMPADDR0 && csr_addr <= (CSR_PMPADDR0 + 12'd7)) begin
              // pmpaddr_i is also frozen when entry i is locked, or when the
              // next entry is locked and uses TOR (it supplies that top address)
              if (!pmpcfg_q[csr_addr[2:0]][7] &&
                  !((csr_addr[2:0] != 3'd7) && pmpcfg_q[csr_addr[2:0] + 3'd1][7] &&
                    (pmpcfg_q[csr_addr[2:0] + 3'd1][4:3] == 2'b10)))
                pmpaddr_q[csr_addr[2:0]] <= {10'd0, csr_wval[53:0]};
            end
          end
        endcase
      end
    end
  end

  // ---- outputs --------------------------------------------------------------
  always_comb begin
    for (int i = 0; i < 8; i++) begin
      pmp_cfg[8*i +: 8]  = pmpcfg_q[i];
      pmp_addr[64*i +: 64] = pmpaddr_q[i];
    end
  end

  assign mtvec_o     = mtvec_q;
  assign mepc_o      = mepc_q;
  assign mcause_o    = mcause_q;
  assign mcycle_o    = mcycle_q;
  assign minstret_o  = minstret_q;

endmodule
`default_nettype wire
