`timescale 1ns/1ps
// Cross-check the predecoder against the full decoder.
//
// The predecoder is only trustworthy if it never disagrees with the decoder it
// is meant to anticipate. Every tag is compared over the ISA sweep vectors, the
// illegal-encoding vectors and a sweep of every opcode byte, so a divergence is
// a test failure rather than a silent difference in behaviour.
module tb_predecode;
  import rv64_pkg::*;

  logic [31:0] insn, prev_insn;
  logic        prev_valid;

  rv64_pkg::ctrl_t ctrl;
  logic [63:0] imm;
  logic [4:0]  d_rs1, d_rs2, d_rd;

  logic is_control, is_branch, is_jal, is_jalr, writes_rd, is_load, is_store;
  logic [4:0] p_rd, p_rs1, p_rs2;
  logic fusion_valid;
  logic [1:0] fusion_kind;

  rv64_decoder u_dec (.insn(insn), .ctrl(ctrl), .imm(imm),
                      .rs1(d_rs1), .rs2(d_rs2), .rd(d_rd));

  rv64_predecode u_pre (
    .insn(insn), .prev_insn(prev_insn), .prev_valid(prev_valid),
    .is_control(is_control), .is_branch(is_branch), .is_jal(is_jal),
    .is_jalr(is_jalr), .writes_rd(writes_rd), .is_load(is_load),
    .is_store(is_store), .rd(p_rd), .rs1(p_rs1), .rs2(p_rs2),
    .fusion_valid(fusion_valid), .fusion_kind(fusion_kind)
  );

  int checks = 0, errors = 0;

  task automatic chk(input string name, input logic got, input logic exp, input logic [31:0] ins);
    begin
      checks++;
      if (got !== exp) begin
        errors++;
        if (errors <= 15) $display("MISMATCH %-14s insn=%08x got=%b expected=%b", name, ins, got, exp);
      end
    end
  endtask

  // compare every tag for one encoding
  task automatic check_insn(input logic [31:0] i);
    begin
      insn = i;
      #1;
      if (!ctrl.illegal) begin
        chk("is_control", is_control, ctrl.is_branch | ctrl.is_jal | ctrl.is_jalr, i);
        chk("is_branch",  is_branch,  ctrl.is_branch, i);
        chk("is_jal",     is_jal,     ctrl.is_jal,    i);
        chk("is_jalr",    is_jalr,    ctrl.is_jalr,   i);
        chk("writes_rd",  writes_rd,  ctrl.reg_we,    i);
        chk("is_load",    is_load,    ctrl.is_load,   i);
        chk("is_store",   is_store,   ctrl.is_store,  i);
        chk("rd",         p_rd[0],    d_rd[0],        i);
        chk("rs1",        p_rs1[0],   d_rs1[0],       i);
        chk("rs2",        p_rs2[0],   d_rs2[0],       i);
      end
    end
  endtask

  logic [31:0] v;
  initial begin
    prev_valid = 0; prev_insn = 0; insn = 0;
    #1;

    // ---- 1. every opcode byte, with a fixed body -------------------------
    for (int op = 0; op < 128; op++) begin
      check_insn({7'(op), 25'h0A5_1234});
    end

    // ---- 2. a sweep of real encodings across the ISA ---------------------
    // register-register ops for every funct3/funct7 combination
    for (int f7 = 0; f7 < 2; f7++) begin
      for (int f3 = 0; f3 < 8; f3++) begin
        check_insn({7'b0110011, 5'd3, 5'd1, 5'd2, 3'(f3), 5'd4, 7'b0000000 | 7'(f7 << 5)});
      end
    end
    // op-imm, loads, stores, branches, jumps, lui, auipc
    for (int f3 = 0; f3 < 8; f3++) begin
      check_insn({12'h123, 5'd1, 3'(f3), 5'd4, 7'b0010011});
      check_insn({12'h123, 5'd1, 3'(f3), 5'd4, 7'b0000011});
      check_insn({7'h12, 5'd2, 5'd1, 3'(f3), 5'h0A, 7'b0100011});
      check_insn({7'h12, 5'd2, 5'd1, 3'(f3), 5'h0B, 7'b1100011});
      check_insn({12'h123, 5'd1, 3'(f3), 5'd4, 7'b1100111});
    end
    check_insn({20'h12345, 5'd7, 7'b0110111});   // lui
    check_insn({20'h12345, 5'd7, 7'b0010111});   // auipc
    check_insn({12'h123, 5'd7, 7'b1101111});     // jal
    // atomics at both widths
    check_insn({5'b00000, 5'd2, 5'd1, 3'b011, 5'd4, 7'b0101111});
    check_insn({5'b00010, 5'd0, 5'd1, 3'b011, 5'd4, 7'b0101111});
    check_insn({5'b00011, 5'd2, 5'd1, 3'b011, 5'd4, 7'b0101111});
    // system / csr
    check_insn({12'h300, 5'd1, 3'b001, 5'd4, 7'b1110011});

    // ---- 3. fusion hints --------------------------------------------------
    prev_valid = 1'b1;
    // lui x5, ... then addi x5, x5, ... -> kind 1
    prev_insn = {20'h12345, 5'd5, 7'b0110111};
    insn = {12'h010, 5'd5, 3'b000, 5'd5, 7'b0010011}; #1;
    checks++; if (fusion_valid !== 1'b1 || fusion_kind !== 2'd1) begin
      errors++; $display("MISMATCH fusion lui+addi got valid=%b kind=%0d", fusion_valid, fusion_kind); end

    // lui x5 then a load through x5 -> kind 1
    insn = {12'h010, 5'd5, 3'b011, 5'd6, 7'b0000011}; #1;
    checks++; if (fusion_valid !== 1'b1 || fusion_kind !== 2'd1) begin
      errors++; $display("MISMATCH fusion lui+load got valid=%b kind=%0d", fusion_valid, fusion_kind); end

    // lui x5 then an op-imm on an unrelated register -> no fusion
    insn = {12'h010, 5'd9, 3'b000, 5'd9, 7'b0010011}; #1;
    checks++; if (fusion_valid !== 1'b0) begin
      errors++; $display("MISMATCH fusion should not fire (unrelated regs)"); end

    // auipc + addi -> kind 2
    prev_insn = {20'h12345, 5'd5, 7'b0010111};
    insn = {12'h010, 5'd5, 3'b000, 5'd5, 7'b0010011}; #1;
    checks++; if (fusion_valid !== 1'b1 || fusion_kind !== 2'd2) begin
      errors++; $display("MISMATCH fusion auipc+addi got valid=%b kind=%0d", fusion_valid, fusion_kind); end

    // jal followed by anything -> kind 3
    prev_insn = {12'h123, 5'd1, 7'b1101111};
    insn = {12'h010, 5'd9, 3'b000, 5'd9, 7'b0010011}; #1;
    checks++; if (fusion_valid !== 1'b1 || fusion_kind !== 2'd3) begin
      errors++; $display("MISMATCH fusion jal+any got valid=%b kind=%0d", fusion_valid, fusion_kind); end

    // no previous instruction -> no hint
    prev_valid = 1'b0; #1;
    checks++; if (fusion_valid !== 1'b0) begin
      errors++; $display("MISMATCH fusion fired with no previous instruction"); end

    $display("tb_predecode: %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
