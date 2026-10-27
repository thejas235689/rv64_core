`timescale 1ns/1ps
// =============================================================================
// rv64_bootauth.sv -- boot image authentication.
//
// Streams a boot image through FNV-1a-64 and compares the digest against the one
// the platform expects. `boot_ok` is asserted only on an exact match; a mismatch
// raises `boot_fail` and leaves `boot_ok` low, so the core can be held in reset.
//
// FNV-1a is used because it is a real hash with published constants and a
// well-defined byte order, so an image's digest can be reproduced off-chip by any
// build tooling. It is NOT a cryptographic signature: it detects corruption and
// accidental mismatch, and it does not resist an attacker who can rewrite both the
// image and the expected digest. A production root of trust needs a signature
// check (RSA/ECDSA) or a keyed MAC, which this block does not implement -- that is
// stated here rather than left to be discovered.
//
//   FNV-1a-64:  h = 0xcbf29ce484222325
//               for each byte b:  h = (h XOR b) * 0x00000100000001b3
//   bytes are taken least-significant first within each 64-bit word.
// =============================================================================
`default_nettype none

module rv64_bootauth (
  input  logic        clk,
  input  logic        rst_n,

  // ---- start / expected digest --------------------------------------------
  input  logic        start,           // begin a new image
  input  logic [63:0] expected,        // digest the platform expects
  input  logic [31:0] nwords,          // how many 64-bit words follow

  // ---- image stream --------------------------------------------------------
  input  logic        in_valid,
  input  logic [63:0] in_data,
  output logic        in_ready,

  // ---- results -------------------------------------------------------------
  output logic        busy,
  output logic        boot_ok,         // exactly one cycle, on a match
  output logic        boot_fail,       // exactly one cycle, on a mismatch
  output logic [63:0] digest,          // the digest just computed
  output logic [31:0] words_hashed
);
  localparam logic [63:0] BASIS = 64'hcbf2_9ce4_8422_2325;
  localparam logic [63:0] PRIME = 64'h0000_0100_0000_01b3;

  typedef enum logic [1:0] {A_IDLE, A_RUN, A_DONE} astate_e;
  astate_e     ast;
  logic [63:0] h_q;
  logic [31:0] cnt_q, n_q;
  logic [63:0] exp_q;
  logic        ok_q, fail_q;

  assign in_ready  = (ast == A_RUN);
  assign busy      = (ast == A_RUN);
  assign boot_ok   = ok_q;
  assign boot_fail = fail_q;
  assign digest    = h_q;
  assign words_hashed = cnt_q;

  // FNV-1a over the eight bytes of one word, least-significant byte first
  function automatic logic [63:0] fnv_word(input logic [63:0] h, input logic [63:0] w);
    logic [63:0] acc;
    begin
      acc = h;
      for (int b = 0; b < 8; b++) begin
        acc = (acc ^ {56'd0, w[8*b +: 8]}) * PRIME;
      end
      fnv_word = acc;
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ast   <= A_IDLE;
      h_q   <= BASIS;
      cnt_q <= 32'd0;
      n_q   <= 32'd0;
      exp_q <= 64'd0;
      ok_q  <= 1'b0;
      fail_q<= 1'b0;
    end else begin
      ok_q   <= 1'b0;
      fail_q <= 1'b0;
      unique case (ast)
        A_IDLE: begin
          if (start) begin
            h_q   <= BASIS;
            cnt_q <= 32'd0;
            n_q   <= nwords;
            exp_q <= expected;
            ast   <= A_RUN;
          end
        end
        A_RUN: begin
          if (in_valid) begin
            h_q   <= fnv_word(h_q, in_data);
            cnt_q <= cnt_q + 32'd1;
            if (cnt_q + 32'd1 == n_q) ast <= A_DONE;
          end
        end
        A_DONE: begin
          if (h_q == exp_q) ok_q   <= 1'b1;
          else              fail_q <= 1'b1;
          ast <= A_IDLE;
        end
        default: ast <= A_IDLE;
      endcase
    end
  end

endmodule
`default_nettype wire
