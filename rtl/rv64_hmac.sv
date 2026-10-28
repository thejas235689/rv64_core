`timescale 1ns/1ps
// =============================================================================
// rv64_hmac.sv -- HMAC-SHA-256 over a single 512-bit message block.
//
// HMAC(K, m) = H((K ^ opad) || H((K ^ ipad) || m))
//
// A keyed MAC is what makes boot authentication tamper-RESISTANT rather than just
// corruption-detecting: an attacker who rewrites the image cannot produce a valid
// MAC without the key, whereas an unkeyed hash (FNV, or plain SHA-256) can simply
// be recomputed.
//
// Scope: one message block. The key is 32 bytes (zero-padded to 64 internally).
// =============================================================================
module rv64_hmac (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         start,
  input  logic [255:0] key,
  input  logic [511:0] msg,
  output logic         busy,
  output logic         done,
  output logic [255:0] mac
);
  localparam logic [511:0] IPAD = {64{8'h36}};
  localparam logic [511:0] OPAD = {64{8'h5c}};

  typedef enum logic [2:0] {H_IDLE, H_W1, H_W2, H_W3, H_W4, H_DONE} hstate_e;
  hstate_e st;

  logic         sha_start, sha_init, sha_busy, sha_done;
  logic [511:0] sha_block;
  logic [255:0] sha_digest;
  logic [255:0] inner_q;
  logic [511:0] keyblock;

  rv64_sha256 u_sha (
    .clk(clk), .rst_n(rst_n), .start(sha_start), .init(sha_init),
    .block(sha_block), .busy(sha_busy), .done(sha_done), .digest(sha_digest)
  );

  assign keyblock = {key, 256'd0};

  assign busy = (st != H_IDLE) && (st != H_DONE);
  assign done = (st == H_DONE);
  assign mac  = sha_digest;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st        <= H_IDLE;
      sha_start <= 1'b0;
      sha_init  <= 1'b0;
      sha_block <= 512'd0;
      inner_q   <= 256'd0;
    end else begin
      sha_start <= 1'b0;
      sha_init  <= 1'b0;
      unique case (st)
        H_IDLE: if (start) begin
          sha_block <= keyblock ^ IPAD;      // block 1: K ^ ipad
          sha_init  <= 1'b1;
          sha_start <= 1'b1;
          st        <= H_W1;
        end
        H_W1: if (sha_done) begin
          sha_block <= msg;                  // block 2: the message
          sha_start <= 1'b1;
          st        <= H_W2;
        end
        H_W2: if (sha_done) begin
          inner_q   <= sha_digest;           // inner digest
          sha_block <= keyblock ^ OPAD;      // block 3: K ^ opad
          sha_init  <= 1'b1;
          sha_start <= 1'b1;
          st        <= H_W3;
        end
        H_W3: if (sha_done) begin
          // block 4: the 32-byte inner digest, padded: 0x80, zeros, then the
          // bit length of 32 + 64 = 96 bytes = 768 bits
          sha_block <= {inner_q, 8'h80, 184'd0, 64'd768};
          sha_start <= 1'b1;
          st        <= H_W4;
        end
        H_W4: if (sha_done) st <= H_DONE;
        H_DONE: st <= H_IDLE;
        default: st <= H_IDLE;
      endcase
    end
  end
endmodule
