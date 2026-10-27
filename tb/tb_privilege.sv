`timescale 1ns/1ps
// Directed testbench for S/U privilege modes in rv64_csr.
//
// The core regression only exercises M-mode, so it cannot show that the new
// privilege state, delegation, mret/sret and CSR permission checks work. This
// drives the CSR block directly through the transitions a real S-mode OS would.
module tb_privilege;
  import rv64_pkg::*;

  logic        clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [11:0] csr_addr;
  logic [1:0]  csr_op;
  logic [63:0] csr_wdata, csr_rdata;
  logic        csr_we, csr_valid;

  logic        trap_valid, mret_valid, sret_valid;
  logic [63:0] trap_cause, trap_pc, trap_tval;
  logic [1:0]  priv_o;
  logic        trap_to_s_o;
  logic [63:0] stvec_o, mtvec_o, mepc_o;
  logic        irq_soft, irq_timer, irq_ext, mstatus_mie, irq_pending;
  logic        retire_valid;
  logic [63:0] mcycle_o, minstret_o, mcause_o;
  logic [8*8-1:0]  pmp_cfg;
  logic [8*64-1:0] pmp_addr;

  rv64_csr u_csr (
    .clk(clk), .rst_n(rst_n),
    .csr_addr(csr_addr), .csr_op(csr_op), .csr_wdata(csr_wdata),
    .csr_we(csr_we), .csr_rdata(csr_rdata), .csr_valid(csr_valid),
    .trap_valid(trap_valid), .trap_cause(trap_cause), .trap_pc(trap_pc),
    .trap_tval(trap_tval), .mret_valid(mret_valid), .sret_valid(sret_valid),
    .priv_o(priv_o), .trap_to_s_o(trap_to_s_o), .stvec_o(stvec_o),
    .mtvec_o(mtvec_o), .mepc_o(mepc_o),
    .irq_soft(irq_soft), .irq_timer(irq_timer), .irq_ext(irq_ext),
    .mstatus_mie(mstatus_mie), .irq_pending(irq_pending),
    .retire_valid(retire_valid), .mcycle_o(mcycle_o), .minstret_o(minstret_o),
    .pmp_cfg(pmp_cfg), .pmp_addr(pmp_addr), .mcause_o(mcause_o)
  );

  int checks = 0, errors = 0;

  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-34s got=%h expected=%h", name, got, exp); end
    end
  endtask

  task automatic csr_write(input logic [11:0] a, input logic [63:0] v);
    begin
      csr_addr = a; csr_op = CSR_RW; csr_wdata = v; csr_we = 1;
      @(posedge clk); #1; csr_we = 0; #1;
    end
  endtask

  task automatic csr_read(input logic [11:0] a, output logic [63:0] v, output logic ok);
    begin csr_addr = a; csr_op = CSR_RW; csr_we = 0; #1; v = csr_rdata; ok = csr_valid; end
  endtask

  // trap_to_s_o is combinational on trap_valid, so it has to be sampled WHILE the
  // trap is asserted -- reading it afterwards always sees 0.
  logic trap_to_s_seen;

  task automatic do_trap(input logic [63:0] cause, input logic [63:0] pc);
    begin
      trap_valid = 1; trap_cause = cause; trap_pc = pc; trap_tval = 64'd0;
      #1; trap_to_s_seen = trap_to_s_o;
      @(posedge clk); #1; trap_valid = 0; #1;
    end
  endtask

  task automatic do_mret;
    begin mret_valid = 1; @(posedge clk); #1; mret_valid = 0; #1; end
  endtask

  task automatic do_sret;
    begin sret_valid = 1; @(posedge clk); #1; sret_valid = 0; #1; end
  endtask

  logic [63:0] v;
  logic ok;

  initial begin
    csr_addr = 0; csr_op = CSR_RW; csr_wdata = 0; csr_we = 0;
    trap_valid = 0; trap_cause = 0; trap_pc = 0; trap_tval = 0;
    mret_valid = 0; sret_valid = 0;
    irq_soft = 0; irq_timer = 0; irq_ext = 0; retire_valid = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---- 1. reset lands in M-mode ----------------------------------------
    chk("reset privilege is M", priv_o, 2'd3);

    // ---- 2. M-mode CSRs are readable at M --------------------------------
    csr_read(CSR_MSTATUS, v, ok);
    chk("mstatus readable at M", ok, 1'b1);
    csr_read(CSR_SEPC, v, ok);
    chk("sepc readable at M", ok, 1'b1);

    // ---- 3. configure delegation while still in M ------------------------
    // medeleg is an M-mode CSR, so it must be written here: a write from S is
    // correctly rejected by the privilege check.
    csr_write(CSR_MEDELEG, 64'h0000_0000_0000_0004);   // bit 2 = illegal insn
    csr_write(CSR_STVEC, 64'h0000_0000_0000_1234);
    chk("stvec latched", stvec_o, 64'h0000_0000_0000_1234);

    // ---- 3b. enter S-mode: MPP = S, then mret ----------------------------
    csr_write(CSR_MSTATUS, 64'h0000_0000_0000_0800);   // MPP = 01 (S)
    do_mret();
    chk("mret to S-mode", priv_o, 2'd1);

    // ---- 4. an M-mode CSR is illegal at S --------------------------------
    csr_read(CSR_MSTATUS, v, ok);
    chk("mstatus illegal at S", ok, 1'b0);
    csr_read(CSR_SEPC, v, ok);
    chk("sepc legal at S", ok, 1'b1);

    // ---- 5. a delegated trap from S must go to S, not M ------------------
    do_trap(64'd2, 64'h8000_0000);
    chk("delegated trap goes to S", trap_to_s_seen, 1'b1);
    chk("still in S after delegated trap", priv_o, 2'd1);
    csr_read(CSR_SEPC, v, ok);
    chk("sepc holds the trap pc", v, 64'h8000_0000);
    csr_read(CSR_SCAUSE, v, ok);
    chk("scause holds the cause", v, 64'd2);

    // ---- 6. sret returns using SPP ---------------------------------------
    csr_write(CSR_SSTATUS, 64'h0000_0000_0000_0100);   // SPP = 1 -> return to S
    do_sret();
    chk("sret stays in S when SPP=1", priv_o, 2'd1);
    csr_write(CSR_SSTATUS, 64'h0);
    do_sret();
    chk("sret to U when SPP=0", priv_o, 2'd0);

    // ---- 7. an undelegated trap from U goes to M and records MPP ---------
    do_trap(64'd11, 64'h8000_0004);                    // ecall from M: not delegated
    chk("undelegated trap does not go to S", trap_to_s_seen, 1'b0);
    chk("undelegated trap goes to M", priv_o, 2'd3);
    csr_read(CSR_MSTATUS, v, ok);
    chk("mstatus MPP recorded U", (v >> 11) & 3, 2'd0);

    // ---- 8. an interrupt is delegated by mideleg -------------------------
    csr_write(CSR_MIDELEG, 64'h0000_0000_0000_0080);   // bit 7 = machine timer
    csr_write(CSR_MSTATUS, 64'h0000_0000_0000_0800);   // MPP = S
    do_mret();
    chk("back in S", priv_o, 2'd1);
    do_trap({1'b1, 59'd0, 4'd7}, 64'h8000_0008);       // timer interrupt, delegated
    chk("delegated interrupt goes to S", priv_o, 2'd1);

    $display("tb_privilege: %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
