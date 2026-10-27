`timescale 1ns/1ps
// =============================================================================
// rv64_lsu.sv -- load/store unit and data-interface sequencer.
//   Owns the request/response handshake with the data port: request backpressure
//   via ready, separate response channel, response-error reporting.
//   Misalignment is detected by the core before the unit is started, so every
//   access here is naturally aligned and fits one 64-bit beat.
// =============================================================================
`default_nettype none

module rv64_lsu (
  input  logic        clk,
  input  logic        rst_n,

  // ---- request from the MEM stage -------------------------------------------
  input  logic        req_start,
  input  logic [63:0] req_addr,
  input  logic [63:0] req_wdata,
  input  logic [2:0]  req_size,
  input  logic        req_uns,
  input  logic        req_we,
  input  logic        pmp_ok,

  // ---- data interface -------------------------------------------------------
  output logic        mem_req_valid,
  output logic [63:0] mem_req_addr,
  output logic        mem_req_we,
  output logic [63:0] mem_req_wdata,
  output logic [7:0]  mem_req_wstrb,
  input  logic        mem_req_ready,
  input  logic        mem_rsp_valid,
  input  logic [63:0] mem_rsp_rdata,
  input  logic        mem_rsp_error,

  // ---- result ---------------------------------------------------------------
  output logic        busy,
  output logic        done,
  output logic        fault,
  output logic [63:0] load_data
);
  import rv64_pkg::*;

  typedef enum logic [1:0] {S_IDLE, S_REQ, S_RESP, S_DONE} state_e;

  state_e      state;
  logic [63:0] addr_q, wdata_q;
  logic [2:0]  size_q;
  logic        uns_q, we_q;
  logic        fault_q;
  logic [63:0] data_q;
  logic        done_q_r;
  logic [63:0] data_lat;

  // ---- request formation ----------------------------------------------------
  logic [63:0] lane_shifted;
  logic [7:0]  strb;

  always_comb begin
    unique case (size_q)
      MSZ_B:   lane_shifted = {56'd0, wdata_q[7:0]};
      MSZ_H:   lane_shifted = {48'd0, wdata_q[15:0]};
      MSZ_W:   lane_shifted = {32'd0, wdata_q[31:0]};
      default: lane_shifted = wdata_q;
    endcase
    lane_shifted = lane_shifted << {addr_q[2:0], 3'b000};
  end

  always_comb begin
    unique case (size_q)
      MSZ_B:   strb = 8'h01 << addr_q[2:0];
      MSZ_H:   strb = 8'h03 << addr_q[2:0];
      MSZ_W:   strb = 8'h0F << addr_q[2:0];
      default: strb = 8'hFF;
    endcase
  end

  // ---- load extraction ------------------------------------------------------
  logic [63:0] rsp_shifted;
  assign rsp_shifted = mem_rsp_rdata >> {addr_q[2:0], 3'b000};

  always_comb begin
    unique case (size_q)
      MSZ_B:   data_q = uns_q ? {56'd0, rsp_shifted[7:0]}
                              : {{56{rsp_shifted[7]}}, rsp_shifted[7:0]};
      MSZ_H:   data_q = uns_q ? {48'd0, rsp_shifted[15:0]}
                              : {{48{rsp_shifted[15]}}, rsp_shifted[15:0]};
      MSZ_W:   data_q = uns_q ? {32'd0, rsp_shifted[31:0]}
                              : {{32{rsp_shifted[31]}}, rsp_shifted[31:0]};
      default: data_q = rsp_shifted;
    endcase
  end

  // ---- handshake ------------------------------------------------------------
  assign mem_req_valid = (state == S_REQ);
  assign mem_req_addr  = addr_q;
  assign mem_req_we    = we_q;
  assign mem_req_wdata = lane_shifted;
  assign mem_req_wstrb = we_q ? strb : 8'h00;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= S_IDLE;
      addr_q  <= 64'd0;
      wdata_q <= 64'd0;
      size_q  <= MSZ_D;
      uns_q   <= 1'b0;
      we_q    <= 1'b0;
      fault_q <= 1'b0;
      done_q_r<= 1'b0;
      data_lat<= 64'd0;
    end else begin
      done_q_r <= 1'b0;

      unique case (state)
        S_IDLE: begin
          if (req_start) begin
            addr_q  <= req_addr;
            wdata_q <= req_wdata;
            size_q  <= req_size;
            uns_q   <= req_uns;
            we_q    <= req_we;
            fault_q <= !pmp_ok;
            if (pmp_ok) state <= S_REQ;
            else        state <= S_DONE;
          end
        end

        S_REQ: begin
          if (mem_req_ready) begin
            if (we_q) state <= S_DONE;
            else      state <= S_RESP;
          end
        end

        S_RESP: begin
          if (mem_rsp_valid) begin
            data_lat <= data_q;
            fault_q  <= mem_rsp_error;
            state    <= S_DONE;
          end
        end

        S_DONE: begin
          done_q_r <= 1'b1;
          state    <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  assign busy      = (state != S_IDLE) || done_q_r;
  assign done      = done_q_r;
  assign fault     = fault_q && done_q_r;
  assign load_data = data_lat;

endmodule
`default_nettype wire
