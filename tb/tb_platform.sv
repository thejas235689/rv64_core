`timescale 1ns/1ps
// Self-checking testbench for the platform blocks: DMI transport, CLINT, UART.
module tb_platform;

  // ---- CLINT ----
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        c_we;  logic [3:0] c_addr; logic [63:0] c_wdata, c_rdata;
  logic        timer_irq, soft_irq;

  rv64_clint u_clint (.clk(clk), .rst_n(rst_n), .csr_we(c_we), .csr_addr(c_addr),
                      .csr_wdata(c_wdata), .csr_rdata(c_rdata),
                      .timer_irq(timer_irq), .soft_irq(soft_irq));

  // ---- UART (looped back: tx -> rx) ----
  logic        u_we;  logic [3:0] u_addr; logic [63:0] u_wdata, u_rdata;
  logic        uart_line;

  rv64_uart u_uart (.clk(clk), .rst_n(rst_n), .csr_we(u_we), .csr_addr(u_addr),
                    .csr_wdata(u_wdata), .csr_rdata(u_rdata),
                    .tx(uart_line), .rx(uart_line));

  // ---- DMI ----
  logic tck = 1'b0, tms, tdi, tdo, trst_n;
  logic d_halt_req, d_resume_req, d_step, d_halted, d_ndmreset;
  logic [4:0]  d_reg_addr;
  logic [63:0] d_reg_data;

  always #3 tck = ~tck;

  rv64_dmi u_dmi (
    .tck(tck), .tms(tms), .tdi(tdi), .tdo(tdo), .trst_n(trst_n),
    .dbg_halt_req(d_halt_req), .dbg_resume_req(d_resume_req), .dbg_step(d_step),
    .dbg_halted(d_halted), .dbg_reg_addr(d_reg_addr), .dbg_reg_data(d_reg_data),
    .ndmreset(d_ndmreset)
  );

  int errors = 0, checks = 0;

  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin errors++; $display("MISMATCH %-26s got=%h expected=%h", name, got, exp); end
    end
  endtask

  task automatic cwr(input logic [3:0] a, input logic [63:0] d);
    begin c_we=1; c_addr=a; c_wdata=d; @(posedge clk); #1; c_we=0; end
  endtask

  task automatic uwr(input logic [3:0] a, input logic [63:0] d);
    begin u_we=1; u_addr=a; u_wdata=d; @(posedge clk); #1; u_we=0; end
  endtask

  // ---- TAP helpers ---------------------------------------------------------
  // Ten TMS-high edges reach Test-Logic-Reset from ANY state (five are enough,
  // ten is the standard rule), and one TMS-low edge then goes to Run-Test/Idle.
  // The previous five-edge version left the TAP in Select-DR, so every later
  // sequence started one state off and the IR/DR phases wrapped.
  task automatic tap_reset;
    begin
      tdi = 0;
      for (int i = 0; i < 10; i++) begin tms = 1; @(posedge tck); #1; end
      tms = 0; @(posedge tck); #1;
    end
  endtask

  task automatic tap_ir(input logic [4:0] v);
    begin
      tms=1; @(posedge tck); #1; // Select-DR
      tms=1; @(posedge tck); #1; // Select-IR
      tms=0; @(posedge tck); #1; // Capture-IR
      tms=0; @(posedge tck); #1; // Shift-IR
      for (int i = 0; i < 5; i++) begin tdi = v[i]; @(posedge tck); #1; end
      tms=1; @(posedge tck); #1; // Exit1-IR
      tms=1; @(posedge tck); #1; // Update-IR
      tms=0; @(posedge tck); #1; // Idle
    end
  endtask

  task automatic tap_dr(input logic [40:0] din, output logic [40:0] dout);
    begin
      dout = 41'd0;
      tms=1; @(posedge tck); #1;      // Select-DR
      tms=0; @(posedge tck); #1;      // Capture-DR
      tms=0; @(posedge tck); #1;      // Shift-DR
      for (int i = 0; i < 41; i++) begin
        tdi = din[i]; @(posedge tck); #1; dout[i] = tdo;
      end
      tms=1; @(posedge tck); #1;      // Exit1-DR
      tms=1; @(posedge tck); #1;      // Update-DR
      tms=0; @(posedge tck); #1;      // Run-Test/Idle
    end
  endtask

  logic [40:0] dr_out;
  logic [40:0] dr_in;

  initial begin
    c_we=0; c_addr=0; c_wdata=0;
    u_we=0; u_addr=0; u_wdata=0;
    tms=0; tdi=0; trst_n=0; d_halted=0; d_reg_data=64'hDEAD_BEEF_0000_0001;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    repeat (3) @(posedge tck);
    trst_n = 1'b1;
    @(posedge tck);

    // =====================================================================
    // CLINT
    // =====================================================================
    c_addr = 4'd5; #1;
    chk("CLINT idle no timer irq", c_rdata[0], 1'b0);
    chk("CLINT idle no soft irq",  c_rdata[1], 1'b0);

    cwr(4'd4, 64'd1);                       // software interrupt
    chk("CLINT soft_irq", soft_irq, 1'b1);
    cwr(4'd4, 64'd0);
    chk("CLINT soft_irq cleared", soft_irq, 1'b0);

    cwr(4'd6, 64'd1);                       // timer enable
    c_addr = 4'd0; #1;
    chk("CLINT mtime counts", (c_rdata[31:0] != 32'd0), 1'b1);

    // arm the comparator just ahead of mtime
    // mtimecmp resets to all-ones, so the HIGH word must be cleared too or the
    // comparator stays far in the future however small the low word is
    cwr(4'd3, 64'd0);
    c_addr = 4'd0; #1; c_wdata = {32'd0, c_rdata[31:0] + 32'd20};
    cwr(4'd2, c_wdata);
    c_addr = 4'd5; #1;
    chk("CLINT timer not yet", c_rdata[0], 1'b0);
    repeat (40) @(posedge clk);
    c_addr = 4'd5; #1;
    chk("CLINT timer fires", c_rdata[0], 1'b1);
    chk("CLINT timer_irq", timer_irq, 1'b1);
    cwr(4'd6, 64'd0);
    chk("CLINT timer gated", timer_irq, 1'b0);

    // =====================================================================
    // UART loopback
    // =====================================================================
    uwr(4'd3, 64'd4);                       // 4 clocks per bit
    uwr(4'd4, 64'd1);                       // enable
    uwr(4'd0, 64'hA5);                      // transmit 0xA5
    u_addr = 4'd2; #1;
    chk("UART tx busy", u_rdata[0], 1'b1);
    // 10 bits at 4 clocks each, plus synchroniser slack
    repeat (120) @(posedge clk);
    u_addr = 4'd2; #1;
    chk("UART rx valid", u_rdata[1], 1'b1);
    u_addr = 4'd1; #1;
    chk("UART loopback byte", u_rdata[7:0], 8'hA5);
    uwr(4'd1, 64'd0);                       // write to RXDATA clears rx_valid
    u_addr = 4'd2; #1;
    chk("UART rx cleared on write", u_rdata[1], 1'b0);

    // =====================================================================
    // DMI: IDCODE, then halt the core through DMCONTROL
    // =====================================================================
    tap_reset();
    tap_ir(5'h01);                          // IDCODE
    dr_in = 41'd0;
    tap_dr(dr_in, dr_out);
    chk("DMI IDCODE bit0", dr_out[0], 32'h1CA1_0D01 & 1);

    tap_reset();
    // write DMCONTROL: haltreq = 1
    tap_reset(); tap_ir(5'h11);
    dr_in = {2'b10, 32'h8000_0000, 7'h10};
    tap_dr(dr_in, dr_out);
    repeat (2) @(posedge tck);
    chk("DMI haltreq reaches core", d_halt_req, 1'b1);

    // read DMSTATUS with the core reporting halted
    d_halted = 1'b1;
    tap_reset(); tap_ir(5'h11);
    dr_in = {2'b01, 32'd0, 7'h11};          // read DMSTATUS: request
    tap_dr(dr_in, dr_out);
    dr_in = {2'b00, 32'd0, 7'h11};          // a nop scan collects the response
    tap_dr(dr_in, dr_out);
    // the DMI data field starts at bit 7, so DMSTATUS data[9] (allhalted) is bit 16
    chk("DMI dmstatus allhalted", dr_out[16], 1'b1);

    // resumereq is a one-shot pulse
    tap_reset(); tap_ir(5'h11);
    dr_in = {2'b10, 32'h4000_0000, 7'h10};
    tap_dr(dr_in, dr_out);
    repeat (4) @(posedge tck);
    chk("DMI resumereq self-clears", d_resume_req, 1'b0);

    $display("tb_platform: %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
