`timescale 1ns/1ps
// =============================================================================
// rv64_icache.sv -- direct-mapped instruction cache.
//
// 64 lines of one 64-bit fetch beat each, which is the width the core's fetch
// port already uses, so a line is exactly one bus response and the fill needs no
// burst machinery. Direct-mapped on address bits [8:3].
//
// A hit returns the beat in the same cycle it is asked for. A miss issues one
// fill request, installs the line on the response, and only then answers -- the
// request is held until it can be satisfied, so a miss costs the fill latency
// rather than a retry.
//
// NOT IMPLEMENTED, stated rather than implied: no victim/writeback (an
// instruction cache needs none), no replacement policy beyond direct mapping, no
// RRIP, no coherence or invalidation port, and no prefetch. A real L1 would add
// at least the invalidate port, which a self-modifying-code path needs.
// =============================================================================
`default_nettype none

module rv64_icache (
  input  logic        clk,
  input  logic        rst_n,

  // ---- core side -----------------------------------------------------------
  input  logic        req_valid,
  input  logic [63:0] req_addr,
  output logic        req_ready,      // only accept while idle
  output logic        resp_valid,
  output logic [63:0] resp_data,
  output logic        resp_miss,      // this access had to fill
  output logic        resp_error,     // the fill failed; the fetch must fault

  // ---- fill port -----------------------------------------------------------
  output logic        fill_valid,
  output logic [63:0] fill_addr,
  input  logic        fill_ready,
  input  logic        fill_rsp_valid,
  input  logic [63:0] fill_rsp_data,
  input  logic        fill_rsp_error,

  // ---- counters ------------------------------------------------------------
  output logic [31:0] hit_count,
  output logic [31:0] miss_count
);
  localparam int NLINES = 64;

  logic [54:0] tag_q  [0:NLINES-1];   // addr[63:9]
  logic [63:0] data_q [0:NLINES-1];
  logic        valid_q[0:NLINES-1];

  wire [5:0]  idx = req_addr[8:3];
  wire [54:0] tag = req_addr[63:9];
  wire        hit = valid_q[idx] && (tag_q[idx] == tag);

  typedef enum logic [1:0] {C_IDLE, C_FILL, C_DONE} cstate_e;
  cstate_e     cst;
  logic [63:0] addr_q;
  logic        miss_q;
  logic        err_q;

  // The core marks a request accepted on req_valid && req_ready. Reporting ready
  // unconditionally while only sampling in C_IDLE lost every request that
  // arrived during a fill, and the requester then waited for a response forever.
  assign req_ready  = (cst == C_IDLE);
  assign fill_valid = (cst == C_FILL);
  assign fill_addr  = {addr_q[63:3], 3'b000};

  assign resp_valid = (cst == C_DONE);
  assign resp_data  = data_q[addr_q[8:3]];
  assign resp_miss  = miss_q;
  assign resp_error = err_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cst        <= C_IDLE;
      addr_q     <= 64'd0;
      miss_q     <= 1'b0;
      err_q      <= 1'b0;
      hit_count  <= 32'd0;
      miss_count <= 32'd0;
      for (int i = 0; i < NLINES; i++) begin
        tag_q[i]   <= 55'd0;
        data_q[i]  <= 64'd0;
        valid_q[i] <= 1'b0;
      end
    end else begin
      case (cst)
        C_IDLE: begin
          if (req_valid) begin
            addr_q <= req_addr;
            if (hit) begin
              miss_q    <= 1'b0;
              err_q     <= 1'b0;
              cst       <= C_DONE;
              hit_count <= hit_count + 32'd1;
            end else begin
              miss_q     <= 1'b1;
              err_q      <= 1'b0;
              cst        <= C_FILL;
              miss_count <= miss_count + 32'd1;
            end
          end
        end

        C_FILL: begin
          if (fill_rsp_valid) begin
            // install the line; an errored fill is not cached, so the next
            // access retries rather than serving bad data forever
            err_q <= fill_rsp_error;
            if (!fill_rsp_error) begin
              tag_q[addr_q[8:3]]   <= addr_q[63:9];
              data_q[addr_q[8:3]]  <= fill_rsp_data;
              valid_q[addr_q[8:3]] <= 1'b1;
            end
            cst <= C_DONE;
          end
        end

        C_DONE: begin
          cst <= C_IDLE;
        end

        default: cst <= C_IDLE;
      endcase
    end
  end

endmodule
`default_nettype wire
