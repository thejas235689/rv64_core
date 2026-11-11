`timescale 1ns/1ps
// =============================================================================
// Configurable instruction cache with 64 sets and one 64-bit beat per line.
// Invalid ways are filled first. Full sets use round-robin replacement.
// The refill bus permits one outstanding accepted request. The optional tagged
// interface can return cache hits ahead of a pending demand refill.
`default_nettype none

module rv64_icache #(
  parameter int WAYS = 1,
  parameter bit ENABLE_STRIDE_PREFETCH = 1'b0,
  // The platform must mark an idempotent physical instruction-memory region.
  parameter logic [63:0] PREFETCH_BASE = 64'd0,
  parameter logic [63:0] PREFETCH_LIMIT = 64'd0,
  parameter bit ENABLE_HIT_UNDER_MISS = 1'b0,
  parameter int REQ_ID_WIDTH = 4
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- core side -----------------------------------------------------------
  input  logic        req_valid,
  input  logic [63:0] req_addr,
  output logic        req_ready,
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

  // ---- invalidate ----------------------------------------------------------
  // Zifencei: fence.i must make stores to instruction memory visible to fetch.
  input  logic        invalidate,
  input  logic        prefetch_enable, // run-time permission from the platform

  // ---- counters ------------------------------------------------------------
  output logic [31:0] hit_count,
  output logic [31:0] miss_count,

  // Tag every demand with a unique ID until its response is observed.
  // Consumers of the optional interface must accept out-of-order responses.
  input  logic [REQ_ID_WIDTH-1:0] req_id,
  output logic [REQ_ID_WIDTH-1:0] resp_id
);
  localparam int SETS = 64;
  localparam int WAY_BITS = WAYS > 1 ? $clog2(WAYS) : 1;
  typedef logic [WAY_BITS-1:0] way_t;

  logic [54:0] tag_q   [SETS][WAYS];
  logic [63:0] data_q  [SETS][WAYS];
  logic        valid_q [SETS][WAYS];
  way_t        replace_q [SETS];
  wire [5:0]   idx = req_addr[8:3];
  wire [54:0]  tag = req_addr[63:9];
  logic        hit;
  way_t        hit_way, victim;

  always_comb begin
    hit = 1'b0;
    hit_way = '0;
    victim = replace_q[idx];
    for (int way = WAYS - 1; way >= 0; way--) begin
      if (!valid_q[idx][way]) victim = way_t'(way);
      if (valid_q[idx][way] && tag_q[idx][way] == tag) begin
        hit = 1'b1;
        hit_way = way_t'(way);
      end
    end
  end

  typedef enum logic [2:0] {C_IDLE, C_REQUEST, C_WAIT, C_DONE, C_DRAIN} state_t;
  state_t state_q;
  logic [63:0] addr_q, response_q;
  way_t victim_q;
  logic miss_q, err_q;
  logic [REQ_ID_WIDTH-1:0] demand_id_q, hit_id_q;
  logic [63:0] hit_data_q;
  logic hit_response_q;

  // Track the last accepted demand and require two consecutive equal,
  // nonzero strides. Keep speculation in a one-beat buffer, so it cannot
  // replace a demand line. Addresses are compared at 8-byte granularity.
  logic last_valid_q, stride_valid_q, stride_confident_q;
  logic speculative_q, prefetch_valid_q, candidate_issued_q;
  logic [63:0] last_addr_q, stride_q, prefetch_addr_q, prefetch_data_q;
  wire [63:0] demand_addr = {req_addr[63:3], 3'b000};
  wire [63:0] observed_stride = demand_addr - last_addr_q;
  wire [63:0] candidate = last_addr_q + stride_q;
  wire prefetch_active = ENABLE_STRIDE_PREFETCH && prefetch_enable;
  wire prefetch_hit = prefetch_active && prefetch_valid_q && prefetch_addr_q == demand_addr;
  wire can_prefetch = prefetch_active && stride_confident_q && !candidate_issued_q &&
                      candidate[63:12] == last_addr_q[63:12] &&
                      candidate >= PREFETCH_BASE && candidate < PREFETCH_LIMIT &&
                      PREFETCH_LIMIT - candidate >= 64'd8;

  // A refill response owns the response register on its arrival edge.
  // A hit accepted earlier can retire while the refill is being captured.
  wire hit_under_miss = ENABLE_HIT_UNDER_MISS && state_q == C_WAIT &&
                        !speculative_q && hit && !fill_rsp_valid;
  assign req_ready = (state_q == C_IDLE || hit_under_miss) && !invalidate;

  // A speculative request can be withdrawn before acceptance. Once accepted,
  // the slot remains owned until the response arrives, even after revocation.
  wire cancel_prefetch = speculative_q && !prefetch_active;
  assign fill_valid = state_q == C_REQUEST && !invalidate && !cancel_prefetch;
  assign fill_addr  = {addr_q[63:3], 3'b000};
  assign resp_valid = (state_q == C_DONE || hit_response_q) && !invalidate;
  assign resp_data  = hit_response_q ? hit_data_q : response_q;
  assign resp_miss  = !hit_response_q && miss_q;
  assign resp_error = !hit_response_q && err_q;
  assign resp_id    = hit_response_q ? hit_id_q : demand_id_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= C_IDLE;
      addr_q <= '0;
      response_q <= '0;
      victim_q <= '0;
      last_valid_q <= 1'b0;
      stride_valid_q <= 1'b0;
      stride_confident_q <= 1'b0;
      speculative_q <= 1'b0;
      prefetch_valid_q <= 1'b0;
      candidate_issued_q <= 1'b0;
      last_addr_q <= '0;
      stride_q <= '0;
      prefetch_addr_q <= '0;
      prefetch_data_q <= '0;
      miss_q <= 1'b0;
      err_q <= 1'b0;
      demand_id_q <= '0;
      hit_id_q <= '0;
      hit_data_q <= '0;
      hit_response_q <= 1'b0;
      hit_count <= '0;
      miss_count <= '0;
      for (int set_id = 0; set_id < SETS; set_id++) begin
        replace_q[set_id] <= '0;
        for (int way = 0; way < WAYS; way++) valid_q[set_id][way] <= 1'b0;
      end
    end else if (invalidate) begin
      hit_response_q <= 1'b0;
      last_valid_q <= 1'b0;
      stride_valid_q <= 1'b0;
      stride_confident_q <= 1'b0;
      prefetch_valid_q <= 1'b0;
      candidate_issued_q <= 1'b0;
      for (int set_id = 0; set_id < SETS; set_id++) begin
        replace_q[set_id] <= '0;
        for (int way = 0; way < WAYS; way++) valid_q[set_id][way] <= 1'b0;
      end
      // An accepted response belongs to the old epoch. Drain it before issuing
      // another request so it cannot install data under the next request's tag.
      state_q <= ((state_q == C_WAIT || state_q == C_DRAIN) && !fill_rsp_valid)
                 ? C_DRAIN : C_IDLE;
    end else begin
      hit_response_q <= hit_under_miss && req_valid;
      if (hit_under_miss && req_valid) begin
        hit_data_q <= data_q[idx][hit_way];
        hit_id_q <= req_id;
        hit_count <= hit_count + 32'd1;
      end
      if (!prefetch_active) begin
        last_valid_q <= 1'b0;
        stride_valid_q <= 1'b0;
        stride_confident_q <= 1'b0;
        prefetch_valid_q <= 1'b0;
      end
      case (state_q)
        C_IDLE: if (req_valid) begin
          speculative_q <= 1'b0;
          if (prefetch_active) begin
            last_valid_q <= 1'b1;
            last_addr_q <= demand_addr;
            stride_valid_q <= last_valid_q && observed_stride != 0;
            stride_confident_q <= stride_valid_q && observed_stride == stride_q;
            stride_q <= observed_stride;
            candidate_issued_q <= 1'b0;
          end
          addr_q <= req_addr;
          if (ENABLE_HIT_UNDER_MISS) demand_id_q <= req_id;
          miss_q <= !(hit || prefetch_hit);
          err_q <= 1'b0;
          if (hit || prefetch_hit) begin
            response_q <= hit ? data_q[idx][hit_way] : prefetch_data_q;
            hit_count <= hit_count + 32'd1;
            state_q <= C_DONE;
          end else begin
            victim_q <= victim;
            miss_count <= miss_count + 32'd1;
            state_q <= C_REQUEST;
          end
        end else if (can_prefetch) begin
          addr_q <= candidate;
          speculative_q <= 1'b1;
          candidate_issued_q <= 1'b1;
          state_q <= C_REQUEST;
        end
        C_REQUEST, C_WAIT: begin
          if (state_q == C_REQUEST && cancel_prefetch) state_q <= C_IDLE;
          else if (state_q == C_REQUEST && fill_ready) state_q <= C_WAIT;
          else if (state_q == C_WAIT && cancel_prefetch && !fill_rsp_valid)
            state_q <= C_DRAIN;
          if (fill_rsp_valid && (state_q == C_WAIT || (fill_valid && fill_ready))) begin
            if (speculative_q) begin
              if (!fill_rsp_error && prefetch_active) begin
                prefetch_data_q <= fill_rsp_data;
                prefetch_addr_q <= addr_q;
                prefetch_valid_q <= 1'b1;
              end
              state_q <= C_IDLE;
            end else begin
              response_q <= fill_rsp_data;
              err_q <= fill_rsp_error;
              if (!fill_rsp_error) begin
                tag_q[addr_q[8:3]][victim_q] <= addr_q[63:9];
                data_q[addr_q[8:3]][victim_q] <= fill_rsp_data;
                valid_q[addr_q[8:3]][victim_q] <= 1'b1;
                replace_q[addr_q[8:3]] <= victim_q == way_t'(WAYS - 1)
                                           ? '0 : victim_q + way_t'(1);
              end
              state_q <= C_DONE;
            end
          end
        end
        C_DRAIN: if (fill_rsp_valid) state_q <= C_IDLE;
        C_DONE: state_q <= C_IDLE;
        default: state_q <= C_IDLE;
      endcase
    end
  end
endmodule
`default_nettype wire
