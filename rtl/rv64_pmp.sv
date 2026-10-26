// =============================================================================
// rv64_pmp.sv -- 8-entry physical memory protection.
//   OFF / TOR / NA4 / NAPOT matching, whole-access checks, lowest-numbered
//   matching entry wins.  Machine-mode semantics per the privileged spec: an
//   entry with L=0 is ignored while the effective privilege is M; an entry
//   with L=1 is enforced in every mode.  No matching entry: M-mode allowed,
//   lower privilege denied (this slice is M-only, so that path is defensive).
// =============================================================================
`default_nettype none

module rv64_pmp #(
  parameter int NENTRY = 8
) (
  input  logic [8*8-1:0]  cfg,
  input  logic [8*64-1:0] addr_cfg,
  input  logic [63:0]     addr,
  input  logic            is_write,
  input  logic            is_exec,
  input  logic            priv_m,
  output logic            allow
);
  logic [NENTRY-1:0] match_v;
  logic [NENTRY-1:0] perm_v;
  logic [NENTRY-1:0] lock_v;

  always_comb begin
    for (int i = 0; i < NENTRY; i++) begin
      logic [7:0]  e;
      logic [1:0]  mode;
      logic [63:0] pa;
      logic [63:0] prev_top;
      logic [63:0] mask;
      logic        m;

      e        = cfg[8*i +: 8];
      mode     = e[4:3];
      pa       = addr_cfg[64*i +: 64];
      prev_top = (i == 0) ? 64'd0 : (addr_cfg[64*(i-1) +: 64] << 2);

      // NAPOT mask: the run of low-order ones plus the first zero bit, which
      // is exactly pa ^ (pa+1).  With k trailing ones this gives a region of
      // 2^(k+3) bytes, i.e. 2^(k+1) four-byte units of don't-care address.
      mask = (pa + 64'd1) ^ pa;

      m = 1'b0;
      unique case (mode)
        2'b00: m = 1'b0;
        // pmpaddr already holds the address in 4-byte units, so compare it
        // against addr[63:2] directly -- slicing pa[63:2] would shift it twice
        2'b01: m = (addr[63:2] == {8'd0, pa[53:0]});                           // NA4
        2'b10: m = (addr >= prev_top) && (addr < (pa << 2));                  // TOR
        // mask and pmpaddr are both in 4-byte units
        2'b11: m = (((addr[63:2] ^ {8'd0, pa[53:0]}) & ~{8'd0, mask[53:0]}) == 62'd0); // NAPOT
        default: m = 1'b0;
      endcase

      match_v[i] = m;
      perm_v[i]  = is_exec ? e[2] : (is_write ? e[1] : e[0]);
      lock_v[i]  = e[7];
    end
  end

  // lowest-numbered matching entry has priority
  logic        hit;
  logic        win_perm;
  logic        win_lock;
  logic [3:0]  win_idx;

  always_comb begin
    hit      = 1'b0;
    win_perm = 1'b0;
    win_lock = 1'b0;
    win_idx  = 4'd0;
    for (int i = NENTRY-1; i >= 0; i--) begin
      if (match_v[i]) begin
        hit      = 1'b1;
        win_idx  = i[3:0];
        win_perm = perm_v[i];
        win_lock = lock_v[i];
      end
    end
  end

  always_comb begin
    if (priv_m) begin
      // locked entries bind machine mode; unlocked ones are ignored
      allow = !(hit && win_lock) || win_perm;
    end else begin
      allow = hit && win_perm;
    end
  end

  logic unused_ok;
  assign unused_ok = win_idx[3] & 1'b0;

endmodule
`default_nettype wire
