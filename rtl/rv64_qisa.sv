`timescale 1ns/1ps
// =============================================================================
// rv64_qisa.sv -- 8-entry qubit model.
//
// WHAT THIS IS, AND WHAT IT IS NOT
//
// This is a *quantum-inspired state model*, not a statevector simulator. Eight
// qubits held as 256 complex amplitudes would not fit a CSR window and would
// not be useful to a CPU testbench; what is modelled here is the state machine
// software actually drives: definite value, superposition flag, phase.
//
// Each qubit carries {phase, superposed, value}:
//
//   RESET    -> value 0, not superposed, phase 0
//   X        -> flips value; if superposed it also flips the phase, which is
//               what X = HZH does to a superposed qubit
//   Z        -> flips phase
//   H        -> toggles superposition (H.H = identity, which the model honours)
//   CNOT c,t -> if the control is definite 1, X the target; if the control is
//               superposed, the target becomes superposed too (entanglement is
//               recorded as a shared flag, not as amplitudes)
//   MEASURE  -> a superposed qubit collapses to a pseudo-random bit from a
//               seeded LFSR; a definite one returns its value. Deterministic
//               for a given seed, so tests can assert exact results.
//
// Control port (write = command, read = status), same shape as Xcetask:
//   0 CTRL     [0] enable, [1] seed reload
//   2 CMD      [3:0] op, [7:4] qubit, [11:8] target, [15:12] control
//   3 ARG      [31:0] seed
//   4 STATE    read: per-qubit {phase, superposed, value} in [3*i +: 3]
//   5 MEAS     read: [7:0] last measurement result, [15:8] which qubits were
//              measured, [31:16] measurement count
//   6 COUNT    read: operations executed
//
// ops: 0 NOP, 1 RESET, 2 X, 3 Z, 4 H, 5 CNOT, 6 MEASURE, 7 RESET_ALL
// =============================================================================
`default_nettype none

module rv64_qisa (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        csr_we,
  input  logic [3:0]  csr_addr,
  input  logic [63:0] csr_wdata,
  output logic [63:0] csr_rdata
);

  localparam logic [3:0] OP_NOP       = 4'd0;
  localparam logic [3:0] OP_RESET     = 4'd1;
  localparam logic [3:0] OP_X         = 4'd2;
  localparam logic [3:0] OP_Z         = 4'd3;
  localparam logic [3:0] OP_H         = 4'd4;
  localparam logic [3:0] OP_CNOT      = 4'd5;
  localparam logic [3:0] OP_MEASURE   = 4'd6;
  localparam logic [3:0] OP_RESET_ALL = 4'd7;

  // ---- state ---------------------------------------------------------------
  logic [23:0] q_val;        // [3*i +: 3] = {phase, superposed, value}
  logic [31:0] lfsr;
  logic [31:0] op_count;
  logic [31:0] meas_count;
  logic [7:0]  meas_last;
  logic [7:0]  meas_mask;
  logic        enable;

  wire [3:0] cmd_op  = csr_wdata[3:0];
  wire [3:0] cmd_q   = csr_wdata[7:4];
  wire [3:0] cmd_tgt = csr_wdata[11:8];
  wire [3:0] cmd_ctl = csr_wdata[15:12];

  // ---- one qubit, as a 3-bit slice -----------------------------------------
  function automatic logic [2:0] qbit(input logic [23:0] s, input int i);
    return s[3*i +: 3];
  endfunction

  // The next LFSR value: x^32 + x^22 + x^2 + x + 1, the standard maximal-length
  // polynomial, so a seeded run is reproducible and does not lock up.
  function automatic logic [31:0] lfsr_next(input logic [31:0] v);
    logic fb;
    fb = v[31] ^ v[21] ^ v[1] ^ v[0];
    return {v[30:0], fb};
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q_val      <= 24'd0;
      lfsr       <= 32'h1234_5678;
      op_count   <= 32'd0;
      meas_count <= 32'd0;
      meas_last  <= 8'd0;
      meas_mask  <= 8'd0;
      enable     <= 1'b0;
    end else if (csr_we && csr_addr == 4'd0) begin
      enable <= csr_wdata[0];
      if (csr_wdata[1]) lfsr <= 32'h1234_5678;
    end else if (csr_we && csr_addr == 4'd3) begin
      lfsr <= csr_wdata[31:0];
    end else if (csr_we && csr_addr == 4'd2 && enable) begin
      logic [2:0]  qs;
      logic [2:0]  ts;
      logic        bit_out;
      logic [23:0] nq;
      nq = q_val;
      qs = qbit(q_val, cmd_q);
      ts = qbit(q_val, cmd_tgt);
      bit_out = 1'b0;

      case (cmd_op)
        OP_RESET_ALL: begin
          nq = 24'd0;
        end
        OP_RESET: begin
          nq[3*cmd_q +: 3] = 3'b000;
        end
        OP_X: begin
          nq[3*cmd_q +: 3] = {qs[2] ^ qs[1], qs[1], ~qs[0]};
        end
        OP_Z: begin
          nq[3*cmd_q +: 3] = {~qs[2], qs[1], qs[0]};
        end
        OP_H: begin
          nq[3*cmd_q +: 3] = {qs[2], ~qs[1], qs[0]};
        end
        OP_CNOT: begin
          if (qs[1]) begin
            // superposed control: the target shares the superposition
            nq[3*cmd_tgt +: 3] = {ts[2], 1'b1, ts[0]};
          end else if (qs[0]) begin
            nq[3*cmd_tgt +: 3] = {ts[2] ^ ts[1], ts[1], ~ts[0]};
          end
        end
        OP_MEASURE: begin
          if (qs[1]) begin
            bit_out = lfsr[0];
            nq[3*cmd_q +: 3] = {1'b0, 1'b0, lfsr[0]};
            lfsr <= lfsr_next(lfsr);
          end else begin
            bit_out = qs[0];
          end
          meas_last  <= {7'd0, bit_out} | (meas_last & 8'h00);
          meas_mask  <= meas_mask | (8'd1 << cmd_q);
          meas_count <= meas_count + 32'd1;
        end
        default: begin
          nq = q_val;
        end
      endcase

      q_val <= nq;
      if (cmd_op != OP_NOP) op_count <= op_count + 32'd1;
    end
  end

  // ---- reads ---------------------------------------------------------------
  always_comb begin
    csr_rdata = 64'd0;
    case (csr_addr)
      4'd0: csr_rdata = {63'd0, enable};
      4'd2: csr_rdata = {48'd0, cmd_ctl, cmd_tgt, cmd_q, cmd_op};
      4'd3: csr_rdata = {32'd0, lfsr};
      4'd4: csr_rdata = {40'd0, q_val};
      4'd5: csr_rdata = {32'd0, meas_count[15:0], meas_mask, meas_last};
      4'd6: csr_rdata = {32'd0, op_count};
      default: csr_rdata = 64'd0;
    endcase
  end

endmodule
`default_nettype wire
