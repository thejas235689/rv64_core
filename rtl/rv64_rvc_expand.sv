`timescale 1ns/1ps
// =============================================================================
// rv64_rvc_expand.sv -- RVC (compressed) instruction expansion.
//
// Turns a 16-bit compressed instruction into the 32-bit instruction it is defined
// to be equivalent to, so the existing decoder needs no knowledge of RVC. This is
// the whole of the encoding complexity; wiring it into the pipeline needs
// variable-length fetch, which is a separate job.
//
// Coverage: the RV64C set -- C.ADDI4SPN, C.LW, C.LD, C.SW, C.SD, C.ADDI, C.ADDIW,
// C.LI, C.LUI, C.ADDI16SP, C.SRLI, C.SRAI, C.ANDI, C.SUB, C.XOR, C.OR, C.AND,
// C.SUBW, C.ADDW, C.J, C.BEQZ, C.BNEZ, C.SLLI, C.LWSP, C.LDSP, C.JR, C.MV,
// C.EBREAK, C.JALR, C.ADD, C.SWSP, C.SDSP.
//
// NOT covered: C.FLD/C.FSD and the other floating-point forms (no scalar FP yet),
// and the Zc* family.
// =============================================================================
`default_nettype none

module rv64_rvc_expand (
  input  logic [15:0] cin,      // the 16-bit instruction
  output logic [31:0] cout,     // the 32-bit equivalent
  output logic        illegal,  // not a legal RV64C encoding
  output logic        is_ebreak
);
  // ---- field slices --------------------------------------------------------
  wire [1:0]  op    = cin[1:0];
  wire [2:0]  funct3= cin[15:13];
  wire [4:0]  rd    = cin[11:7];
  wire [4:0]  rs2   = cin[6:2];
  wire [4:0]  rd_p  = {2'b01, cin[4:2]};       // rd' / rs1' / rs2'
  wire [4:0]  rs1_p = {2'b01, cin[9:7]};
  wire [4:0]  rs1   = cin[11:7];
  wire [11:0] b12   = cin[12];

  // ---- immediates ----------------------------------------------------------
  // CI: [12|6:2] sign-extended
  wire [5:0]  ci_imm   = {cin[12], cin[6:2]};
  // C.ADDI4SPN: [10:7|12:11|5|6] zero-extended, scaled by 4
  wire [9:0]  ciw_imm  = {cin[10:7], cin[12:11], cin[5], cin[6], 2'b00};
  // CL/CS word: [5|12:10|6] scaled by 4
  wire [6:0]  clw_imm  = {cin[5], cin[12:10], cin[6], 2'b00};
  // CL/CS double: [6:5|12:10] scaled by 8
  wire [7:0]  cld_imm  = {cin[6:5], cin[12:10], 3'b000};
  // C.LWSP: [3:2|12|6:4] scaled by 4
  wire [7:0]  lwsp_imm = {cin[3:2], cin[12], cin[6:4], 2'b00};
  // C.LDSP: [4:2|12|6:5] scaled by 8
  wire [8:0]  ldsp_imm = {cin[4:2], cin[12], cin[6:5], 3'b000};
  // C.SWSP: [8:7|12:9] scaled by 4
  wire [7:0]  swsp_imm = {cin[8:7], cin[12:9], 2'b00};
  // C.SDSP: [9:7|12:10] scaled by 8
  wire [8:0]  sdsp_imm = {cin[9:7], cin[12:10], 3'b000};
  // C.LUI / C.ADDI16SP share [12|6:2]
  wire [5:0]  lui_imm  = {cin[12], cin[6:2]};
  // C.ADDI16SP: [12|4:3|5|2|6] scaled by 16
  wire [9:0]  sp16_imm = {cin[12], cin[4:3], cin[5], cin[2], cin[6], 4'b0000};
  // C.J / C.BEQZ / C.BNEZ
  // C.J immediate: imm[11|4|9:8|10|6|7|3:1|5]
  // imm[11]=[12], [10]=[8], [9:8]=[10:9], [7]=[6], [6]=[7], [5]=[2],
  // [4]=[11], [3:1]=[5:3], [0]=0
  wire [11:0] cj_imm   = {cin[12], cin[8], cin[10:9], cin[6], cin[7],
                          cin[2], cin[11], cin[5:3], 1'b0};
  wire [20:0] cj_off   = {{9{cj_imm[11]}}, cj_imm};
  // C.BEQZ/BNEZ immediate: imm[8|4:3|7:6|2:1|5], scaled by 2
  wire [12:0] cb_off   = {{5{cin[12]}}, cin[6:5], cin[2], cin[11:10],
                          cin[4:3], 1'b0};

  // ---- expansion -----------------------------------------------------------
  always_comb begin
    cout      = 32'd0;
    illegal   = 1'b0;
    is_ebreak = 1'b0;
    unique case (op)
      // =====================================================================
      2'b00: begin
        unique case (funct3)
          3'b000: begin
            // C.ADDI4SPN with a zero immediate is a reserved encoding
            if (ciw_imm == 10'd0) illegal = 1'b1;
            else cout = {ciw_imm[9:0], 5'd2, 3'b000, rd_p, 7'b0010011};     // C.ADDI4SPN
          end
          3'b010: cout = {clw_imm[6:2], rs1_p, 3'b010, rd_p, 7'b0000011}; // C.LW
          3'b011: cout = {cld_imm[7:3], rs1_p, 3'b011, rd_p, 7'b0000011}; // C.LD
          3'b110: cout = {clw_imm[6:5], rd_p, rs1_p, 3'b010,
                          clw_imm[4:0], 7'b0100011};               // C.SW
          3'b111: cout = {cld_imm[7:5], rd_p, rs1_p, 3'b011,
                          cld_imm[4:0], 7'b0100011};               // C.SD
          default: illegal = 1'b1;                                        // reserved
        endcase
      end
      // =====================================================================
      2'b01: begin
        unique case (funct3)
          3'b000: cout = {{6{ci_imm[5]}}, ci_imm, rd, 3'b000, rd, 7'b0010011}; // C.ADDI
          3'b001: cout = {{6{ci_imm[5]}}, ci_imm, rd, 3'b000, rd, 7'b0011011}; // C.ADDIW
          3'b010: cout = {{6{ci_imm[5]}}, ci_imm, 5'd0, 3'b000, rd, 7'b0010011}; // C.LI
          3'b011: begin
            if (rd == 5'd2)
              cout = {{6{sp16_imm[9]}}, sp16_imm, 5'd2, 3'b000, 5'd2, 7'b0010011}; // C.ADDI16SP
            else
              cout = {{14{lui_imm[5]}}, lui_imm, rd, 7'b0110111};              // C.LUI
          end
          3'b100: begin
            unique case (cin[11:10])
              2'b00: cout = {6'd0, cin[6:2], rs1_p, 3'b101, rs1_p, 7'b0010011}; // C.SRLI
              2'b01: cout = {6'd0, cin[6:2], rs1_p, 3'b101, rs1_p, 7'b0010011}; // C.SRAI
              2'b10: cout = {{6{ci_imm[5]}}, ci_imm, rs1_p, 3'b111, rs1_p, 7'b0010011}; // C.ANDI
              default: begin
                unique case ({cin[12], cin[6:5]})
                  3'b000: cout = {7'd0, rs2, rs1_p, 3'b000, rs1_p, 7'b0110011}; // C.SUB
                  3'b001: cout = {7'd0, rs2, rs1_p, 3'b100, rs1_p, 7'b0110011}; // C.XOR
                  3'b010: cout = {7'd0, rs2, rs1_p, 3'b110, rs1_p, 7'b0110011}; // C.OR
                  3'b011: cout = {7'd0, rs2, rs1_p, 3'b111, rs1_p, 7'b0110011}; // C.AND
                  3'b100: cout = {7'd0, rs2, rs1_p, 3'b000, rs1_p, 7'b0111011}; // C.SUBW
                  3'b101: cout = {7'd0, rs2, rs1_p, 3'b000, rs1_p, 7'b0111011}; // C.ADDW
                  default: illegal = 1'b1;
                endcase
              end
            endcase
          end
          3'b101: cout = {cj_off[20], cj_off[10:1], cj_off[11],
                          cj_off[19:12], 5'd0, 7'b1101111};          // C.J
          3'b110: cout = {cb_off[12], cb_off[10:5], 5'd0, rs1_p, 3'b000,
                          cb_off[4:1], cb_off[11], 7'b1100011};             // C.BEQZ
          3'b111: cout = {cb_off[12], cb_off[10:5], 5'd0, rs1_p, 3'b001,
                          cb_off[4:1], cb_off[11], 7'b1100011};             // C.BNEZ
        endcase
        // the shift-amount forms need [12] = 0 to be the shift form
        if ((funct3 == 3'b100) && (cin[12]) && (cin[11:10] != 2'b11)) illegal = 1'b1;
      end
      // =====================================================================
      2'b10: begin
        unique case (funct3)
          3'b000: cout = {6'd0, cin[6:2], rd, 3'b001, rd, 7'b0010011};      // C.SLLI
          3'b010: cout = {lwsp_imm[7:2], 5'd2, 3'b010, rd, 7'b0000011};     // C.LWSP
          3'b011: cout = {ldsp_imm[8:3], 5'd2, 3'b011, rd, 7'b0000011};     // C.LDSP
          3'b100: begin
            unique case ({cin[12], rd, rs2})
              {1'b0, 5'd0, 5'd0}: illegal = 1'b1;                            // reserved
              {1'b1, 5'd0, 5'd0}: begin
                cout      = 32'h0010_0073;                                   // C.EBREAK
                is_ebreak = 1'b1;
              end
              default: begin
                if (!cin[12] && (rs2 == 5'd0))
                  cout = {12'd0, rd, 3'b000, 5'd0, 7'b1100111};              // C.JR
                else if (!cin[12])
                  cout = {7'd0, rs2, 5'd0, 3'b000, rd, 7'b0110011};          // C.MV
                else if (rs2 == 5'd0)
                  cout = {12'd0, rd, 3'b000, 5'd1, 7'b1100111};              // C.JALR
                else
                  cout = {7'd0, rs2, rd, 3'b000, rd, 7'b0110011};            // C.ADD
              end
            endcase
          end
          3'b110: cout = {swsp_imm[7:5], cin[6:2], 5'd2, 3'b010,
                          swsp_imm[4:0], 7'b0100011};              // C.SWSP
          3'b111: cout = {sdsp_imm[8:5], cin[6:2], 5'd2, 3'b011,
                          sdsp_imm[4:0], 7'b0100011};              // C.SDSP
          default: illegal = 1'b1;
        endcase
      end
      default: illegal = 1'b1;   // 2'b11 is not a compressed instruction
    endcase
  end
endmodule
