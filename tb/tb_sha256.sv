`timescale 1ns/1ps
// Known-answer testbench for SHA-256.
//
// Vectors from the standard: SHA-256("abc") and SHA-256("") -- both are published
// digests, so this checks the core against the algorithm rather than against itself.
module tb_sha256;
  logic         clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic         start, init, busy, done;
  logic [511:0] block;
  logic [255:0] digest;

  rv64_sha256 u_dut (
    .clk(clk), .rst_n(rst_n), .start(start), .init(init),
    .block(block), .busy(busy), .done(done), .digest(digest)
  );

  int checks = 0, errors = 0;

  task automatic chk(input string name, input logic [255:0] got, input logic [255:0] exp);
    begin
      checks++;
      if (got !== exp) begin
        errors++;
        $display("MISMATCH %-28s got=%h expected=%h", name, got, exp);
      end
    end
  endtask

  task automatic hash_block(input logic [511:0] b, input logic do_init);
    begin
      @(posedge clk); #1;
      block = b; init = do_init; start = 1'b1;
      @(posedge clk); #1;
      start = 1'b0; init = 1'b0;
      begin
        int g; g = 0;
        // a stale done from the previous block would end this wait immediately
        while (done && g < 200) begin @(posedge clk); #1; g++; end
        g = 0;
        while (!done && g < 200) begin @(posedge clk); #1; g++; end
        if (g >= 200) begin errors++; $display("MISMATCH hash never finished"); end
      end
    end
  endtask

  initial begin
    start = 1'b0; init = 1'b0; block = 512'd0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // ---- SHA-256("abc") -------------------------------------------------
    // 0x616263, pad 0x80, zeros, then the bit length 24 = 0x18
    begin
      logic [511:0] b;
      b = 512'd0;
      b[511:480] = 32'h61626380;
      b[63:0]    = 64'h0000000000000018;
      hash_block(b, 1'b1);
      chk("sha256(\"abc\")", digest,
          256'hba7816bf_8f01cfea_414140de_5dae2223_b00361a3_96177a9c_b410ff61_f20015ad);
    end

    // ---- SHA-256("") ----------------------------------------------------
    begin
      logic [511:0] b;
      b = 512'd0;
      b[511:504] = 8'h80;
      b[63:0]    = 64'd0;
      hash_block(b, 1'b1);
      chk("sha256(\"\")", digest,
          256'he3b0c442_98fc1c14_9afbf4c8_996fb924_27ae41e4_649b934c_a495991b_7852b855);
    end

    // ---- one block of 64 'a': isolates block 1 from the chaining --------
    begin
      logic [511:0] b;
      b = {64{8'h61}};
      hash_block(b, 1'b1);
      chk("sha256(64 x 'a')", digest,
          256'hffe054fe_7ae0cb6d_c65c3af9_b61d5209_f439851d_b43d0ba5_997337df_154668eb);
    end

    // ---- two-block chaining: 128 bytes of 'a' --------------------------
    // HMAC depends entirely on chaining, so it needs its own known answer.
    begin
      logic [511:0] b;
      b = {64{8'h61}};
      hash_block(b, 1'b1);
      hash_block(b, 1'b0);
      chk("sha256(128 x 'a')", digest,
          256'h6836cf13_bac400e9_105071cd_6af47084_dfacad4e_5e302c94_bfed24e0_13afb73e);
    end

    // ---- chaining: two blocks without init continue the state ----------
    begin
      logic [255:0] first;
      logic [511:0] b;
      b = 512'd0; b[511:480] = 32'h61626380; b[63:0] = 64'h18;
      hash_block(b, 1'b1);
      first = digest;
      b = 512'd0; b[511:504] = 8'h80;
      hash_block(b, 1'b0);                 // no init: state carries over
      chk("chained digest differs", (digest == first) ? 256'd0 : 256'd1, 256'd1);
    end

    $display("tb_sha256: %0d checks, %0d mismatches", checks, errors);
    $display(errors == 0 ? "RESULT: PASS" : "RESULT: FAIL");
    $finish;
  end
endmodule
