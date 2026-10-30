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
  input  logic        sret_valid,
  // current privilege, so the trap and CSR-permission logic can see it
  output logic [1:0]  priv_o,
  output logic        trap_to_s_o,     // this trap is delegated to S-mode
  output logic [63:0] stvec_o,
  output logic [63:0] satp_o,
  output logic [63:0] mtvec_o,
  output logic [63:0] mepc_o,

  // ---- interrupt inputs -----------------------------------------------------
  input  logic        irq_soft,
  input  logic        irq_timer,
  input  logic        irq_ext,
  // Custom accelerator CSR windows (RVV, QISA, AI, XRV512, Xcetask, numeric).
  // They live outside this module, so it cannot decode them itself -- but it must
  // not call them illegal, or every access traps before the accelerator sees it.
  input  logic        accel_csr_sel,
  input  logic [63:0] accel_csr_rdata,
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
  // Floating-point state. FS is required by the privileged spec so an OS can save
  // and restore FP state lazily; fcsr carries frm and fflags.
  logic [1:0]  mstatus_fs_q;
  logic [7:0]  fcsr_q;
  // ---- hypervisor state ----------------------------------------------------
  logic [63:0] hstatus_q, hedeleg_q, hideleg_q, hie_q, htvec_q;
  logic [63:0] hscratch_q, hepc_q, hcause_q, htval_q, hip_q, htinst_q, hgatp_q;
  logic [63:0] vsstatus_q, vsie_q, vstvec_q, vsscratch_q;
  logic [63:0] vsepc_q, vscause_q, vstval_q, vsip_q;
  logic [63:0] mtvec_q, mepc_q, mcause_q, mtval_q, mscratch_q;
  logic [2:0]  mie_q;                // MSIE, MTIE, MEIE
  logic [2:0]  mip_q;                // pending, read-only from the platform
  logic [63:0] mcounteren_q;
  logic [7:0]  pmpcfg_q [0:7];
  logic [63:0] pmpaddr_q [0:7];
  logic [63:0] mcycle_q, minstret_q;

  // ---- supervisor state ----------------------------------------------------
  logic [1:0]  priv_q;                 // 3 = M, 1 = S, 0 = U
  logic        sstatus_sie_q, sstatus_spie_q, sstatus_spp_q;
  logic        mstatus_sum_q, mstatus_mxr_q;
  logic [63:0] stvec_q, sepc_q, scause_q, stval_q, sscratch_q;
  logic [63:0] medeleg_q, mideleg_q;
  logic [63:0] satp_q;                 // MODE[63:60], ASID[59:44], PPN[43:0]
  logic [2:0]  sie_q;                  // SSIE, STIE, SEIE

  // A CSR's privilege level is encoded in address bits [9:8]: 11 = M, 01 = S,
  // 00 = U. Access is legal when the current privilege is at least that.
  wire [1:0] csr_priv_lvl = csr_addr[9:8];
  wire       csr_perm_ok  = (csr_priv_lvl <= priv_q);

  logic [2:0]  irq_in;

  assign irq_in = {irq_ext, irq_timer, irq_soft};

  // ---- read path ------------------------------------------------------------
  logic csr_impl;
  always_comb begin
    csr_rdata = 64'd0;
    csr_impl  = 1'b1;
    unique case (csr_addr)
      CSR_MSTATUS:    csr_rdata = {49'd0, mstatus_fs_q, mstatus_mpp_q, 3'd0, mstatus_mpie_q, 3'd0, mstatus_mie_q, 3'd0};
      // MXL=2 (RV64), then A(0), C(2), I(8), M(12), S(18), U(20). V is deliberately NOT
      // set: the vector unit takes RVV semantics but not RVV encoding, so a program
      // reading misa must not be told rv64gcv binaries will run.
      CSR_MISA:       csr_rdata = {2'b10, 36'd0, 26'h1411A5};   // + C(2) F(5) H(7)
      CSR_HSTATUS:    csr_rdata = hstatus_q;
      CSR_HEDELEG:    csr_rdata = hedeleg_q;
      CSR_HIDELEG:    csr_rdata = hideleg_q;
      CSR_HIE:        csr_rdata = hie_q;
      CSR_HTVEC:      csr_rdata = htvec_q;
      CSR_HSCRATCH:   csr_rdata = hscratch_q;
      CSR_HEPC:       csr_rdata = hepc_q;
      CSR_HCAUSE:     csr_rdata = hcause_q;
      CSR_HTVAL:      csr_rdata = htval_q;
      CSR_HIP:        csr_rdata = hip_q;
      CSR_HTINST:     csr_rdata = htinst_q;
      CSR_HGATP:      csr_rdata = hgatp_q;
      CSR_VSSTATUS:   csr_rdata = vsstatus_q;
      CSR_VSIE:       csr_rdata = vsie_q;
      CSR_VSTVEC:     csr_rdata = vstvec_q;
      CSR_VSSCRATCH:  csr_rdata = vsscratch_q;
      CSR_VSEPC:      csr_rdata = vsepc_q;
      CSR_VSCAUSE:    csr_rdata = vscause_q;
      CSR_VSTVAL:     csr_rdata = vstval_q;
      CSR_VSIP:       csr_rdata = vsip_q;
      CSR_FFLAGS:     csr_rdata = {59'd0, fcsr_q[4:0]};
      CSR_FRM:        csr_rdata = {61'd0, fcsr_q[7:5]};
      CSR_FCSR:       csr_rdata = {56'd0, fcsr_q};
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
      // ---- supervisor ----
      CSR_SSTATUS:    csr_rdata = {50'd0, mstatus_sum_q, mstatus_mxr_q, 8'd0,
                                   sstatus_spp_q, 3'd0, sstatus_spie_q, 3'd0,
                                   sstatus_sie_q, 3'd0};
      CSR_SIE:        csr_rdata = {52'd0, sie_q[2], 3'd0, sie_q[1], 3'd0, sie_q[0], 3'd0};
      CSR_STVEC:      csr_rdata = stvec_q;
      CSR_SSCRATCH:   csr_rdata = sscratch_q;
      CSR_SEPC:       csr_rdata = sepc_q;
      CSR_SCAUSE:     csr_rdata = scause_q;
      CSR_STVAL:      csr_rdata = stval_q;
      CSR_SIP:        csr_rdata = {52'd0, mip_q[2], 3'd0, mip_q[1], 3'd0, mip_q[0], 3'd0};
      CSR_SATP:       csr_rdata = satp_q;
      CSR_MEDELEG:    csr_rdata = medeleg_q;
      CSR_MIDELEG:    csr_rdata = mideleg_q;
      default: begin
        if (csr_addr >= CSR_PMPADDR0 && csr_addr <= (CSR_PMPADDR0 + 12'd7)) begin
          csr_rdata = pmpaddr_q[csr_addr[2:0]];
        end else begin
          csr_impl  = 1'b0;
          csr_rdata = 64'd0;
        end
      end
    endcase
    // An implemented CSR is still illegal at too low a privilege: reading an
    // M-mode CSR from S or U must trap, and the core uses csr_valid for exactly
    // that. This assignment is the only driver of csr_valid -- without it the
    // output floats at 0 and every CSR access becomes an illegal-CSR trap.
    // accelerator windows are implemented, by definition of accel_csr_sel
    if (accel_csr_sel) begin
      csr_impl  = 1'b1;
      csr_rdata = accel_csr_rdata;
    end
    csr_valid = csr_impl && csr_perm_ok;
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

  // ---- trap delegation ------------------------------------------------------
  // Exception causes are delegated by medeleg, interrupts by mideleg, indexed by
  // the low four cause bits. A trap is never delegated away from M-mode.
  logic        trap_delegated;
  logic [3:0]  cause_idx;
  assign cause_idx      = trap_cause[3:0];
  assign trap_delegated = trap_cause[63] ? mideleg_q[cause_idx] : medeleg_q[cause_idx];
  assign trap_to_s_o    = trap_valid && trap_delegated && (priv_q != 2'b11);
  assign priv_o         = priv_q;
  assign stvec_o        = stvec_q;
  assign satp_o         = satp_q;

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
      mstatus_fs_q   <= 2'b01;   // FS = Initial
      fcsr_q         <= 8'd0;
      hstatus_q <= '0; hedeleg_q <= '0; hideleg_q <= '0; hie_q <= '0;
      htvec_q <= '0; hscratch_q <= '0; hepc_q <= '0; hcause_q <= '0;
      htval_q <= '0; hip_q <= '0; htinst_q <= '0; hgatp_q <= '0;
      vsstatus_q <= '0; vsie_q <= '0; vstvec_q <= '0; vsscratch_q <= '0;
      vsepc_q <= '0; vscause_q <= '0; vstval_q <= '0; vsip_q <= '0;
      priv_q         <= 2'b11;      // reset into M-mode
      sstatus_sie_q  <= 1'b0;
      sstatus_spie_q <= 1'b0;
      sstatus_spp_q  <= 1'b0;
      mstatus_sum_q  <= 1'b0;
      mstatus_mxr_q  <= 1'b0;
      stvec_q        <= 64'd0;
      sepc_q         <= 64'd0;
      scause_q       <= 64'd0;
      stval_q        <= 64'd0;
      sscratch_q     <= 64'd0;
      medeleg_q      <= 64'd0;
      mideleg_q      <= 64'd0;
      sie_q          <= 3'd0;
      satp_q         <= 64'd0;
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
      // A trap delegated to S-mode writes S state and leaves M state alone;
      // anything else enters M and records where it came from in MPP.
      if (trap_valid && trap_to_s_o) begin
        sepc_q         <= trap_pc;
        scause_q       <= trap_cause;
        stval_q        <= trap_tval;
        sstatus_spie_q <= sstatus_sie_q;
        sstatus_sie_q  <= 1'b0;
        sstatus_spp_q  <= (priv_q == 2'b01);
        priv_q         <= 2'b01;
      end else if (trap_valid) begin
        mstatus_mpie_q <= mstatus_mie_q;
        mstatus_mie_q  <= 1'b0;
        mstatus_mpp_q  <= priv_q;
        mstatus_fs_q   <= csr_wdata[14:13];
        mepc_q         <= trap_pc;
        mcause_q       <= trap_cause;
        mtval_q        <= trap_tval;
        priv_q         <= 2'b11;
      end else if (mret_valid) begin
        mstatus_mie_q  <= mstatus_mpie_q;
        mstatus_mpie_q <= 1'b1;
        priv_q         <= mstatus_mpp_q;
        mstatus_mpp_q  <= 2'b00;
      end else if (sret_valid) begin
        sstatus_sie_q  <= sstatus_spie_q;
        sstatus_spie_q <= 1'b1;
        priv_q         <= sstatus_spp_q ? 2'b01 : 2'b00;
        sstatus_spp_q  <= 1'b0;
      end else if (csr_do_write) begin
        unique case (csr_addr)
          CSR_MSTATUS: begin
            mstatus_mie_q  <= csr_wval[3];
            mstatus_mpie_q <= csr_wval[7];
            mstatus_mpp_q  <= csr_wval[12:11];
            mstatus_sum_q  <= csr_wval[18];
            mstatus_mxr_q  <= csr_wval[19];
          end
          CSR_MIE:        mie_q        <= {csr_wval[11], csr_wval[7], csr_wval[3]};
          CSR_MEDELEG:    medeleg_q    <= csr_wval & 64'hFFFF_FFFF_FFFF_B3FF;
          CSR_MIDELEG:    mideleg_q    <= csr_wval & 64'h0000_0000_0000_0AAA;
          CSR_SSTATUS: begin
            sstatus_sie_q  <= csr_wval[1];
            sstatus_spie_q <= csr_wval[5];
            sstatus_spp_q  <= csr_wval[8];
            mstatus_sum_q  <= csr_wval[18];
            mstatus_mxr_q  <= csr_wval[19];
          end
          CSR_SIE:        sie_q        <= {csr_wval[9], csr_wval[5], csr_wval[1]};
          CSR_STVEC:      stvec_q      <= {csr_wval[63:2], 2'b00};
          CSR_SSCRATCH:   sscratch_q   <= csr_wval;
          CSR_SEPC:       sepc_q       <= {csr_wval[63:2], 2'b00};
          CSR_SCAUSE:     scause_q     <= csr_wval;
          CSR_STVAL:      stval_q      <= csr_wval;
          // only MODE=0 (bare) and MODE=8 (Sv39) are accepted; anything else
          // keeps the old value rather than putting the core in a mode it does
          // not implement
          CSR_SATP: begin
            if ((csr_wval[63:60] == 4'd0) || (csr_wval[63:60] == 4'd8))
              satp_q <= csr_wval;
          end
          CSR_MTVEC:      mtvec_q      <= {csr_wval[63:2], 2'b00};   // direct mode only
          CSR_MCOUNTEREN: mcounteren_q <= csr_wval;
          CSR_MSCRATCH:   mscratch_q   <= csr_wval;
          CSR_HSTATUS:    hstatus_q    <= csr_wval;
          CSR_HEDELEG:    hedeleg_q    <= csr_wval;
          CSR_HIDELEG:    hideleg_q    <= csr_wval;
          CSR_HIE:        hie_q        <= csr_wval;
          CSR_HTVEC:      htvec_q      <= csr_wval;
          CSR_HSCRATCH:   hscratch_q   <= csr_wval;
          CSR_HEPC:       hepc_q       <= csr_wval;
          CSR_HCAUSE:     hcause_q     <= csr_wval;
          CSR_HTVAL:      htval_q      <= csr_wval;
          CSR_HIP:        hip_q        <= csr_wval;
          CSR_HTINST:     htinst_q     <= csr_wval;
          CSR_HGATP:      hgatp_q      <= csr_wval;
          CSR_VSSTATUS:   vsstatus_q   <= csr_wval;
          CSR_VSIE:       vsie_q       <= csr_wval;
          CSR_VSTVEC:     vstvec_q     <= csr_wval;
          CSR_VSSCRATCH:  vsscratch_q  <= csr_wval;
          CSR_VSEPC:      vsepc_q      <= csr_wval;
          CSR_VSCAUSE:    vscause_q    <= csr_wval;
          CSR_VSTVAL:     vstval_q     <= csr_wval;
          CSR_VSIP:       vsip_q       <= csr_wval;
          CSR_FFLAGS:     fcsr_q[4:0]  <= csr_wval[4:0];
          CSR_FRM:        fcsr_q[7:5]  <= csr_wval[2:0];
          CSR_FCSR:       fcsr_q       <= csr_wval[7:0];
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
