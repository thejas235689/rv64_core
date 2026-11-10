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
  // ---- hypervisor (H) extension -------------------------------------------
  localparam logic [11:0] CSR_VSSTATUS   = 12'h200;
  localparam logic [11:0] CSR_VSIE       = 12'h204;
  localparam logic [11:0] CSR_VSTVEC     = 12'h205;
  localparam logic [11:0] CSR_VSSCRATCH  = 12'h240;
  localparam logic [11:0] CSR_VSEPC      = 12'h241;
  localparam logic [11:0] CSR_VSCAUSE    = 12'h242;
  localparam logic [11:0] CSR_VSTVAL     = 12'h243;
  localparam logic [11:0] CSR_VSIP       = 12'h244;
  localparam logic [11:0] CSR_HSTATUS    = 12'h600;
  localparam logic [11:0] CSR_HEDELEG    = 12'h602;
  localparam logic [11:0] CSR_HIDELEG    = 12'h603;
  localparam logic [11:0] CSR_HIE        = 12'h604;
  localparam logic [11:0] CSR_HTVEC      = 12'h605;
  localparam logic [11:0] CSR_HSCRATCH   = 12'h640;
  localparam logic [11:0] CSR_HEPC       = 12'h641;
  localparam logic [11:0] CSR_HCAUSE     = 12'h642;
  localparam logic [11:0] CSR_HTVAL      = 12'h643;
  localparam logic [11:0] CSR_HIP        = 12'h644;
  localparam logic [11:0] CSR_HTINST     = 12'h64A;
  localparam logic [11:0] CSR_HGATP      = 12'h680;
  localparam logic [11:0] CSR_FFLAGS     = 12'h001;
  localparam logic [11:0] CSR_FRM        = 12'h002;
  localparam logic [11:0] CSR_FCSR       = 12'h003;
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

  // ------------------------------------------------------------------ FPU ops
  // The operation, WITHOUT the precision: `fp_single` in ctrl_t carries the
  // format bit, so fadd.s and fadd.d are the same FP_ADD through the same
  // datapath and only the fmt input to the FPU blocks differs.  That is the
  // whole point of the extension: one FPU, two formats.
  //
  // FP_NONE means "not an FPU datapath operation" -- fld/fsd/flw/fsw set it, so
  // the FPU blocks are not asked to compute anything for them.  The fcvt family
  // keeps the source/destination width and signedness in fp_op because they are
  // part of the instruction encoding (rs2), not the format bit.
  localparam logic [4:0] FP_NONE       = 5'd0;
  localparam logic [4:0] FP_ADD        = 5'd1;
  localparam logic [4:0] FP_SUB        = 5'd2;
  localparam logic [4:0] FP_MUL        = 5'd3;
  localparam logic [4:0] FP_DIV        = 5'd4;
  localparam logic [4:0] FP_SQRT       = 5'd5;
  localparam logic [4:0] FP_FEQ        = 5'd6;
  localparam logic [4:0] FP_FLT        = 5'd7;
  localparam logic [4:0] FP_FLE        = 5'd8;
  // fp -> integer: fp_single is the SOURCE format
  localparam logic [4:0] FP_CVT_W      = 5'd9;
  localparam logic [4:0] FP_CVT_WU     = 5'd10;
  localparam logic [4:0] FP_CVT_L      = 5'd11;
  localparam logic [4:0] FP_CVT_LU     = 5'd12;
  // integer -> fp: fp_single is the DESTINATION format
  localparam logic [4:0] FP_CVT_FROM_W  = 5'd13;
  localparam logic [4:0] FP_CVT_FROM_WU = 5'd14;
  localparam logic [4:0] FP_CVT_FROM_L  = 5'd15;
  localparam logic [4:0] FP_CVT_FROM_LU = 5'd16;
  // fp -> fp: fp_single is the DESTINATION format (fcvt.s.d is fmt=0)
  localparam logic [4:0] FP_CVT_FP     = 5'd17;
  // moves: fp_single says which half-width form is in use
  localparam logic [4:0] FP_MV_X_W     = 5'd18;
  localparam logic [4:0] FP_MV_X_D     = 5'd19;
  localparam logic [4:0] FP_MV_W_X     = 5'd20;
  localparam logic [4:0] FP_MV_D_X     = 5'd21;
  localparam logic [4:0] FP_FMA        = 5'd22;

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
    logic        is_fp;       // OP-FP: operands and result live in the FP file
    logic [4:0]  fp_op;       // FPU operation; FP_NONE for fld/fsd/flw/fsw
    logic [2:0]  fp_f3;       // raw funct3: rounding mode, or fcmp selector
    logic        fp_src;      // operands come from the FP file
    logic        fp_single;   // 1 = binary32 (fmt bit 0), 0 = binary64
    // ---- hypervisor instructions (H) --------------------------------------
    logic        is_hret;     // 0x20200073
    logic        is_hfence;   // hfence.vvma / hfence.gvma -- guest TLB maintenance
    logic        is_hlv;      // hypervisor load  (HLV/HLVX family)
    logic        is_hsv;      // hypervisor store (HSV family)
    // is_fp means the RESULT goes to the FP file
    logic        is_fence;
    logic        is_cbo;        // Zicbom: cbo.inval / cbo.clean / cbo.flush
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
