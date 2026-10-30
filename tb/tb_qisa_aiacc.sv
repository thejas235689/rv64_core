`timescale 1ns/1ps
// Self-checking testbench for the QISA qubit model and the INT8 accelerator.
// Every check is against a hand-computed expected value.
module tb_qisa_aiacc;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // ---- QISA ----
  logic        q_we;
  logic [3:0]  q_addr;
  logic [63:0] q_wdata, q_rdata;

  // ---- AI accelerator ----
  logic        a_we;
  logic [3:0]  a_addr;
  logic [63:0] a_wdata, a_rdata;

  rv64_qisa  u_q (.clk(clk), .rst_n(rst_n), .csr_we(q_we), .csr_addr(q_addr),
                  .csr_wdata(q_wdata), .csr_rdata(q_rdata));
  rv64_aiacc u_a (.clk(clk), .rst_n(rst_n), .csr_we(a_we), .csr_addr(a_addr),
                  .csr_wdata(a_wdata), .csr_rdata(a_rdata));

  int errors = 0;
  int checks = 0;

  task automatic qwr(input logic [3:0] addr, input logic [63:0] data);
    begin q_we = 1; q_addr = addr; q_wdata = data; @(posedge clk); #1; q_we = 0; end
  endtask

  task automatic awr(input logic [3:0] addr, input logic [63:0] data);
    begin a_we = 1; a_addr = addr; a_wdata = data; @(posedge clk); #1; a_we = 0; end
  endtask

  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin
        errors++;
        $display("MISMATCH %-28s got=%h expected=%h", name, got, exp);
      end
    end
  endtask

  // qubit i state slice
  function automatic logic [2:0] qs(input int i);
    return q_rdata[3*i +: 3];
  endfunction

  task automatic qstate(input logic [63:0] exp);
    begin q_addr = 4'd4; #1; chk("QISA state", q_rdata[23:0], exp); end
  endtask

  // op encoding: {ctl, tgt, q, op}
  function automatic logic [63:0] qcmd(input logic [3:0] op, input logic [3:0] q,
                                       input logic [3:0] tgt, input logic [3:0] ctl);
    return {48'd0, ctl, tgt, q, op};
  endfunction

  initial begin
    q_we = 0; q_addr = 0; q_wdata = 0;
    a_we = 0; a_addr = 0; a_wdata = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // =====================================================================
    // QISA
    // =====================================================================
    qwr(4'd0, 64'h1);                 // enable

    qwr(4'd2, qcmd(4'd7, 0, 0, 0));   // RESET_ALL
    qstate(24'd0);

    qwr(4'd2, qcmd(4'd2, 0, 0, 0));   // X on q0 -> value 1
    qstate(24'h000001);

    qwr(4'd2, qcmd(4'd4, 0, 0, 0));   // H on q0 -> superposed, value still 1
    qstate(24'h000003);

    qwr(4'd2, qcmd(4'd4, 0, 0, 0));   // H again -> H.H = identity
    qstate(24'h000001);

    qwr(4'd2, qcmd(4'd3, 0, 0, 0));   // Z on q0 -> phase set
    qstate(24'h000005);

    qwr(4'd2, qcmd(4'd1, 0, 0, 0));   // RESET q0
    qstate(24'd0);

    // CNOT with a definite control: q1 = 1, target q2 flips 0 -> 1
    qwr(4'd2, qcmd(4'd2, 4'd1, 0, 0));            // X on q1
    qwr(4'd2, qcmd(4'd5, 4'd1, 4'd2, 4'd1));      // CNOT ctl=q1 tgt=q2
    // q1 slice is bits 3..5 (value at bit 3 = 0x08), q2 slice is bits 6..8
    // (value at bit 6 = 0x40): the RTL was right and this expectation was not
    qstate(24'h000048);

    // CNOT with a superposed control marks the target superposed
    qwr(4'd2, qcmd(4'd7, 0, 0, 0));               // RESET_ALL
    qwr(4'd2, qcmd(4'd4, 4'd3, 0, 0));            // H on q3 -> superposed
    qwr(4'd2, qcmd(4'd5, 4'd3, 4'd4, 4'd1));      // CNOT ctl=q3 tgt=q4
    // q3 superposed is bit 10 (0x400), q4 superposed is bit 13 (0x2000)
    qstate(24'h002400);

    // MEASURE on a definite qubit returns its value and counts
    qwr(4'd2, qcmd(4'd7, 0, 0, 0));
    qwr(4'd2, qcmd(4'd2, 4'd5, 0, 0));            // X on q5
    qwr(4'd2, qcmd(4'd6, 4'd5, 0, 0));            // MEASURE q5 -> 1
    q_addr = 4'd5; #1;
    chk("QISA measure value", q_rdata[7:0], 8'h01);
    chk("QISA measure mask", q_rdata[15:8], 8'h20);
    chk("QISA measure count", q_rdata[31:16], 16'd1);

    // MEASURE on a superposed qubit collapses it
    qwr(4'd2, qcmd(4'd7, 0, 0, 0));
    qwr(4'd2, qcmd(4'd4, 4'd6, 0, 0));            // H on q6
    qwr(4'd2, qcmd(4'd6, 4'd6, 0, 0));            // MEASURE q6
    q_addr = 4'd4; #1;
    chk("QISA collapse clears superposed", q_rdata[3*6+1 +: 1], 1'b0);

    // =====================================================================
    // AI accelerator: C = A x B with B = identity, so C must equal A
    // =====================================================================
    for (int i = 0; i < 16; i++) begin
      awr(4'd1, {59'd0, 1'b0, i[3:0]});           // select A, element i
      awr(4'd2, {56'd0, 8'(i + 1)});              // A[i] = i+1
    end
    for (int i = 0; i < 4; i++) begin
      for (int j = 0; j < 4; j++) begin
        awr(4'd1, {59'd0, 1'b1, 4'(i*4 + j)});    // select B
        awr(4'd2, {56'd0, 8'((i == j) ? 1 : 0)}); // identity
      end
    end
    awr(4'd0, 64'h1);                              // start
    @(posedge clk); #1;
    a_addr = 4'd0; #1;
    chk("AIACC done", a_rdata[1], 1'b1);
    for (int i = 0; i < 16; i++) begin
      awr(4'd1, {59'd0, 1'b0, i[3:0]});   // clock the index in, then read
      a_addr = 4'd2; #1;
      chk("AIACC C=A*I", a_rdata[31:0], 32'(i + 1));
    end

    // all-ones A and B: every C element is 4
    for (int i = 0; i < 16; i++) begin
      awr(4'd1, {59'd0, 1'b0, i[3:0]}); awr(4'd2, 64'h1);
      awr(4'd1, {59'd0, 1'b1, i[3:0]}); awr(4'd2, 64'h1);
    end
    awr(4'd0, 64'h1); @(posedge clk); #1;
    for (int i = 0; i < 16; i++) begin
      awr(4'd1, {59'd0, 1'b0, i[3:0]});
      a_addr = 4'd2; #1;
      chk("AIACC ones*ones=4", a_rdata[31:0], 32'd4);
    end
    a_addr = 4'd4; #1;
    chk("AIACC sum", a_rdata[31:0], 32'd64);

    // signed: A = -1, B = 2 -> every C element is -8
    for (int i = 0; i < 16; i++) begin
      awr(4'd1, {59'd0, 1'b0, i[3:0]}); awr(4'd2, 64'hFF);   // -1
      awr(4'd1, {59'd0, 1'b1, i[3:0]}); awr(4'd2, 64'h02);   // 2
    end
    awr(4'd0, 64'h1); @(posedge clk); #1;
    awr(4'd1, 64'd0);
    a_addr = 4'd2; #1;
    chk("AIACC signed -1*2", a_rdata[63:0], 64'hFFFF_FFFF_FFFF_FFF8);

    $display("tb_qisa_aiacc: %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
