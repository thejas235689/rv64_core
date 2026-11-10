`timescale 1ns/1ps
// =============================================================================
// Configurable instruction cache with 64 sets and one 64-bit beat per line.
// Invalid ways are filled first. Full sets use round-robin replacement.
// The refill bus permits one outstanding accepted request.
`default_nettype none

module rv64_icache #(parameter int WAYS = 1) (
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

  // ---- invalidate ----------------------------------------------------------
  // Zifencei: fence.i must make stores to instruction memory visible to fetch.
  input  logic        invalidate,

  // ---- counters ------------------------------------------------------------
  output logic [31:0] hit_count,
  output logic [31:0] miss_count
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

  assign req_ready  = state_q == C_IDLE && !invalidate;
  assign fill_valid = state_q == C_REQUEST && !invalidate;
  assign fill_addr  = {addr_q[63:3], 3'b000};
  assign resp_valid = state_q == C_DONE && !invalidate;
  assign resp_data  = response_q;
  assign resp_miss  = miss_q;
  assign resp_error = err_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= C_IDLE;
      addr_q <= '0;
      response_q <= '0;
      victim_q <= '0;
      miss_q <= 1'b0;
      err_q <= 1'b0;
      hit_count <= '0;
      miss_count <= '0;
      for (int set_id = 0; set_id < SETS; set_id++) begin
        replace_q[set_id] <= '0;
        for (int way = 0; way < WAYS; way++) valid_q[set_id][way] <= 1'b0;
      end
    end else if (invalidate) begin
      for (int set_id = 0; set_id < SETS; set_id++) begin
        replace_q[set_id] <= '0;
        for (int way = 0; way < WAYS; way++) valid_q[set_id][way] <= 1'b0;
      end
      // An accepted response belongs to the old epoch. Drain it before issuing
      // another request so it cannot install data under the next request's tag.
      state_q <= ((state_q == C_WAIT || state_q == C_DRAIN) && !fill_rsp_valid)
                 ? C_DRAIN : C_IDLE;
    end else begin
      case (state_q)
        C_IDLE: if (req_valid) begin
          addr_q <= req_addr;
          miss_q <= !hit;
          err_q <= 1'b0;
          if (hit) begin
            response_q <= data_q[idx][hit_way];
            hit_count <= hit_count + 32'd1;
            state_q <= C_DONE;
          end else begin
            victim_q <= victim;
            miss_count <= miss_count + 32'd1;
            state_q <= C_REQUEST;
          end
        end
        C_REQUEST, C_WAIT: begin
          if (state_q == C_REQUEST && fill_ready) state_q <= C_WAIT;
          if (fill_rsp_valid && (state_q == C_WAIT || fill_ready)) begin
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
        C_DRAIN: if (fill_rsp_valid) state_q <= C_IDLE;
        C_DONE: state_q <= C_IDLE;
        default: state_q <= C_IDLE;
      endcase
    end
  end
endmodule
`default_nettype wire
