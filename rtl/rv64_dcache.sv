`timescale 1ns/1ps
// =============================================================================
// rv64_dcache.sv -- write-through data cache.
//
// 64 lines of one 64-bit beat, direct-mapped on address bits [8:3], matching the
// instruction cache and the width of the core's data bus. The LSU sends the exact
// (possibly unaligned) address and expects the beat containing it back, so lines
// are indexed and tagged on addr[63:3] while the requester keeps its own byte
// extraction.
//
// WRITE POLICY: write-through, write-allocate on a hit only.
//   * a store that hits updates the cached line through its byte strobes AND
//     issues the same store to memory, so memory is never stale;
//   * a store that misses goes straight to memory and does NOT allocate, which
//     avoids a pointless fill for data that was written once.
// Write-through is the slow choice, and it is deliberate: it keeps the cache
// coherent with a memory that page-table walks also read, with no invalidation
// protocol. A write-back cache would need dirty lines and a flush path before
// Sv39 could trust it.
//
// NOT IMPLEMENTED, stated rather than implied: no invalidate port, no write-back,
// no L2, no RRIP or any replacement beyond direct mapping, no prefetch, no
// uncached-region control. Stores that straddle two lines are handled by the LSU
// (it never issues one), not here.
// =============================================================================
`default_nettype none

module rv64_dcache (
  input  logic        clk,
  input  logic        rst_n,

  // ---- core side (same shape as the LSU's bus port) ------------------------
  input  logic        req_valid,
  input  logic [63:0] req_addr,
  input  logic        req_we,
  input  logic [7:0]  req_wstrb,
  input  logic [63:0] req_wdata,
  output logic        req_ready,
  output logic        rsp_valid,
  output logic [63:0] rsp_rdata,
  output logic        rsp_error,

  // ---- bus side ------------------------------------------------------------
  output logic        bus_req_valid,
  output logic [63:0] bus_req_addr,
  output logic        bus_req_we,
  output logic [7:0]  bus_req_wstrb,
  output logic [63:0] bus_req_wdata,
  input  logic        bus_req_ready,
  input  logic        bus_rsp_valid,
  input  logic [63:0] bus_rsp_rdata,
  input  logic        bus_rsp_error,

  // ---- counters ------------------------------------------------------------
  output logic [31:0] hit_count,
  output logic [31:0] miss_count
);
  localparam int NLINES = 64;

  logic [54:0] tag_q  [0:NLINES-1];   // addr[63:9]
  logic [63:0] data_q [0:NLINES-1];
  logic        valid_q[0:NLINES-1];

  wire [63:0] line_addr = {req_addr[63:3], 3'b000};
  wire [5:0]  idx       = req_addr[8:3];
  wire [54:0] tag       = req_addr[63:9];
  wire        hit       = valid_q[idx] && (tag_q[idx] == tag);

  // No D_WRESP: this bus answers loads only. A store is accepted and forgotten,
  // which is what the LSU already assumes -- waiting for a write response
  // deadlocked the core the first time this cache was wired in.
  typedef enum logic [2:0] {D_IDLE, D_FILL, D_WREQ, D_DONE} dstate_e;
  dstate_e     dst;
  logic [63:0] addr_q, wdata_q;
  logic [7:0]  wstrb_q;
  logic        we_q;
  logic [63:0] rdata_q;
  logic        err_q;

  assign req_ready = (dst == D_IDLE);

  assign bus_req_valid = (dst == D_FILL) || (dst == D_WREQ);
  assign bus_req_addr  = {addr_q[63:3], 3'b000};
  assign bus_req_we    = we_q;
  assign bus_req_wstrb = (dst == D_WREQ) ? wstrb_q : 8'h00;
  assign bus_req_wdata = wdata_q;

  assign rsp_valid = (dst == D_DONE);
  assign rsp_rdata = rdata_q;
  assign rsp_error = err_q;

  // merge the store bytes into a cached line
  function automatic logic [63:0] merge(input logic [63:0] old, input logic [63:0] wd,
                                        input logic [7:0] strb);
    logic [63:0] r;
    begin
      r = old;
      for (int i = 0; i < 8; i++) if (strb[i]) r[8*i +: 8] = wd[8*i +: 8];
      return r;
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dst        <= D_IDLE;
      addr_q     <= 64'd0;
      wdata_q    <= 64'd0;
      wstrb_q    <= 8'd0;
      we_q       <= 1'b0;
      rdata_q    <= 64'd0;
      err_q      <= 1'b0;
      hit_count  <= 32'd0;
      miss_count <= 32'd0;
      for (int i = 0; i < NLINES; i++) begin
        tag_q[i]   <= 55'd0;
        data_q[i]  <= 64'd0;
        valid_q[i] <= 1'b0;
      end
    end else begin
      case (dst)
        D_IDLE: begin
          if (req_valid) begin
            addr_q  <= req_addr;
            wdata_q <= req_wdata;
            wstrb_q <= req_wstrb;
            we_q    <= req_we;
            if (req_we) begin
              // write-through: the line is updated if present, and the store
              // always goes to memory
              if (hit) begin
                data_q[idx] <= merge(data_q[idx], req_wdata, req_wstrb);
                hit_count   <= hit_count + 32'd1;
              end else begin
                miss_count  <= miss_count + 32'd1;
              end
              dst <= D_WREQ;
            end else if (hit) begin
              rdata_q    <= data_q[idx];
              err_q      <= 1'b0;
              hit_count  <= hit_count + 32'd1;
              dst        <= D_DONE;
            end else begin
              miss_count <= miss_count + 32'd1;
              dst        <= D_FILL;
            end
          end
        end

        D_FILL: begin
          if (bus_rsp_valid) begin
            if (!bus_rsp_error) begin
              tag_q[addr_q[8:3]]   <= addr_q[63:9];
              data_q[addr_q[8:3]]  <= bus_rsp_rdata;
              valid_q[addr_q[8:3]] <= 1'b1;
            end
            rdata_q <= bus_rsp_rdata;
            err_q   <= bus_rsp_error;
            dst     <= D_DONE;
          end
        end

        D_WREQ: begin
          // the store is done once the bus accepts it
          if (bus_req_ready) dst <= D_DONE;
        end

        D_DONE: dst <= D_IDLE;
        default: dst <= D_IDLE;
      endcase
    end
  end

endmodule
`default_nettype wire
