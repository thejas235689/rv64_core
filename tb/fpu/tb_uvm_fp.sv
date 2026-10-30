`timescale 1ns/1ps
module tb_uvm_fp;
  logic clk = 1'b0;
  always #5 clk = ~clk;

  import fp_golden_pkg::*;

  fp_if vif (.clk(clk));

  rv64_fp_add u_dut (.sub(vif.sub), .a(vif.a), .b(vif.b),
                     .result(vif.result),
                     .flag_invalid(vif.flag_invalid),
                     .flag_inexact(vif.flag_inexact));

  // run_test() must be called at time 0: UVM fatals if any simulation time is
  // consumed first ("The run phase must start at time 0"). The idle drive is
  // therefore a separate process, not a delay before run_test().
  initial begin
    uvm_config_db#(virtual fp_if)::set(null, "*", "vif", vif);
    uvm_root::get().set_timeout(100ms, 0);
    run_test();
  end

  initial begin
    vif.sub = 1'b0;
    vif.a   = 64'd0;
    vif.b   = 64'd0;
  end
endmodule
