`timescale 1ns/1ps
// Known-answer testbench for HMAC-SHA-256, RFC 4231 test case 1:
//   key  = 0x0b x 20
//   data = "Hi There"
//   HMAC = b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7
module tb_hmac;
  logic         clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic         start, busy, done;
  logic [255:0] key, mac;
  logic [511:0] msg;

  rv64_hmac u_dut (
    .clk(clk), .rst_n(rst_n), .start(start), .key(key), .msg(msg),
    .busy(busy), .done(done), .mac(mac)
  );

  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic [255:0] got, input logic [255:0] exp);
    begin
      checks++;
      if (got !== exp) begin
        errors++;
        $display("MISMATCH %-24s got=%h expected=%h", name, got, exp);
      end
    end
  endtask

  initial begin
    start = 1'b0; key = 256'd0; msg = 512'd0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // key = 0x0b repeated 20 times, zero padded
    key = 256'h0b0b0b0b_0b0b0b0b_0b0b0b0b_0b0b0b0b_0b0b0b0b_00000000_00000000_00000000;
    // msg = "Hi There" then 0x80, zeros, and the bit length 8*8 = 64
    msg = 512'd0;
    msg[511:448] = 64'h48692054_68657265;
    msg[447:440] = 8'h80;
    msg[63:0]    = 64'd576;   // 64-byte key block + 8-byte message

    @(posedge clk); #1;
    start = 1'b1;
    @(posedge clk); #1;
    start = 1'b0;
    begin
      int g; g = 0;
      while (!done && g < 400) begin @(posedge clk); #1; g++; end
      if (g >= 400) begin errors++; $display("MISMATCH hmac never finished"); end
    end
    @(posedge clk); #1;
    chk("RFC4231 case 1", mac,
        256'hb0344c61_d8db3853_5ca8afce_af0bf12b_881dc200_c9833da7_26e9376c_2e32cff7);

    $display("tb_hmac: %0d checks, %0d mismatches", checks, errors);
    $display(errors == 0 ? "RESULT: PASS" : "RESULT: FAIL");
    $finish;
  end
endmodule
