// =============================================================================
// riscv_core_top.sv -- single-hart 64-bit RISC-V core, machine mode.
//
//   ISA profile : RV64IM + Zba + Zbb + Zbc + Zbs + Zicond + Zihintpause + Zicsr
//   Microarch  : in-order IF/ID/EX/MEM/WB, full EX/MEM + MEM/WB forwarding,
//                load-use interlock, branch resolution in EX, tournament
//                prediction in IF, single trap point in MEM, multi-cycle MDU
//   Bus        : separate instruction and data valid/ready interfaces with
//                64-bit beats, byte strobes, request backpressure and a
//                separate response channel carrying an error flag
//
//   Reset: synchronous active-low (rst_n), single clock domain.
// =============================================================================
`default_nettype none

module riscv_core_top #(
  parameter logic [63:0] RESET_PC            = 64'h0000_0000_0000_0000,
  parameter bit          EBREAK_ENTERS_DEBUG = 1'b1
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- instruction interface ------------------------------------------------
  output logic        if_req_valid,
  output logic [63:0] if_req_addr,
  input  logic        if_req_ready,
  input  logic        if_rsp_valid,
  input  logic [63:0] if_rsp_data,
  input  logic        if_rsp_error,

  // ---- data interface -------------------------------------------------------
  output logic        d_req_valid,
  output logic [63:0] d_req_addr,
  output logic        d_req_we,
  output logic [63:0] d_req_wdata,
  output logic [7:0]  d_req_wstrb,
  input  logic        d_req_ready,
  input  logic        d_rsp_valid,
  input  logic [63:0] d_rsp_rdata,
  input  logic        d_rsp_error,

  // ---- interrupts -----------------------------------------------------------
  input  logic        irq_soft,
  input  logic        irq_timer,
  input  logic        irq_ext,

  // ---- debug ----------------------------------------------------------------
  input  logic        dbg_halt_req,
  input  logic        dbg_resume_req,
  input  logic        dbg_step,
  output logic        dbg_halted,
  input  logic [4:0]  dbg_reg_addr,
  output logic [63:0] dbg_reg_data,

  // ---- watchpoint -----------------------------------------------------------
  input  logic        wp_en,
  input  logic [63:0] wp_addr,
  output logic        wp_hit,

  // ---- observability --------------------------------------------------------
  output logic        retire_valid,
  output logic [63:0] retire_pc,
  output logic [31:0] retire_insn,
  output logic        gpr_we,
  output logic [4:0]  gpr_waddr,
  output logic [63:0] gpr_wdata,
  output logic        trap_valid_o,
  output logic [63:0] trap_cause_o,
  output logic [63:0] trap_pc_o,
  output logic        irq_taken_o,
  output logic [1:0]  priv_o,
  output logic        debug_event_o,
  output logic [63:0] mcycle_o,
  output logic [63:0] minstret_o,

  // ---- custom task slots (Xcetask) engine side -----------------------------
  output logic        task_start_valid,
  output logic [1:0]  task_start_slot,
  output logic [63:0] task_start_token,
  output logic [31:0] task_start_timeout,
  input  logic        task_done_valid,
  input  logic [1:0]  task_done_slot,
  input  logic [63:0] task_done_result,
  output logic        task_irq_o
);
  import rv64_pkg::*;
  import rv64_num_pkg::*;

  // ===========================================================================
  // Pipeline state
  // ===========================================================================
  logic [63:0] pc_f;

  // IF/ID
  logic        if_id_v;
  logic [63:0] if_id_pc;
  logic [31:0] if_id_insn;
  logic        if_id_ptaken;
  logic [63:0] if_id_ptarget;

  // ID/EX
  logic        id_ex_v;
  logic [63:0] id_ex_pc;
  logic [31:0] id_ex_insn;
  logic [63:0] id_ex_imm;
  ctrl_t       id_ex_ctrl;
  logic [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
  logic [63:0] id_ex_rs1_data, id_ex_rs2_data;
  logic        id_ex_ptaken;
  logic [63:0] id_ex_ptarget;
  logic        id_ex_is_num;
  logic [63:0] id_ex_nrs1_data, id_ex_nrs2_data;

  // EX/MEM
  logic        ex_mem_v;
  logic [63:0] ex_mem_pc;
  logic [31:0] ex_mem_insn;
  logic [4:0]  ex_mem_rd;
  logic        ex_mem_reg_we;
  logic [1:0]  ex_mem_wb_sel;
  logic [63:0] ex_mem_wb_val;
  logic [63:0] ex_mem_addr;
  logic [63:0] ex_mem_store_data;
  logic [2:0]  ex_mem_mem_size;
  logic        ex_mem_mem_uns;
  logic        ex_mem_is_load;
  logic        ex_mem_is_store;
  logic        ex_mem_is_mret;
  logic        ex_mem_is_wfi;
  logic        ex_mem_is_ebreak;
  logic        ex_mem_is_ecall;
  logic        ex_mem_is_num;
  logic        ex_mem_exc;
  logic [63:0] ex_mem_exc_cause;
  logic [63:0] ex_mem_exc_tval;

  // MEM/WB
  logic        mem_wb_v;
  logic [63:0] mem_wb_pc;
  logic [31:0] mem_wb_insn;
  logic [4:0]  mem_wb_rd;
  logic        mem_wb_reg_we;
  logic        mem_wb_is_num;
  logic [63:0] mem_wb_wdata;

  // ===========================================================================
  // Trap / CSR control declarations
  // (declared here because iverilog requires declare-before-use)
  // ===========================================================================
  logic        trap_taken, trap_to_csr, mem_trap;
  logic        irq_take, wfi_irq_take, fetch_fault_take;
  logic        redirect_ex, ebreak_commit, mret_commit, ex_advance;
  logic [63:0] redirect_pc_ex;
  logic [63:0] trap_cause_sel, trap_pc_sel, trap_tval_sel;
  logic [63:0] irq_cause;
  logic [63:0] csr_mtvec, csr_mepc, csr_mcause, csr_mcycle, csr_minstret;
  logic        csr_mstatus_mie, csr_irq_pending, csr_we;
  logic [63:0] csr_wdata;
  logic [8*8-1:0]  pmp_cfg;
  logic [8*64-1:0] pmp_addr;


  // ===========================================================================
  // Fetch stage
  // ===========================================================================
  logic        f_insn_valid;
  logic [63:0] f_insn_pc;
  logic [31:0] f_insn;
  logic        f_fault_valid;
  logic [63:0] f_fault_pc;
  logic        f_req_valid;
  logic [63:0] f_req_addr;
  logic        f_consume, f_pause, f_redirect;
  logic [63:0] f_redirect_pc;

  logic        fetch_pmp_ok;
  logic        fetch_pmp_fault;

  logic        f_pred_taken;
  logic [63:0] f_pred_target;

  logic        halted_q, halt_pending_q, step_mode_q;
  logic        wfi_active_q;
  logic [63:0] wfi_pc_q;

  logic        fetch_stopped;

  assign fetch_stopped = halted_q || halt_pending_q || wfi_active_q ||
                         f_fault_valid || fetch_pmp_fault;

  rv64_fetch u_fetch (
    .clk         (clk),
    .rst_n       (rst_n),
    .redirect    (f_redirect),
    .pc_i        (pc_f),
    .consume     (f_consume),
    .pause       (f_pause || fetch_stopped || f_redirect),
    .req_valid   (f_req_valid),
    .req_addr    (f_req_addr),
    .req_ready   (if_req_ready),
    .rsp_valid   (if_rsp_valid),
    .rsp_data    (if_rsp_data),
    .rsp_error   (if_rsp_error),
    .insn_valid  (f_insn_valid),
    .insn_pc     (f_insn_pc),
    .insn        (f_insn),
    .fault_valid (f_fault_valid),
    .fault_pc    (f_fault_pc)
  );

  assign if_req_valid = f_req_valid && fetch_pmp_ok;
  assign if_req_addr  = f_req_addr;

  // ===========================================================================
  // Branch prediction
  // ===========================================================================
  logic        bpu_upd_valid;
  logic        bpu_upd_taken;
  logic [63:0] bpu_upd_target;
  logic        bpu_upd_is_cond, bpu_upd_is_uncond, bpu_upd_is_call, bpu_upd_is_ret;

  rv64_bpu u_bpu (
    .clk          (clk),
    .rst_n        (rst_n),
    .lookup_pc    (pc_f),
    .pred_taken   (f_pred_taken),
    .pred_target  (f_pred_target),
    .upd_valid    (bpu_upd_valid),
    .upd_pc       (id_ex_pc),
    .upd_taken    (bpu_upd_taken),
    .upd_target   (bpu_upd_target),
    .upd_is_cond  (bpu_upd_is_cond),
    .upd_is_uncond(bpu_upd_is_uncond),
    .upd_is_call  (bpu_upd_is_call),
    .upd_is_ret   (bpu_upd_is_ret)
  );

  // ===========================================================================
  // ID stage
  // ===========================================================================
  ctrl_t       dec_ctrl;
  logic [63:0] dec_imm;
  logic [4:0]  dec_rs1, dec_rs2, dec_rd;
  logic [63:0] rs1_data, rs2_data;

  rv64_decoder u_decoder (
    .insn (if_id_insn),
    .ctrl (dec_ctrl),
    .imm  (dec_imm),
    .rs1  (dec_rs1),
    .rs2  (dec_rs2),
    .rd   (dec_rd)
  );

  logic [63:0] rf_rs1_data, rf_rs2_data;

  rv64_regfile u_regfile (
    .clk      (clk),
    .rst_n    (rst_n),
    .rs1_addr (dec_rs1),
    .rs2_addr (dec_rs2),
    .rs1_data (rf_rs1_data),
    .rs2_data (rf_rs2_data),
    .we       (mem_wb_v && mem_wb_reg_we),
    .rd_addr  (mem_wb_rd),
    .rd_data  (mem_wb_wdata),
    .dbg_addr (dbg_reg_addr),
    .dbg_data (dbg_reg_data)
  );

  // Write-through on the ID read: the register file write and this read land in
  // the same cycle, so a producer retiring in WB must bypass into ID.  Without
  // this, a fetch bubble between producer and consumer leaves ID holding a
  // value one writeback stale (there is then no EX/MEM or MEM/WB copy left to
  // forward from when the consumer reaches EX).
  always_comb begin
    rs1_data = rf_rs1_data;
    rs2_data = rf_rs2_data;
    if (mem_wb_v && mem_wb_reg_we && (mem_wb_rd != 5'd0)) begin
      if (mem_wb_rd == dec_rs1) rs1_data = mem_wb_wdata;
      if (mem_wb_rd == dec_rs2) rs2_data = mem_wb_wdata;
    end
  end

  // ===========================================================================
  // Custom numeric ABI: its own register bank, datapath and CSRs
  // ===========================================================================
  logic [63:0] nrf_rs1_data, nrf_rs2_data;
  logic [63:0] nrs1_data, nrs2_data;
  logic [63:0] num_y, num_err, num_err_cur, num_cfg;
  logic [7:0]  num_flags;
  logic [127:0] num_quire;
  logic        num_csr_valid;
  logic [63:0] num_csr_rdata;
  logic        num_csr_sel;

  rv64_numfile u_numfile (
    .clk      (clk),
    .rst_n    (rst_n),
    .rs1_addr (dec_rs1),
    .rs2_addr (dec_rs2),
    .rs1_data (nrf_rs1_data),
    .rs2_data (nrf_rs2_data),
    // a numeric op writes the numeric bank; NUM_TOINT is the one case that sets
    // reg_we as well (it lands in the integer file), so exclude it here or the
    // bridge would clobber a numeric register with its own result
    .we       (mem_wb_v && mem_wb_is_num && !mem_wb_reg_we),
    .rd_addr  (mem_wb_rd),
    .rd_data  (mem_wb_wdata),
    .dbg_addr (5'd0),
    .dbg_data ()
  );

  // same write-through rule as the integer bank: no forwarding path exists on
  // the numeric side, so a producer retiring in WB must bypass into ID
  always_comb begin
    nrs1_data = nrf_rs1_data;
    nrs2_data = nrf_rs2_data;
    if (mem_wb_v && mem_wb_is_num) begin
      if (mem_wb_rd == dec_rs1) nrs1_data = mem_wb_wdata;
      if (mem_wb_rd == dec_rs2) nrs2_data = mem_wb_wdata;
    end
  end

  // ===========================================================================
  // Custom task slots (Xcetask), reached through the CSR window at 0x7D0
  // ===========================================================================
  logic        task_csr_valid;
  logic [63:0] task_csr_rdata;
  logic        task_csr_sel;

  assign task_csr_sel = (id_ex_ctrl.csr_addr >= CSR_TASK_BASE) &&
                        (id_ex_ctrl.csr_addr <= (CSR_TASK_BASE + 12'd8));

  rv64_xcetask #(.NSLOT(4), .SLOT_W(2)) u_xcetask (
    .clk           (clk),
    .rst_n         (rst_n),
    .csr_we        (csr_we && task_csr_sel),
    .csr_addr      (id_ex_ctrl.csr_addr[3:0] - CSR_TASK_BASE[3:0]),
    .csr_wdata     (csr_wdata),
    .csr_rdata     (task_csr_rdata),
    .start_valid   (task_start_valid),
    .start_slot    (task_start_slot),
    .start_token   (task_start_token),
    .start_timeout (task_start_timeout),
    .done_valid    (task_done_valid),
    .done_slot     (task_done_slot),
    .done_result   (task_done_result),
    .irq           (task_irq_o)
  );

  // exactly one pulse per numeric instruction, however long EX is held
  logic num_exec;
  assign num_exec = id_ex_v && id_ex_ctrl.is_num && ex_advance && !trap_taken;

  rv64_num_unit u_num_unit (
    .clk   (clk),
    .rst_n (rst_n),
    .op    (id_ex_ctrl.num_op),
    .fmt   (id_ex_ctrl.num_fmt),
    .a     (id_ex_nrs1_data),
    .b     (id_ex_nrs2_data),
    .cfg   (num_cfg),
    .op_valid (num_exec),
    .y     (num_y),
    .flags (num_flags),
    .err   (num_err),
    .err_cur (num_err_cur),
    .quire (num_quire)
  );

  assign num_csr_sel = (id_ex_ctrl.csr_addr >= CSR_NCFG) &&
                       (id_ex_ctrl.csr_addr <= CSR_NERR);

  rv64_num_csr u_num_csr (
    .clk        (clk),
    .rst_n      (rst_n),
    .csr_addr   (id_ex_ctrl.csr_addr),
    .csr_op     (id_ex_ctrl.csr_op),
    .csr_wdata  (csr_wdata),
    .csr_we     (csr_we),
    .csr_rdata  (num_csr_rdata),
    .csr_valid  (num_csr_valid),
    .op_flags   (num_flags),
    .op_valid   (num_exec),
    .op_err     (num_err_cur),
    .ncfg_o     (num_cfg)
  );

  // ===========================================================================
  // EX stage
  // ===========================================================================
  logic [63:0] op_a, op_b;
  logic [63:0] alu_a, alu_b, alu_y;
  logic [63:0] csr_rdata;
  logic [63:0] main_csr_rdata;

  always_comb begin
    if (task_csr_sel)     csr_rdata = task_csr_rdata;
    else if (num_csr_sel) csr_rdata = num_csr_rdata;
    else                  csr_rdata = main_csr_rdata;
  end
  logic        csr_valid;
  logic [63:0] mdu_result;
  logic        mdu_busy, mdu_done;
  logic        mdu_start;

  logic        exmem_fwd_ok, memwb_fwd_ok;
  logic [63:0] ex_alu_out, ex_wb_val;

  logic        eq_x, lt_x, ltu_x, branch_taken;
  logic [63:0] ex_target;
  logic        ex_misalign;
  logic        ex_exc;
  logic [63:0] ex_exc_cause, ex_exc_tval;

  assign exmem_fwd_ok = ex_mem_v && ex_mem_reg_we && !ex_mem_is_load && (ex_mem_rd != 5'd0);
  assign memwb_fwd_ok = mem_wb_v && mem_wb_reg_we && (mem_wb_rd != 5'd0);

  always_comb begin
    op_a = id_ex_rs1_data;
    if (exmem_fwd_ok && (ex_mem_rd == id_ex_rs1))      op_a = ex_mem_wb_val;
    else if (memwb_fwd_ok && (mem_wb_rd == id_ex_rs1)) op_a = mem_wb_wdata;
  end

  always_comb begin
    op_b = id_ex_rs2_data;
    if (exmem_fwd_ok && (ex_mem_rd == id_ex_rs2))      op_b = ex_mem_wb_val;
    else if (memwb_fwd_ok && (mem_wb_rd == id_ex_rs2)) op_b = mem_wb_wdata;
  end

  always_comb begin
    unique case (id_ex_ctrl.a_sel)
      A_PC:    alu_a = id_ex_pc;
      A_ZERO:  alu_a = 64'd0;
      default: alu_a = op_a;
    endcase
  end

  assign alu_b = (id_ex_ctrl.b_sel == B_IMM) ? id_ex_imm : op_b;

  rv64_alu u_alu (
    .a  (alu_a),
    .b  (alu_b),
    .op (id_ex_ctrl.alu_op),
    .y  (alu_y)
  );

  // ---- MDU ------------------------------------------------------------------
  assign mdu_start = id_ex_v && id_ex_ctrl.is_mdu && !mdu_busy && !mdu_done;

  rv64_mdu u_mdu (
    .clk    (clk),
    .rst_n  (rst_n),
    .start  (mdu_start),
    .op     (id_ex_ctrl.mdu_op),
    .a      (op_a),
    .b      (op_b),
    .busy   (mdu_busy),
    .done   (mdu_done),
    .result (mdu_result)
  );

  assign ex_alu_out = id_ex_ctrl.is_mdu ? mdu_result :
                      (id_ex_ctrl.is_num
                         ? ((id_ex_ctrl.num_op == NUM_TOINT)   ? id_ex_nrs1_data :
                            (id_ex_ctrl.num_op == NUM_FROMINT) ? op_a : num_y)
                         : alu_y);

  // ---- branch / jump resolution --------------------------------------------
  assign eq_x  = (op_a == op_b);
  assign lt_x  = ($signed(op_a) < $signed(op_b));
  assign ltu_x = (op_a < op_b);

  always_comb begin
    unique case (id_ex_ctrl.branch_op)
      BR_EQ:   branch_taken = eq_x;
      BR_NE:   branch_taken = !eq_x;
      BR_LT:   branch_taken = lt_x;
      BR_GE:   branch_taken = !lt_x;
      BR_LTU:  branch_taken = ltu_x;
      BR_GEU:  branch_taken = !ltu_x;
      default: branch_taken = 1'b0;
    endcase
  end

  always_comb begin
    if (id_ex_ctrl.is_jalr)     ex_target = {ex_alu_out[63:1], 1'b0};
    else                        ex_target = id_ex_pc + id_ex_imm;
  end

  // ---- misalignment (per the contract: misaligned accesses trap) -----------
  always_comb begin
    ex_misalign = 1'b0;
    if (id_ex_ctrl.is_load || id_ex_ctrl.is_store) begin
      unique case (id_ex_ctrl.mem_size)
        MSZ_B:   ex_misalign = 1'b0;
        MSZ_H:   ex_misalign = ex_alu_out[0];
        MSZ_W:   ex_misalign = (ex_alu_out[1:0] != 2'b00);
        MSZ_D:   ex_misalign = (ex_alu_out[2:0] != 3'b000);
        default: ex_misalign = 1'b0;
      endcase
    end
  end

  // ---- exception generation -------------------------------------------------
  always_comb begin
    ex_exc       = 1'b0;
    ex_exc_cause = 64'd0;
    ex_exc_tval  = 64'd0;

    if (id_ex_ctrl.illegal ||
        (id_ex_ctrl.is_csr && !csr_valid && !num_csr_valid && !task_csr_sel)) begin
      ex_exc       = 1'b1;
      ex_exc_cause = CAUSE_ILLEGAL;
      ex_exc_tval  = {32'd0, id_ex_insn};
    end else if (id_ex_ctrl.is_ecall) begin
      ex_exc       = 1'b1;
      ex_exc_cause = CAUSE_ECALL_M;
    end else if (id_ex_ctrl.is_ebreak && !EBREAK_ENTERS_DEBUG) begin
      ex_exc       = 1'b1;
      ex_exc_cause = CAUSE_BREAKPOINT;
    end else if (ex_misalign) begin
      ex_exc       = 1'b1;
      ex_exc_cause = id_ex_ctrl.is_store ? CAUSE_STORE_MISALIGN : CAUSE_LOAD_MISALIGN;
      ex_exc_tval  = ex_alu_out;
    end
  end

  always_comb begin
    unique case (id_ex_ctrl.wb_sel)
      WB_MEM:  ex_wb_val = 64'd0;             // filled from the load result in MEM
      WB_CSR:  ex_wb_val = csr_rdata;
      WB_PC4:  ex_wb_val = id_ex_pc + 64'd4;
      default: ex_wb_val = ex_alu_out;
    endcase
  end

  // ===========================================================================
  // MEM stage
  // ===========================================================================
  logic        lsu_busy, lsu_done, lsu_fault;
  logic [63:0] lsu_load_data;
  logic        lsu_start;
  logic        d_pmp_ok;
  logic        mem_stall;
  logic        ex_hold;
  logic        stall_id;
  logic        csr_vs_mret;

  assign lsu_start = ex_mem_v && (ex_mem_is_load || ex_mem_is_store) &&
                     !ex_mem_exc && !lsu_busy;

  rv64_lsu u_lsu (
    .clk           (clk),
    .rst_n         (rst_n),
    .req_start     (lsu_start),
    .req_addr      (ex_mem_addr),
    .req_wdata     (ex_mem_store_data),
    .req_size      (ex_mem_mem_size),
    .req_uns       (ex_mem_mem_uns),
    .req_we        (ex_mem_is_store),
    .pmp_ok        (d_pmp_ok),
    .mem_req_valid (d_req_valid),
    .mem_req_addr  (d_req_addr),
    .mem_req_we    (d_req_we),
    .mem_req_wdata (d_req_wdata),
    .mem_req_wstrb (d_req_wstrb),
    .mem_req_ready (d_req_ready),
    .mem_rsp_valid (d_rsp_valid),
    .mem_rsp_rdata (d_rsp_rdata),
    .mem_rsp_error (d_rsp_error),
    .busy          (lsu_busy),
    .done          (lsu_done),
    .fault         (lsu_fault),
    .load_data     (lsu_load_data)
  );

  assign mem_stall = ex_mem_v && (ex_mem_is_load || ex_mem_is_store) &&
                     !ex_mem_exc && !lsu_done;

  assign wp_hit = wp_en && d_req_valid && (d_req_addr == wp_addr);

  // ===========================================================================
  // CSR file
  // ===========================================================================


  assign csr_wdata = id_ex_ctrl.csr_imm ? {59'd0, id_ex_rs1} : op_a;
  // the numeric CSRs live outside the machine CSR file, so the access is
  // arbitrated here: address decode picks exactly one of the two files
  assign csr_we    = id_ex_v && id_ex_ctrl.is_csr && (csr_valid || num_csr_valid || task_csr_sel) &&
                     !trap_to_csr && !ex_hold;

  rv64_csr u_csr (
    .clk            (clk),
    .rst_n          (rst_n),
    .csr_addr       (id_ex_ctrl.csr_addr),
    .csr_op         (id_ex_ctrl.csr_op),
    .csr_wdata      (csr_wdata),
    .csr_we         (csr_we),
    .csr_rdata      (main_csr_rdata),
    .csr_valid      (csr_valid),
    .trap_valid     (trap_to_csr),
    .trap_cause     (trap_cause_sel),
    .trap_pc        (trap_pc_sel),
    .trap_tval      (trap_tval_sel),
    .mret_valid     (mret_commit),
    .mtvec_o        (csr_mtvec),
    .mepc_o         (csr_mepc),
    .irq_soft       (irq_soft),
    .irq_timer      (irq_timer),
    .irq_ext        (irq_ext),
    .mstatus_mie    (csr_mstatus_mie),
    .irq_pending    (csr_irq_pending),
    .retire_valid   (mem_wb_v),
    .mcycle_o       (csr_mcycle),
    .minstret_o     (csr_minstret),
    .pmp_cfg        (pmp_cfg),
    .pmp_addr       (pmp_addr),
    .mcause_o       (csr_mcause)
  );

  // ===========================================================================
  // PMP checks
  // ===========================================================================
  rv64_pmp u_pmp_fetch (
    .cfg      (pmp_cfg),
    .addr_cfg (pmp_addr),
    .addr     (f_req_addr),
    .is_write (1'b0),
    .is_exec  (1'b1),
    .priv_m   (1'b1),
    .allow    (fetch_pmp_ok)
  );

  rv64_pmp u_pmp_data (
    .cfg      (pmp_cfg),
    .addr_cfg (pmp_addr),
    .addr     (ex_mem_addr),
    .is_write (ex_mem_is_store),
    .is_exec  (1'b0),
    .priv_m   (1'b1),
    .allow    (d_pmp_ok)
  );

  // The PMP verdict for the address the core would fetch next.  It is derived
  // from the registered pc only, which keeps the fault path out of the fetch
  // request handshake (no combinational loop through pause/redirect).
  assign fetch_pmp_fault = !fetch_pmp_ok;

  // ===========================================================================
  // Trap, interrupt and redirect control
  // ===========================================================================

  assign mem_trap = ex_mem_v && (ex_mem_exc || (lsu_done && lsu_fault));

  always_comb begin
    if (csr_irq_pending && irq_ext && csr_mstatus_mie)       irq_cause = CAUSE_M_EXT_INT;
    else if (csr_irq_pending && irq_timer && csr_mstatus_mie) irq_cause = CAUSE_M_TIMER_INT;
    else                                                     irq_cause = CAUSE_M_SOFT_INT;
  end

  assign irq_take = csr_mstatus_mie && csr_irq_pending && !mem_trap && !halted_q &&
                    !halt_pending_q && id_ex_v && !id_ex_ctrl.illegal && !id_ex_ctrl.is_ebreak &&
                    !id_ex_ctrl.is_mret;

  assign wfi_irq_take = wfi_active_q && csr_irq_pending && csr_mstatus_mie &&
                        !id_ex_v && !ex_mem_v;

  assign fetch_fault_take = (f_fault_valid || fetch_pmp_fault) && !id_ex_v && !ex_mem_v;

  assign trap_taken = mem_trap || irq_take || wfi_irq_take || fetch_fault_take;
  assign trap_to_csr = trap_taken;

  always_comb begin
    if (mem_trap) begin
      trap_cause_sel = ex_mem_exc ? ex_mem_exc_cause
                                  : (ex_mem_is_store ? CAUSE_STORE_ACCESS : CAUSE_LOAD_ACCESS);
      trap_pc_sel    = ex_mem_pc;
      trap_tval_sel  = ex_mem_exc ? ex_mem_exc_tval : ex_mem_addr;
    end else if (irq_take) begin
      trap_cause_sel = irq_cause;
      trap_pc_sel    = id_ex_pc;
      trap_tval_sel  = 64'd0;
    end else if (wfi_irq_take) begin
      trap_cause_sel = irq_cause;
      trap_pc_sel    = wfi_pc_q + 64'd4;
      trap_tval_sel  = 64'd0;
    end else begin
      trap_cause_sel = CAUSE_INST_ACCESS;
      trap_pc_sel    = f_fault_valid ? f_fault_pc : f_req_addr;
      trap_tval_sel  = trap_pc_sel;
    end
  end

  // ---- mispredict / return redirect ----------------------------------------
  assign ex_advance = !mem_stall && !ex_hold;

  assign redirect_ex = ex_advance && id_ex_v && !trap_taken &&
                       (id_ex_ctrl.is_branch || id_ex_ctrl.is_jal || id_ex_ctrl.is_jalr) &&
                       ((branch_taken || id_ex_ctrl.is_jal || id_ex_ctrl.is_jalr) != id_ex_ptaken ||
                        (((branch_taken || id_ex_ctrl.is_jal || id_ex_ctrl.is_jalr)) &&
                         (ex_target != id_ex_ptarget)));

  // Redirect target for an EX-stage mispredict.  A conditional branch that
  // resolves NOT taken must resume at pc+4 -- its branch target is the wrong
  // path in that case.
  always_comb begin
    if (id_ex_ctrl.is_branch && !branch_taken) redirect_pc_ex = id_ex_pc + 64'd4;
    else                                       redirect_pc_ex = ex_target;
  end

  assign mret_commit = ex_mem_v && ex_mem_is_mret && !mem_trap;
  assign ebreak_commit = ex_mem_v && ex_mem_is_ebreak && EBREAK_ENTERS_DEBUG && !mem_trap;

  assign bpu_upd_valid = ex_advance && id_ex_v && !trap_taken &&
                         (id_ex_ctrl.is_branch || id_ex_ctrl.is_jal || id_ex_ctrl.is_jalr);
  assign bpu_upd_taken   = id_ex_ctrl.is_branch ? branch_taken : 1'b1;
  assign bpu_upd_target  = ex_target;
  assign bpu_upd_is_cond = id_ex_ctrl.is_branch;
  assign bpu_upd_is_uncond = id_ex_ctrl.is_jal || id_ex_ctrl.is_jalr;
  assign bpu_upd_is_call = (id_ex_ctrl.is_jal || id_ex_ctrl.is_jalr) &&
                           ((id_ex_rd == 5'd1) || (id_ex_rd == 5'd5));
  assign bpu_upd_is_ret  = id_ex_ctrl.is_jalr &&
                           ((id_ex_rs1 == 5'd1) || (id_ex_rs1 == 5'd5)) &&
                           !((id_ex_rd == 5'd1) || (id_ex_rd == 5'd5));

  // ---- stalls ---------------------------------------------------------------
  assign csr_vs_mret = mret_commit && id_ex_v && id_ex_ctrl.is_csr;
  assign ex_hold     = mdu_busy || (id_ex_v && id_ex_ctrl.is_mdu && !mdu_done) || csr_vs_mret;

  always_comb begin
    stall_id = 1'b0;
    // conservative numeric interlock: hold ID while a numeric write is anywhere
    // in the pipeline and the instruction in ID is itself a numeric op
    // the flag must be qualified by the stage valid bit: ex_mem_is_num keeps
    // its old value when ex_mem takes a bubble, and an unqualified check
    // deadlocks the pipeline on a stale flag
    if (dec_ctrl.is_num &&
        ((id_ex_v  && id_ex_is_num)  ||
         (ex_mem_v && ex_mem_is_num) ||
         (mem_wb_v && mem_wb_is_num)))
      stall_id = 1'b1;
    if (id_ex_v && id_ex_ctrl.is_load && (id_ex_rd != 5'd0) && if_id_v) begin
      if ((dec_rs1 == id_ex_rd) || (dec_rs2 == id_ex_rd)) stall_id = 1'b1;
    end
  end

  // ---- redirect mux ---------------------------------------------------------
  logic        flush_front;
  logic        dbg_resume_pulse;

  assign dbg_resume_pulse = dbg_resume_req && halted_q;
  // MRET and EBREAK both redirect the front end: whatever was fetched behind
  // them is wrong-path and must be squashed, exactly like a branch redirect.
  assign flush_front = trap_taken || redirect_ex || ebreak_commit || mret_commit;

  always_comb begin
    f_redirect    = 1'b1;
    f_redirect_pc = pc_f + 64'd4;
    if (trap_taken) begin
      f_redirect_pc = csr_mtvec;
    end else if (mret_commit) begin
      f_redirect_pc = csr_mepc;
    end else if (redirect_ex) begin
      f_redirect_pc = redirect_pc_ex;
    end else if (ebreak_commit) begin
      f_redirect_pc = ex_mem_pc + 64'd4;
    end else if (dbg_resume_pulse) begin
      f_redirect_pc = if_id_v ? if_id_pc : pc_f;
    end else begin
      f_redirect    = 1'b0;
      f_redirect_pc = pc_f + 64'd4;
    end
  end

  // ===========================================================================
  // Sequential: fetch pc and pipeline registers
  // ===========================================================================
  logic id_ex_accept;

  assign id_ex_accept = !mem_stall && !ex_hold && !stall_id && !flush_front;
  assign f_consume    = f_insn_valid && (!if_id_v || id_ex_accept) && !flush_front && !fetch_stopped;
  assign f_pause      = mem_stall || ex_hold || stall_id;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_f          <= RESET_PC;
      if_id_v       <= 1'b0;
      if_id_pc      <= 64'd0;
      if_id_insn    <= 32'd0;
      if_id_ptaken  <= 1'b0;
      if_id_ptarget <= 64'd0;
    end else begin
      if (f_redirect) begin
        pc_f <= f_redirect_pc;
      end else if (f_consume) begin
        pc_f <= f_pred_taken ? f_pred_target : (f_insn_pc + 64'd4);
      end

      if (flush_front) begin
        if_id_v <= 1'b0;
      end else if (f_consume) begin
        if_id_v       <= 1'b1;
        if_id_pc      <= f_insn_pc;
        if_id_insn    <= f_insn;
        if_id_ptaken  <= f_pred_taken;
        if_id_ptarget <= f_pred_target;
      end else if (id_ex_accept) begin
        if_id_v <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      id_ex_v        <= 1'b0;
      id_ex_pc       <= 64'd0;
      id_ex_insn     <= 32'd0;
      id_ex_imm      <= 64'd0;
      id_ex_ctrl     <= ctrl_default();
      id_ex_rs1      <= 5'd0;
      id_ex_rs2      <= 5'd0;
      id_ex_rd       <= 5'd0;
      id_ex_rs1_data <= 64'd0;
      id_ex_rs2_data <= 64'd0;
      id_ex_ptaken   <= 1'b0;
      id_ex_ptarget  <= 64'd0;
    end else if (flush_front) begin
      id_ex_v <= 1'b0;
    end else if (mem_stall || ex_hold) begin
      // hold the EX stage
    end else if (stall_id) begin
      id_ex_v <= 1'b0;                 // bubble while the load completes
    end else if (if_id_v) begin
      id_ex_v        <= 1'b1;
      id_ex_pc       <= if_id_pc;
      id_ex_insn     <= if_id_insn;
      id_ex_imm      <= dec_imm;
      id_ex_ctrl     <= dec_ctrl;
      id_ex_rs1      <= dec_rs1;
      id_ex_rs2      <= dec_rs2;
      id_ex_rd       <= dec_rd;
      id_ex_rs1_data <= rs1_data;
      id_ex_rs2_data <= rs2_data;
      id_ex_ptaken   <= if_id_ptaken;
      id_ex_ptarget  <= if_id_ptarget;
      id_ex_is_num   <= dec_ctrl.is_num;
      id_ex_nrs1_data <= nrs1_data;
      id_ex_nrs2_data <= nrs2_data;
    end else begin
      id_ex_v <= 1'b0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ex_mem_v          <= 1'b0;
      ex_mem_pc         <= 64'd0;
      ex_mem_insn       <= 32'd0;
      ex_mem_rd         <= 5'd0;
      ex_mem_reg_we     <= 1'b0;
      ex_mem_wb_sel     <= WB_ALU;
      ex_mem_wb_val     <= 64'd0;
      ex_mem_addr       <= 64'd0;
      ex_mem_store_data <= 64'd0;
      ex_mem_mem_size   <= MSZ_D;
      ex_mem_mem_uns    <= 1'b0;
      ex_mem_is_load    <= 1'b0;
      ex_mem_is_store   <= 1'b0;
      ex_mem_is_mret    <= 1'b0;
      ex_mem_is_wfi     <= 1'b0;
      ex_mem_is_ebreak  <= 1'b0;
      ex_mem_is_ecall   <= 1'b0;
      ex_mem_is_num     <= 1'b0;
      ex_mem_exc        <= 1'b0;
      ex_mem_exc_cause  <= 64'd0;
      ex_mem_exc_tval   <= 64'd0;
    end else if (trap_taken || mret_commit || ebreak_commit) begin
      // A trap, an MRET or an EBREAK that commits in MEM must also stop the
      // younger instruction sitting in EX from advancing into MEM. Clearing
      // if_id/id_ex alone is not enough: the EX instruction is transferred to
      // MEM in this very cycle, so it would execute anyway -- and a wrong-path
      // instruction behind an MRET would take a trap of its own.
      ex_mem_v <= 1'b0;
    end else if (mem_stall) begin
      // hold
    end else if (ex_hold) begin
      ex_mem_v <= 1'b0;
    end else if (id_ex_v) begin
      ex_mem_v          <= 1'b1;
      ex_mem_pc         <= id_ex_pc;
      ex_mem_insn       <= id_ex_insn;
      ex_mem_rd         <= id_ex_rd;
      ex_mem_reg_we     <= id_ex_ctrl.reg_we;
      ex_mem_wb_sel     <= id_ex_ctrl.wb_sel;
      ex_mem_wb_val     <= ex_wb_val;
      ex_mem_addr       <= ex_alu_out;
      ex_mem_store_data <= op_b;
      ex_mem_mem_size   <= id_ex_ctrl.mem_size;
      ex_mem_mem_uns    <= id_ex_ctrl.mem_uns;
      ex_mem_is_load    <= id_ex_ctrl.is_load;
      ex_mem_is_store   <= id_ex_ctrl.is_store;
      ex_mem_is_mret    <= id_ex_ctrl.is_mret;
      ex_mem_is_wfi     <= id_ex_ctrl.is_wfi;
      ex_mem_is_ebreak  <= id_ex_ctrl.is_ebreak;
      ex_mem_is_ecall   <= id_ex_ctrl.is_ecall;
      ex_mem_is_num     <= id_ex_ctrl.is_num;
      ex_mem_exc        <= ex_exc;
      ex_mem_exc_cause  <= ex_exc_cause;
      ex_mem_exc_tval   <= ex_exc_tval;
    end else begin
      ex_mem_v <= 1'b0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_wb_v      <= 1'b0;
      mem_wb_pc     <= 64'd0;
      mem_wb_insn   <= 32'd0;
      mem_wb_rd     <= 5'd0;
      mem_wb_reg_we <= 1'b0;
      mem_wb_is_num <= 1'b0;
      mem_wb_wdata  <= 64'd0;
    end else if (mem_stall || mem_trap) begin
      mem_wb_v <= 1'b0;
    end else if (ex_mem_v) begin
      mem_wb_v      <= 1'b1;
      mem_wb_pc     <= ex_mem_pc;
      mem_wb_insn   <= ex_mem_insn;
      mem_wb_rd     <= ex_mem_rd;
      mem_wb_reg_we <= ex_mem_reg_we;
      mem_wb_is_num <= ex_mem_is_num;
      mem_wb_wdata  <= (ex_mem_wb_sel == WB_MEM) ? lsu_load_data : ex_mem_wb_val;
    end else begin
      mem_wb_v <= 1'b0;
    end
  end

  // ===========================================================================
  // Debug, WFI and halt control
  // ===========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      halted_q       <= 1'b0;
      halt_pending_q <= 1'b0;
      step_mode_q    <= 1'b0;
      wfi_active_q   <= 1'b0;
      wfi_pc_q       <= 64'd0;
    end else begin
      // ---- halt request / ebreak entry ------------------------------------
      if ((dbg_halt_req || ebreak_commit) && !halted_q) halt_pending_q <= 1'b1;

      // ---- pipeline drained: enter debug ----------------------------------
      if (halt_pending_q && !id_ex_v && !ex_mem_v && !lsu_busy) begin
        halted_q       <= 1'b1;
        halt_pending_q <= 1'b0;
      end

      // ---- resume ---------------------------------------------------------
      if (dbg_resume_pulse) begin
        halted_q    <= 1'b0;
        step_mode_q <= dbg_step;
      end

      // ---- single step: halt again after one retirement --------------------
      if (step_mode_q && mem_wb_v) begin
        halted_q    <= 1'b1;
        step_mode_q <= 1'b0;
      end

      // ---- WFI ------------------------------------------------------------
      if (ex_mem_v && ex_mem_is_wfi && !mem_trap) begin
        wfi_active_q <= 1'b1;
        wfi_pc_q     <= ex_mem_pc;
      end else if (wfi_active_q && csr_irq_pending) begin
        wfi_active_q <= 1'b0;
      end
    end
  end

  // ===========================================================================
  // Observability
  // ===========================================================================
  assign retire_valid  = mem_wb_v;
  assign retire_pc     = mem_wb_pc;
  assign retire_insn   = mem_wb_insn;
  assign gpr_we        = mem_wb_v && mem_wb_reg_we;
  assign gpr_waddr     = mem_wb_rd;
  assign gpr_wdata     = mem_wb_wdata;
  assign trap_valid_o  = trap_taken;
  assign trap_cause_o  = trap_cause_sel;
  assign trap_pc_o     = trap_pc_sel;
  assign irq_taken_o   = irq_take || wfi_irq_take;
  assign priv_o        = 2'b11;
  assign debug_event_o = (ebreak_commit && EBREAK_ENTERS_DEBUG) || (halt_pending_q && !id_ex_v && !ex_mem_v && !lsu_busy);
  assign dbg_halted    = halted_q;
  assign mcycle_o      = csr_mcycle;
  assign minstret_o    = csr_minstret;

endmodule
`default_nettype wire
