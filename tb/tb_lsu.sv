`timescale 1ns/1ps
// Directed testbench for the load/store unit.
//
// Built because two attempts at Zicclsm were debugged through the whole core,
// where a failing byte load gives no visibility at all. Here every signal is
// local: the request, the beats on the bus, and the merged result.
//
// Zicclsm requires misaligned loads and stores to work in hardware. An access
// that fits inside one 8-byte beat must be unchanged; one that crosses the
// boundary must be split into two beats and merged.
module tb_lsu;
  import rv64_pkg::*;
  logic        clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        req_start;
  logic [63:0] req_addr, req_wdata;
  logic [2:0]  req_size;
  logic        req_uns, req_we;
  logic [1:0]  req_atomic;
  logic [4:0]  req_amo_op;

  logic        mem_req_valid, mem_req_we;
  logic [63:0] mem_req_addr, mem_req_wdata;
  logic [7:0]  mem_req_wstrb;
  logic        mem_req_ready = 1'b1;
  logic        mem_rsp_valid;
  logic [63:0] mem_rsp_rdata;
  logic        mem_rsp_error = 1'b0;

  logic        busy, done, fault;
  logic [63:0] load_data;

  rv64_lsu u_dut (
    .clk(clk), .rst_n(rst_n),
    .req_start(req_start), .req_addr(req_addr), .req_wdata(req_wdata),
    .req_size(req_size), .req_uns(req_uns), .req_we(req_we),
    .req_atomic(req_atomic), .req_amo_op(req_amo_op),
    .satp(64'd0), .priv(2'd3), .mprv(1'b0), .sum(1'b0), .mxr(1'b0), .pmp_ok(1'b1),
    .mem_req_valid(mem_req_valid), .mem_req_addr(mem_req_addr),
    .mem_req_we(mem_req_we), .mem_req_wdata(mem_req_wdata),
    .mem_req_wstrb(mem_req_wstrb), .mem_req_ready(mem_req_ready),
    .mem_rsp_valid(mem_rsp_valid), .mem_rsp_rdata(mem_rsp_rdata),
    .mem_rsp_error(mem_rsp_error),
    .busy(busy), .done(done), .fault(fault), .load_data(load_data)
  );

  // ---- memory: byte addressable, one response per request -----------------
  logic [7:0] mem [0:4095];
  int         beats = 0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_rsp_valid <= 1'b0;
      mem_rsp_rdata <= 64'd0;
    end else begin
      mem_rsp_valid <= 1'b0;
      if (mem_req_valid && mem_req_ready) begin
        beats <= beats + 1;
        for (int b = 0; b < 8; b++)
          if (mem_req_we && mem_req_wstrb[b])
            mem[(mem_req_addr & ~64'd7) + b] <= mem_req_wdata[8*b +: 8];
        if (!mem_req_we) begin
          mem_rsp_valid <= 1'b1;
          for (int b = 0; b < 8; b++)
            mem_rsp_rdata[8*b +: 8] <= mem[(mem_req_addr & ~64'd7) + b];
        end
      end
    end
  end

  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin
        errors++;
        $display("MISMATCH %-32s got=%h expected=%h", name, got, exp);
      end
    end
  endtask

  // drive one access and wait for done
  task automatic amo(input logic [63:0] a, input logic [2:0] sz,
                     input logic [4:0] op, input logic [63:0] wd);
    begin
      @(posedge clk); #1;
      req_addr = a; req_size = sz; req_uns = 1'b0; req_we = 1'b0; req_wdata = wd;
      req_start = 1'b1; req_atomic = AT_AMO; req_amo_op = op;
      @(posedge clk); #1;
      req_start = 1'b0;
      begin
        int g; g = 0;
        while (!busy && g < 20) begin @(posedge clk); #1; g++; end
        g = 0;
        while (!done && g < 60) begin @(posedge clk); #1; g++; end
        if (g >= 60) begin errors++; $display("MISMATCH amo never completed for %h", a); end
      end
      @(posedge clk); #1;
    end
  endtask

  task automatic access(input logic [63:0] a, input logic [2:0] sz,
                        input logic uns, input logic we, input logic [63:0] wd);
    begin
      @(posedge clk); #1;
      req_addr = a; req_size = sz; req_uns = uns; req_we = we; req_wdata = wd;
      req_start = 1'b1; req_atomic = 2'd0; req_amo_op = 5'd0;
      @(posedge clk); #1;
      req_start = 1'b0;
      begin
        int g; g = 0;
        // wait for the unit to pick the request up before looking for done, or a
        // stale done from the previous access ends the wait immediately
        while (!busy && g < 20) begin @(posedge clk); #1; g++; end
        g = 0;
        while (!done && g < 60) begin @(posedge clk); #1; g++; end
        if (g >= 60) begin errors++; $display("MISMATCH access never completed for %h", a); end
      end
      @(posedge clk); #1;
    end
  endtask

  // expected little-endian value of `nbytes` at `a`
  function automatic logic [63:0] mem_val(input int unsigned a, input int nbytes);
    logic [63:0] v;
    v = 64'd0;
    for (int i = 0; i < 8; i++)
      if (i < nbytes) v[8*i +: 8] = mem[a + i];
    return v;
  endfunction


  initial begin
    req_start = 0; req_addr = 0; req_wdata = 0; req_size = 0;
    req_uns = 0; req_we = 0; req_atomic = 0; req_amo_op = 0;
    for (int i = 0; i < 4096; i++) mem[i] = i[7:0];
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // ---- 1. aligned accesses: unchanged behaviour -----------------------
    access(64'h100, MSZ_B, 1'b1, 1'b0, 64'd0);
    chk("aligned lb 0x100", load_data, 64'h00);
    access(64'h103, MSZ_B, 1'b1, 1'b0, 64'd0);
    chk("aligned lb 0x103", load_data, 64'h03);
    access(64'h100, MSZ_W, 1'b1, 1'b0, 64'd0);
    chk("aligned lw 0x100", load_data, 64'h03020100);
    access(64'h100, MSZ_D, 1'b1, 1'b0, 64'd0);
    chk("aligned ld 0x100", load_data, 64'h0706050403020100);
    access(64'h101, MSZ_H, 1'b1, 1'b0, 64'd0);
    chk("aligned lh 0x101 (unaligned half)", load_data, 64'h00000201);

    // ---- 2. misaligned loads that cross a beat --------------------------
    access(64'h103, MSZ_W, 1'b1, 1'b0, 64'd0);
    chk("misaligned lw 0x103", load_data, mem_val(32'h103, 4));
    access(64'h105, MSZ_D, 1'b1, 1'b0, 64'd0);
    chk("misaligned ld 0x105", load_data, mem_val(32'h105, 8));
    access(64'h10F, MSZ_H, 1'b1, 1'b0, 64'd0);
    chk("misaligned lh 0x10F", load_data, mem_val(32'h10F, 2));

    // ---- 3. misaligned stores that cross a beat -------------------------
    access(64'h203, MSZ_W, 1'b0, 1'b1, 64'hDEADBEEF);
    chk("misaligned sw byte 0x203", {56'd0, mem[32'h203]}, 64'hEF);
    chk("misaligned sw byte 0x204", {56'd0, mem[32'h204]}, 64'hBE);
    chk("misaligned sw byte 0x205", {56'd0, mem[32'h205]}, 64'hAD);
    chk("misaligned sw byte 0x206", {56'd0, mem[32'h206]}, 64'hDE);
    chk("misaligned sw leaves 0x207", {56'd0, mem[32'h207]}, 64'h07);
    access(64'h203, MSZ_W, 1'b1, 1'b0, 64'd0);
    chk("read back misaligned sw", load_data, 64'h000000DEADBEEF);

    // ---- 4. Zabha: byte and halfword AMOs -------------------------------
    // The neighbouring bytes must survive: an AMO that clobbers them is the
    // classic sub-word atomics bug.
    for (int i = 0; i < 8; i++) mem[32'h300 + i] = 8'hA0 + i[7:0];
    amo(64'h303, MSZ_B, 5'b00000, 64'h0000_0000_0000_0005);   // amoadd.b
    chk("amoadd.b result byte", {56'd0, mem[32'h303]}, 64'hA8);   // 0xA3 + 5
    chk("amoadd.b leaves 0x302", {56'd0, mem[32'h302]}, 64'hA2);
    chk("amoadd.b leaves 0x304", {56'd0, mem[32'h304]}, 64'hA4);

    for (int i = 0; i < 8; i++) mem[32'h340 + i] = 8'h10 + i[7:0];
    amo(64'h342, MSZ_H, 5'b00001, 64'h0000_0000_0000_BEEF);   // amoswap.h
    chk("amoswap.h low byte", {56'd0, mem[32'h342]}, 64'hEF);
    chk("amoswap.h high byte", {56'd0, mem[32'h343]}, 64'hBE);
    chk("amoswap.h leaves 0x341", {56'd0, mem[32'h341]}, 64'h11);
    chk("amoswap.h leaves 0x344", {56'd0, mem[32'h344]}, 64'h14);

    // amomax.b with a signed comparison: -1 must win over 1
    mem[32'h380] = 8'hFF;
    amo(64'h380, MSZ_B, 5'b10100, 64'h0000_0000_0000_0001);   // amomax.b
    chk("amomax.b signed", {56'd0, mem[32'h380]}, 64'h01);

    $display("tb_lsu: %0d checks, %0d mismatches (beats=%0d)", checks, errors, beats);
    $display(errors == 0 ? "RESULT: PASS" : "RESULT: FAIL");
    $finish;
  end
endmodule
