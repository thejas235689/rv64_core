`timescale 1ns/1ps
// =============================================================================
// rv64_decoder.sv -- instruction decode for RV64IM + Zba + Zbb + Zbc + Zbs +
//                    Zicond + Zihintpause, machine mode, Zicsr.
//   Purely combinational.  Anything not recognised drives ctrl.illegal = 1
//   with a fully defined control bundle (never X), so the core traps cleanly.
// =============================================================================
`default_nettype none

module rv64_decoder (
  input  logic [31:0] insn,
  output rv64_pkg::ctrl_t ctrl,
  output logic [63:0] imm,
  output logic [4:0]  rs1,
  output logic [4:0]  rs2,
  output logic [4:0]  rd
);
  import rv64_pkg::*;

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic [5:0] funct6;
  logic [11:0] imm12;
  logic [4:0]  rs2f;      // rs2 field, also the shamt / sub-op field

  assign opcode = insn[6:0];
  assign funct3 = insn[14:12];
  assign funct7 = insn[31:25];
  assign funct6 = insn[31:26];
  assign imm12  = insn[31:20];
  assign rs2f   = insn[24:20];

  assign rs1 = insn[19:15];
  assign rs2 = insn[24:20];
  assign rd  = insn[11:7];

  // ---- immediate ------------------------------------------------------------
  always_comb begin
    unique case (ctrl.imm_sel)
      IMM_I:   imm = {{52{insn[31]}}, insn[31:20]};
      IMM_S:   imm = {{52{insn[31]}}, insn[31:25], insn[11:7]};
      IMM_B:   imm = {{51{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
      IMM_U:   imm = {{32{insn[31]}}, insn[31:12], 12'd0};
      IMM_J:   imm = {{43{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};
      IMM_Z:   imm = {59'd0, insn[19:15]};
      default: imm = 64'd0;
    endcase
  end

  // ---- control --------------------------------------------------------------
  always_comb begin
    ctrl = ctrl_default();

    unique case (opcode)
      // ------------------------------------------------------------------ LUI
      7'b0110111: begin
        ctrl.imm_sel = IMM_U;
        ctrl.a_sel   = A_ZERO;
        ctrl.b_sel   = B_IMM;
        ctrl.alu_op  = ALU_PASS_B;
        ctrl.reg_we  = 1'b1;
      end

      // ---------------------------------------------------------------- AUIPC
      7'b0010111: begin
        ctrl.imm_sel = IMM_U;
        ctrl.a_sel   = A_PC;
        ctrl.b_sel   = B_IMM;
        ctrl.alu_op  = ALU_ADD;
        ctrl.reg_we  = 1'b1;
      end

      // ------------------------------------------------------------------ JAL
      7'b1101111: begin
        ctrl.imm_sel = IMM_J;
        ctrl.is_jal  = 1'b1;
        ctrl.reg_we  = 1'b1;
        ctrl.wb_sel  = WB_PC4;
      end

      // ----------------------------------------------------------------- JALR
      7'b1100111: begin
        if (funct3 == 3'b000) begin
          ctrl.imm_sel = IMM_I;
          ctrl.is_jalr = 1'b1;
          ctrl.reg_we  = 1'b1;
          ctrl.wb_sel  = WB_PC4;
          ctrl.alu_op  = ALU_ADD;
        end else begin
          ctrl.illegal = 1'b1;
        end
      end

      // -------------------------------------------------------------- BRANCH
      7'b1100011: begin
        ctrl.imm_sel = IMM_B;
        ctrl.is_branch = 1'b1;
        ctrl.alu_op  = ALU_SUB;
        unique case (funct3)
          3'b000: ctrl.branch_op = BR_EQ;
          3'b001: ctrl.branch_op = BR_NE;
          3'b100: ctrl.branch_op = BR_LT;
          3'b101: ctrl.branch_op = BR_GE;
          3'b110: ctrl.branch_op = BR_LTU;
          3'b111: ctrl.branch_op = BR_GEU;
          default: ctrl.illegal = 1'b1;
        endcase
      end

      // ---------------------------------------------------------------- LOAD
      7'b0000011: begin
        ctrl.imm_sel = IMM_I;
        ctrl.is_load = 1'b1;
        ctrl.reg_we  = 1'b1;
        ctrl.wb_sel  = WB_MEM;
        ctrl.alu_op  = ALU_ADD;
        unique case (funct3)
          3'b000: begin ctrl.mem_size = MSZ_B; ctrl.mem_uns = 1'b0; end
          3'b001: begin ctrl.mem_size = MSZ_H; ctrl.mem_uns = 1'b0; end
          3'b010: begin ctrl.mem_size = MSZ_W; ctrl.mem_uns = 1'b0; end
          3'b011: begin ctrl.mem_size = MSZ_D; ctrl.mem_uns = 1'b0; end
          3'b100: begin ctrl.mem_size = MSZ_B; ctrl.mem_uns = 1'b1; end
          3'b101: begin ctrl.mem_size = MSZ_H; ctrl.mem_uns = 1'b1; end
          3'b110: begin ctrl.mem_size = MSZ_W; ctrl.mem_uns = 1'b1; end
          default: ctrl.illegal = 1'b1;
        endcase
      end

      // --------------------------------------------------------------- STORE
      7'b0100011: begin
        ctrl.imm_sel = IMM_S;
        ctrl.is_store = 1'b1;
        ctrl.alu_op  = ALU_ADD;
        unique case (funct3)
          3'b000: ctrl.mem_size = MSZ_B;
          3'b001: ctrl.mem_size = MSZ_H;
          3'b010: ctrl.mem_size = MSZ_W;
          3'b011: ctrl.mem_size = MSZ_D;
          default: ctrl.illegal = 1'b1;
        endcase
      end

      // -------------------------------------------------------------- OP-IMM
      7'b0010011: begin
        ctrl.imm_sel = IMM_I;
        ctrl.reg_we  = 1'b1;
        unique case (funct3)
          3'b000: ctrl.alu_op = ALU_ADD;                       // addi
          3'b010: ctrl.alu_op = ALU_SLT;                       // slti
          3'b011: ctrl.alu_op = ALU_SLTU;                      // sltiu
          3'b100: ctrl.alu_op = ALU_XOR;                       // xori
          3'b110: ctrl.alu_op = ALU_OR;                        // ori
          3'b111: ctrl.alu_op = ALU_AND;                       // andi
          3'b001: begin
            unique case (funct6)
              6'b000000: ctrl.alu_op = ALU_SLL;                // slli
              6'b011000: begin                                 // clz/ctz/cpop/sext.b/sext.h
                unique case (rs2f)
                  5'd0:    ctrl.alu_op = ALU_CLZ;
                  5'd1:    ctrl.alu_op = ALU_CTZ;
                  5'd2:    ctrl.alu_op = ALU_CPOP;
                  5'd4:    ctrl.alu_op = ALU_SEXTB;
                  5'd5:    ctrl.alu_op = ALU_SEXTH;
                  default: ctrl.illegal = 1'b1;
                endcase
              end
              6'b001010: ctrl.alu_op = ALU_BSET;               // bseti
              6'b010010: ctrl.alu_op = ALU_BCLR;               // bclri
              6'b011010: ctrl.alu_op = ALU_BINV;               // binvi
              default:   ctrl.illegal = 1'b1;
            endcase
          end
          default: begin                                        // funct3 == 101
            unique case (imm12)
              12'h287:  ctrl.alu_op = ALU_ORCB;                // orc.b
              12'h6B8:  ctrl.alu_op = ALU_REV8;                // rev8
              default: begin
                unique case (funct6)
                  6'b000000: ctrl.alu_op = ALU_SRL;            // srli
                  6'b010000: ctrl.alu_op = ALU_SRA;            // srai
                  6'b011000: ctrl.alu_op = ALU_ROR;            // rori
                  6'b010010: ctrl.alu_op = ALU_BEXT;           // bexti
                  default:   ctrl.illegal = 1'b1;
                endcase
              end
            endcase
          end
        endcase
      end

      // ------------------------------------------------------------------ OP
      7'b0110011: begin
        ctrl.reg_we = 1'b1;
        unique case (funct7)
          7'b0000000: begin
            unique case (funct3)
              3'b000: ctrl.alu_op = ALU_ADD;
              3'b001: ctrl.alu_op = ALU_SLL;
              3'b010: ctrl.alu_op = ALU_SLT;
              3'b011: ctrl.alu_op = ALU_SLTU;
              3'b100: ctrl.alu_op = ALU_XOR;
              3'b101: ctrl.alu_op = ALU_SRL;
              3'b110: ctrl.alu_op = ALU_OR;
              3'b111: ctrl.alu_op = ALU_AND;
            endcase
          end
          7'b0100000: begin
            unique case (funct3)
              3'b000: ctrl.alu_op = ALU_SUB;
              3'b101: ctrl.alu_op = ALU_SRA;
              3'b111: ctrl.alu_op = ALU_ANDN;                  // Zbb
              3'b110: ctrl.alu_op = ALU_ORN;                   // Zbb
              3'b100: ctrl.alu_op = ALU_XNOR;                  // Zbb
              default: ctrl.illegal = 1'b1;
            endcase
          end
          7'b0000001: begin                                    // RV64M
            ctrl.is_mdu = 1'b1;
            ctrl.reg_we = 1'b1;
            ctrl.alu_op = ALU_PASS_A;
            ctrl.mdu_op = funct3;
          end
          7'b0000101: begin                                    // min/max (Zbb), clmul (Zbc)
            unique case (funct3)
              3'b001: ctrl.alu_op = ALU_CLMUL;                 // clmul
              3'b010: ctrl.alu_op = ALU_CLMULR;                // clmulr
              3'b011: ctrl.alu_op = ALU_CLMULH;                // clmulh
              3'b100: ctrl.alu_op = ALU_MIN;
              3'b101: ctrl.alu_op = ALU_MINU;
              3'b110: ctrl.alu_op = ALU_MAX;
              3'b111: ctrl.alu_op = ALU_MAXU;
              default: ctrl.illegal = 1'b1;
            endcase
          end
          7'b0010100: begin                                    // Zbs
            unique case (funct3)
              3'b001: ctrl.alu_op = ALU_BSET;
              3'b101: ctrl.alu_op = ALU_BEXT;
              default: ctrl.illegal = 1'b1;
            endcase
          end
          7'b0100100: begin                                    // Zbs
            unique case (funct3)
              3'b001: ctrl.alu_op = ALU_BCLR;
              3'b101: ctrl.alu_op = ALU_BEXT;
              default: ctrl.illegal = 1'b1;
            endcase
          end
          7'b0110100: begin                                    // Zbs
            if (funct3 == 3'b001) ctrl.alu_op = ALU_BINV;
            else                  ctrl.illegal = 1'b1;
          end
          7'b0110000: begin                                    // rol/ror
            unique case (funct3)
              3'b001: ctrl.alu_op = ALU_ROL;
              3'b101: ctrl.alu_op = ALU_ROR;
              default: ctrl.illegal = 1'b1;
            endcase
          end
          7'b0000100: begin                                    // zext.h
            if ((funct3 == 3'b100) && (rs2f == 5'd0)) ctrl.alu_op = ALU_ZEXTH;
            else                                     ctrl.illegal = 1'b1;
          end
          7'b0010000: begin                                    // Zba
            unique case (funct3)
              3'b010: ctrl.alu_op = ALU_SH1ADD;
              3'b100: ctrl.alu_op = ALU_SH2ADD;
              3'b110: ctrl.alu_op = ALU_SH3ADD;
              default: ctrl.illegal = 1'b1;
            endcase
          end
          7'b0000111: begin                                    // Zicond
            unique case (funct3)
              3'b101: ctrl.alu_op = ALU_CZERO_EQZ;
              3'b111: ctrl.alu_op = ALU_CZERO_NEZ;
              default: ctrl.illegal = 1'b1;
            endcase
          end
          default: ctrl.illegal = 1'b1;
        endcase
      end

      // ----------------------------------------------------------- OP-IMM-32
      7'b0011011: begin
        ctrl.imm_sel = IMM_I;
        ctrl.reg_we  = 1'b1;
        unique case (funct3)
          3'b000: ctrl.alu_op = ALU_ADDW;                      // addiw
          3'b001: begin
            if (funct6 == 6'b000000)      ctrl.alu_op = ALU_SLLW;    // slliw
            else if (funct6 == 6'b000010) ctrl.alu_op = ALU_SLLIUW;  // slli.uw
            else                          ctrl.illegal = 1'b1;
          end
          3'b101: begin                                        // srliw / sraiw
            unique case (funct6)
              6'b000000: ctrl.alu_op = ALU_SRLW;               // srliw
              6'b010000: ctrl.alu_op = ALU_SRAW;               // sraiw
              default:   ctrl.illegal = 1'b1;
            endcase
          end
          // funct3 = 010/011/100/110/111 are reserved: a `default` arm here
          // would silently accept them (funct3=7 decoded as srliw)
          default: ctrl.illegal = 1'b1;
        endcase
      end

      // -------------------------------------------------------------- OP-32
      7'b0111011: begin
        ctrl.reg_we = 1'b1;
        unique case (funct7)
          7'b0000000: begin
            unique case (funct3)
              3'b000: ctrl.alu_op = ALU_ADDW;
              3'b001: ctrl.alu_op = ALU_SLLW;
              3'b101: ctrl.alu_op = ALU_SRLW;
              default: ctrl.illegal = 1'b1;
            endcase
          end
          7'b0100000: begin
            unique case (funct3)
              3'b000: ctrl.alu_op = ALU_SUBW;
              3'b101: ctrl.alu_op = ALU_SRAW;
              default: ctrl.illegal = 1'b1;
            endcase
          end
          7'b0000100: begin                                    // add.uw / zext.h
            if (funct3 == 3'b000)      ctrl.alu_op = ALU_ADDUW;
            else if (funct3 == 3'b100 && rs2f == 5'd0) ctrl.alu_op = ALU_ZEXTH;
            else                       ctrl.illegal = 1'b1;
          end
          7'b0110000: begin                                    // rolw / rorw
            unique case (funct3)
              3'b001: ctrl.alu_op = ALU_ROLW;
              3'b101: ctrl.alu_op = ALU_RORW;
              default: ctrl.illegal = 1'b1;
            endcase
          end
          default: ctrl.illegal = 1'b1;
        endcase
      end

      // ------------------------------------------------------------ MISC-MEM
      7'b0001111: begin
        // fence / fence.i / pause are accepted as ordering no-ops; the memory
        // model is strongly ordered for a single hart.
        ctrl.is_fence = 1'b1;
        if (funct3 > 3'b001) ctrl.illegal = 1'b1;
      end

      // -------------------------------------------------------------- SYSTEM
      7'b1110011: begin
        if (funct3 == 3'b000) begin
          unique case (imm12)
            12'h000: ctrl.is_ecall  = 1'b1;
            12'h001: ctrl.is_ebreak = 1'b1;
            12'h302: ctrl.is_mret   = 1'b1;
            12'h105: ctrl.is_wfi    = 1'b1;
            default: ctrl.illegal   = 1'b1;
          endcase
        end else begin
          // CSR instructions
          ctrl.is_csr   = 1'b1;
          ctrl.csr_addr = imm12;
          ctrl.reg_we   = 1'b1;
          ctrl.wb_sel   = WB_CSR;
          ctrl.alu_op   = ALU_PASS_A;
          ctrl.imm_sel  = (funct3[2]) ? IMM_Z : IMM_I;
          ctrl.csr_imm  = funct3[2];
          unique case (funct3[1:0])
            2'b01: ctrl.csr_op = CSR_RW;
            2'b10: ctrl.csr_op = CSR_RS;
            2'b11: ctrl.csr_op = CSR_RC;
            default: ctrl.illegal = 1'b1;
          endcase
        end
      end

      // ------------------------------------------------------- custom-0: numeric
      7'b0001011: begin
        // funct7[4:0] selects the numeric operation, funct3 the format.
        // rd/rs1/rs2 index the numeric register bank, never the integer file,
        // so reg_we stays low here.
        ctrl.imm_sel = IMM_NONE;
        ctrl.reg_we  = 1'b0;
        if (funct7[6:5] != 2'b00) begin
          ctrl.illegal = 1'b1;
        end else begin
          ctrl.is_num  = 1'b1;
          ctrl.num_op  = funct7[4:0];
          ctrl.num_fmt = funct3;
          // NUM_TOINT lands its result in the integer register file
          if (funct7[4:0] == 5'd18) ctrl.reg_we = 1'b1;
        end
      end

      default: ctrl.illegal = 1'b1;
    endcase

    // Any instruction carrying an immediate uses it as the ALU B operand
    // (I/S/B/J/U/Z forms).  LUI/AUIPC already select it explicitly; this
    // also covers OP-IMM, OP-IMM-32, LOAD, STORE and JALR address generation.
    if (ctrl.imm_sel != IMM_NONE) ctrl.b_sel = B_IMM;
  end

endmodule
`default_nettype wire
