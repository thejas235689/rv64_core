// =============================================================================
// tb_xcetask_top.sv -- directed self-checking testbench for rv64_xcetask.
//
// Covers the whole lifecycle: start (explicit and auto-allocated), completion,
// out-of-order completion across slots, timeout expiry, cancel, free, stray
// completions for non-active slots, and the interrupt enable/pending behaviour.
//
//   xezim -s tb_xcetask_top rtl/rv64_xcetask.sv tb/tb_xcetask_top.sv
// =============================================================================
`timescale 1ns/1ps

module tb_xcetask_top;

  localparam int NSLOT = 4;

  logic        clk = 1'b0;
  logic        rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        csr_we;
  logic [3:0]  csr_addr;
  logic [63:0] csr_wdata;
  logic [63:0] csr_rdata;

  logic        start_valid;
  logic [1:0]  start_slot;
  logic [63:0] start_token;
  logic [31:0] start_timeout;

  logic        done_valid;
  logic [1:0]  done_slot;
  logic [63:0] done_result;

  logic        irq;

  int errors = 0;
  int checks = 0;

  // addresses
  localparam logic [3:0] A_CTRL = 4'd0, A_CMD = 4'd1, A_TOKEN = 4'd2,
                        A_TIMEOUT = 4'd3, A_STATUS = 4'd4, A_RESULT = 4'd5,
                        A_DONECNT = 4'd6, A_PENDING = 4'd7, A_TOKRD = 4'd8;
  localparam logic [3:0] OP_START = 4'd1, OP_CANCEL = 4'd2, OP_FREE = 4'd3,
                        OP_CLEARIRQ = 4'd4;

  rv64_xcetask #(.NSLOT(NSLOT), .SLOT_W(2)) dut (
    .clk (clk), .rst_n (rst_n),
    .csr_we (csr_we), .csr_addr (csr_addr), .csr_wdata (csr_wdata),
    .csr_rdata (csr_rdata),
    .start_valid (start_valid), .start_slot (start_slot),
    .start_token (start_token), .start_timeout (start_timeout),
    .done_valid (done_valid), .done_slot (done_slot), .done_result (done_result),
    .irq (irq)
  );

  // ---- helpers -------------------------------------------------------------
  task automatic chk(input string what, input bit [63:0] got, input bit [63:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  MISMATCH %s: got %0h expected %0h", what, got, exp);
    end
  endtask

  task automatic wr(input logic [3:0] a, input logic [63:0] d);
    @(negedge clk);
    csr_we = 1'b1; csr_addr = a; csr_wdata = d;
    @(posedge clk); #1;
    csr_we = 1'b0;
  endtask

  task automatic rd(input logic [3:0] a, output logic [63:0] d);
    @(negedge clk);
    csr_we = 1'b0; csr_addr = a;
    #1;
    d = csr_rdata;
    @(posedge clk);
  endtask

  // issue a START and capture the engine-side start pulse
  task automatic start(input logic [3:0] slot, input logic [63:0] tok,
                       input logic [31:0] tmo,
                       output logic        svalid,
                       output logic [1:0]  sslot,
                       output logic [63:0] stok);
    wr(A_TOKEN, tok);
    wr(A_TIMEOUT, {32'd0, tmo});
    @(negedge clk);
    csr_we = 1'b1; csr_addr = A_CMD;
    csr_wdata = {56'd0, slot, OP_START};
    #1;
    svalid = start_valid;
    sslot  = start_slot;
    stok   = start_token;
    @(posedge clk); #1;
    csr_we = 1'b0;
  endtask

  task automatic complete(input logic [1:0] slot, input logic [63:0] res);
    @(negedge clk);
    done_valid = 1'b1; done_slot = slot; done_result = res;
    @(posedge clk); #1;
    done_valid = 1'b0;
  endtask

  function automatic logic [1:0] slot_state(input logic [63:0] status, input int i);
    return status[2*i +: 2];
  endfunction

  // ---- test ----------------------------------------------------------------
  logic [63:0] st, cnt, res, pend, tok_rd;
  logic        sv;
  logic [1:0]  ss;
  logic [63:0] stk;

  initial begin
    csr_we = 0; csr_addr = 0; csr_wdata = 0;
    done_valid = 0; done_slot = 0; done_result = 0;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // ---- reset state -------------------------------------------------------
    rd(A_STATUS, st);
    chk("reset: all slots idle", {62'd0, slot_state(st, 0)} | {62'd0, slot_state(st, 1)} |
                                 {62'd0, slot_state(st, 2)} | {62'd0, slot_state(st, 3)}, 64'd0);
    rd(A_DONECNT, cnt);  chk("reset: donecnt", cnt, 64'd0);
    chk("reset: irq", {63'd0, irq}, 64'd0);

    // ---- enable + interrupt enable ----------------------------------------
    wr(A_CTRL, 64'h3);
    rd(A_CTRL, st); chk("ctrl readback", st, 64'h3);

    // ---- start slot 0, complete it ----------------------------------------
    start(4'd0, 64'hAAAA, 32'd100, sv, ss, stk);
    chk("start pulse valid",  {63'd0, sv},  64'd1);
    chk("start slot",         {62'd0, ss},  64'd0);
    chk("start token",        stk,          64'hAAAA);
    rd(A_STATUS, st); chk("slot0 active", {62'd0, slot_state(st, 0)}, 64'd1);

    complete(2'd0, 64'h1234);
    rd(A_STATUS, st); chk("slot0 done",   {62'd0, slot_state(st, 0)}, 64'd2);
    rd(A_RESULT, res); chk("slot0 result", res, 64'h1234);
    rd(A_TOKRD,  tok_rd); chk("slot0 token", tok_rd, 64'hAAAA);
    rd(A_DONECNT, cnt); chk("donecnt 1", cnt, 64'd1);
    chk("irq asserted", {63'd0, irq}, 64'd1);

    // ---- clear interrupt, free the slot ----------------------------------
    wr(A_CMD, {56'd0, 4'd0, OP_CLEARIRQ});
    chk("irq cleared", {63'd0, irq}, 64'd0);
    rd(A_PENDING, pend); chk("pending cleared", pend, 64'd0);
    wr(A_CMD, {56'd0, 4'd0, OP_FREE});
    rd(A_STATUS, st); chk("slot0 freed", {62'd0, slot_state(st, 0)}, 64'd0);

    // ---- timeout path -----------------------------------------------------
    start(4'd1, 64'hBBBB, 32'd5, sv, ss, stk);
    chk("timeout: start slot1", {62'd0, ss}, 64'd1);
    repeat (10) @(posedge clk);
    rd(A_STATUS, st); chk("slot1 timed out", {62'd0, slot_state(st, 1)}, 64'd3);
    chk("timeout raises irq", {63'd0, irq}, 64'd1);
    rd(A_DONECNT, cnt); chk("timeout does not count as completion", cnt, 64'd1);
    wr(A_CMD, {56'd0, 4'd1, OP_CLEARIRQ});
    wr(A_CMD, {56'd0, 4'd1, OP_FREE});
    rd(A_STATUS, st); chk("slot1 freed", {62'd0, slot_state(st, 1)}, 64'd0);

    // ---- cancel ----------------------------------------------------------
    start(4'd2, 64'hCCCC, 32'd0, sv, ss, stk);
    rd(A_STATUS, st); chk("slot2 active", {62'd0, slot_state(st, 2)}, 64'd1);
    wr(A_CMD, {56'd0, 4'd2, OP_CANCEL});
    rd(A_STATUS, st); chk("slot2 cancelled", {62'd0, slot_state(st, 2)}, 64'd0);

    // ---- auto-allocation picks the first idle slot -----------------------
    start(4'hF, 64'hDDDD, 32'd50, sv, ss, stk);
    chk("auto-alloc slot", {62'd0, ss}, 64'd0);
    chk("auto-alloc token", stk, 64'hDDDD);
    rd(A_STATUS, st); chk("auto-alloc active", {62'd0, slot_state(st, 0)}, 64'd1);

    // ---- two concurrent tasks, completed out of order --------------------
    start(4'd1, 64'h1111, 32'd50, sv, ss, stk);
    complete(2'd1, 64'hBB);
    complete(2'd0, 64'hAA);
    rd(A_STATUS, st);
    chk("slot0 done",  {62'd0, slot_state(st, 0)}, 64'd2);
    chk("slot1 done",  {62'd0, slot_state(st, 1)}, 64'd2);
    wr(A_CMD, {56'd0, 4'd0, 4'd0});   // NOP with slot 0: selects slot 0
    rd(A_RESULT, res); chk("slot0 result out-of-order", res, 64'hAA);
    wr(A_CMD, {56'd0, 4'd1, 4'd0});
    rd(A_RESULT, res); chk("slot1 result out-of-order", res, 64'hBB);
    rd(A_DONECNT, cnt); chk("donecnt 3", cnt, 64'd3);

    // ---- stray completion for an idle slot is ignored --------------------
    complete(2'd3, 64'hDEAD);
    rd(A_STATUS, st); chk("stray completion ignored", {62'd0, slot_state(st, 3)}, 64'd0);
    rd(A_DONECNT, cnt); chk("stray completion not counted", cnt, 64'd3);

    // ---- interrupt disabled: pending set, irq stays low ------------------
    wr(A_CMD, {56'd0, 4'd0, OP_CLEARIRQ});
    wr(A_CMD, {56'd0, 4'd1, OP_CLEARIRQ});
    wr(A_CMD, {56'd0, 4'd0, OP_FREE});
    wr(A_CMD, {56'd0, 4'd1, OP_FREE});
    wr(A_CTRL, 64'h1);                       // enable, irq disabled
    start(4'd0, 64'hEEEE, 32'd50, sv, ss, stk);
    complete(2'd0, 64'h5A);
    chk("irq masked", {63'd0, irq}, 64'd0);
    rd(A_PENDING, pend); chk("pending latched while masked", pend, 64'd1);
    wr(A_CTRL, 64'h3);                       // re-enable the interrupt
    chk("irq after unmask", {63'd0, irq}, 64'd1);

    // ---- disabled core does not start tasks ------------------------------
    wr(A_CMD, {56'd0, 4'd0, OP_CLEARIRQ});
    wr(A_CMD, {56'd0, 4'd0, OP_FREE});
    wr(A_CTRL, 64'h0);                       // disable
    start(4'd0, 64'hFFFF, 32'd50, sv, ss, stk);
    chk("disabled: no start pulse", {63'd0, sv}, 64'd0);
    rd(A_STATUS, st); chk("disabled: slot stays idle", {62'd0, slot_state(st, 0)}, 64'd0);

    $display("tb_xcetask_top: %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL");
    $finish;
  end

endmodule
