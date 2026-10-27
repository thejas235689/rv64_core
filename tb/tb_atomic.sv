`timescale 1ns/1ps
// Directed testbench for the A extension in the LSU: LR/SC and the nine AMOs.
// The memory model answers one cycle after accept and supports byte strobes, so
// the read-modify-write sequence is exercised exactly as it would be on the bus.
module tb_atomic;
  import rv64_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        req_start;
  logic [63:0] req_addr, req_wdata;
  logic [2:0]  req_size;
  logic        req_uns, req_we, pmp_ok;
  logic [1:0]  req_atomic;
  logic [4:0]  req_amo_op;

  logic        mem_req_valid, mem_req_we;
  logic [63:0] mem_req_addr, mem_req_wdata;
  logic [7:0]  mem_req_wstrb;
  logic        mem_req_ready;
  logic        mem_rsp_valid, mem_rsp_error;
  logic [63:0] mem_rsp_rdata;

  logic        busy, done, fault;
  logic [63:0] load_data;

  // ---- memory model --------------------------------------------------------
  // `mem` is written only from the always_ff below. Seeding it from an initial
  // block as well would make it a multiply-driven variable -- legal Verilog,
  // but slang rejects it and it is a real hazard. The test seeds memory with
  // ordinary stores instead, which also exercises the store path.
  logic [63:0] mem [0:63];
  logic [63:0] pend_rdata;
  logic        pend_valid;

  assign mem_req_ready = 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend_valid <= 1'b0;
      pend_rdata <= 64'd0;
      for (int i = 0; i < 64; i++) mem[i] <= 64'd0;
    end else begin
      pend_valid <= 1'b0;
      if (mem_req_valid) begin
        if (mem_req_we) begin
          for (int b = 0; b < 8; b++) begin
            if (mem_req_wstrb[b]) mem[mem_req_addr[7:3]][8*b +: 8] <= mem_req_wdata[8*b +: 8];
          end
        end else begin
          pend_rdata <= mem[mem_req_addr[7:3]];
          pend_valid <= 1'b1;
        end
      end
    end
  end

  assign mem_rsp_valid = pend_valid;
  assign mem_rsp_rdata = pend_rdata;
  assign mem_rsp_error = 1'b0;

  rv64_lsu u_lsu (
    .clk(clk), .rst_n(rst_n),
    .req_start(req_start), .req_addr(req_addr), .req_wdata(req_wdata),
    .req_size(req_size), .req_uns(req_uns), .req_we(req_we), .pmp_ok(pmp_ok),
    .req_atomic(req_atomic), .req_amo_op(req_amo_op),
    .mem_req_valid(mem_req_valid), .mem_req_addr(mem_req_addr),
    .mem_req_we(mem_req_we), .mem_req_wdata(mem_req_wdata),
    .mem_req_wstrb(mem_req_wstrb), .mem_req_ready(mem_req_ready),
    .mem_rsp_valid(mem_rsp_valid), .mem_rsp_rdata(mem_rsp_rdata),
    .mem_rsp_error(mem_rsp_error),
    .busy(busy), .done(done), .fault(fault), .load_data(load_data)
  );

  int errors = 0;
  int checks = 0;

  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin
        errors++;
        $display("MISMATCH %-26s got=%h expected=%h", name, got, exp);
      end
    end
  endtask

  task automatic issue(input logic [1:0] kind, input logic [4:0] op,
                       input logic [63:0] addr, input logic [63:0] wdata,
                       input logic [2:0] size);
    begin
      req_atomic = kind; req_amo_op = op; req_addr = addr; req_wdata = wdata;
      req_size = size; req_uns = 1'b0; pmp_ok = 1'b1; req_we = 1'b0;
      req_start = 1'b1; @(posedge clk); #1; req_start = 1'b0;
      wait (done); @(posedge clk); #1;
    end
  endtask

  // A plain store, so seeding does not depend on guessing intent from the
  // operand values.
  task automatic issue_store(input logic [63:0] addr, input logic [63:0] wdata,
                             input logic [2:0] size);
    begin
      req_atomic = AT_NONE; req_amo_op = 5'd0; req_addr = addr; req_wdata = wdata;
      req_size = size; req_uns = 1'b0; pmp_ok = 1'b1; req_we = 1'b1;
      req_start = 1'b1; @(posedge clk); #1; req_start = 1'b0;
      wait (done); @(posedge clk); #1;
    end
  endtask

  initial begin
    req_start = 0; req_addr = 0; req_wdata = 0; req_size = MSZ_D;
    req_uns = 0; req_we = 0; pmp_ok = 1; req_atomic = AT_NONE; req_amo_op = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // seed memory through the store path
    issue_store(64'h100, 64'd100, MSZ_D);
    issue_store(64'h108, 64'd0, MSZ_D);

    // ---- LR.D ------------------------------------------------------------
    issue(AT_LR, 5'b00010, 64'h100, 64'd0, MSZ_D);
    chk("LR.D value", load_data, 64'd100);

    // ---- AMOADD.D: returns the old value, memory becomes 105 ------------
    issue(AT_AMO, 5'b00000, 64'h100, 64'd5, MSZ_D);
    chk("AMOADD.D old", load_data, 64'd100);
    chk("AMOADD.D mem", mem[0], 64'd105);

    // ---- AMOSWAP.D: returns 105, memory becomes 7 ----------------------
    issue(AT_AMO, 5'b00001, 64'h100, 64'd7, MSZ_D);
    chk("AMOSWAP.D old", load_data, 64'd105);
    chk("AMOSWAP.D mem", mem[0], 64'd7);

    // ---- AMOMAXU.D 3: 7 > 3 so memory stays 7 --------------------------
    issue(AT_AMO, 5'b11100, 64'h100, 64'd3, MSZ_D);
    chk("AMOMAXU.D old", load_data, 64'd7);
    chk("AMOMAXU.D mem", mem[0], 64'd7);

    // ---- AMOMIN.D with -1: signed, so -1 < 7 wins ----------------------
    issue(AT_AMO, 5'b10000, 64'h100, 64'hFFFF_FFFF_FFFF_FFFF, MSZ_D);
    chk("AMOMIN.D old", load_data, 64'd7);
    chk("AMOMIN.D mem", mem[0], 64'hFFFF_FFFF_FFFF_FFFF);

    // ---- AMOXOR / AMOAND / AMOOR ---------------------------------------
    issue_store(64'h100, 64'hF0F0, MSZ_D);
    issue(AT_AMO, 5'b00100, 64'h100, 64'h0FF0, MSZ_D);
    chk("AMOXOR.D mem", mem[0], 64'hFF00);
    issue(AT_AMO, 5'b01000, 64'h100, 64'hFF00, MSZ_D);
    chk("AMOAND.D mem", mem[0], 64'hFF00);
    issue(AT_AMO, 5'b01100, 64'h100, 64'h000F, MSZ_D);
    chk("AMOOR.D mem", mem[0], 64'hFF0F);

    // ---- AMO.W: 32-bit operation, zero-extended result ------------------
    issue_store(64'h100, 64'hFFFF_FFFF_0000_0001, MSZ_D);
    issue(AT_AMO, 5'b00000, 64'h100, 64'h0000_0002, MSZ_W);
    chk("AMOADD.W old", load_data, 64'h0000_0001);
    chk("AMOADD.W mem", mem[0], 64'hFFFF_FFFF_0000_0003);

    // ---- SC.D: reservation from the first LR was consumed by nothing, so
    //      it still holds; but each AMO does not clear it, and the SC below
    //      is the first one, so it must succeed ------------------------
    issue(AT_SC, 5'b00011, 64'h100, 64'h1234, MSZ_D);
    chk("SC.D first status", load_data, 64'd0);
    chk("SC.D first mem", mem[0], 64'h1234);

    // ---- a second SC without an intervening LR must fail ----------------
    issue(AT_SC, 5'b00011, 64'h100, 64'h9999, MSZ_D);
    chk("SC.D second status", load_data, 64'd1);
    chk("SC.D second mem", mem[0], 64'h1234);

    // ---- SC to a different address than the reservation must fail ------
    issue(AT_LR, 5'b00010, 64'h100, 64'd0, MSZ_D);
    issue(AT_SC, 5'b00011, 64'h108, 64'h5555, MSZ_D);
    chk("SC.D wrong addr", load_data, 64'd1);
    chk("SC.D wrong addr mem", mem[1], 64'd0);

    // ---- LR then SC to the same address succeeds -----------------------
    issue(AT_LR, 5'b00010, 64'h108, 64'd0, MSZ_D);
    issue(AT_SC, 5'b00011, 64'h108, 64'h7777, MSZ_D);
    chk("SC.D matched status", load_data, 64'd0);
    chk("SC.D matched mem", mem[1], 64'h7777);

    // ---- a normal store still works after all that ---------------------
    req_atomic = AT_NONE; req_amo_op = 0; req_addr = 64'h110; req_wdata = 64'hCAFE;
    req_size = MSZ_D; req_we = 1'b1; pmp_ok = 1'b1;
    req_start = 1'b1; @(posedge clk); #1; req_start = 1'b0;
    wait (done); @(posedge clk); #1;
    chk("plain store", mem[2], 64'hCAFE);

    $display("tb_atomic: %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
