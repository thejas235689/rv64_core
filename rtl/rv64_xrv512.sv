`timescale 1ns/1ps
// =============================================================================
// rv64_xrv512.sv -- XRV512: a 32 x 512-bit register bank with lane arithmetic.
//
// 32 architectural registers of 512 bits, viewed as eight 64-bit lanes. The
// elementwise operations act on all eight lanes at once, so a start is one cycle:
// like the other accelerators here, this exists to give software a real wide
// register file to drive, not to win on throughput.
//
// Control port (CSR window, the same shape as Xcetask / QISA / AIACC):
//   0 CTRL    [0] start (self-clearing); read [1] busy, [2] done
//   1 OP      [3:0] operation
//   2 SRC1    [4:0] source register 1
//   3 SRC2    [4:0] source register 2
//   4 DST     [4:0] destination register (also the register read by DATA)
//   5 LANE    [2:0] which 64-bit lane DATA reads or writes
//   6 DATA    write a lane of DST, or read a lane of DST
//   7 STATUS  read-only {done, busy}
//
// Operations: VADD, VSUB, VMUL (low 64 bits of each product), VAND, VOR, VXOR,
// VMINU, VMAXU, VMINS, VMAXS, and VRED (sum of the eight lanes into lane 0).
//
// NOT IMPLEMENTED, stated rather than implied: no vector length or masking, no
// strided or indexed memory access, no widening/narrowing operations, no
// floating point, no chaining. VMUL keeps only the low 64 bits of each product --
// there is no high-half variant.
// =============================================================================
`default_nettype none

