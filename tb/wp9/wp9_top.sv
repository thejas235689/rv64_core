`timescale 1ns/1ps
module wp9_top;
  import uvm_pkg::*;
  import wp9_pkg::*;
  bit clk=0;
  always #5 clk=~clk;
  wp9_if bus(clk);
  initial begin
    bus.rst_n=0;
    repeat(4) @(negedge clk);
    bus.rst_n=1;
  end
  // FIXTURE ONLY: replace this with a WP-specific real RTL adapter.
  assign bus.req_ready=bus.rst_n;
  assign bus.rsp_valid=bus.req_valid && bus.req_ready;
  assign bus.rsp_data=bus.operand_a ^ bus.operand_b ^ {52'h0,bus.wp_id,bus.op};
  assign bus.rsp_error=1'b0;

  initial begin
    uvm_config_db#(virtual wp9_if)::set(null,"*","vif",bus);
    run_test("wp9_test");
  end
endmodule
