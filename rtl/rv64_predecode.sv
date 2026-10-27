`timescale 1ns/1ps
// =============================================================================
// rv64_predecode.sv -- cheap instruction classification for the front end.
//
// The front end needs three facts about an instruction before the full decoder
// has it: is it a control transfer, does it write a register, and does it pair
// with the previous instruction. This module answers those from the encoding
// alone, with no state and no tables, so it can sit in the fetch path.
//
// The tags are deliberately a SUBSET of what the decoder produces. They are not
// a second decoder: `tb/tb_predecode.sv` cross-checks every tag against the full
// decoder over the ISA sweep vectors, so a disagreement is a test failure rather
// than a silent divergence.
//
// Fusion hints (roadmap item): the pair detector flags sequences a fused
// backend could collapse --
//   1  LUI   + OP-IMM/LOAD/STORE writing the same rd   (the common address build)
//   2  AUIPC + ADDI/JALR using the same rd
//   3  JAL/JALR + anything                             (call/return pairing)
// Only the HINT is produced. No fused execution unit exists: the pipeline still
// issues both instructions. Stating that here rather than implying a fused
// datapath is the point.
// =============================================================================
`default_nettype none

module rv64_predecode (
  input  logic [31:0] insn,
  input  logic [31:0] prev_insn,      // the previously fetched instruction
  input  logic        prev_valid,

  output logic        is_control,     // branch, jal or jalr
  output logic        is_branch,
  output logic        is_jal,
  output logic        is_jalr,
  output logic        writes_rd,
  output logic        is_load,
  output logic        is_store,
  output logic [4:0]  rd,
  output logic [4:0]  rs1,
  output logic [4:0]  rs2,

  output logic        fusion_valid,
  output logic [1:0]  fusion_kind
);

  wire [6:0] opcode = insn[6:0];
  wire [4:0] rd_i   = insn[11:7];
  wire [4:0] rs1_i  = insn[19:15];
  wire [4:0] rs2_i  = insn[24:20];

  assign rd  = rd_i;
  assign rs1 = rs1_i;
  assign rs2 = rs2_i;

  localparam logic [6:0] OP_LUI    = 7'b0110111;
  localparam logic [6:0] OP_AUIPC  = 7'b0010111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;
  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_LOAD   = 7'b0000011;
  localparam logic [6:0] OP_STORE  = 7'b0100011;
  localparam logic [6:0] OP_IMM    = 7'b0010011;
  localparam logic [6:0] OP_REG    = 7'b0110011;
  localparam logic [6:0] OP_ATOMIC = 7'b0101111;
  localparam logic [6:0] OP_SYSTEM = 7'b1110011;

  always_comb begin
    is_branch  = (opcode == OP_BRANCH);
    is_jal     = (opcode == OP_JAL);
    is_jalr    = (opcode == OP_JALR);
    is_control = is_branch | is_jal | is_jalr;
    is_load    = (opcode == OP_LOAD) | (opcode == OP_ATOMIC);
    is_store   = (opcode == OP_STORE);

    // A register write for the classes that have a destination. x0 writes are
    // still reported: the tag says "this class writes rd", and the register
    // file suppresses x0 on its own.
    unique case (opcode)
      OP_LUI, OP_AUIPC, OP_JAL, OP_JALR, OP_LOAD, OP_IMM, OP_REG, OP_ATOMIC:
        writes_rd = 1'b1;
      // SYSTEM covers both the CSR forms, which do write rd, and the privileged
      // ones (ecall/ebreak/mret/wfi), which do not: funct3 == 0 is the split.
      OP_SYSTEM:
        writes_rd = (insn[14:12] != 3'b000);
      default:
        writes_rd = 1'b0;
    endcase
  end

  // ---- fusion hints ---------------------------------------------------------
  wire [6:0] p_opcode = prev_insn[6:0];
  wire [4:0] p_rd     = prev_insn[11:7];

  always_comb begin
    fusion_valid = 1'b0;
    fusion_kind  = 2'd0;
    if (prev_valid) begin
      if (p_opcode == OP_LUI && (opcode == OP_IMM || opcode == OP_LOAD ||
                                 opcode == OP_STORE) && (rd_i == p_rd || rs1_i == p_rd)) begin
        // the classic address build: lui + addi / load / store
        fusion_valid = 1'b1;
        fusion_kind  = 2'd1;
      end else if (p_opcode == OP_AUIPC && (opcode == OP_IMM || opcode == OP_JALR) &&
                   (rd_i == p_rd || rs1_i == p_rd)) begin
        fusion_valid = 1'b1;
        fusion_kind  = 2'd2;
      end else if (p_opcode == OP_JAL || p_opcode == OP_JALR) begin
        fusion_valid = 1'b1;
        fusion_kind  = 2'd3;
      end
    end
  end

endmodule
`default_nettype wire
