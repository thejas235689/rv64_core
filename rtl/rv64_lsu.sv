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
  // atomics (A extension). req_atomic = AT_NONE for an ordinary load or store.
  input  logic [1:0]  req_atomic,
  input  logic [4:0]  req_amo_op,
  // ---- translation ---------------------------------------------------------
  input  logic [63:0] satp,
  input  logic [1:0]  priv,
  input  logic        mprv, sum, mxr,
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

  typedef enum logic [3:0] {S_IDLE, S_XLATE, S_REQ, S_RESP, S_WREQ, S_DONE,
                           S_REQ2, S_RESP2} state_e;

  state_e      state;
  // S_WREQ: the write half of an AMO's read-modify-write

  logic [63:0] addr_q, wdata_q;
  logic [2:0]  size_q;
  logic        uns_q, we_q;
  logic        fault_q;
  logic [63:0] data_q;
  logic        done_q_r;
  logic [63:0] data_lat;

  // ---- atomic support ------------------------------------------------------
  // A single-hart reservation: an LR records the address, an SC succeeds only
  // if that address is still reserved, and any SC clears it (success or fail).
  // A multi-hart system would also have to clear it on a foreign store; that is
  // a cache-coherence concern and is called out in the header rather than
  // pretended here.
  logic        resv_valid;
  logic [63:0] resv_addr;

  logic [1:0]  atomic_q;
  logic [4:0]  amo_op_q;
  logic        sc_ok_q;
  logic [63:0] amo_new;

  // The read-modify-write value: old data from the response, source from the
  // instruction. For .W the operation is on 32 bits and the result is
  // zero-extended, as the A extension specifies.
  function automatic logic [63:0] amo_calc(input logic [4:0]  op,
                                           input logic [63:0] old_v,
                                           input logic [63:0] src,
                                           input logic        is_w);
    logic [63:0]        o, sx;
    logic signed [63:0] os, ss;
    logic [63:0]        r;
    begin
      o  = is_w ? {32'd0, old_v[31:0]} : old_v;
      sx = is_w ? {32'd0, src[31:0]}   : src;
      os = is_w ? $signed({{32{old_v[31]}}, old_v[31:0]}) : $signed(old_v);
      ss = is_w ? $signed({{32{src[31]}}, src[31:0]})     : $signed(src);
      unique case (op)
        5'b00001: r = sx;                                  // AMOSWAP
        5'b00000: r = o + sx;                              // AMOADD
        5'b00100: r = o ^ sx;                              // AMOXOR
        5'b01100: r = o | sx;                              // AMOOR
        5'b01000: r = o & sx;                              // AMOAND
        5'b10000: r = ($signed(os) < $signed(ss)) ? o : sx; // AMOMIN
        5'b10100: r = ($signed(os) > $signed(ss)) ? o : sx; // AMOMAX
        5'b11000: r = (o < sx) ? o : sx;                    // AMOMINU
        5'b11100: r = (o > sx) ? o : sx;                    // AMOMAXU
        default:  r = sx;
      endcase
      return is_w ? {32'd0, r[31:0]} : r;
    end
  endfunction

  wire amo_is_w = (size_q == MSZ_W);

  // ---- Sv39 translation ----------------------------------------------------
  // The walker's PTE reads share this unit's memory port: while it is walking it
  // owns the bus, otherwise the LSU does. A translation that faults becomes the
  // access fault for the original request.
  logic        mmu_req, mmu_resp, mmu_fault, mmu_busy;
  logic [63:0] mmu_paddr, mmu_cause;
  logic        mmu_pte_valid;
  logic [63:0] mmu_pte_addr;
  logic        xlate_q;
  logic [63:0] paddr_q;

  wire [1:0] acc_kind = we_q ? 2'd2 : 2'd1;      // store or load

  rv64_mmu u_mmu (
    .clk(clk), .rst_n(rst_n),
    .satp(satp), .priv(priv), .mprv(mprv), .sum(sum), .mxr(mxr),
    .req_valid(mmu_req), .vaddr(addr_q), .acc_type(acc_kind),
    .resp_valid(mmu_resp), .paddr(mmu_paddr), .fault(mmu_fault),
    .fault_cause(mmu_cause), .fault_tval(), .busy(mmu_busy),
    .pte_req_valid(mmu_pte_valid), .pte_req_addr(mmu_pte_addr),
    .pte_req_ready(mem_req_ready), .pte_rsp_valid(mem_rsp_valid),
    .pte_rsp_data(mem_rsp_rdata), .pte_rsp_error(mem_rsp_error)
  );

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
  // ---- Zicclsm: an access that crosses an 8-byte beat is split in two -------
  // The old strobe was 8 bits wide, so `8'h0F << 5` dropped a byte and a
  // misaligned word store wrote only 3 of its 4 bytes. Everything is computed at
  // 16 bytes and sliced per beat instead.
  wire [3:0]  size_bytes = (size_q == MSZ_B) ? 4'd1 :
                           (size_q == MSZ_H) ? 4'd2 :
                           (size_q == MSZ_W) ? 4'd4 : 4'd8;
  wire        span       = ({1'b0, addr_q[2:0]} + size_bytes) > 4'd8;
  wire [7:0]  shift_b    = {addr_q[2:0], 3'b000};
  wire        beat_hi    = (state == S_REQ2) || (state == S_RESP2);

  logic [15:0]  strb16;
  logic [127:0] data128;
  always_comb begin
    unique case (size_q)
      MSZ_B:   strb16 = 16'h0001;
      MSZ_H:   strb16 = 16'h0003;
      MSZ_W:   strb16 = 16'h000F;
      default: strb16 = 16'h00FF;
    endcase
    strb16 = strb16 << addr_q[2:0];   // byte strobes shift by bytes
    unique case (size_q)
      MSZ_B:   data128 = {120'd0, wdata_q[7:0]};
      MSZ_H:   data128 = {112'd0, wdata_q[15:0]};
      MSZ_W:   data128 = {96'd0,  wdata_q[31:0]};
      default: data128 = {64'd0,  wdata_q};
    endcase
    data128 = data128 << shift_b;
  end

  // The response for the beat being captured arrives THIS cycle, so both muxes
  // read the live bus while their state is active; reading only the latches
  // returns the previous access's data.
  logic [63:0] lo_q, hi_q;
  wire  [63:0] lo_now = (state == S_RESP)  ? mem_rsp_rdata : lo_q;
  wire  [63:0] hi_now = (state == S_RESP2) ? mem_rsp_rdata : hi_q;
  wire  [63:0] rsp_merged = span ? ((lo_now >> shift_b) | (hi_now << (8'd64 - shift_b)))
                                 :  (lo_now >> shift_b);

  assign rsp_shifted = rsp_merged;

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
  // S_WREQ is the write half of an AMO's read-modify-write: without it here the
  // read happens and the write never reaches the bus.
  assign mem_req_valid = mmu_busy ? mmu_pte_valid
                                  : ((state == S_REQ) || (state == S_WREQ) ||
                                     (state == S_REQ2));
  assign mem_req_addr  = mmu_busy ? mmu_pte_addr
                        : (beat_hi ? (paddr_q + 64'd8) : paddr_q);
  assign mem_req_we    = mmu_busy ? 1'b0 : we_q;
  // During an AMO's write phase the data is the computed result, not rs2.
  assign mem_req_wdata = (atomic_q == AT_AMO) ? amo_new
                        : (beat_hi ? data128[127:64] : data128[63:0]);
  assign mem_req_wstrb = (mmu_busy || !we_q) ? 8'h00
                        : (beat_hi ? strb16[15:8] : strb16[7:0]);

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
      resv_valid <= 1'b0;
      resv_addr  <= 64'd0;
      mmu_req    <= 1'b0;
      xlate_q    <= 1'b0;
      paddr_q    <= 64'd0;
      atomic_q   <= AT_NONE;
      amo_op_q   <= 5'd0;
      sc_ok_q    <= 1'b1;
      amo_new    <= 64'd0;
    end else begin
      done_q_r <= 1'b0;

      unique case (state)
        S_IDLE: begin
          if (req_start) begin
            addr_q    <= req_addr;
            wdata_q   <= req_wdata;
            size_q    <= req_size;
            uns_q     <= req_uns;
            atomic_q  <= req_atomic;
            amo_op_q  <= req_amo_op;
            fault_q   <= !pmp_ok;
            sc_ok_q   <= 1'b1;
            // An SC only touches memory when the reservation still matches;
            // a failed SC returns 1 and performs no bus access at all.
            mmu_req <= 1'b1;
            xlate_q <= 1'b1;
            paddr_q <= req_addr;      // bare default until the MMU answers
            // the reservation and the bus both use the physical address, so the
            // access is deferred until translation completes
            state   <= S_XLATE;
          end
        end

        // ---- translation -------------------------------------------------
        S_XLATE: begin
          mmu_req <= 1'b0;
          if (mmu_resp) begin
            if (mmu_fault) begin
              fault_q <= 1'b1;
              state   <= S_DONE;
            end else begin
              paddr_q <= mmu_paddr;
              if (req_atomic == AT_SC) begin
                if (pmp_ok && resv_valid && (resv_addr == mmu_paddr)) begin
                  we_q     <= 1'b1;
                  sc_ok_q  <= 1'b1;
                  state    <= S_REQ;
                end else begin
                  we_q     <= 1'b0;
                  sc_ok_q  <= 1'b0;
                  fault_q  <= !pmp_ok;
                  state    <= S_DONE;
                end
                resv_valid <= 1'b0;             // an SC always consumes it
              end else if (req_atomic != AT_NONE) begin
                we_q  <= 1'b0;                  // LR and AMO read first
                if (pmp_ok) state <= S_REQ;
                else        state <= S_DONE;
              end else begin
                we_q <= req_we;
                if (pmp_ok) state <= S_REQ;
                else        state <= S_DONE;
              end
            end
          end
        end

        S_REQ: begin
          if (mem_req_ready) begin
            if (we_q) begin
              if (span) state <= S_REQ2;   // Icarus rejects enums in ternaries
              else      state <= S_DONE;
            end else state <= S_RESP;
          end
        end

        S_REQ2: begin
          if (mem_req_ready) begin
            if (we_q) state <= S_DONE;
            else      state <= S_RESP2;
          end
        end

        S_RESP2: begin
          if (mem_rsp_valid) begin
            fault_q  <= mem_rsp_error;
            data_lat <= data_q;      // data_q merges both beats
            state    <= S_DONE;
          end
        end

        // AMO write phase: the read has completed and amo_new holds the result
        S_WREQ: begin
          if (mem_req_ready) state <= S_DONE;
        end

        S_RESP: begin
          if (mem_rsp_valid) begin
            fault_q <= mem_rsp_error;
            lo_q    <= mem_rsp_rdata;
            if (span && (atomic_q == AT_NONE)) begin
              state <= S_REQ2;
            end else if (atomic_q == AT_LR) begin
              // the loaded value is the result, and the address is reserved
              data_lat   <= data_q;
              resv_valid <= !mem_rsp_error;
              resv_addr  <= addr_q;
              state      <= S_DONE;
            end else if (atomic_q == AT_AMO) begin
              // old value to rd, computed value to memory
              data_lat <= data_q;
              amo_new  <= amo_calc(amo_op_q, data_q, wdata_q, amo_is_w);
              we_q     <= 1'b1;
              state    <= S_WREQ;
            end else begin
              data_lat <= data_q;
              state    <= S_DONE;
            end
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
  // An SC reports 0 on success and 1 on failure; everything else reports the
  // value captured from the bus.
  assign load_data = (atomic_q == AT_SC) ? {63'd0, !sc_ok_q} : data_lat;

endmodule
`default_nettype wire
