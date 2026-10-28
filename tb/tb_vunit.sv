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

  // ---- element memory model ----------------------------------------------
  logic        m_req_valid, m_req_we, m_req_ready, m_rsp_valid;
  logic [63:0] m_req_addr, m_req_wdata, m_rsp_rdata;
  logic [7:0]  m_req_wstrb;
  logic [63:0] mem [0:4095];

  assign m_req_ready = 1'b1;
  logic m_pend;
  assign m_rsp_valid = m_pend;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_pend <= 1'b0; m_rsp_rdata <= 64'd0;
      for (int i = 0; i < 4096; i++) mem[i] <= 64'd0;
    end else begin
      m_pend <= 1'b0;
      if (m_req_valid && m_req_ready) begin
        if (m_req_we) begin
          for (int b = 0; b < 8; b++)
            if (m_req_wstrb[b]) mem[m_req_addr[11:3]][8*b +: 8] <= m_req_wdata[8*b +: 8];
        end else begin
          m_rsp_rdata <= mem[m_req_addr[11:3]];
          m_pend      <= 1'b1;
        end
      end
    end
  end

  rv64_vunit u_v (
    .clk(clk), .rst_n(rst_n),
    .csr_we(csr_we), .csr_addr(csr_addr), .csr_wdata(csr_wdata),
    .csr_rdata(csr_rdata), .insn_count(insn_count), .illegal(illegal),
    .mem_req_valid(m_req_valid), .mem_req_addr(m_req_addr), .mem_req_we(m_req_we),
    .mem_req_wstrb(m_req_wstrb), .mem_req_wdata(m_req_wdata),
    .mem_req_ready(m_req_ready), .mem_rsp_valid(m_rsp_valid),
    .mem_rsp_rdata(m_rsp_rdata), .mem_rsp_error(1'b0)
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

  // wait for a vector walk to start and then finish
  task automatic wait_walk();
    begin
      int g; g = 0;
      while (!u_v.el_walk_q && g < 20) begin @(posedge clk); #1; g++; end
      g = 0;
      while (u_v.el_walk_q && g < 300) begin @(posedge clk); #1; g++; end
      if (g >= 300) begin errors++; $display("MISMATCH walk never finished"); end
      @(posedge clk); #1;
    end
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
  // float: funct3 = 001 (OPFVV)
  function automatic logic [31:0] enc_vv_f(input logic [5:0] fn, input logic [4:0] vs2,
                                           input logic [4:0] vs1, input logic [4:0] vd);
    return {fn, 1'b1, vs2, vs1, 3'b001, vd, 7'b1010111};
  endfunction

  // reduction: funct3 = 010 (OPMVV)
  // vle<n>.v vd, (base)   -- opcode 0000111
  function automatic logic [31:0] enc_vle(input logic [2:0] width, input logic [4:0] vd);
    return {3'd0, 1'b0, 2'b00, 1'b1, 5'd0, 5'd0, width, vd, 7'b0000111};
  endfunction
  // vse<n>.v vs3, (base)  -- opcode 0100111
  function automatic logic [31:0] enc_vse(input logic [2:0] width, input logic [4:0] vs3);
    return {3'd0, 1'b0, 2'b00, 1'b1, 5'd0, 5'd0, width, vs3, 7'b0100111};
  endfunction

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

    // ---- 13. vle8.v: load eight bytes from memory ----------------------
    issue(enc_vset(11'h000));            // e8, vl = 8
    for (int i = 0; i < 8; i++) mem[(64'h100 >> 3)] [8*i +: 8] = 8'h10 + i;
    wr(4'd10, 64'h100);                  // base address
    issue(enc_vle(3'b000, 5'd21));       // vle8.v v21, (base)
    wait_walk();
    get_vreg(5'd21, d);
    chk("vle8.v loaded eight elements", d, 64'h1716_1514_1312_1110);

    // ---- 14. vse8.v: store eight bytes to memory -----------------------
    // v4 holds 1,2,3,...,8 from earlier
    wr(4'd10, 64'h200);
    issue(enc_vse(3'b000, 5'd4));        // vse8.v v4, (base)
    wait_walk();
    chk("vse8.v stored eight elements", mem[(64'h200 >> 3)], 64'h0807_0605_0403_0201);

    // ---- 15. vwadd.vv at e8: four 16-bit results -----------------------
    issue(enc_vset(11'h000));            // e8, vl = 8
    // v4 holds bytes 1..8; only four results fit in a 64-bit register
    issue(enc_vv(6'b110000, 5'd4, 5'd4, 5'd22));   // vwadd.vv v22, v4, v4
    get_vreg(5'd22, d);
    chk("vwadd.vv e8", d, 64'h0008_0006_0004_0002);

    // ---- 16. vwmul.vv at e8 --------------------------------------------
    issue(enc_vv(6'b111000, 5'd4, 5'd4, 5'd23));   // vwmul.vv
    get_vreg(5'd23, d);
    chk("vwmul.vv e8", d, 64'h0010_0009_0004_0001);

    // ---- 17. signed vs unsigned is the discriminator -------------------
    // byte 0 of v24 is 0xFF: -1 signed, 255 unsigned. +1 gives 0 or 256.
    set_vreg(5'd24, 64'h0101_0101_0101_01FF);
    set_vreg(5'd25, 64'h0101_0101_0101_0101);
    issue(enc_vv(6'b110000, 5'd24, 5'd25, 5'd26));  // vwadd.vv  (signed)
    get_vreg(5'd26, d);
    chk("vwadd.vv sign-extends", d, 64'h0002_0002_0002_0000);
    issue(enc_vv(6'b110001, 5'd24, 5'd25, 5'd27));  // vwaddu.vv (unsigned)
    get_vreg(5'd27, d);
    chk("vwaddu.vv zero-extends", d, 64'h0002_0002_0002_0100);

    // ---- 18. vlmul=2: an op spanning two registers ---------------------
    issue(enc_vset(11'h001));            // vsew=0, vlmul=1 -> LMUL 2
    rd(4'd1, d);
    chk("vsetvli LMUL=2 sets vl to 16", d, 16);
    // v4..v5 and v6..v7 hold 1..16
    set_vreg(5'd4, 64'h0807_0605_0403_0201);
    set_vreg(5'd5, 64'h100f_0e0d_0c0b_0a09);
    set_vreg(5'd6, 64'h0807_0605_0403_0201);
    set_vreg(5'd7, 64'h100f_0e0d_0c0b_0a09);
    issue(enc_vv(6'b000000, 5'd4, 5'd6, 5'd8));   // v8..v9 = v4..v5 + v6..v7
    begin
      int g; g = 0;
      while (u_v.grp_walk_q && g < 40) begin @(posedge clk); #1; g++; end
      @(posedge clk); #1;
    end
    get_vreg(5'd8, d);
    chk("vlmul=2 low register", d, 64'h100E_0C0A_0806_0402);
    get_vreg(5'd9, d);
    chk("vlmul=2 high register", d, 64'h201E_1C1A_1816_1412);

    // ---- 19. vnsrl.wi at e8: 16-bit sources, 8-bit results --------------
    issue(enc_vset(11'h000));            // e8, LMUL 1, vl = 8
    // v4 = 0x0807060504030201 -> source elements 0x0201,0x0403,0x0605,0x0807
    issue(enc_vi(6'b101100, 5'd4, 5'd1, 5'd28));  // vnsrl.wi by 1
    get_vreg(5'd28, d);
    chk("vnsrl.wi by 1", d, 64'h0000_0000_0302_0100);

    // ---- 20. arithmetic vs logical is the discriminator ----------------
    // Narrowing keeps only the low byte, so a SMALL shift hides the difference
    // between logical and arithmetic. Source element 0 is 0x8000 (-32768) and the
    // shift is 15: logically 0x8000>>15 = 1, arithmetically -32768>>15 = -1 = 0xFF.
    set_vreg(5'd29, 64'h0000_0000_0000_8000);
    issue(enc_vi(6'b101100, 5'd29, 5'd15, 5'd30)); // vnsrl.wi
    get_vreg(5'd30, d);
    chk("vnsrl stays logical", d, 64'h0000_0000_0000_0001);
    issue(enc_vi(6'b101101, 5'd29, 5'd15, 5'd31)); // vnsra.wi
    get_vreg(5'd31, d);
    chk("vnsra sign-extends", d, 64'h0000_0000_0000_00FF);

    // ---- 21. vnclip rounding: rnu vs truncate on the same input --------
    // source element 0 is 3; >>1 rounds to 2 (rnu) or truncates to 1 (rdn).
    set_vreg(5'd29, 64'h0000_0000_0000_0003);
    wr(4'd11, 64'd0);                            // vxrm = 0, round to nearest up
    issue(enc_vi(6'b101110, 5'd29, 5'd1, 5'd5)); // vnclip.wi by 1
    get_vreg(5'd5, d);
    chk("vnclip rounds up", d, 64'h0000_0000_0000_0002);
    wr(4'd11, 64'd2);                            // vxrm = 2, truncate
    issue(enc_vi(6'b101110, 5'd29, 5'd1, 5'd5));
    get_vreg(5'd5, d);
    chk("vnclip truncates", d, 64'h0000_0000_0000_0001);

    // ---- 22. vnclip saturation ----------------------------------------
    // 0x7FFF does not fit in a signed byte, so it clamps to 127 and sets vxsat.
    wr(4'd5, 64'd0);                             // clear vxsat
    set_vreg(5'd29, 64'h0000_0000_0000_7FFF);
    issue(enc_vi(6'b101110, 5'd29, 5'd0, 5'd5)); // vnclip.wi by 0
    get_vreg(5'd5, d);
    chk("vnclip saturates positive", d, 64'h0000_0000_0000_007F);
    rd(4'd5, d);
    chk("vnclip sets vxsat", d, 64'd1);
    // and the negative side
    set_vreg(5'd29, 64'h0000_0000_0000_8000);
    issue(enc_vi(6'b101110, 5'd29, 5'd0, 5'd5));
    get_vreg(5'd5, d);
    chk("vnclip saturates negative", d, 64'h0000_0000_0000_0080);

    // ---- 23. vslideup.vi by 2: low elements keep their old value --------
    issue(enc_vset(11'h000));            // e8, vl = 8
    // v4 holds bytes 1..8; vd starts at 0xAA so a wrongly-written low element shows
    set_vreg(5'd6, 64'hAAAA_AAAA_AAAA_AAAA);
    issue(enc_vi(6'b001110, 5'd4, 5'd2, 5'd6));   // vslideup.vi v6, v4, 2
    get_vreg(5'd6, d);
    chk("vslideup preserves the low elements", d, 64'h0605_0403_0201_AAAA);

    // ---- 24. vslidedown.vi by 2: past the end becomes zero --------------
    issue(enc_vi(6'b001111, 5'd4, 5'd2, 5'd7));   // vslidedown.vi v7, v4, 2
    get_vreg(5'd7, d);
    chk("vslidedown zero-fills the top", d, 64'h0000_0807_0605_0403);

    // ---- 25. binary32 add / sub / mul ---------------------------------
    issue(enc_vset(11'h010));            // vsew = 2 -> SEW 32, vl = 2
    // v4 = {1.5, 2.5}, v5 = {2.5, 1.5}
    set_vreg(5'd4, {32'h40200000, 32'h3FC00000});
    set_vreg(5'd5, {32'h3FC00000, 32'h40200000});
    issue(enc_vv_f(6'b000000, 5'd4, 5'd5, 5'd6));   // vfadd.vv
    get_vreg(5'd6, d);
    chk("vfadd.vv 1.5+2.5 and 2.5+1.5", d, {32'h40800000, 32'h40800000});
    issue(enc_vv_f(6'b000010, 5'd4, 5'd5, 5'd7));   // vfsub.vv
    get_vreg(5'd7, d);
    chk("vfsub.vv 1.5-2.5 and 2.5-1.5", d, {32'h3F800000, 32'hBF800000});
    // v4 * 2.0 = {3.0, 5.0}
    set_vreg(5'd8, {32'h40000000, 32'h40000000});
    issue(enc_vv_f(6'b100100, 5'd4, 5'd8, 5'd9));   // vfmul.vv
    get_vreg(5'd9, d);
    chk("vfmul.vv 1.5*2 and 2.5*2", d, {32'h40A00000, 32'h40400000});

    // ---- 26. float special cases --------------------------------------
    // special cases at vl = 1, so each is isolated in element 0
    wr(4'd1, 64'd1);
    set_vreg(5'd10, 64'h000000007F800000);           // +inf
    issue(enc_vv_f(6'b000000, 5'd10, 5'd10, 5'd11)); // inf + inf = inf
    get_vreg(5'd11, d);
    chk("inf + inf = inf", d[31:0], 32'h7F800000);
    set_vreg(5'd12, 64'h00000000FF800000);           // -inf
    issue(enc_vv_f(6'b000000, 5'd10, 5'd12, 5'd13)); // inf + -inf = NaN
    get_vreg(5'd13, d);
    chk("inf + -inf = NaN", d[31:0], 32'h7FC00000);
    set_vreg(5'd14, 64'h0000000000000000);           // +0
    set_vreg(5'd15, 64'h0000000080000000);           // -0
    issue(enc_vv_f(6'b000000, 5'd14, 5'd15, 5'd16)); // +0 + -0 = +0
    get_vreg(5'd16, d);
    chk("+0 + -0 = +0", d[31:0], 32'h00000000);
    set_vreg(5'd17, 64'h000000007FC00000);           // NaN
    issue(enc_vv_f(6'b000000, 5'd17, 5'd10, 5'd18)); // NaN + inf = NaN
    get_vreg(5'd18, d);
    chk("NaN propagates", d[31:0], 32'h7FC00000);

    // ---- 27. instruction counter ----------------------------------------
    chk("insn counter", insn_count, 32'd44);

    $display("tb_vunit: %0d checks, %0d mismatches (insns=%0d)", checks, errors, insn_count);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
