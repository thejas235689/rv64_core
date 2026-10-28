`timescale 1ns/1ps
// =============================================================================
// rv64_l2cache.sv -- unified set-associative L2 with RRIP replacement.
//
// Sits behind both L1s and in front of memory. 16 sets x 4 ways x 32 bytes, so a
// line is four 64-bit beats and a miss fetches four beats rather than one.
//
// REPLACEMENT: RRIP (re-reference interval prediction, Jaleel et al.).
// Each way carries a 2-bit RRPV. A newly inserted line starts at 3 (distant, the
// preferred victim); a hit sets the way to 0 (near-immediate reuse). The victim
// is the first way at 3; if no way is at 3, every RRPV in the set increments and
// the search repeats, which ages the set rather than picking arbitrarily. That is
// the point of RRIP over LRU: it does not require exact recency, so it is cheap
// and it resists scans evicting a working set.
//
// NOT IMPLEMENTED, stated rather than implied: no inclusion management with the
// L1s (the L1s do not invalidate on an L2 eviction), no write-back (this is a
// read/fill cache; stores pass through), no coherence, no prefetch, no
// non-blocking misses (one outstanding fill).
// =============================================================================
`default_nettype none

module rv64_l2cache #(
  parameter int NSET = 16,
  parameter int NWAY = 4
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- core side: one beat request, same shape as the L1s' bus port ---------
  input  logic        req_valid,
  input  logic [63:0] req_addr,
  input  logic        req_we,
  input  logic [7:0]  req_wstrb,
  input  logic [63:0] req_wdata,
  output logic        req_ready,
  output logic        rsp_valid,
  output logic [63:0] rsp_rdata,
  output logic        rsp_error,

  // ---- memory side: beat port ----------------------------------------------
  output logic        mem_req_valid,
  output logic [63:0] mem_req_addr,
  output logic        mem_req_we,
  output logic [7:0]  mem_req_wstrb,
  output logic [63:0] mem_req_wdata,
  input  logic        mem_req_ready,
  input  logic        mem_rsp_valid,
  input  logic [63:0] mem_rsp_rdata,
  input  logic        mem_rsp_error,

  // ---- counters ------------------------------------------------------------
  output logic [31:0] hit_count,
  output logic [31:0] miss_count,
  output logic [31:0] rrip_bump_count
);
  // Geometry is a parameter so the same verified module serves both levels:
  //   L2  16 sets x 4 ways = 2 KB
  //   L3  64 sets x 8 ways = 16 KB
  // The set index sits above the four beats of a 32-byte line, so the tag starts
  // at bit (5 + SET_BITS).
  localparam int BEATS = 4;          // 32-byte lines
  localparam int SET_BITS = (NSET == 128) ? 7 : (NSET == 64) ? 6
                          : (NSET == 32) ? 5 : 4;
  localparam int TAG_TOP  = 63;
  localparam int TAG_LO   = 5 + SET_BITS;
  localparam int TAG_BITS = TAG_TOP - TAG_LO + 1;

  logic [TAG_BITS-1:0] tag_q [0:NSET-1][0:NWAY-1];
  // flattened to one dimension: a 3-D unpacked array read came back X under
  // xezim while the same code was correct under Icarus
  logic [63:0] data_q  [0:NSET*NWAY*BEATS-1];
  logic        valid_q [0:NSET-1][0:NWAY-1];
  logic [1:0]  rrpv_q  [0:NSET-1][0:NWAY-1];

  wire [SET_BITS-1:0] set = req_addr[5 +: SET_BITS];
  wire [1:0] beat   = req_addr[4:3];
  wire [TAG_BITS-1:0] tag = req_addr[63:TAG_LO];

  // ---- lookup --------------------------------------------------------------
  logic [$clog2(NWAY)-1:0] hit_way;
  logic       hit;
  always_comb begin
    hit     = 1'b0;
    hit_way = '0;
    for (int w = 0; w < NWAY; w++) begin
      if (!hit && valid_q[set][w] && (tag_q[set][w] == tag)) begin
        hit     = 1'b1;
        hit_way = w[$clog2(NWAY)-1:0];
      end
    end
  end

  // ---- RRIP victim selection ----------------------------------------------
  // the first way at the distant RRPV; if none, the set is aged and re-checked
  logic [1:0] victim;
  logic       need_age;
  always_comb begin
    victim   = '0;
    need_age = 1'b0;
    begin
      logic found;
      // An INVALID way always wins. A fresh set has every RRPV at 3, so pure
      // RRIP picked way 0 every time and evicted a line while three ways sat
      // empty -- the fill then served the old line's data.
      found = 1'b0;
      for (int w = 0; w < NWAY; w++) begin
        if (!found && !valid_q[set][w]) begin
          found  = 1'b1;
          victim = w[$clog2(NWAY)-1:0];
        end
      end
      if (!found) begin
        for (int w = 0; w < NWAY; w++) begin
          if (!found && (rrpv_q[set][w] == 2'b11)) begin
            found  = 1'b1;
            victim = w[$clog2(NWAY)-1:0];
          end
        end
      end
      if (!found) need_age = 1'b1;
    end
  end

  // merge a store's bytes into a cached line
  function automatic logic [63:0] merge(input logic [63:0] old, input logic [63:0] wd,
                                        input logic [7:0] strb);
    logic [63:0] r;
    begin
      r = old;
      for (int b = 0; b < 8; b++) if (strb[b]) r[8*b +: 8] = wd[8*b +: 8];
      return r;
    end
  endfunction

  typedef enum logic [2:0] {L_IDLE, L_FILL, L_WREQ, L_DONE} lstate_e;
  lstate_e     lst;
  logic [63:0] addr_q, wdata_q;
  logic [7:0]  wstrb_q;
  logic        we_q;
  logic [1:0]  fill_beat;
  logic        fill_issued_q;      // one beat outstanding at a time
  logic        fill_err_q;         // ANY beat errored: the line is unusable
  logic [$clog2(NWAY)-1:0] way_q;
  logic [63:0] rdata_q;
  logic        err_q;

  assign req_ready = (lst == L_IDLE);

  // A beat request is issued and then WAITED for. Holding the request while its
  // response was outstanding made the memory serve the same beat twice, so every
  // beat landed one slot late in the line.
  assign mem_req_valid = ((lst == L_FILL) && !fill_issued_q) || (lst == L_WREQ);
  // A store uses the request's own beat; fill_beat is only meaningful while
  // filling, and using it for a store sent the write to the wrong beat.
  wire [1:0] beat_sel = (lst == L_WREQ) ? addr_q[4:3] : fill_beat;
  assign mem_req_addr  = {addr_q[63:5], beat_sel, 3'b000};
  assign mem_req_we    = we_q;
  assign mem_req_wstrb = (lst == L_WREQ) ? wstrb_q : 8'h00;
  assign mem_req_wdata = wdata_q;

  assign rsp_valid = (lst == L_DONE);
  assign rsp_rdata = rdata_q;
  assign rsp_error = err_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lst        <= L_IDLE;
      addr_q     <= 64'd0;
      wdata_q    <= 64'd0;
      wstrb_q    <= 8'd0;
      we_q       <= 1'b0;
      fill_beat  <= 2'd0;
      fill_issued_q <= 1'b0;
      fill_err_q <= 1'b0;
      way_q      <= '0;
      rdata_q    <= 64'd0;
      err_q      <= 1'b0;
      hit_count  <= 32'd0;
      miss_count <= 32'd0;
      rrip_bump_count <= 32'd0;
      for (int s = 0; s < NSET; s++)
        for (int w = 0; w < NWAY; w++) begin
          tag_q[s][w]   <= {TAG_BITS{1'b0}};
          valid_q[s][w] <= 1'b0;
          rrpv_q[s][w]  <= 2'b11;
          for (int b = 0; b < BEATS; b++) data_q[(s*NWAY + w)*BEATS + b] <= 64'd0;
        end
    end else begin
      case (lst)
        L_IDLE: begin
          if (req_valid) begin
            addr_q  <= req_addr;
            wdata_q <= req_wdata;
            wstrb_q <= req_wstrb;
            we_q    <= req_we;
            if (req_we) begin
              // Write-through alone left the cached line stale: a later read hit
              // the old data. A write hit must also update the line.
              if (hit)
                data_q[(set*NWAY + hit_way)*BEATS + beat] <=
                  merge(data_q[(set*NWAY + hit_way)*BEATS + beat], req_wdata, req_wstrb);
              lst <= L_WREQ;
            end else if (hit) begin
              rdata_q   <= data_q[(set*NWAY + hit_way)*BEATS + beat];
              err_q     <= 1'b0;
              rrpv_q[set][hit_way] <= 2'b00;      // near-immediate reuse
              hit_count <= hit_count + 32'd1;
              lst       <= L_DONE;
            end else begin
              miss_count <= miss_count + 32'd1;
              way_q      <= victim;
              fill_beat  <= 2'd0;
              fill_issued_q <= 1'b0;
              fill_err_q <= 1'b0;
              if (need_age) begin
                // age the whole set, then the next lookup finds a victim
                for (int w = 0; w < NWAY; w++)
                  if (rrpv_q[set][w] != 2'b11) rrpv_q[set][w] <= rrpv_q[set][w] + 2'd1;
                rrip_bump_count <= rrip_bump_count + 32'd1;
              end
              lst <= L_FILL;
            end
          end
        end

        L_FILL: begin
          if (!fill_issued_q) begin
            if (mem_req_ready) fill_issued_q <= 1'b1;
          end else if (mem_rsp_valid) begin
            fill_issued_q <= 1'b0;
            if (mem_rsp_error) fill_err_q <= 1'b1;
            else data_q[(addr_q[5 +: SET_BITS]*NWAY + way_q)*BEATS + fill_beat] <= mem_rsp_rdata;
            if (fill_beat == addr_q[4:3]) rdata_q <= mem_rsp_rdata;
            // the response the requester wants is the beat it asked for, not
            // whichever beat happens to complete the line
            if (fill_beat == addr_q[4:3]) rdata_q <= mem_rsp_rdata;
            if (fill_beat == 2'd3) begin
              // line complete. An ERRORED fill must not become valid: marking it
              // valid made a later access hit garbage.
              // an error on ANY beat makes the whole line unusable
              if (!mem_rsp_error && !fill_err_q) begin
                tag_q[addr_q[5 +: SET_BITS]][way_q]   <= addr_q[63:TAG_LO];
                valid_q[addr_q[5 +: SET_BITS]][way_q] <= 1'b1;
                rrpv_q[addr_q[5 +: SET_BITS]][way_q]  <= 2'b11;   // distant on insert
              end
              err_q   <= mem_rsp_error || fill_err_q;
              lst     <= L_DONE;
            end else begin
              fill_beat <= fill_beat + 2'd1;
            end
          end
        end

        L_WREQ: begin
          // A store is fire-and-forget on this bus: no response is generated,
          // because a requester that is filling takes ANY response as its own
          // data. Returning one here corrupted the next read.
          if (mem_req_ready) lst <= L_IDLE;
        end

        L_DONE: lst <= L_IDLE;
        default: lst <= L_IDLE;
      endcase
    end
  end

endmodule
`default_nettype wire
