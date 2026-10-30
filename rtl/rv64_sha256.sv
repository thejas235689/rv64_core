`timescale 1ns/1ps
// =============================================================================
// rv64_sha256.sv -- SHA-256 compression, one round per cycle.
//
// Streaming: load a 512-bit block, run 64 rounds, get a 256-bit digest. The
// chaining state carries over between blocks, which is what HMAC needs.
//
// This replaces FNV-1a in the boot authenticator. FNV detects corruption but not
// tampering -- an attacker who rewrites the image recomputes the hash. A keyed
// MAC over SHA-256 cannot be forged without the key.
// =============================================================================
module rv64_sha256 (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         start,
  input  logic         init,        // pulse with start: reset the chaining state
  input  logic [511:0] block,
  output logic         busy,
  output logic         done,        // one-cycle pulse
  output logic [255:0] digest
);
  localparam logic [31:0] K0  = 32'h428a2f98, K1  = 32'h71374491;
  localparam logic [31:0] K2  = 32'hb5c0fbcf, K3  = 32'he9b5dba5;
  localparam logic [31:0] K4  = 32'h3956c25b, K5  = 32'h59f111f1;
  localparam logic [31:0] K6  = 32'h923f82a4, K7  = 32'hab1c5ed5;
  localparam logic [31:0] K8  = 32'hd807aa98, K9  = 32'h12835b01;
  localparam logic [31:0] K10 = 32'h243185be, K11 = 32'h550c7dc3;
  localparam logic [31:0] K12 = 32'h72be5d74, K13 = 32'h80deb1fe;
  localparam logic [31:0] K14 = 32'h9bdc06a7, K15 = 32'hc19bf174;
  localparam logic [31:0] K16 = 32'he49b69c1, K17 = 32'hefbe4786;
  localparam logic [31:0] K18 = 32'h0fc19dc6, K19 = 32'h240ca1cc;
  localparam logic [31:0] K20 = 32'h2de92c6f, K21 = 32'h4a7484aa;
  localparam logic [31:0] K22 = 32'h5cb0a9dc, K23 = 32'h76f988da;
  localparam logic [31:0] K24 = 32'h983e5152, K25 = 32'ha831c66d;
  localparam logic [31:0] K26 = 32'hb00327c8, K27 = 32'hbf597fc7;
  localparam logic [31:0] K28 = 32'hc6e00bf3, K29 = 32'hd5a79147;
  localparam logic [31:0] K30 = 32'h06ca6351, K31 = 32'h14292967;
  localparam logic [31:0] K32 = 32'h27b70a85, K33 = 32'h2e1b2138;
  localparam logic [31:0] K34 = 32'h4d2c6dfc, K35 = 32'h53380d13;
  localparam logic [31:0] K36 = 32'h650a7354, K37 = 32'h766a0abb;
  localparam logic [31:0] K38 = 32'h81c2c92e, K39 = 32'h92722c85;
  localparam logic [31:0] K40 = 32'ha2bfe8a1, K41 = 32'ha81a664b;
  localparam logic [31:0] K42 = 32'hc24b8b70, K43 = 32'hc76c51a3;
  localparam logic [31:0] K44 = 32'hd192e819, K45 = 32'hd6990624;
  localparam logic [31:0] K46 = 32'hf40e3585, K47 = 32'h106aa070;
  localparam logic [31:0] K48 = 32'h19a4c116, K49 = 32'h1e376c08;
  localparam logic [31:0] K50 = 32'h2748774c, K51 = 32'h34b0bcb5;
  localparam logic [31:0] K52 = 32'h391c0cb3, K53 = 32'h4ed8aa4a;
  localparam logic [31:0] K54 = 32'h5b9cca4f, K55 = 32'h682e6ff3;
  localparam logic [31:0] K56 = 32'h748f82ee, K57 = 32'h78a5636f;
  localparam logic [31:0] K58 = 32'h84c87814, K59 = 32'h8cc70208;
  localparam logic [31:0] K60 = 32'h90befffa, K61 = 32'ha4506ceb;
  localparam logic [31:0] K62 = 32'hbef9a3f7, K63 = 32'hc67178f2;

  logic [31:0] w [0:63];
  logic [31:0] h [0:7];
  logic [31:0] a, b, c, d, e, f, g, hh;
  logic [6:0]  rnd;
  logic        running;

  assign busy = running;

  function automatic logic [31:0] rotr(input logic [31:0] x, input int n);
    return (x >> n) | (x << (32 - n));
  endfunction

  function automatic logic [31:0] kconst(input logic [6:0] i);
    case (i)
      7'd0:  kconst = K0;   7'd1:  kconst = K1;   7'd2:  kconst = K2;   7'd3:  kconst = K3;
      7'd4:  kconst = K4;   7'd5:  kconst = K5;   7'd6:  kconst = K6;   7'd7:  kconst = K7;
      7'd8:  kconst = K8;   7'd9:  kconst = K9;   7'd10: kconst = K10;  7'd11: kconst = K11;
      7'd12: kconst = K12;  7'd13: kconst = K13;  7'd14: kconst = K14;  7'd15: kconst = K15;
      7'd16: kconst = K16;  7'd17: kconst = K17;  7'd18: kconst = K18;  7'd19: kconst = K19;
      7'd20: kconst = K20;  7'd21: kconst = K21;  7'd22: kconst = K22;  7'd23: kconst = K23;
      7'd24: kconst = K24;  7'd25: kconst = K25;  7'd26: kconst = K26;  7'd27: kconst = K27;
      7'd28: kconst = K28;  7'd29: kconst = K29;  7'd30: kconst = K30;  7'd31: kconst = K31;
      7'd32: kconst = K32;  7'd33: kconst = K33;  7'd34: kconst = K34;  7'd35: kconst = K35;
      7'd36: kconst = K36;  7'd37: kconst = K37;  7'd38: kconst = K38;  7'd39: kconst = K39;
      7'd40: kconst = K40;  7'd41: kconst = K41;  7'd42: kconst = K42;  7'd43: kconst = K43;
      7'd44: kconst = K44;  7'd45: kconst = K45;  7'd46: kconst = K46;  7'd47: kconst = K47;
      7'd48: kconst = K48;  7'd49: kconst = K49;  7'd50: kconst = K50;  7'd51: kconst = K51;
      7'd52: kconst = K52;  7'd53: kconst = K53;  7'd54: kconst = K54;  7'd55: kconst = K55;
      7'd56: kconst = K56;  7'd57: kconst = K57;  7'd58: kconst = K58;  7'd59: kconst = K59;
      7'd60: kconst = K60;  7'd61: kconst = K61;  7'd62: kconst = K62;
      default: kconst = K63;
    endcase
  endfunction

  logic [31:0] t1, t2, wi, s0, s1, ch, maj;
  always_comb begin
    wi  = w[rnd];
    s1  = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
    ch  = (e & f) ^ (~e & g);
    t1  = hh + s1 + ch + kconst(rnd) + wi;
    s0  = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
    maj = (a & b) ^ (a & c) ^ (b & c);
    t2  = s0 + maj;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      running <= 1'b0;
      done    <= 1'b0;
      rnd     <= 7'd0;
      for (int i = 0; i < 8; i++) h[i] <= 32'd0;
    end else begin
      done <= 1'b0;
      if (start) begin
        for (int i = 0; i < 16; i++) w[i] <= block[511 - 32*i -: 32];
        a  <= init ? 32'h6a09e667 : h[0];
        b  <= init ? 32'hbb67ae85 : h[1];
        c  <= init ? 32'h3c6ef372 : h[2];
        d  <= init ? 32'ha54ff53a : h[3];
        e  <= init ? 32'h510e527f : h[4];
        f  <= init ? 32'h9b05688c : h[5];
        g  <= init ? 32'h1f83d9ab : h[6];
        hh <= init ? 32'h5be0cd19 : h[7];
        if (init) begin
          h[0] <= 32'h6a09e667; h[1] <= 32'hbb67ae85;
          h[2] <= 32'h3c6ef372; h[3] <= 32'ha54ff53a;
          h[4] <= 32'h510e527f; h[5] <= 32'h9b05688c;
          h[6] <= 32'h1f83d9ab; h[7] <= 32'h5be0cd19;
        end
        rnd     <= 7'd0;
        running <= 1'b1;
      end else if (running) begin
        if (rnd <= 7'd47)
          w[rnd + 7'd16] <= (rotr(w[rnd+7'd14], 17) ^ rotr(w[rnd+7'd14], 19) ^ (w[rnd+7'd14] >> 10))
                          + w[rnd+7'd9]
                          + (rotr(w[rnd+7'd1], 7) ^ rotr(w[rnd+7'd1], 18) ^ (w[rnd+7'd1] >> 3))
                          + w[rnd];
        hh <= g; g <= f; f <= e;
        e  <= d + t1;
        d  <= c; c <= b; b <= a;
        a  <= t1 + t2;
        if (rnd == 7'd63) begin
          h[0] <= h[0] + t1 + t2;
          h[1] <= h[1] + a;
          h[2] <= h[2] + b;
          h[3] <= h[3] + c;
          h[4] <= h[4] + d + t1;
          h[5] <= h[5] + e;
          h[6] <= h[6] + f;
          h[7] <= h[7] + g;
          running <= 1'b0;
          done    <= 1'b1;
        end else begin
          rnd <= rnd + 7'd1;
        end
      end
    end
  end

  always_comb begin
    for (int i = 0; i < 8; i++) digest[255 - 32*i -: 32] = h[i];
  end
endmodule
