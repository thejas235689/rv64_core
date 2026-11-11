// Standalone verification-contract interface; NOT connected to RV64 RTL yet.
interface wp9_if(input logic clk);
  logic rst_n;
  logic req_valid, req_ready;
  logic [3:0] wp_id;
  logic [7:0] op;
  logic [63:0] operand_a, operand_b;
  logic rsp_valid;
  logic [63:0] rsp_data;
  logic rsp_error;
endinterface
