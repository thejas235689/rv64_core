`timescale 1ns/1ps
// Directed testbench for XRV512: the register file's lane access and every
// elementwise operation.
module tb_xrv512;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        csr_we;
  logic [3:0]  csr_addr;
  logic [63:0] csr_wdata, csr_rdata;
  logic        busy;
  logic [31:0] op_count;

  rv64_xrv512 u_x (
    .clk(clk), .rst_n(rst_n),
    .csr_we(csr_we), .csr_addr(csr_addr), .csr_wdata(csr_wdata),
    .csr_rdata(csr_rdata), .busy(busy), .op_count(op_count)
  );

  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-34s got=%h expected=%h", name, got, exp); end
    end
  endtask

  task automatic wr(input logic [3:0] a, input logic [63:0] d);
    begin csr_addr = a; csr_wdata = d; csr_we = 1; @(posedge clk); #1; csr_we = 0; #1; end
  endtask

  task automatic rd(input logic [3:0] a, output logic [63:0] d);
    begin csr_addr = a; csr_we = 0; #1; d = csr_rdata; end
  endtask

  // write one lane of a register
  task automatic set_lane(input logic [4:0] reg_i, input logic [2:0] lane, input logic [63:0] v);
    begin
      wr(4'd4, {59'd0, reg_i});
      wr(4'd5, {61'd0, lane});
      wr(4'd6, v);
    end
  endtask

  // read one lane of a register
  task automatic get_lane(input logic [4:0] reg_i, input logic [2:0] lane, output logic [63:0] v);
    begin
      wr(4'd4, {59'd0, reg_i});
      wr(4'd5, {61'd0, lane});
      rd(4'd6, v);
    end
  endtask

  task automatic exec(input logic [3:0] op, input logic [4:0] s1, input logic [4:0] s2,
                      input logic [4:0] d);
    begin
      wr(4'd1, {60'd0, op});
      wr(4'd2, {59'd0, s1});
      wr(4'd3, {59'd0, s2});
      wr(4'd4, {59'd0, d});
      wr(4'd0, 64'd1);          // start
    end
  endtask

  logic [63:0] v;
  logic [63:0] sum;

  initial begin
    csr_we = 0; csr_addr = 0; csr_wdata = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---- 1. load two registers through the lane port ---------------------
    sum = 0;
    for (int l = 0; l < 8; l++) begin
      set_lane(5'd1, l, (l + 1) * 10);       // 10,20,...,80
      set_lane(5'd2, l, (l + 1));            // 1,2,...,8
      sum = sum + (l + 1) * 10;
    end

    // ---- 2. VADD --------------------------------------------------------
    exec(4'd0, 5'd1, 5'd2, 5'd3);
    for (int l = 0; l < 8; l++) begin
      get_lane(5'd3, l, v);
      chk("VADD lane", v, ((l + 1) * 10) + (l + 1));
    end

    // ---- 3. VSUB --------------------------------------------------------
    exec(4'd1, 5'd1, 5'd2, 5'd4);
    get_lane(5'd4, 3'd0, v);
    chk("VSUB lane 0", v, 9);
    get_lane(5'd4, 3'd7, v);
    chk("VSUB lane 7", v, 72);

    // ---- 4. VMUL --------------------------------------------------------
    exec(4'd2, 5'd1, 5'd2, 5'd5);
    get_lane(5'd5, 3'd0, v);
    chk("VMUL lane 0", v, 10);
    get_lane(5'd5, 3'd7, v);
    chk("VMUL lane 7", v, 640);

    // ---- 5. VMINU / VMAXU ----------------------------------------------
    exec(4'd6, 5'd1, 5'd2, 5'd6);
    get_lane(5'd6, 3'd0, v);
    chk("VMINU lane 0", v, 1);
    exec(4'd7, 5'd1, 5'd2, 5'd7);
    get_lane(5'd7, 3'd0, v);
    chk("VMAXU lane 0", v, 10);

    // ---- 6. signed min: -5 vs 3 ----------------------------------------
    set_lane(5'd8, 3'd0, 64'hFFFF_FFFF_FFFF_FFFB);   // -5
    set_lane(5'd9, 3'd0, 64'd3);
    exec(4'd8, 5'd8, 5'd9, 5'd10);
    get_lane(5'd10, 3'd0, v);
    chk("VMINS picks the negative", v, 64'hFFFF_FFFF_FFFF_FFFB);

    // ---- 7. VRED -------------------------------------------------------
    exec(4'd10, 5'd1, 5'd2, 5'd11);
    get_lane(5'd11, 3'd0, v);
    chk("VRED lane 0", v, sum);
    get_lane(5'd11, 3'd1, v);
    chk("VRED other lanes zero", v, 0);

    // ---- 8. op counter --------------------------------------------------
    rd(4'd7, v);
    chk("op counter counts every start", op_count, 32'd8);

    $display("tb_xrv512: %0d checks, %0d mismatches (ops=%0d)", checks, errors, op_count);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
