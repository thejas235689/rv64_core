`timescale 1ns/1ps
module tb_trap_dbg;
  logic clk=0, rst_n=0;
  always #5 clk = ~clk;

  logic [63:0] mem [0:1023];
  logic        if_req_valid, if_req_ready, if_rsp_valid, if_rsp_error;
  logic [63:0] if_req_addr, if_rsp_data;
  logic        d_req_valid, d_req_we, d_req_ready, d_rsp_valid, d_rsp_error;
  logic [63:0] d_req_addr, d_req_wdata, d_rsp_rdata;
  logic [7:0]  d_req_wstrb;

  logic retire_valid, gpr_we, trap_valid, irq_taken, dbg_halted, wp_hit, debug_event;
  logic [63:0] retire_pc, gpr_wdata, trap_cause, trap_pc, mcycle, minstret, dbg_reg_data;
  logic [31:0] retire_insn;
  logic [4:0]  gpr_waddr, dbg_reg_addr;
  logic [1:0]  priv;

  riscv_core_top u_core (
    .clk(clk), .rst_n(rst_n),
    .if_req_valid(if_req_valid), .if_req_addr(if_req_addr), .if_req_ready(if_req_ready),
    .if_rsp_valid(if_rsp_valid), .if_rsp_data(if_rsp_data), .if_rsp_error(if_rsp_error),
    .d_req_valid(d_req_valid), .d_req_addr(d_req_addr), .d_req_we(d_req_we),
    .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb), .d_req_ready(d_req_ready),
    .d_rsp_valid(d_rsp_valid), .d_rsp_rdata(d_rsp_rdata), .d_rsp_error(d_rsp_error),
    .irq_soft(1'b0), .irq_timer(1'b0), .irq_ext(1'b0),
    .dbg_halt_req(1'b0), .dbg_resume_req(1'b0), .dbg_step(1'b0), .dbg_halted(dbg_halted),
    .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(dbg_reg_data),
    .wp_en(1'b0), .wp_addr(64'd0), .wp_hit(wp_hit),
    .retire_valid(retire_valid), .retire_pc(retire_pc), .retire_insn(retire_insn),
    .gpr_we(gpr_we), .gpr_waddr(gpr_waddr), .gpr_wdata(gpr_wdata),
    .trap_valid_o(trap_valid), .trap_cause_o(trap_cause), .trap_pc_o(trap_pc),
    .irq_taken_o(irq_taken), .priv_o(priv), .debug_event_o(debug_event),
    .mcycle_o(mcycle), .minstret_o(minstret));

  // one-cycle memory
  logic i_pend, d_pend; logic [63:0] i_addr_q, d_addr_q; logic d_we_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      if_rsp_valid<=0; if_rsp_data<=0; if_rsp_error<=0; i_pend<=0;
      d_rsp_valid<=0; d_rsp_rdata<=0; d_rsp_error<=0; d_pend<=0; d_we_q<=0;
    end else begin
      if_rsp_valid <= i_pend;
      if (i_pend) if_rsp_data <= mem[i_addr_q[15:3]];
      i_pend <= if_req_valid && if_req_ready;
      if (if_req_valid && if_req_ready) i_addr_q <= if_req_addr;

      d_rsp_valid <= d_pend && !d_we_q;
      if (d_pend && !d_we_q) d_rsp_rdata <= mem[d_addr_q[15:3]];
      d_pend <= d_req_valid && d_req_ready;
      d_we_q <= d_req_we;
      if (d_req_valid && d_req_ready) d_addr_q <= d_req_addr;
      if (d_req_valid && d_req_ready && d_req_we)
        for (int b=0;b<8;b++) if (d_req_wstrb[b]) mem[d_req_addr[15:3]][8*b+:8] <= d_req_wdata[8*b+:8];
    end
  end
  assign if_req_ready = 1'b1;
  assign d_req_ready  = 1'b1;

  int nret=0, ntr=0, dbgwin=0;
  always @(posedge clk) begin
    #1;
    if (retire_valid) begin nret++; $display("RET %0d pc=%03h insn=%08h", nret-1, retire_pc, retire_insn); end
    if (trap_valid)   begin ntr++;  $display("TRAP %0d pc=%03h cause=%0d", ntr-1, trap_pc, trap_cause); end
    if (u_core.ex_mem_is_mret || u_core.id_ex_ctrl.is_mret || dbgwin > 0) begin
      if (dbgwin > 0) dbgwin--;
    end
    if (u_core.ex_mem_is_mret || u_core.id_ex_ctrl.is_mret)
      $display("   mretdbg pc_f=%03h mret_commit=%0b csr_mepc=%03h flush=%0b f_redir=%0b f_rpc=%03h",
               u_core.pc_f, u_core.mret_commit, u_core.csr_mepc, u_core.flush_front,
               u_core.f_redirect, u_core.f_redirect_pc);
    if (u_core.ex_mem_is_mret) begin
      dbgwin = 8;
      $display("   >>> mret commits, watching pipeline");
    end
    if (dbgwin > 0)
      $display("      pc_f=%03h if_id=%0b/%08h id_ex=%0b/%08h ex_mem=%0b/%08h mem_wb=%0b/%08h",
               u_core.pc_f, u_core.if_id_v, u_core.if_id_insn,
               u_core.id_ex_v, u_core.id_ex_insn,
               u_core.ex_mem_v, u_core.ex_mem_insn,
               u_core.mem_wb_v, u_core.mem_wb_insn);
  end

  initial begin
    for (int i=0;i<1024;i++) mem[i]=64'd0;
    // 0x00 addi x18,x0,0x100 ; 0x04 csrrw x0,mtvec,x18
    mem[0] = {32'h30591073, 32'h10000913};
    mem[1] = {32'h00000000, 32'h00000000};   // 0x08,0x0c: illegal
    mem[2] = {32'h00000013, 32'h00000073};   // 0x10 ecall ; 0x14 nop
    // handler at 0x100: csrrs x28,mcause,x0 ; csrrs x29,mepc,x0 ; addi x29,x29,4 ;
    //                   csrrw x0,mepc,x29 ; mret
    // 0x100 csrrs x29,mepc ; 0x104 addi x29,x29,4 ; 0x108 csrrw mepc,x29
    // 0x10c csrrs x28,mcause ; 0x110 mret
    mem[32] = {32'h004e8e93, 32'h34102ef3};
    mem[33] = {32'h34202e73, 32'h341e9073};
    mem[34] = {32'h00000000, 32'h30200073};
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (200) @(posedge clk);
    $display("done: %0d retirements, %0d traps", nret, ntr);
    $finish;
  end
endmodule
