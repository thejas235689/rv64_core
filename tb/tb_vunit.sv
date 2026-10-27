`timescale 1ns/1ps
// Directed testbench for the RVV subset: vsetvli, elementwise arithmetic across
// SEW, the .vv/.vx/.vi forms, vl truncation and vmv.
module tb_vunit;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        csr_we;
  logic [3:0]  csr_addr;
  logic [63:0] csr_wdata, csr_rdata;
  logic [31:0] insn_count;
  logic        illegal;

  rv64_vunit u_v (
    .clk(clk), .rst_n(rst_n),
    .csr_we(csr_we), .csr_addr(csr_addr), .csr_wdata(csr_wdata),
    .csr_rdata(csr_rdata), .insn_count(insn_count), .illegal(illegal)
  );

  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-40s got=%h expected=%h", name, got, exp); end
    end
  endtask

  task automatic wr(input logic [3:0] a, input logic [63:0] d);
    begin csr_addr = a; csr_wdata = d; csr_we = 1; @(posedge clk); #1; csr_we = 0; #1; end
  endtask

  task automatic rd(input logic [3:0] a, output logic [63:0] d);
    begin csr_addr = a; csr_we = 0; #1; d = csr_rdata; end
  endtask

  task automatic set_vreg(input logic [4:0] r, input logic [63:0] v);
    begin wr(4'd6, {59'd0, r}); wr(4'd7, v); end
  endtask

  task automatic get_vreg(input logic [4:0] r, output logic [63:0] v);
    begin wr(4'd6, {59'd0, r}); rd(4'd6, v); end
  endtask

  task automatic issue(input logic [31:0] insn);
    begin wr(4'd4, {32'd0, insn}); wr(4'd0, 64'd1); end
  endtask

  // ---- instruction builders ------------------------------------------------
  function automatic logic [31:0] enc_vv(input logic [5:0] fn, input logic [4:0] vs2,
                                         input logic [4:0] vs1, input logic [4:0] vd);
    return {fn, 1'b1, vs2, vs1, 3'b000, vd, 7'b1010111};
  endfunction
  // vm = 0 -> masked by v0
  function automatic logic [31:0] enc_vv_m(input logic [5:0] fn, input logic [4:0] vs2,
                                           input logic [4:0] vs1, input logic [4:0] vd);
    return {fn, 1'b0, vs2, vs1, 3'b000, vd, 7'b1010111};
  endfunction
  // reduction: funct3 = 010 (OPMVV)
  function automatic logic [31:0] enc_red(input logic [5:0] fn, input logic [4:0] vs2,
                                          input logic [4:0] vs1, input logic [4:0] vd);
    return {fn, 1'b1, vs2, vs1, 3'b010, vd, 7'b1010111};
  endfunction
  function automatic logic [31:0] enc_vx(input logic [5:0] fn, input logic [4:0] vs2,
                                         input logic [4:0] rs1, input logic [4:0] vd);
    return {fn, 1'b1, vs2, rs1, 3'b100, vd, 7'b1010111};
  endfunction
  function automatic logic [31:0] enc_vi(input logic [5:0] fn, input logic [4:0] vs2,
                                         input logic [4:0] imm, input logic [4:0] vd);
    return {fn, 1'b1, vs2, imm, 3'b011, vd, 7'b1010111};
  endfunction
  function automatic logic [31:0] enc_vset(input logic [10:0] vtypei);
    return {11'd0, vtypei, 5'd0, 3'b111, 5'd0, 7'b1010111};
  endfunction

  logic [63:0] d;
  logic [63:0] exp;

  initial begin
    csr_we = 0; csr_addr = 0; csr_wdata = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---- 1. vsetvli e64 -> vl = 1 ---------------------------------------
    issue(enc_vset(11'h018));            // vsew = 3 (64-bit)
    rd(4'd1, d);
    chk("vsetvli e64 sets vl", d, 1);
    rd(4'd2, d);
    chk("vsetvli e64 sets vtype vsew", d, 8'h18);

    // ---- 2. vadd.vv at SEW=64 -------------------------------------------
    set_vreg(5'd1, 64'd100);
    set_vreg(5'd2, 64'd23);
    issue(enc_vv(6'b000000, 5'd2, 5'd1, 5'd3));   // v3 = v2 + v1
    get_vreg(5'd3, d);
    chk("vadd.vv e64", d, 64'd123);

    // ---- 3. vsetvli e8 -> vl = 8 ----------------------------------------
    issue(enc_vset(11'h000));            // vsew = 0 (8-bit)
    rd(4'd1, d);
    chk("vsetvli e8 sets vl", d, 8);

    // ---- 4. eight byte elements -----------------------------------------
    set_vreg(5'd4, 64'h0807_0605_0403_0201);
    set_vreg(5'd5, 64'h0101_0101_0101_0101);
    issue(enc_vv(6'b000000, 5'd5, 5'd4, 5'd6));   // v6 = v5 + v4
    get_vreg(5'd6, d);
    chk("vadd.vv e8 all lanes", d, 64'h0908_0706_0504_0302);

    // ---- 5. vl truncation: only the first 3 elements written -------------
    wr(4'd1, 64'd3);                     // vl = 3
    set_vreg(5'd7, 64'hFFFF_FFFF_FFFF_FFFF);
    issue(enc_vv(6'b000000, 5'd5, 5'd4, 5'd7));
    get_vreg(5'd7, d);
    chk("vl truncates, tail preserved", d, 64'hFFFF_FFFF_FF04_0302);

    // ---- 6. vadd.vx with a scalar ---------------------------------------
    wr(4'd1, 64'd8);                     // vl = 8 again
    wr(4'd9, 64'h0000_0000_0000_0002);   // scalar = 2
    issue(enc_vx(6'b000000, 5'd4, 5'd9, 5'd8));
    get_vreg(5'd8, d);
    chk("vadd.vx e8", d, 64'h0A09_0807_0605_0403);

    // ---- 7. vadd.vi with an immediate -----------------------------------
    issue(enc_vi(6'b000000, 5'd4, 5'd1, 5'd9));   // +1
    get_vreg(5'd9, d);
    chk("vadd.vi e8", d, 64'h0908_0706_0504_0302);

    // ---- 8. vand / vxor at e8 -------------------------------------------
    set_vreg(5'd10, 64'hFFFF_FFFF_FFFF_FFFF);
    issue(enc_vv(6'b001001, 5'd4, 5'd10, 5'd11));  // v11 = v4 & all-ones
    get_vreg(5'd11, d);
    chk("vand.vv e8", d, 64'h0807_0605_0403_0201);
    issue(enc_vv(6'b001011, 5'd4, 5'd4, 5'd12));   // v12 = v4 ^ v4 = 0
    get_vreg(5'd12, d);
    chk("vxor.vv e8 self", d, 64'd0);

    // ---- 9. vmv.v.v ------------------------------------------------------
    issue(enc_vv(6'b010111, 5'd4, 5'd4, 5'd13));
    get_vreg(5'd13, d);
    chk("vmv.v.v copies", d, 64'h0807_0605_0403_0201);

    // ---- 10. masked vadd: only the selected elements are written ---------
    issue(enc_vset(11'h000));            // e8, vl = 8
    set_vreg(5'd0, 64'h0000_0000_0000_000F);   // v0: elements 0..3 active
    set_vreg(5'd14, 64'h0101_0101_0101_0101);
    set_vreg(5'd15, 64'hFFFF_FFFF_FFFF_FFFF);  // vd starts all-ones
    issue(enc_vv_m(6'b000000, 5'd14, 5'd14, 5'd15));  // v15 += v14, masked
    get_vreg(5'd15, d);
    chk("masking writes only active elements", d, 64'hFFFF_FFFF_0202_0202);

    // ---- 11. vredsum.vs: sum of v4 elements + seed ----------------------
    // v4 = 1,2,3,4,5,6,7,8 -> sum 36; vs1[0] = 4 -> 40
    set_vreg(5'd16, 64'd4);
    issue(enc_red(6'b000000, 5'd4, 5'd16, 5'd17));
    get_vreg(5'd17, d);
    chk("vredsum with a seed", d, 64'd40);

    // ---- 12. vredmaxu / vredminu ----------------------------------------
    issue(enc_red(6'b000110, 5'd4, 5'd16, 5'd18));   // max of v4, seeded 4
    get_vreg(5'd18, d);
    chk("vredmaxu", d, 64'd8);
    set_vreg(5'd19, 64'd200);                        // seed above every element
    issue(enc_red(6'b000100, 5'd4, 5'd19, 5'd20));   // min
    get_vreg(5'd20, d);
    chk("vredminu", d, 64'd1);

    // ---- 13. instruction counter ----------------------------------------
    chk("insn counter", insn_count, 32'd15);

    $display("tb_vunit: %0d checks, %0d mismatches (insns=%0d)", checks, errors, insn_count);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