module rv64_xrv512 (
  input  logic        clk,
  input  logic        rst_n,

  // ---- control port --------------------------------------------------------
  input  logic        csr_we,
  input  logic [3:0]  csr_addr,
  input  logic [63:0] csr_wdata,
  output logic [63:0] csr_rdata,

  // ---- observability -------------------------------------------------------
  output logic        busy,
  output logic [31:0] op_count
);
  localparam int NREG  = 32;
  localparam int LANES = 8;

  localparam logic [3:0] OP_ADD = 4'd0, OP_SUB = 4'd1, OP_MUL = 4'd2,
                         OP_AND = 4'd3, OP_OR  = 4'd4, OP_XOR = 4'd5,
                         OP_MINU= 4'd6, OP_MAXU= 4'd7, OP_MINS= 4'd8,
                         OP_MAXS= 4'd9, OP_RED = 4'd10;

  // the bank lives in its own module, as the numeric file does
  logic [511:0] rdata_a, rdata_b, wdata;
  logic         we;
  logic [63:0]  ldata;

  logic [3:0] op_q;
  logic [4:0] src1_q, src2_q, dst_q;
  logic [2:0] lane_q;
  logic       busy_q, done_q;
  logic [31:0] op_count_q;

  rv64_xrv512_file u_file (
    .clk(clk), .rst_n(rst_n),
    .raddr_a(src1_q), .rdata_a(rdata_a),
    .raddr_b(src2_q), .rdata_b(rdata_b),
    .waddr(dst_q), .wdata(wdata), .we(we),
    .laddr(dst_q), .llane(lane_q), .ldata(ldata),
    .lwdata(csr_wdata), .lwe(csr_we && (csr_addr == 4'd6))
  );

  // ---- elementwise compute -------------------------------------------------
  // Eight explicitly-indexed lanes with constant part-selects. A loop with a
  // computed index (`rdata_a[64*l +: 64]`, then `rdata_a >> (64*l)`) evaluated as
  // lane 0 for every lane under xezim, so all eight lanes came out holding the
  // first lane's result.
  function automatic logic [63:0] elem(input logic [3:0] op,
                                       input logic [63:0] a, input logic [63:0] b);
    logic signed [63:0] sa, sb;
    begin
    sa = a;
    sb = b;
    unique case (op)
      OP_ADD:  return a + b;
      OP_SUB:  return a - b;
      OP_MUL:  return a * b;                       // low half only
      OP_AND:  return a & b;
      OP_OR:   return a | b;
      OP_XOR:  return a ^ b;
      OP_MINU: return (a < b) ? a : b;
      OP_MAXU: return (a > b) ? a : b;
      OP_MINS: return (sa < sb) ? a : b;
      OP_MAXS: return (sa > sb) ? a : b;
      default: return a;
    endcase
    end
  endfunction

  logic [511:0] result;
  logic [63:0]  red;

  always_comb begin
    red = rdata_a[63:0]    + rdata_a[127:64]  + rdata_a[191:128] + rdata_a[255:192]
        + rdata_a[319:256] + rdata_a[383:320] + rdata_a[447:384] + rdata_a[511:448];

    result[63:0]     = (op_q == OP_RED) ? red : elem(op_q, rdata_a[63:0],     rdata_b[63:0]);
    result[127:64]   = (op_q == OP_RED) ? 64'd0 : elem(op_q, rdata_a[127:64],   rdata_b[127:64]);
    result[191:128]  = (op_q == OP_RED) ? 64'd0 : elem(op_q, rdata_a[191:128],  rdata_b[191:128]);
    result[255:192]  = (op_q == OP_RED) ? 64'd0 : elem(op_q, rdata_a[255:192],  rdata_b[255:192]);
    result[319:256]  = (op_q == OP_RED) ? 64'd0 : elem(op_q, rdata_a[319:256],  rdata_b[319:256]);
    result[383:320]  = (op_q == OP_RED) ? 64'd0 : elem(op_q, rdata_a[383:320],  rdata_b[383:320]);
    result[447:384]  = (op_q == OP_RED) ? 64'd0 : elem(op_q, rdata_a[447:384],  rdata_b[447:384]);
    result[511:448]  = (op_q == OP_RED) ? 64'd0 : elem(op_q, rdata_a[511:448],  rdata_b[511:448]);
  end

  // ---- read path -----------------------------------------------------------
  always_comb begin
    csr_rdata = 64'd0;
    unique case (csr_addr)
      4'd0: csr_rdata = {61'd0, done_q, busy_q, 1'b0};
      4'd1: csr_rdata = {60'd0, op_q};
      4'd2: csr_rdata = {59'd0, src1_q};
      4'd3: csr_rdata = {59'd0, src2_q};
      4'd4: csr_rdata = {59'd0, dst_q};
      4'd5: csr_rdata = {61'd0, lane_q};
      4'd6: csr_rdata = ldata;
      4'd7: csr_rdata = {62'd0, done_q, busy_q};
      default: csr_rdata = 64'd0;
    endcase
  end


  assign busy     = busy_q;
  assign op_count = op_count_q;
  assign wdata = result;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      op_q       <= 4'd0;
      src1_q     <= 5'd0;
      src2_q     <= 5'd0;
      dst_q      <= 5'd0;
      lane_q     <= 3'd0;
      busy_q     <= 1'b0;
      done_q     <= 1'b0;
      op_count_q <= 32'd0;
      we <= 1'b0;
    end else begin
      busy_q <= 1'b0;
      we     <= 1'b0;
      if (csr_we) begin
        unique case (csr_addr)
          4'd0: begin
            if (csr_wdata[0]) begin
              // execute: the whole register is computed combinationally
              we          <= 1'b1;
              busy_q      <= 1'b1;
              done_q      <= 1'b1;
              op_count_q  <= op_count_q + 32'd1;
            end else begin
              done_q <= 1'b0;
            end
          end
          4'd1: begin op_q   <= csr_wdata[3:0]; done_q <= 1'b0; end
          4'd2: begin src1_q <= csr_wdata[4:0]; done_q <= 1'b0; end
          4'd3: begin src2_q <= csr_wdata[4:0]; done_q <= 1'b0; end
          4'd4: begin dst_q  <= csr_wdata[4:0]; done_q <= 1'b0; end
          4'd5: lane_q <= csr_wdata[2:0];
          4'd6: ;   // handled by the register file's lane port
          default: ;
        endcase
      end
    end
  end

endmodule
`default_nettype wire
