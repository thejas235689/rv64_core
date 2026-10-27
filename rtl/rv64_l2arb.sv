`timescale 1ns/1ps
// =============================================================================
// rv64_l2arb.sv -- two-port arbiter feeding a shared L2.
//
// The I-cache and the D-cache each present one fill request. Only one can use the
// L2 at a time, so this arbitrates between them and routes the response back to
// whoever owns the transaction.
//
// POLICY: round-robin on grant, and the grant is HELD until the response returns.
// Holding is the important part -- both L1s present a request and wait for a
// response, so switching away mid-transaction would drop a request and hang the
// cache that sent it. Round-robin rather than fixed priority because a fixed
// priority starves the loser: an instruction stream that misses constantly would
// lock out every data fill.
//
// The owner is registered, so the response routes to the port that was granted,
// not the one asking now.
// =============================================================================
`default_nettype none

module rv64_l2arb (
  input  logic        clk,
  input  logic        rst_n,

  // ---- port A (instruction fills) -----------------------------------------
  input  logic        a_req_valid,
  input  logic [63:0] a_req_addr,
  input  logic        a_req_we,
  input  logic [7:0]  a_req_wstrb,
  input  logic [63:0] a_req_wdata,
  output logic        a_rsp_valid,
  output logic [63:0] a_rsp_rdata,
  output logic        a_rsp_error,

  // ---- port B (data fills) ------------------------------------------------
  input  logic        b_req_valid,
  input  logic [63:0] b_req_addr,
  input  logic        b_req_we,
  input  logic [7:0]  b_req_wstrb,
  input  logic [63:0] b_req_wdata,
  output logic        b_rsp_valid,
  output logic [63:0] b_rsp_rdata,
  output logic        b_rsp_error,

  // ---- to the L2 -----------------------------------------------------------
  output logic        req_valid,
  output logic [63:0] req_addr,
  output logic        req_we,
  output logic [7:0]  req_wstrb,
  output logic [63:0] req_wdata,
  input  logic        l2_req_ready,  // the L2 has taken the request
  input  logic        rsp_valid,
  input  logic [63:0] rsp_rdata,
  input  logic        rsp_error,

  // ---- acceptance ----------------------------------------------------------
  // A requester must not assume its request was taken: with a transaction in
  // flight the arbiter cannot start another, and a cache that assumed otherwise
  // dropped the request and hung.
  output logic        req_ready,

  // ---- observability -------------------------------------------------------
  output logic        grant_a,        // current owner (1 = A)
  output logic        busy,
  output logic [31:0] grant_a_count,
  output logic [31:0] grant_b_count
);
  logic       owner_q;        // 1 = A owns the in-flight transaction
  logic       busy_q;
  logic       issued_q;       // the L2 has accepted this transaction
  // The requester drops its request as soon as it is accepted, so the payload has
  // to be latched at grant time -- forwarding the live inputs sent a stale
  // address to memory.
  logic [63:0] addr_q, wdata_q;
  logic [7:0]  wstrb_q;
  logic        we_q;
  logic       last_q;         // who was granted last, for round-robin
  logic [31:0] ga_q, gb_q;

  assign req_ready = !busy_q;
  assign grant_a = owner_q;
  assign busy    = busy_q;

  // a new grant is taken when nothing is in flight
  wire take_a = !busy_q && a_req_valid && (!b_req_valid || !last_q);
  wire take_b = !busy_q && b_req_valid && (!a_req_valid ||  last_q);

  assign req_valid = busy_q ? !issued_q : (a_req_valid ? 1'b1 : b_req_valid);
  assign req_addr  = busy_q ? addr_q  : (a_req_valid ? a_req_addr  : b_req_addr);
  assign req_we    = busy_q ? we_q    : (a_req_valid ? a_req_we    : b_req_we);
  assign req_wstrb = busy_q ? wstrb_q : (a_req_valid ? a_req_wstrb : b_req_wstrb);
  assign req_wdata = busy_q ? wdata_q : (a_req_valid ? a_req_wdata : b_req_wdata);

  assign a_rsp_valid = rsp_valid && owner_q;
  assign a_rsp_rdata = rsp_rdata;
  assign a_rsp_error = rsp_error;
  assign b_rsp_valid = rsp_valid && !owner_q;
  assign b_rsp_rdata = rsp_rdata;
  assign b_rsp_error = rsp_error;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      owner_q  <= 1'b1;
      busy_q   <= 1'b0;
      issued_q <= 1'b0;
      last_q   <= 1'b0;
      addr_q   <= 64'd0;
      wdata_q  <= 64'd0;
      wstrb_q  <= 8'd0;
      we_q     <= 1'b0;
      ga_q    <= 32'd0;
      gb_q    <= 32'd0;
    end else begin
      if (take_a) begin
        owner_q <= 1'b1;
        busy_q  <= 1'b1;
        last_q  <= 1'b1;
        addr_q  <= a_req_addr;
        we_q    <= a_req_we;
        wstrb_q <= a_req_wstrb;
        wdata_q <= a_req_wdata;
        ga_q    <= ga_q + 32'd1;
      end else if (take_b) begin
        owner_q <= 1'b0;
        busy_q  <= 1'b1;
        last_q  <= 1'b0;
        addr_q  <= b_req_addr;
        we_q    <= b_req_we;
        wstrb_q <= b_req_wstrb;
        wdata_q <= b_req_wdata;
        gb_q    <= gb_q + 32'd1;
      end
      // the request is issued once, when the L2 takes it
      if (busy_q && !issued_q && l2_req_ready) issued_q <= 1'b1;
      // the transaction ends when its response returns
      if (rsp_valid) begin
        busy_q   <= 1'b0;
        issued_q <= 1'b0;
      end
    end
  end

  assign grant_a_count = ga_q;
  assign grant_b_count = gb_q;

endmodule
`default_nettype wire
