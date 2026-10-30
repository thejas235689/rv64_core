`timescale 1ns/1ps
// Boot authentication with a keyed MAC.
//
// The case that matters is the third: the RIGHT MAC under the WRONG key must be
// rejected. That is what makes this tamper-resistant rather than
// corruption-detecting -- an attacker who rewrites the image can recompute a plain
// hash, but cannot forge a MAC without the key.
module tb_bootauth_hmac;
  logic         clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic         start, busy, done, boot_ok, boot_fail;
  logic [255:0] key, expected, mac;
  logic [511:0] image;

  rv64_bootauth_hmac u_dut (
    .clk(clk), .rst_n(rst_n), .start(start), .key(key), .image(image),
    .expected(expected), .busy(busy), .done(done),
    .boot_ok(boot_ok), .boot_fail(boot_fail), .mac(mac)
  );

  int checks = 0, errors = 0;
  localparam logic [255:0] RFC_MAC =
    256'hb0344c61_d8db3853_5ca8afce_af0bf12b_881dc200_c9833da7_26e9376c_2e32cff7;

  task automatic chkbit(input string name, input logic got, input logic exp);
    begin
      checks++;
      if (got !== exp) begin
        errors++;
        $display("MISMATCH %-34s got=%b expected=%b", name, got, exp);
      end
    end
  endtask

  task automatic run_auth();
    begin
      @(posedge clk); #1;
      start = 1'b1;
      @(posedge clk); #1;
      start = 1'b0;
      begin
        int g; g = 0;
        while (!done && g < 400) begin @(posedge clk); #1; g++; end
        if (g >= 400) begin errors++; $display("MISMATCH auth never finished"); end
      end
      @(posedge clk); #1;
    end
  endtask

  task automatic reset_dut();
    begin
      rst_n = 1'b0; repeat (3) @(posedge clk);
      rst_n = 1'b1; repeat (2) @(posedge clk);
    end
  endtask

  initial begin
    start = 1'b0;
    key = 256'h0b0b0b0b_0b0b0b0b_0b0b0b0b_0b0b0b0b_0b0b0b0b_00000000_00000000_00000000;
    image = 512'd0;
    image[511:448] = 64'h48692054_68657265;   // "Hi There"
    image[447:440] = 8'h80;
    image[63:0]    = 64'd576;                  // 64-byte key block + 8-byte message
    expected = RFC_MAC;
    reset_dut();

    // ---- 1. right key, right MAC ---------------------------------------
    run_auth();
    chkbit("right key + right MAC boots", boot_ok, 1'b1);
    chkbit("right key + right MAC no fail", boot_fail, 1'b0);

    // ---- 2. right key, wrong MAC ---------------------------------------
    reset_dut();
    expected = RFC_MAC ^ 256'h1;               // one bit different
    run_auth();
    chkbit("wrong MAC is rejected", boot_ok, 1'b0);
    chkbit("wrong MAC raises boot_fail", boot_fail, 1'b1);

    // ---- 3. WRONG key, right MAC: the tamper case ----------------------
    reset_dut();
    expected = RFC_MAC;
    key = 256'h0c0c0c0c_0c0c0c0c_0c0c0c0c_0c0c0c0c_0c0c0c0c_00000000_00000000_00000000;
    run_auth();
    chkbit("wrong key cannot forge a boot", boot_ok, 1'b0);
    chkbit("wrong key raises boot_fail", boot_fail, 1'b1);

    $display("tb_bootauth_hmac: %0d checks, %0d mismatches", checks, errors);
    $display(errors == 0 ? "RESULT: PASS" : "RESULT: FAIL");
    $finish;
  end
endmodule
