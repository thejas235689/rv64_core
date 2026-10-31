`timescale 1ns/1ps
// Compares rv64_montmul against per-iteration intermediates from a Python model.
module tb_montmul;
  localparam int W = 4;
  logic clk = 0, rst_n = 0, start = 0, busy, done;
  logic [63:0] n0inv;
  logic a_we=0, b_we=0, n_we=0;
  logic [7:0] a_addr=0, b_addr=0, n_addr=0, r_addr=0;
  logic [63:0] a_wdata=0, b_wdata=0, n_wdata=0, r_rdata;
  logic [7:0] probe_i; logic [63:0] probe_t0, probe_t1, probe_t2, probe_t3;
  logic probe_valid; logic [2:0] probe_state;

  rv64_montmul #(.WORDS(W)) dut (
    .clk(clk), .rst_n(rst_n), .start(start), .n0inv(n0inv), .busy(busy), .done(done),
    .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata),
    .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata),
    .n_we(n_we), .n_addr(n_addr), .n_wdata(n_wdata),
    .r_rdata(r_rdata), .r_addr(r_addr),
    .probe_i(probe_i), .probe_t0(probe_t0), .probe_t1(probe_t1),
    .probe_t2(probe_t2), .probe_t3(probe_t3),
    .probe_state(probe_state), .probe_valid(probe_valid));
  always #5 clk = ~clk;

  integer errors = 0, checks = 0;
  logic [63:0] exp_t [0:W-1][0:W];
  logic [63:0] exp_r [0:W-1];
  integer fd, i, j, code;
  logic [63:0] w;

  task automatic ld(input int which, input int idx, input logic [63:0] d);
    begin
      @(posedge clk);
      case (which) 0: begin a_we=1; a_addr=idx; a_wdata=d; end
                   1: begin b_we=1; b_addr=idx; b_wdata=d; end
                   2: begin n_we=1; n_addr=idx; n_wdata=d; end endcase
      @(posedge clk); a_we=0; b_we=0; n_we=0;
    end
  endtask

  initial begin
    fd = $fopen("vectors.hex", "r");
    if (fd == 0) begin $display("MONT: no vectors.hex"); $finish; end
    for (i=0;i<W;i++) begin code=$fscanf(fd,"%h",w); ld(0,i,w); end
    for (i=0;i<W;i++) begin code=$fscanf(fd,"%h",w); ld(1,i,w); end
    for (i=0;i<W;i++) begin code=$fscanf(fd,"%h",w); ld(2,i,w); end
    code = $fscanf(fd,"%h",w); n0inv = w;
    // the probe fires once, at FIN: one row of W+1 words
    for (j=0;j<=W;j++) begin
      code = $fscanf(fd,"%h",w); exp_t[0][j] = w;
    end
    for (i=0;i<W;i++) begin code=$fscanf(fd,"%h",w); exp_r[i]=w; end
    $fclose(fd);
    $display("  READ exp_t[0]=%016h %016h %016h %016h %016h",
             exp_t[0][0], exp_t[0][1], exp_t[0][2], exp_t[0][3], exp_t[0][4]);
    $display("  READ exp_r=%016h %016h %016h %016h", exp_r[0], exp_r[1], exp_r[2], exp_r[3]);

    repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
    $display("  LOADED a=%016h %016h %016h %016h", dut.amem[0], dut.amem[1], dut.amem[2], dut.amem[3]);
    $display("  LOADED b=%016h %016h %016h %016h", dut.bmem[0], dut.bmem[1], dut.bmem[2], dut.bmem[3]);
    $display("  LOADED n=%016h %016h %016h %016h", dut.nmem[0], dut.nmem[1], dut.nmem[2], dut.nmem[3]);
    $display("  n0inv=%016h", n0inv);
    start = 1; @(posedge clk); start = 0;

    // capture t[] at every state transition -- this names the PHASE that diverges
    forever begin
      @(posedge clk);
      #1;
      if (probe_state != 3'd0) begin
        $display("  TRACE st=%0d i=%0d t=%016h %016h %016h %016h",
                 probe_state, dut.i_q, probe_t0, probe_t1, probe_t2, probe_t3);
      end
      if (probe_valid && probe_i < W) begin
        checks = checks + 1;
        if (probe_t0 !== exp_t[0][0] || probe_t1 !== exp_t[0][1] ||
            probe_t2 !== exp_t[0][2] || probe_t3 !== exp_t[0][3]) begin
          errors = errors + 1;
          $display("MONT_ITER got %016h %016h %016h %016h", probe_t0, probe_t1, probe_t2, probe_t3);
          $display("           exp %016h %016h %016h %016h",
                   exp_t[0][0], exp_t[0][1], exp_t[0][2], exp_t[0][3]);
        end
      end
      if (done) break;
    end
    repeat (3) @(posedge clk);   // let the FIN write land before reading rmem
    for (i=0;i<W;i++) $display("  t[%0d]=%016h rmem[%0d]=%016h exp=%016h",
                               i, dut.t[i], i, dut.rmem[i], exp_r[i]);
    for (i=0;i<W;i++) begin
      r_addr = i[7:0]; #1; checks = checks + 1;
      if (r_rdata !== exp_r[i]) begin
        errors = errors + 1;
        $display("MONT_RES i=%0d got %016h exp %016h", i, r_rdata, exp_r[i]);
      end
    end
    $display("MONT_RESULT checks=%0d errors=%0d", checks, errors);
    $display(errors==0 ? "MONT: PASS" : "MONT: FAIL");
    $finish;
  end
endmodule
