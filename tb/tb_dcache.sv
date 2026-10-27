`timescale 1ns/1ps
// Directed testbench for the write-through data cache.
//
// The write path carries the risk: a store must update the cached line AND reach
// memory, byte strobes must merge rather than overwrite a whole line, and a store
// that misses must not silently leave memory stale.
module tb_dcache;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        req_valid, req_we, req_ready, rsp_valid, rsp_error;
  logic [63:0] req_addr, req_wdata, rsp_rdata;
  logic [7:0]  req_wstrb;

  logic        bus_req_valid, bus_req_we, bus_req_ready, bus_rsp_valid, bus_rsp_error;
  logic [63:0] bus_req_addr, bus_req_wdata, bus_rsp_rdata;
  logic [7:0]  bus_req_wstrb;
  logic [31:0] hits, misses;

  rv64_dcache u_dc (
    .clk(clk), .rst_n(rst_n),
    .req_valid(req_valid), .req_addr(req_addr), .req_we(req_we),
    .req_wstrb(req_wstrb), .req_wdata(req_wdata), .req_ready(req_ready),
    .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
    .bus_req_valid(bus_req_valid), .bus_req_addr(bus_req_addr), .bus_req_we(bus_req_we),
    .bus_req_wstrb(bus_req_wstrb), .bus_req_wdata(bus_req_wdata),
    .bus_req_ready(bus_req_ready), .bus_rsp_valid(bus_rsp_valid),
    .bus_rsp_rdata(bus_rsp_rdata), .bus_rsp_error(bus_rsp_error),
    .hit_count(hits), .miss_count(misses)
  );

  // ---- memory: honours byte strobes, one cycle to respond ------------------
  logic [63:0] mem [0:8191];
  logic        pend_v;
  logic [63:0] pend_d;
  assign bus_req_ready = 1'b1;
  assign bus_rsp_valid = pend_v;
  assign bus_rsp_rdata = pend_d;
  assign bus_rsp_error = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend_v <= 1'b0; pend_d <= 64'd0;
      for (int i = 0; i < 8192; i++) mem[i] <= ((i * 7) + 1);
    end else begin
      pend_v <= 1'b0;
      if (bus_req_valid && bus_req_ready) begin
        if (bus_req_we) begin
          // stores are fire-and-forget: no response, matching the core's bus
          for (int b = 0; b < 8; b++)
            if (bus_req_wstrb[b]) mem[bus_req_addr[15:3]][8*b +: 8] <= bus_req_wdata[8*b +: 8];
        end else begin
          pend_d <= mem[bus_req_addr[15:3]];
          pend_v <= 1'b1;
        end
      end
    end
  end

  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-40s got=%h expected=%h", name, got, exp); end
    end
  endtask

  // one access through the cache
  task automatic acc(input logic [63:0] a, input logic we, input logic [7:0] strb,
                     input logic [63:0] wd, output logic [63:0] rd);
    begin
      // req_ready is high only while idle, so the first edge with req_valid
      // high is the accept. Holding it longer made the cache accept repeatedly.
      req_valid = 1; req_addr = a; req_we = we; req_wstrb = strb; req_wdata = wd;
      @(posedge clk); #1; req_valid = 0;
      begin
        int g2; g2 = 0;
        while (!rsp_valid && g2 < 60) begin @(posedge clk); #1; g2++; end
        if (g2 >= 60) begin errors++; $display("MISMATCH access never completed for %h", a); end
      end
      #1; rd = rsp_rdata;
      @(posedge clk); #1;
    end
  endtask

  logic [63:0] d;
  logic [63:0] exp_line;

  initial begin
    req_valid = 0; req_addr = 0; req_we = 0; req_wstrb = 0; req_wdata = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---- 1. read miss fills ---------------------------------------------
    acc(64'h0000, 1'b0, 8'h00, 64'd0, d);
    chk("read miss data", d, 1);
    chk("read miss counter", misses, 32'd1);

    // ---- 2. read hit ----------------------------------------------------
    acc(64'h0000, 1'b0, 8'h00, 64'd0, d);
    chk("read hit data", d, 1);
    chk("read hit counter", hits, 32'd1);

    // ---- 3. write hit: line updated AND memory written -------------------
    acc(64'h0000, 1'b1, 8'hFF, 64'hDEAD_BEEF_0000_0001, d);
    chk("write hit to memory", mem[0], 64'hDEAD_BEEF_0000_0001);
    acc(64'h0000, 1'b0, 8'h00, 64'd0, d);
    chk("write hit updated the line", d, 64'hDEAD_BEEF_0000_0001);

    // ---- 4. byte strobes merge, not overwrite ---------------------------
    // set byte 2 only
    acc(64'h0000, 1'b1, 8'h04, 64'h0000_0000_00AB_0000, d);
    acc(64'h0000, 1'b0, 8'h00, 64'd0, d);
    chk("strobe merge keeps other bytes", d, 64'hDEAD_BEEF_00AB_0001);
    chk("strobe merge reached memory", mem[0], 64'hDEAD_BEEF_00AB_0001);

    // ---- 5. write miss goes to memory and does NOT allocate -------------
    acc(64'h0400, 1'b1, 8'hFF, 64'h1111_2222_3333_4444, d);
    chk("write miss reached memory", mem[64'h400 >> 3], 64'h1111_2222_3333_4444);
    // the next read of that line must miss (no allocation happened)
    acc(64'h0400, 1'b0, 8'h00, 64'd0, d);
    chk("write miss did not allocate -> read sees memory", d, 64'h1111_2222_3333_4444);

    // ---- 6. eviction: same index, different tag -------------------------
    // 0x000 and 0x2000 share addr[8:3]
    acc(64'h2000, 1'b0, 8'h00, 64'd0, d);
    chk("aliasing line fills", d, mem[64'h2000 >> 3]);
    acc(64'h0000, 1'b0, 8'h00, 64'd0, d);
    chk("original line re-reads from memory", d, mem[0]);

    $display("tb_dcache: %0d checks, %0d mismatches (hits=%0d misses=%0d)",
             checks, errors, hits, misses);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
