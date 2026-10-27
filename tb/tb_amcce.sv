`timescale 1ns/1ps
// Directed testbench for AMCCE: mode selection from the miss rate, and the
// hysteresis that stops it oscillating at the boundary.
module tb_amcce;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        acc_valid, acc_hit, acc_miss;
  logic [1:0]  mode;
  logic        bypass;
  logic        csr_we;
  logic [3:0]  csr_addr;
  logic [63:0] csr_wdata, csr_rdata;
  logic [31:0] total_hits, total_misses, switches;

  rv64_amcce u_a (
    .clk(clk), .rst_n(rst_n),
    .acc_valid(acc_valid), .acc_hit(acc_hit), .acc_miss(acc_miss),
    .mode(mode), .bypass(bypass),
    .csr_we(csr_we), .csr_addr(csr_addr), .csr_wdata(csr_wdata),
    .csr_rdata(csr_rdata),
    .total_hits(total_hits), .total_misses(total_misses), .mode_switches(switches)
  );

  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-42s got=%h expected=%h", name, got, exp); end
    end
  endtask

  task automatic wr(input logic [3:0] a, input logic [63:0] d);
    begin csr_addr = a; csr_wdata = d; csr_we = 1; @(posedge clk); #1; csr_we = 0; #1; end
  endtask

  task automatic rd(input logic [3:0] a, output logic [63:0] d);
    begin csr_addr = a; csr_we = 0; #1; d = csr_rdata; end
  endtask

  // drive `n` accesses with the given hit pattern (1 = hit)
  task automatic accs(input int n, input int n_hits);
    begin
      for (int i = 0; i < n; i++) begin
        acc_valid = 1;
        acc_hit   = (i < n_hits);
        acc_miss  = !(i < n_hits);
        @(posedge clk); #1;
      end
      acc_valid = 0; acc_hit = 0; acc_miss = 0;
      @(posedge clk); #1;
    end
  endtask

  logic [63:0] d;

  initial begin
    acc_valid = 0; acc_hit = 0; acc_miss = 0;
    csr_we = 0; csr_addr = 0; csr_wdata = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---- 1. defaults -----------------------------------------------------
    rd(4'd4, d);
    chk("starts in NORMAL", d, 0);
    rd(4'd1, d);
    chk("default window", d, 64);

    // a short window makes the test quick and the arithmetic checkable
    wr(4'd1, 64'd16);          // window = 16
    wr(4'd2, 64'd75);          // hi = 75%
    wr(4'd3, 64'd25);          // lo = 25%
    wr(4'd0, 64'd1);           // enable

    // ---- 2. a clean window keeps NORMAL ---------------------------------
    accs(16, 16);              // all hits
    rd(4'd4, d);
    chk("all-hit window stays NORMAL", d, 0);

    // ---- 3. a streaming window switches to BYPASS -----------------------
    accs(16, 0);               // all misses
    rd(4'd4, d);
    chk("all-miss window switches to BYPASS", d, 1);
    chk("bypass output follows the mode", bypass, 1'b1);
    rd(4'd7, d);
    chk("one mode switch so far", d, 1);

    // ---- 4. reuse returns it to NORMAL ----------------------------------
    accs(16, 16);
    rd(4'd4, d);
    chk("all-hit window returns to NORMAL", d, 0);
    rd(4'd7, d);
    chk("two mode switches", d, 2);

    // ---- 5. hysteresis: 50% is between the thresholds, so HOLD ----------
    accs(16, 8);               // half hits, half misses
    rd(4'd4, d);
    chk("50% miss rate holds NORMAL (hysteresis)", d, 0);
    accs(16, 8);
    rd(4'd4, d);
    chk("still holding after a second 50% window", d, 0);
    rd(4'd7, d);
    chk("no switch from an in-between rate", d, 2);

    // ---- 6. go to BYPASS, then hold there at 50% ------------------------
    accs(16, 0);
    rd(4'd4, d);
    chk("back to BYPASS on a streaming window", d, 1);
    accs(16, 8);
    rd(4'd4, d);
    chk("50% holds BYPASS (hysteresis both ways)", d, 1);

    // ---- 7. counters -----------------------------------------------------
    rd(4'd5, d);
    chk("total hits counted", d, total_hits);
    rd(4'd6, d);
    chk("total misses counted", d, total_misses);
    chk("hits = 3 all-hit windows + 2 half windows + 1 half window",
        total_hits, 16 + 16 + 8 + 8 + 8);
    chk("misses = two all-miss windows + three half windows",
        total_misses, 16 + 16 + 8 + 8 + 8);

    // ---- 8. disabling freezes the counters ------------------------------
    wr(4'd0, 64'd0);
    accs(8, 8);
    chk("disabled engine ignores accesses", total_hits, 56);

    $display("tb_amcce: %0d checks, %0d mismatches (switches=%0d)", checks, errors, switches);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
