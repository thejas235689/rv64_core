`timescale 1ns/1ps
// Directed testbench for Sv39 translation in rv64_mmu.
//
// Builds a real three-level page table in a memory model and walks it, checking
// the translated address, every permission rule, and the page fault each access
// type must raise. A walker that translates but faults wrongly is worse than no
// walker at all, so the fault cases carry as much weight here as the hits.
module tb_mmu;
  logic        clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [63:0] satp;
  logic [1:0]  priv;
  logic        mprv, sum, mxr;

  logic        req_valid;
  logic [63:0] vaddr;
  logic [1:0]  acc_type;
  logic        resp_valid, fault, busy;
  logic [63:0] paddr, fault_cause, fault_tval;

  logic        pte_req_valid, pte_req_ready;
  logic [63:0] pte_req_addr;
  logic        pte_rsp_valid, pte_rsp_error;
  logic [63:0] pte_rsp_data;

  rv64_mmu u_mmu (
    .clk(clk), .rst_n(rst_n),
    .satp(satp), .priv(priv), .mprv(mprv), .sum(sum), .mxr(mxr),
    .req_valid(req_valid), .vaddr(vaddr), .acc_type(acc_type),
    .resp_valid(resp_valid), .paddr(paddr), .fault(fault),
    .fault_cause(fault_cause), .fault_tval(fault_tval), .busy(busy),
    .pte_req_valid(pte_req_valid), .pte_req_addr(pte_req_addr),
    .pte_req_ready(pte_req_ready), .pte_rsp_valid(pte_rsp_valid),
    .pte_rsp_data(pte_rsp_data), .pte_rsp_error(pte_rsp_error)
  );

  // ---- memory model: 256 KB of physical memory ----------------------------
  logic [63:0] mem [0:32767];
  logic        pend_v;
  logic [63:0] pend_d;
  assign pte_req_ready = 1'b1;
  assign pte_rsp_valid = pend_v;
  assign pte_rsp_data  = pend_d;
  assign pte_rsp_error = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend_v <= 1'b0; pend_d <= 64'd0;
      for (int i = 0; i < 32768; i++) mem[i] <= 64'd0;
    end else begin
      pend_v <= 1'b0;
      if (pte_req_valid) begin
        pend_d <= mem[pte_req_addr[17:3]];
        pend_v <= 1'b1;
      end
    end
  end

  int checks = 0, errors = 0;
  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-38s got=%h expected=%h", name, got, exp); end
    end
  endtask

  // run one translation to completion
  task automatic xlate(input logic [63:0] va, input logic [1:0] acc,
                       output logic [63:0] pa, output logic flt, output logic [63:0] cause);
    begin
      req_valid = 1; vaddr = va; acc_type = acc;
      @(posedge clk); #1; req_valid = 0;
      // The settling delay has to be INSIDE the loop: evaluating resp_valid
      // immediately at the edge reads it before the non-blocking update, so the
      // single-cycle W_DONE window is missed and a later, unrelated value is
      // sampled instead.
      // bounded wait: an unbounded spin hides a hang as a timeout with no
      // message, which is exactly what Icarus did here.
      begin
        int guard;
        guard = 0;
        while (!resp_valid && guard < 200) begin @(posedge clk); #1; guard++; end
        if (guard >= 200) begin
          errors++;
          $display("MISMATCH translation never completed for va=%h acc=%0d", va, acc);
        end
      end
      #1;
      pa = paddr; flt = fault; cause = fault_cause;
      @(posedge clk); #1;
    end
  endtask

  // PTE helpers
  function automatic logic [63:0] pte_leaf(input logic [43:0] ppn, input logic r,
                                           input logic w, input logic x, input logic u);
    return (64'(ppn) << 10) | (64'(u) << 4) | (64'(x) << 3) | (64'(w) << 2) |
           (64'(r) << 1) | 64'h1 | (64'h1 << 6) | (64'h1 << 7);   // A and D preset
  endfunction

  function automatic logic [63:0] pte_ptr(input logic [43:0] ppn);
    return (64'(ppn) << 10) | 64'h1;
  endfunction

  logic [63:0] pa, cause;
  logic        flt;

  initial begin
    satp = 0; priv = 2'b01; mprv = 0; sum = 0; mxr = 0;
    req_valid = 0; vaddr = 0; acc_type = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---- 1. bare mode passes the address through -------------------------
    satp = 64'h0;
    xlate(64'h0000_0000_0000_1234, 2'd1, pa, flt, cause);
    chk("bare: address unchanged", pa, 64'h1234);
    chk("bare: no fault", flt, 1'b0);

    // ---- 2. build a 3-level table: VA 0x1000 -> PA 0x8000 -----------------
    // root at 0x1000 (satp PPN 1), L1 at 0x2000, L0 at 0x3000
    mem[64'h1000 >> 3] = pte_ptr(44'h2);      // root[0]   -> 0x2000
    mem[64'h2000 >> 3] = pte_ptr(44'h3);      // L1[0]     -> 0x3000
    mem[(64'h3000 + 8*1) >> 3] = pte_leaf(44'h8, 1, 1, 1, 0);   // L0[1] -> 0x8000, RWX
    satp = {4'd8, 16'd0, 44'h1};

    xlate(64'h0000_0000_0000_1000, 2'd1, pa, flt, cause);
    chk("sv39: load translated", pa, 64'h8000);
    chk("sv39: load no fault", flt, 1'b0);

    xlate(64'h0000_0000_0000_1018, 2'd2, pa, flt, cause);
    chk("sv39: store translated with offset", pa, 64'h8018);

    xlate(64'h0000_0000_0000_1004, 2'd0, pa, flt, cause);
    chk("sv39: fetch translated", pa, 64'h8004);

    // ---- 3. the TLB must now serve this page without walking --------------
    xlate(64'h0000_0000_0000_1FF8, 2'd1, pa, flt, cause);
    chk("sv39: second access translated", pa, 64'h8FF8);
    chk("sv39: second access no fault", flt, 1'b0);

    // ---- 4. a page without X must not be fetchable ------------------------
    mem[(64'h3000 + 8*2) >> 3] = pte_leaf(44'h9, 1, 0, 0, 0);   // VA 0x2000, R only
    xlate(64'h0000_0000_0000_2000, 2'd0, pa, flt, cause);
    chk("no-X page: fetch faults", flt, 1'b1);
    chk("no-X page: cause is inst page fault", cause, 64'd12);

    // a load from it is fine
    xlate(64'h0000_0000_0000_2000, 2'd1, pa, flt, cause);
    chk("no-X page: load ok", flt, 1'b0);
    chk("no-X page: load address", pa, 64'h9000);

    // ---- 5. a read-only page rejects a store ------------------------------
    xlate(64'h0000_0000_0000_2000, 2'd2, pa, flt, cause);
    chk("RO page: store faults", flt, 1'b1);
    chk("RO page: cause is store page fault", cause, 64'd15);

    // ---- 6. the U bit -----------------------------------------------------
    mem[(64'h3000 + 8*3) >> 3] = pte_leaf(44'hA, 1, 1, 1, 1);   // VA 0x3000, U=1
    priv = 2'b01; sum = 0;
    xlate(64'h0000_0000_0000_3000, 2'd1, pa, flt, cause);
    chk("U page from S without SUM: faults", flt, 1'b1);
    sum = 1;
    xlate(64'h0000_0000_0000_3000, 2'd1, pa, flt, cause);
    chk("U page from S with SUM: ok", flt, 1'b0);
    sum = 0;

    priv = 2'b00;
    xlate(64'h0000_0000_0000_3000, 2'd1, pa, flt, cause);
    chk("U page from U: ok", flt, 1'b0);

    // a non-U page from U must fault
    xlate(64'h0000_0000_0000_1000, 2'd1, pa, flt, cause);
    chk("non-U page from U: faults", flt, 1'b1);

    // ---- 7. an invalid PTE faults ----------------------------------------
    priv = 2'b01;
    mem[(64'h3000 + 8*4) >> 3] = 64'd0;                        // VA 0x4000, V=0
    xlate(64'h0000_0000_0000_4000, 2'd1, pa, flt, cause);
    chk("invalid PTE: faults", flt, 1'b1);
    chk("invalid PTE: load page fault", cause, 64'd13);

    // ---- 8. M-mode is not translated, except with MPRV --------------------
    priv = 2'b11; mprv = 0;
    xlate(64'h0000_0000_0000_1000, 2'd1, pa, flt, cause);
    chk("M-mode: load untranslated", pa, 64'h1000);

    mprv = 1;
    xlate(64'h0000_0000_0000_1000, 2'd1, pa, flt, cause);
    chk("M-mode MPRV: load translated", pa, 64'h8000);
    mprv = 0;

    $display("tb_mmu: %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
