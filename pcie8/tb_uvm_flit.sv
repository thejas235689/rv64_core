`timescale 1ns/1ps
module tb_uvm_flit;
  logic clk = 1'b0;
  always #5 clk = ~clk;

  flit_if vif (.clk(clk));

  pcie_flit_pack u_dut (
    .clk(clk), .rst_n(vif.rst_n),
    .in_valid(vif.in_valid), .in_ready(vif.in_ready),
    .in_byte(vif.in_byte), .in_last(vif.in_last),
    .flit_valid(vif.flit_valid), .flit_ready(vif.flit_ready),
    .flit(vif.flit)
  );

  initial begin
    vif.rst_n      = 1'b0;
    vif.in_valid   = 1'b0;
    vif.in_byte    = 8'd0;
    vif.in_last    = 1'b0;
    vif.flit_ready = 1'b0;
    repeat (4) @(posedge clk);
    vif.rst_n = 1'b1;
  end

  initial begin
    uvm_config_db#(virtual flit_if)::set(null, "*", "vif", vif);
    run_test();
  end
endmodule
