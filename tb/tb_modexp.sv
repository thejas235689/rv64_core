`timescale 1ns/1ps
module tb_modexp;
  localparam int W = 2;
  logic clk=0, rst_n=0, start=0, busy, done;
  logic n0inv_we=0; logic [63:0] n0inv_wdata=0; logic [15:0] e_bits=0;
  logic ld_we=0; logic [2:0] ld_sel=0; logic [7:0] ld_addr=0; logic [63:0] ld_wdata=0;
  logic [63:0] r_rdata; logic [7:0] r_addr=0;
  logic [15:0] probe_op; logic probe_op_valid;
  logic m_start, m_done; logic [63:0] m_n0inv;
  logic m_a_we, m_b_we, m_n_we; logic [7:0] m_a_addr, m_b_addr, m_n_addr, m_r_addr;
  logic [63:0] m_a_wdata, m_b_wdata, m_n_wdata, m_r_rdata;
  rv64_montmul #(.WORDS(W)) u_mont (
    .clk(clk), .rst_n(rst_n), .start(m_start), .n0inv(m_n0inv), .busy(), .done(m_done),
    .a_we(m_a_we), .a_addr(m_a_addr), .a_wdata(m_a_wdata),
    .b_we(m_b_we), .b_addr(m_b_addr), .b_wdata(m_b_wdata),
    .n_we(m_n_we), .n_addr(m_n_addr), .n_wdata(m_n_wdata),
    .r_rdata(m_r_rdata), .r_addr(m_r_addr),
    .probe_i(), .probe_t0(), .probe_t1(), .probe_t2(), .probe_t3(),
    .probe_state(), .probe_valid());
  rv64_modexp #(.WORDS(W)) dut (
    .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done),
    .n0inv_we(n0inv_we), .n0inv_wdata(n0inv_wdata), .e_bits(e_bits),
    .ld_we(ld_we), .ld_sel(ld_sel), .ld_addr(ld_addr), .ld_wdata(ld_wdata),
    .r_rdata(r_rdata), .r_addr(r_addr),
    .probe_op(probe_op), .probe_op_valid(probe_op_valid),
    .m_start(m_start), .m_n0inv(m_n0inv), .m_done(m_done),
    .m_a_we(m_a_we), .m_a_addr(m_a_addr), .m_a_wdata(m_a_wdata),
    .m_b_we(m_b_we), .m_b_addr(m_b_addr), .m_b_wdata(m_b_wdata),
    .m_n_we(m_n_we), .m_n_addr(m_n_addr), .m_n_wdata(m_n_wdata),
    .m_r_rdata(m_r_rdata), .m_r_addr(m_r_addr));
  always #5 clk = ~clk;
  integer errors=0, checks=0, fd, i, code;
  logic [63:0] w, exp_res[0:W-1];
  task automatic put(input int sel, input int idx, input logic [63:0] d);
    begin @(posedge clk); ld_we=1; ld_sel=sel[2:0]; ld_addr=idx[7:0]; ld_wdata=d;
          @(posedge clk); ld_we=0; end
  endtask
  initial begin
    repeat (2) @(posedge clk);
    rst_n = 1; @(posedge clk);
    rst_n = 0; repeat (3) @(posedge clk);  // real negedge, BEFORE any loads
    rst_n = 1; repeat (2) @(posedge clk);
    fd = $fopen("vectors_exp.hex","r");
    if (fd==0) begin $display("no vectors"); $finish; end
    for (i=0;i<W;i++) begin code=$fscanf(fd,"%h",w); put(0,i,w); end
    for (i=0;i<W;i++) begin code=$fscanf(fd,"%h",w); put(1,i,w); end
    for (i=0;i<W;i++) begin code=$fscanf(fd,"%h",w); put(2,i,w); end
    for (i=0;i<W;i++) begin code=$fscanf(fd,"%h",w); put(3,i,w); end
    for (i=0;i<W;i++) begin code=$fscanf(fd,"%h",w); put(4,i,w); end
    code=$fscanf(fd,"%h",w); e_bits = w[15:0];
    for (i=0;i<W;i++) begin code=$fscanf(fd,"%h",w); exp_res[i]=w; end
    $fclose(fd);

    start = 1; @(posedge clk); start = 0;
    for (i=0;i<4000;i++) begin
      @(posedge clk); #1;
      if ((i > 30 && i < 34) || (i > 1500 && i < 1504)) $display("  i=%0d m_st=%0d rmem0=%016h acc0=%016h", i, u_mont.state_q, u_mont.rmem[0], dut.acc[0]);
      if (done) i=9999;
    end
    $display("  fin: done=%b op=%0d acc0=%016h rmem0=%016h rst=%b m_st=%0d",
             done, probe_op, dut.acc[0], u_mont.rmem[0], u_mont.rst_n, u_mont.state_q);
    repeat (2) @(posedge clk);
    for (i=0;i<W;i++) begin
      r_addr = i[7:0]; #1; checks=checks+1;
      if (r_rdata !== exp_res[i]) begin errors=errors+1;
        $display("EXP_RES i=%0d got %016h exp %016h", i, r_rdata, exp_res[i]); end
    end
    $display("EXP_RESULT checks=%0d errors=%0d", checks, errors);
    $display(errors==0 ? "MODEXP: PASS" : "MODEXP: FAIL");
    $finish;
  end
endmodule
