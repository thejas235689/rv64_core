`timescale 1ns/1ps
// =============================================================================
// rv64_bootauth_hmac.sv -- keyed boot image authentication.
//
// Replaces the FNV-1a authenticator for the case that matters: FNV detects
// corruption, but anyone who rewrites the image can recompute it. Here the image is
// authenticated with HMAC-SHA-256 under a secret key, so a forged image cannot
// produce a valid MAC without the key.
//
// `boot_ok` asserts only on an exact MAC match. A mismatch raises `boot_fail` and
// leaves `boot_ok` low so the core stays held.
//
// Scope: one 512-bit image block. A multi-block image needs the HMAC streamed across
// blocks, which this does not do -- stated here rather than implied.
// =============================================================================
module rv64_bootauth_hmac (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         start,        // pulse: authenticate
  input  logic [255:0] key,
  input  logic [511:0] image,        // the padded image block
  input  logic [255:0] expected,     // the MAC the platform expects
  output logic         busy,
  output logic         done,
  output logic         boot_ok,      // sticky until reset
  output logic         boot_fail,    // sticky until reset
  output logic [255:0] mac           // the MAC actually computed
);
  logic hmac_start, hmac_busy, hmac_done;
  logic [255:0] hmac_mac;
  logic         launched_q;

  rv64_hmac u_hmac (
    .clk(clk), .rst_n(rst_n), .start(hmac_start), .key(key), .msg(image),
    .busy(hmac_busy), .done(hmac_done), .mac(hmac_mac)
  );

  assign busy = launched_q || hmac_busy;
  assign mac  = hmac_mac;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hmac_start <= 1'b0;
      launched_q <= 1'b0;
      done       <= 1'b0;
      boot_ok    <= 1'b0;
      boot_fail  <= 1'b0;
    end else begin
      hmac_start <= 1'b0;
      done       <= 1'b0;
      if (start && !launched_q && !boot_ok && !boot_fail) begin
        hmac_start <= 1'b1;
        launched_q <= 1'b1;
      end else if (hmac_done) begin
        launched_q <= 1'b0;
        done       <= 1'b1;
        // compare the whole MAC: a partial match is a failure
        if (hmac_mac == expected) boot_ok   <= 1'b1;
        else                      boot_fail <= 1'b1;
      end
    end
  end
endmodule
