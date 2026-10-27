`timescale 1ns/1ps
// =============================================================================
// rv64_pkg.sv -- shared types, opcodes and constants for the RV64 core slice.
// No state, no logic: package only.  Imported by every module in rtl/.
// =============================================================================
`default_nettype none
`ifndef RV64_PKG_SV
`define RV64_PKG_SV

package rv64_pkg;

  // ------------------------------------------------------------------ ALU ops
  localparam logic [5:0] ALU_ADD     = 6'd0;
  localparam logic [5:0] ALU_SUB     = 6'd1;
  localparam logic [5:0] ALU_SLL     = 6'd2;
  localparam logic [5:0] ALU_SLT     = 6'd3;
  localparam logic [5:0] ALU_SLTU    = 6'd4;
  localparam logic [5:0] ALU_XOR     = 6'd5;
  localparam logic [5:0] ALU_SRL     = 6'd6;
  localparam logic [5:0] ALU_SRA     = 6'd7;
  localparam logic [5:0] ALU_OR      = 6'd8;
  localparam logic [5:0] ALU_AND     = 6'd9;
  localparam logic [5:0] ALU_ADDW    = 6'd10;
  localparam logic [5:0] ALU_SUBW    = 6'd11;
  localparam logic [5:0] ALU_SLLW    = 6'd12;
  localparam logic [5:0] ALU_SRLW    = 6'd13;
  localparam logic [5:0] ALU_SRAW    = 6'd14;
  // Zbb
  localparam logic [5:0] ALU_ANDN    = 6'd15;
  localparam logic [5:0] ALU_ORN     = 6'd16;
  localparam logic [5:0] ALU_XNOR    = 6'd17;
  localparam logic [5:0] ALU_MAX     = 6'd18;
  localparam logic [5:0] ALU_MAXU    = 6'd19;
  localparam logic [5:0] ALU_MIN     = 6'd20;
  localparam logic [5:0] ALU_MINU    = 6'd21;
  localparam logic [5:0] ALU_SEXTB   = 6'd22;
  localparam logic [5:0] ALU_SEXTH   = 6'd23;
  localparam logic [5:0] ALU_ZEXTH   = 6'd24;
  localparam logic [5:0] ALU_CLZ     = 6'd25;
  localparam logic [5:0] ALU_CTZ     = 6'd26;
  localparam logic [5:0] ALU_CPOP    = 6'd27;
  localparam logic [5:0] ALU_ROL     = 6'd28;
  localparam logic [5:0] ALU_ROR     = 6'd29;
  localparam logic [5:0] ALU_ROLW    = 6'd30;
  localparam logic [5:0] ALU_RORW    = 6'd31;
  localparam logic [5:0] ALU_REV8    = 6'd32;
  localparam logic [5:0] ALU_ORCB    = 6'd33;
  // Zbs
  localparam logic [5:0] ALU_BSET    = 6'd34;
  localparam logic [5:0] ALU_BCLR    = 6'd35;
  localparam logic [5:0] ALU_BINV    = 6'd36;
  localparam logic [5:0] ALU_BEXT    = 6'd37;
  // Zba
  localparam logic [5:0] ALU_SH1ADD  = 6'd38;
  localparam logic [5:0] ALU_SH2ADD  = 6'd39;
  localparam logic [5:0] ALU_SH3ADD  = 6'd40;
  localparam logic [5:0] ALU_ADDUW   = 6'd41;
  localparam logic [5:0] ALU_SLLIUW  = 6'd42;
  // Zbc
  localparam logic [5:0] ALU_CLMUL   = 6'd43;
  localparam logic [5:0] ALU_CLMULH  = 6'd44;
  localparam logic [5:0] ALU_CLMULR  = 6'd45;
  // Zicond
  localparam logic [5:0] ALU_CZERO_EQZ = 6'd46;
  localparam logic [5:0] ALU_CZERO_NEZ = 6'd47;
  localparam logic [5:0] ALU_PASS_A  = 6'd48;
  localparam logic [5:0] ALU_PASS_B  = 6'd49;

  // ------------------------------------------------------------ immediate sel
  localparam logic [2:0] IMM_I    = 3'd0;
  localparam logic [2:0] IMM_S    = 3'd1;
  localparam logic [2:0] IMM_B    = 3'd2;
  localparam logic [2:0] IMM_U    = 3'd3;
  localparam logic [2:0] IMM_J    = 3'd4;
  localparam logic [2:0] IMM_Z    = 3'd5;  // CSR zimm (rs1 field, zero extended)
  localparam logic [2:0] IMM_NONE = 3'd6;

  // ------------------------------------------------------------- operand sel
  localparam logic [1:0] A_RS1  = 2'd0;
  localparam logic [1:0] A_PC   = 2'd1;
  localparam logic [1:0] A_ZERO = 2'd2;

  localparam logic [1:0] B_RS2 = 2'd0;
  localparam logic [1:0] B_IMM = 2'd1;

  // ------------------------------------------------------------- writeback sel
  localparam logic [1:0] WB_ALU = 2'd0;
  localparam logic [1:0] WB_MEM = 2'd1;
  localparam logic [1:0] WB_CSR = 2'd2;
  localparam logic [1:0] WB_PC4 = 2'd3;

  // ------------------------------------------------------------------ csr ops
  localparam logic [1:0] CSR_NONE = 2'd0;
  localparam logic [1:0] CSR_RW   = 2'd1;  // csrrw / csrrwi
  localparam logic [1:0] CSR_RS   = 2'd2;  // csrrs / csrrsi
  localparam logic [1:0] CSR_RC   = 2'd3;  // csrrc / csrrci

  // --------------------------------------------------------------- mem sizes
  // atomic kinds
  localparam logic [1:0] AT_NONE = 2'd0;
  localparam logic [1:0] AT_LR   = 2'd1;
  localparam logic [1:0] AT_SC   = 2'd2;
  localparam logic [1:0] AT_AMO  = 2'd3;

  localparam logic [2:0] MSZ_B = 3'd1;
  localparam logic [2:0] MSZ_H = 3'd2;
  localparam logic [2:0] MSZ_W = 3'd3;
  localparam logic [2:0] MSZ_D = 3'd4;

  // ------------------------------------------------------------- branch ops
  localparam logic [2:0] BR_NONE = 3'd0;
  localparam logic [2:0] BR_EQ   = 3'd1;
  localparam logic [2:0] BR_NE   = 3'd2;
  localparam logic [2:0] BR_LT   = 3'd3;
  localparam logic [2:0] BR_GE   = 3'd4;
  localparam logic [2:0] BR_LTU  = 3'd5;
  localparam logic [2:0] BR_GEU  = 3'd6;

  // ------------------------------------------------------------- MDU opcodes
  localparam logic [2:0] MDU_MUL    = 3'd0;
  localparam logic [2:0] MDU_MULH   = 3'd1;
  localparam logic [2:0] MDU_MULHSU = 3'd2;
  localparam logic [2:0] MDU_MULHU  = 3'd3;
  localparam logic [2:0] MDU_DIV    = 3'd4;
  localparam logic [2:0] MDU_DIVU   = 3'd5;
  localparam logic [2:0] MDU_REM    = 3'd6;
  localparam logic [2:0] MDU_REMU   = 3'd7;

  // --------------------------------------------------------------------- CSRs
  localparam logic [11:0] CSR_MSTATUS    = 12'h300;
  // ---- supervisor CSRs -----------------------------------------------------
  localparam logic [11:0] CSR_SSTATUS    = 12'h100;
  localparam logic [11:0] CSR_SIE        = 12'h104;
  localparam logic [11:0] CSR_STVEC      = 12'h105;
  localparam logic [11:0] CSR_SSCRATCH   = 12'h140;
  localparam logic [11:0] CSR_SEPC       = 12'h141;
  localparam logic [11:0] CSR_SCAUSE     = 12'h142;
  localparam logic [11:0] CSR_STVAL      = 12'h143;
  localparam logic [11:0] CSR_SIP        = 12'h144;
  localparam logic [11:0] CSR_SATP       = 12'h180;
  localparam logic [11:0] CSR_MEDELEG    = 12'h302;
  localparam logic [11:0] CSR_MIDELEG    = 12'h303;
  localparam logic [11:0] CSR_MISA       = 12'h301;
  localparam logic [11:0] CSR_MIE        = 12'h304;
  localparam logic [11:0] CSR_MTVEC      = 12'h305;
  localparam logic [11:0] CSR_MCOUNTEREN = 12'h306;
  localparam logic [11:0] CSR_MSCRATCH   = 12'h340;
  localparam logic [11:0] CSR_MEPC       = 12'h341;
  localparam logic [11:0] CSR_MCAUSE     = 12'h342;
  localparam logic [11:0] CSR_MTVAL      = 12'h343;
  localparam logic [11:0] CSR_MIP        = 12'h344;
  localparam logic [11:0] CSR_PMPCFG0    = 12'h3A0;
  localparam logic [11:0] CSR_PMPADDR0   = 12'h3B0;  // .. 0x3B7
  localparam logic [11:0] CSR_MCYCLE     = 12'hB00;
  localparam logic [11:0] CSR_MINSTRET   = 12'hB02;
  localparam logic [11:0] CSR_MCYCLEH    = 12'hB80;
  localparam logic [11:0] CSR_MINSTRETH  = 12'hB82;
  localparam logic [11:0] CSR_MVENDORID  = 12'hF11;
  localparam logic [11:0] CSR_MARCHID    = 12'hF12;
  localparam logic [11:0] CSR_MIMPID     = 12'hF13;
  localparam logic [11:0] CSR_MHARTID    = 12'hF14;

  // ------------------------------------------------------------- trap causes
  localparam logic [63:0] CAUSE_INST_MISALIGN  = 64'd0;
  localparam logic [63:0] CAUSE_INST_ACCESS    = 64'd1;
  localparam logic [63:0] CAUSE_ILLEGAL        = 64'd2;
  localparam logic [63:0] CAUSE_BREAKPOINT     = 64'd3;
  localparam logic [63:0] CAUSE_LOAD_MISALIGN  = 64'd4;
  localparam logic [63:0] CAUSE_LOAD_ACCESS    = 64'd5;
  localparam logic [63:0] CAUSE_STORE_MISALIGN = 64'd6;
  localparam logic [63:0] CAUSE_STORE_ACCESS   = 64'd7;
  localparam logic [63:0] CAUSE_ECALL_M        = 64'd11;
  // ---- Sv39 page faults ----------------------------------------------------
  localparam logic [63:0] CAUSE_INST_PAGE      = 64'd12;
  localparam logic [63:0] CAUSE_LOAD_PAGE      = 64'd13;
  localparam logic [63:0] CAUSE_STORE_PAGE     = 64'd15;
  localparam logic [63:0] CAUSE_ECALL_U        = 64'd8;
  localparam logic [63:0] CAUSE_ECALL_S        = 64'd9;
  localparam logic [63:0] CAUSE_M_SOFT_INT     = 64'h8000_0000_0000_0003;
  localparam logic [63:0] CAUSE_M_TIMER_INT    = 64'h8000_0000_0000_0007;
  localparam logic [63:0] CAUSE_M_EXT_INT      = 64'h8000_0000_0000_000B;

  // ------------------------------------------------------------------ control
  // Everything the decoder produces for one instruction, carried down the pipe.
  typedef struct packed {
    logic [11:0] csr_addr;
    logic [5:0]  alu_op;
    logic [2:0]  imm_sel;
    logic [2:0]  mem_size;
    logic [2:0]  branch_op;
    logic [2:0]  mdu_op;
    logic [1:0]  a_sel;
    logic [1:0]  b_sel;
    logic [1:0]  wb_sel;
    logic [1:0]  csr_op;
    logic        mem_uns;
    logic        reg_we;
    logic        is_load;
    logic        is_store;
    // atomics (A extension): a load-reserved, a store-conditional, or a
    // read-modify-write. `amo_op` is the funct5 field.
    logic        is_atomic;
    logic [1:0]  atomic_kind;
    logic [4:0]  amo_op;
    logic        is_branch;
    logic        is_jal;
    logic        is_jalr;
    logic        is_mret;
    logic        is_sret;
    logic        is_wfi;
    logic        is_ecall;
    logic        is_ebreak;
    logic        is_fence;
    logic        is_csr;
    logic        is_mdu;
    logic        csr_imm;
    logic        is_num;          // custom-0 numeric-ABI instruction
    logic [4:0]  num_op;
    logic [2:0]  num_fmt;
    logic        illegal;
  } ctrl_t;

  function automatic ctrl_t ctrl_default();
    ctrl_t c;
    c = '0;
    c.alu_op   = ALU_ADD;
    c.imm_sel  = IMM_NONE;
    c.is_sret  = 1'b0;
    c.a_sel    = A_RS1;
    c.b_sel    = B_RS2;
    c.wb_sel   = WB_ALU;
    c.csr_op   = CSR_NONE;
    c.branch_op= BR_NONE;
    c.is_num   = 1'b0;
    c.num_op   = 5'd0;
    c.num_fmt  = 3'd0;
    return c;
  endfunction

endpackage

`endif
`default_nettype wire
