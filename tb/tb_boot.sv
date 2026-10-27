`timescale 1ns/1ps
// Directed testbench for the boot ROM and the image authenticator.
//
// The expected digest is a KNOWN ANSWER computed independently (FNV-1a-64 over
// the two stub words, least-significant byte first), not read back from the DUT.
module tb_boot;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // ---- ROM -----------------------------------------------------------------
  logic        rom_req_valid, rom_req_ready, rom_rsp_valid, rom_rsp_error;
  logic [63:0] rom_req_addr, rom_rsp_rdata, reset_vector;

  rv64_bootrom u_rom (
    .clk(clk), .rst_n(rst_n),
    .req_valid(rom_req_valid), .req_addr(rom_req_addr), .req_ready(rom_req_ready),
    .rsp_valid(rom_rsp_valid), .rsp_rdata(rom_rsp_rdata), .rsp_error(rom_rsp_error),
    .reset_vector(reset_vector)
  );

  // ---- authenticator -------------------------------------------------------
  logic        start, in_valid, in_ready, busy, boot_ok, boot_fail;
  logic [63:0] expected, in_data, digest;
  logic [31:0] nwords, words_hashed;

  rv64_bootauth u_auth (
    .clk(clk), .rst_n(rst_n),
    .start(start), .expected(expected), .nwords(nwords),
    .in_valid(in_valid), .in_data(in_data), .in_ready(in_ready),
    .busy(busy), .boot_ok(boot_ok), .boot_fail(boot_fail),
    .digest(digest), .words_hashed(words_hashed)
  );

  logic [63:0] d, dg;
  logic        err, dummy_err;
  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-42s got=%h expected=%h", name, got, exp); end
    end
  endtask

  task automatic chk_bit(input string name, input logic got, input logic exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-42s got=%b expected=%b", name, got, exp); end
    end
  endtask

  // read one beat from the ROM
  task automatic rom_read(input logic [63:0] a, output logic [63:0] d, output logic err);
    begin
      rom_req_addr = a; rom_req_valid = 1;
      @(posedge clk); #1; rom_req_valid = 0;
      begin
        int g; g = 0;
        while (!rom_rsp_valid && g < 20) begin @(posedge clk); #1; g++; end
      end
      #1; d = rom_rsp_rdata; err = rom_rsp_error;
      @(posedge clk); #1;
    end
  endtask

  // hash `n` words starting at ROM beat 0
  task automatic hash_rom(input logic [31:0] n, input logic [63:0] exp_digest,
                          output logic [63:0] got_digest);
    begin
      expected = exp_digest; nwords = n; start = 1;
      @(posedge clk); #1; start = 0;
      for (int i = 0; i < n; i++) begin
        rom_read({54'd0, 4'(i), 3'b000}, in_data, dummy_err);
        in_valid = 1;
        begin
          int g; g = 0;
          while (!in_ready && g < 20) begin @(posedge clk); #1; g++; end
        end
        @(posedge clk); #1; in_valid = 0;
      end
      begin
        int g; g = 0;
        while (busy && g < 40) begin @(posedge clk); #1; g++; end
      end
      @(posedge clk); #1;
      got_digest = digest;
    end
  endtask


  initial begin
    rom_req_valid = 0; rom_req_addr = 0;
    start = 0; in_valid = 0; in_data = 0; expected = 0; nwords = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---- 1. reset vector and stub image ---------------------------------
    chk("reset vector", reset_vector, 64'h0000011300000117);

    rom_read(64'h0000, d, err);
    chk("ROM beat 0", d, 64'h0000011300000117);
    chk_bit("ROM beat 0 no error", err, 1'b0);
    rom_read(64'h0008, d, err);
    chk("ROM beat 1", d, 64'h000080E7800000B7);
    rom_read(64'h07F8, d, err);
    chk("last ROM beat in range", d, 64'd0);
    chk_bit("last beat no error", err, 1'b0);
    // out of range must fault
    rom_read(64'h8000_0000_0000_0000, d, err);
    chk_bit("out-of-range read faults", err, 1'b1);

    // ---- 2. known-answer digest over the two stub words -----------------
    hash_rom(2, 64'hf88c4a6e10254d59, dg);
    chk("FNV digest matches the known answer", dg, 64'hf88c4a6e10254d59);
    chk_bit("matching image boots", boot_ok, 1'b1);
    chk_bit("matching image does not fail", boot_fail, 1'b0);
    chk("words hashed", words_hashed, 32'd2);

    // ---- 3. a single-word image has a different digest ------------------
    hash_rom(1, 64'ha9cff5b4ffd6c279, dg);
    chk("one-word digest matches", dg, 64'ha9cff5b4ffd6c279);
    chk_bit("one-word image boots", boot_ok, 1'b1);

    // ---- 4. a wrong expected digest must NOT boot ------------------------
    hash_rom(2, 64'hdead_beef_dead_beef, dg);
    chk_bit("wrong digest refuses to boot", boot_ok, 1'b0);
    chk_bit("wrong digest raises boot_fail", boot_fail, 1'b1);
    chk("digest is still the real one", dg, 64'hf88c4a6e10254d59);

    $display("tb_boot: %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
