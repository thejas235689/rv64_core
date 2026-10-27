`timescale 1ns/1ps
// =============================================================================
// rv64_aiacc.sv -- INT8 4x4x4 matrix accelerator.
//
// C[4x4] = A[4x4] x B[4x4], signed INT8 operands, INT32 accumulation. The whole
// product is combinational (64 multiply-accumulates), so a start costs one
// cycle: the block is here to give software a real accelerator to drive, not to
// win on throughput.
//
// Matrices are row-major. A and B live in their own 16x8 register file; C is
// 16 x INT32 and is read one element at a time through the index register,
// because a 4x4 INT32 result does not fit a 64-bit CSR.
//
// Control port (write = command, read = status), same shape as Xcetask:
//   0 CTRL    write: [0] start (self-clearing), [1] clear done
//             read:  [0] busy, [1] done, [2] overflow
//   1 IDX     [3:0] element 0..15, [4] matrix select (0 = A, 1 = B)
//   2 DATA    write: INT8 into the selected matrix element
//             read:  INT32 result element (always from C)
//   3 COUNT   read: number of completed products
//   4 SUM     read: sum of all 16 C elements, a one-register checksum
//   5 TAPS    read: number of non-zero A elements, [15:0]
// =============================================================================
`default_nettype none

module rv64_aiacc (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        csr_we,
  input  logic [3:0]  csr_addr,
  input  logic [63:0] csr_wdata,
  output logic [63:0] csr_rdata
);

  logic signed [7:0]  mat_a [0:15];
  logic signed [7:0]  mat_b [0:15];
  logic signed [31:0] mat_c [0:15];

  logic        busy;
  logic        done;
  logic        overflow;
  logic [31:0] count;

  // The index is a REGISTER. Reading `csr_wdata` here would work for a write
  // and silently read element 0 for a read, because the write bus is idle
  // during a read.
  logic [3:0] idx;
  logic       sel_b;

  // ---- the array -----------------------------------------------------------
  // One product per start. Accumulating four INT8 products needs at most 18
  // bits; the INT32 result cannot overflow for INT8 inputs, so `overflow` stays
  // a documented status bit rather than a possible event.
  logic signed [31:0] prod [0:15];

  always_comb begin
    for (int i = 0; i < 4; i++) begin
      for (int j = 0; j < 4; j++) begin
        logic signed [31:0] acc;
        acc = 32'sd0;
        for (int k = 0; k < 4; k++) begin
          acc = acc + $signed(mat_a[i * 4 + k]) * $signed(mat_b[k * 4 + j]);
        end
        prod[i * 4 + j] = acc;
      end
    end
  end

  logic [15:0] taps;
  always_comb begin
    taps = 16'd0;
    for (int i = 0; i < 16; i++) taps[i] = (mat_a[i] != 8'sd0);
  end

  logic signed [31:0] c_sum;
  always_comb begin
    c_sum = 32'sd0;
    for (int i = 0; i < 16; i++) c_sum = c_sum + mat_c[i];
  end

  // ---- control -------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 16; i++) begin
        mat_a[i] <= 8'sd0;
        mat_b[i] <= 8'sd0;
        mat_c[i] <= 32'sd0;
      end
      idx      <= 4'd0;
      sel_b    <= 1'b0;
      busy     <= 1'b0;
      done     <= 1'b0;
      overflow <= 1'b0;
      count    <= 32'd0;
    end else if (csr_we) begin
      case (csr_addr)
        4'd0: begin
          if (csr_wdata[0]) begin
            for (int i = 0; i < 16; i++) mat_c[i] <= prod[i];
            done  <= 1'b1;
            count <= count + 32'd1;
          end
          if (csr_wdata[1]) begin
            done <= 1'b0;
          end
        end
        4'd1: begin
          idx   <= csr_wdata[3:0];
          sel_b <= csr_wdata[4];
        end
        4'd2: begin
          if (sel_b) mat_b[idx] <= csr_wdata[7:0];
          else       mat_a[idx] <= csr_wdata[7:0];
        end
        default: ;
      endcase
    end
  end

  // ---- reads ---------------------------------------------------------------
  always_comb begin
    csr_rdata = 64'd0;
    case (csr_addr)
      4'd0: csr_rdata = {61'd0, overflow, done, busy};
      4'd1: csr_rdata = {59'd0, sel_b, idx};
      4'd2: csr_rdata = {{32{mat_c[idx][31]}}, mat_c[idx]};
      4'd3: csr_rdata = {32'd0, count};
      4'd4: csr_rdata = {{32{c_sum[31]}}, c_sum};
      4'd5: csr_rdata = {48'd0, taps};
      default: csr_rdata = 64'd0;
    endcase
  end

endmodule
`default_nettype wire
