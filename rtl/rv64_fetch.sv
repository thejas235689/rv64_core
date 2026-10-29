`timescale 1ns/1ps
// =============================================================================
// rv64_fetch.sv -- fetch buffering with request/response tracking.
//   The instruction port returns one aligned 64-bit beat carrying two 32-bit
//   parcels; the buffer serves both before issuing the next request, so a
//   sequential stream costs one request per eight bytes.
//   Responses are matched against the address actually requested, so a beat
//   that arrives after a redirect is discarded instead of being executed.
// =============================================================================
`default_nettype none

module rv64_fetch (
  input  logic        clk,
  input  logic        rst_n,

  // ---- control from the core ------------------------------------------------
  input  logic        redirect,      // squash the buffer, restart at pc_i
  input  logic [63:0] pc_i,          // next instruction address
  input  logic        consume,       // an instruction was accepted downstream
  input  logic        pause,         // stop issuing requests

  // ---- instruction interface ------------------------------------------------
  output logic        req_valid,
  output logic [63:0] req_addr,
  input  logic        req_ready,
  input  logic        rsp_valid,
  input  logic [63:0] rsp_data,
  input  logic        rsp_error,

  // ---- instruction out ------------------------------------------------------
  output logic        insn_valid,
  output logic [63:0] insn_pc,
  output logic [31:0] insn,
  output logic [1:0]  insn_len,
  output logic        fault_valid,
  output logic [63:0] fault_pc,

  // ---- predecode tags for the instruction being presented ------------------
  output logic        tag_is_control,
  output logic        tag_writes_rd,
  output logic        tag_fusion_valid,
  output logic [1:0]  tag_fusion_kind
);
  logic        beat_v;
  logic [63:0] beat_addr;
  logic [63:0] beat_data;

  logic        out_pending;
  logic [63:0] out_addr;

  logic        fault_q;
  logic [63:0] fault_addr_q;

  logic [63:0] aligned;
  logic        need;

  // The previously CONSUMED instruction, so the fusion detector sees the pair
  // as the pipeline sees it rather than as the fetch stream happens to align.
  logic [31:0] prev_insn_q;
  logic        prev_valid_q;

  logic        nxt_v;
  logic [63:0] nxt_addr, nxt_data;
  logic [63:0] win;
  logic [31:0] insn_raw;
  logic        straddle;

  assign win      = {nxt_data, beat_data};
  assign insn_raw = win[{pc_i[2:1], 4'b0000} +: 32];
  assign straddle = (pc_i[2:0] == 3'd6) && (insn_raw[1:0] == 2'b11);

  logic [31:0] cur_insn;
  logic        rvc_illegal;
  rv64_rvc_expand u_rvc (
    .cin(insn_raw[15:0]), .cout(cur_insn), .illegal(rvc_illegal), .is_ebreak()
  );
  wire is_rvc = (insn_raw[1:0] != 2'b11);

  rv64_predecode u_pre (
    .insn           (cur_insn),
    .prev_insn      (prev_insn_q),
    .prev_valid     (prev_valid_q),
    .is_control     (tag_is_control),
    .is_branch      (),
    .is_jal         (),
    .is_jalr        (),
    .writes_rd      (tag_writes_rd),
    .is_load        (),
    .is_store       (),
    .rd             (),
    .rs1            (),
    .rs2            (),
    .fusion_valid   (tag_fusion_valid),
    .fusion_kind    (tag_fusion_kind)
  );

  assign aligned = {pc_i[63:3], 3'b000};
  assign need    = !beat_v || (beat_addr != aligned);

  // single outstanding request: never issue while one is in flight
  wire need_nxt = (pc_i[2:0] == 3'd6) && (!nxt_v || (nxt_addr != (aligned + 64'd8)));
  assign req_valid = (need || need_nxt) && !pause && !fault_q && !out_pending;
  assign req_addr  = need ? aligned : (aligned + 64'd8);

  assign insn_valid = beat_v && (beat_addr == aligned) && !fault_q &&
                      (!straddle || nxt_v);
  assign insn_pc    = pc_i;
  assign insn       = is_rvc ? cur_insn : insn_raw;
  assign insn_len   = is_rvc ? 2'd2 : 2'd4;

  assign fault_valid = fault_q;
  assign fault_pc    = fault_addr_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      beat_v       <= 1'b0;
      beat_addr    <= 64'd0;
      beat_data    <= 64'd0;
      out_pending  <= 1'b0;
      out_addr     <= 64'd0;
      fault_q      <= 1'b0;
      fault_addr_q <= 64'd0;
      prev_insn_q  <= 32'd0;
      prev_valid_q <= 1'b0;
      nxt_v        <= 1'b0;
      nxt_addr     <= 64'd0;
      nxt_data     <= 64'd0;
    end else if (redirect) begin
      beat_v       <= 1'b0;
      nxt_v        <= 1'b0;
      out_pending  <= 1'b0;
      fault_q      <= 1'b0;
    end else begin
      // remember what was consumed, for the next pair's fusion hint
      if (consume && insn_valid) begin
        prev_insn_q  <= is_rvc ? cur_insn : insn_raw;
        prev_valid_q <= 1'b1;
      end
      // issue tracking
      if (req_valid && req_ready) begin
        out_pending <= 1'b1;
        out_addr    <= need ? aligned : (aligned + 64'd8);
      end

      // response: accept only if it still matches the address we want
      if (rsp_valid && out_pending) begin
        out_pending <= 1'b0;
        if (rsp_error && (out_addr == aligned)) begin
          fault_q      <= 1'b1;
          fault_addr_q <= aligned;
          beat_v       <= 1'b0;
        end else if (!rsp_error) begin
          if (out_addr == aligned) begin
            beat_v <= 1'b1; beat_addr <= out_addr; beat_data <= rsp_data;
          end else begin
            nxt_v <= 1'b1; nxt_addr <= out_addr; nxt_data <= rsp_data;
          end
        end
      end
    end
  end

endmodule
`default_nettype wire
