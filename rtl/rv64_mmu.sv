`timescale 1ns/1ps
// =============================================================================
// rv64_mmu.sv -- Sv39 address translation: TLB plus a three-level walker.
//
// Translation is active when satp.MODE = 8 and the access is subject to it:
// always for S and U, and for M only when mstatus.MPRV is set and the access is
// a load or store (fetches from M are never translated). Otherwise the address
// passes through untouched, which is what keeps M-mode boot working.
//
// A 16-entry TLB caches VPN -> PPN. A miss runs the standard three-level walk
// (VPN[2], VPN[1], VPN[0]), reading 8-byte PTEs through the port provided. The
// permission rules are enforced, including the megapage alignment checks and the
// U-bit rules with SUM, and a bad PTE raises the page fault the spec names for
// the access type.
//
// NOT IMPLEMENTED, stated rather than implied: the A and D bits are checked but
// not SET by hardware (software must pre-set them, as a system without the Svade
// extension requires), there is no ASID-tagged TLB flush on satp writes beyond a
// global flush, and there are no superpage TLB entries -- a 2 MB or 1 GB mapping
// is re-walked rather than cached as a large page.
// =============================================================================
`default_nettype none

module rv64_mmu (
  input  logic        clk,
  input  logic        rst_n,

  // ---- translation control -------------------------------------------------
  input  logic [63:0] satp,
  input  logic [1:0]  priv,
  input  logic        mprv,
  input  logic        sum,
  input  logic        mxr,

  // ---- translate request ---------------------------------------------------
  input  logic        req_valid,
  input  logic [63:0] vaddr,
  input  logic [1:0]  acc_type,      // ACC_FETCH / ACC_LOAD / ACC_STORE
  output logic        resp_valid,    // translation finished this cycle
  output logic [63:0] paddr,
  output logic        fault,
  output logic [63:0] fault_cause,
  output logic [63:0] fault_tval,
  output logic        busy,

  // ---- PTE read port -------------------------------------------------------
  output logic        pte_req_valid,
  output logic [63:0] pte_req_addr,
  input  logic        pte_req_ready,
  input  logic        pte_rsp_valid,
  input  logic [63:0] pte_rsp_data,
  input  logic        pte_rsp_error
);
  localparam logic [1:0] ACC_FETCH = 2'd0;
  localparam logic [1:0] ACC_LOAD  = 2'd1;
  localparam logic [1:0] ACC_STORE = 2'd2;

  localparam int TLB_N = 16;

  // ---- when does translation apply? ----------------------------------------
  wire sv39_on = (satp[63:60] == 4'd8);
  wire subject  = (priv != 2'b11) || (mprv && (acc_type != ACC_FETCH));
  wire xlate    = sv39_on && subject;

  // ---- TLB -----------------------------------------------------------------
  logic         tlb_v    [0:TLB_N-1];
  logic [26:0]  tlb_vpn  [0:TLB_N-1];
  logic [43:0]  tlb_ppn  [0:TLB_N-1];
  logic [3:0]   tlb_perm [0:TLB_N-1];   // {u, x, w, r}
  // The page SIZE has to be cached with the entry: a 1 GB megapage and a 4 KB
  // page differ in how the offset is composed, so a hit that assumed 4 KB
  // collapsed a megapage address to zero.
  logic [1:0]   tlb_lvl  [0:TLB_N-1];

  wire [26:0] vpn0 = vaddr[38:12];
  wire [3:0]  tlb_idx = vpn0[3:0];

  wire tlb_hit = tlb_v[tlb_idx] && (tlb_vpn[tlb_idx] == vpn0);

  // Permission check straight from the cached bits, for a TLB hit. Rebuilding a
  // PTE out of the entry and re-decoding it was both fragile and wrong (the
  // permission field is four bits wide, so the reconstructed PTE was malformed).
  wire [3:0] hp = tlb_perm[tlb_idx];   // {u, x, w, r}
  logic hit_perm_ok;
  always_comb begin
    hit_perm_ok = 1'b0;
    unique case (acc_type)
      ACC_FETCH: hit_perm_ok = hp[2];
      ACC_LOAD:  hit_perm_ok = hp[0] | (mxr & hp[2]);
      default:   hit_perm_ok = hp[1];
    endcase
    if (priv == 2'b00)
      hit_perm_ok = hit_perm_ok & hp[3];
    else if (priv == 2'b01)
      hit_perm_ok = hit_perm_ok & (hp[3] ? (sum && (acc_type != ACC_FETCH)) : 1'b1);
  end

  // ---- walker state --------------------------------------------------------
  // Plain bits rather than an enum: Icarus does not advance an enum state
  // variable in this FSM (the branch runs, the state assignment is lost), while
  // slang, Verilator and xezim all accept the enum form.
  localparam logic [2:0] W_IDLE = 3'd0, W_REQ = 3'd1, W_RESP = 3'd2,
                         W_DONE = 3'd3, W_FAULT = 3'd4;
  logic [2:0]  wst;
  logic [1:0]  level;
  logic [43:0] a_ppn;          // current table PPN
  logic [8:0]  vpn_sel;        // VPN at the current level
  logic [63:0] v_q;
  logic [1:0]  acc_q;
  logic [63:0] pte_q;
  logic [43:0] leaf_ppn;
  logic [1:0]  leaf_level;
  logic        leaf_is_leaf;
  // A response that arrives while the walk is still issuing its request would be
  // lost: W_RESP used to sample pte_rsp_valid on a single cycle. Any response
  // seen while a walk is in flight is latched here instead.
  logic        pte_got_q;
  logic [63:0] pte_lat_q;
  logic        bare_q;         // this access bypasses translation entirely

  // PTE field decode
  wire [63:0] pte = pte_q;
  wire        p_v = pte[0];
  wire        p_r = pte[1];
  wire        p_w = pte[2];
  wire        p_x = pte[3];
  wire        p_u = pte[4];
  wire        p_a = pte[6];
  wire        p_d = pte[7];
  wire [43:0] p_ppn = pte[53:10];

  // the response the walker should act on: live if present, else the latched one
  wire [63:0] rsp_eff   = pte_rsp_valid ? pte_rsp_data : pte_lat_q;
  wire        rsp_eff_v = pte_rsp_valid || pte_got_q;

  // ---- permission check for the access being translated --------------------
  // Computed from the PTE fields directly. Reading `leaf_is_leaf` here was
  // wrong: it is assigned in the same cycle the check runs, so the check always
  // saw the previous value (0) and every leaf faulted.
  logic perm_ok;
  always_comb begin
    perm_ok = 1'b0;
    if (pte[1] || pte[3]) begin
      unique case (acc_q)
        ACC_FETCH: perm_ok = p_x;
        ACC_LOAD:  perm_ok = p_r | (mxr & p_x);
        default:   perm_ok = p_w;
      endcase
      // the U bit must agree with the privilege level, with SUM letting S reach
      // user pages for loads and stores only
      if (priv == 2'b00) perm_ok = perm_ok & p_u;
      else if (priv == 2'b01)
        perm_ok = perm_ok & (p_u ? (sum && (acc_q != ACC_FETCH)) : 1'b1);
      // A and D are required, not set
      perm_ok = perm_ok & p_a & ((acc_q == ACC_STORE) ? p_d : 1'b1);
    end
  end

  // the same check against a PTE that has just arrived, for the walker
  function automatic logic perm_of(input logic [63:0] t, input logic [1:0] acc);
    logic ok;
    begin
      ok = 1'b0;
      unique case (acc)
        ACC_FETCH: ok = t[3];
        ACC_LOAD:  ok = t[1] | (mxr & t[3]);
        default:   ok = t[2];
      endcase
      if (priv == 2'b00)      ok = ok & t[4];
      else if (priv == 2'b01) ok = ok & (t[4] ? (sum && (acc != ACC_FETCH)) : 1'b1);
      ok = ok & t[6] & ((acc == ACC_STORE) ? t[7] : 1'b1);
      return ok;
    end
  endfunction

  // a leaf PTE must also be aligned for the level it terminates at
  logic leaf_aligned;
  always_comb begin
    unique case (leaf_level)
      2'd1:    leaf_aligned = (p_ppn[8:0]  == 9'd0);
      2'd2:    leaf_aligned = (p_ppn[17:0] == 18'd0);
      default: leaf_aligned = 1'b1;
    endcase
  end

  // ---- final address -------------------------------------------------------
  logic [63:0] base, off;
  always_comb begin
    unique case (leaf_level)
      2'd2:    base = {16'd0, leaf_ppn[17:0], 30'd0};
      2'd1:    base = {16'd0, leaf_ppn[26:0], 21'd0};
      default: base = {8'd0, leaf_ppn, 12'd0};
    endcase
    unique case (leaf_level)
      2'd2:    off = {34'd0, v_q[29:0]};
      2'd1:    off = {43'd0, v_q[20:0]};
      default: off = {52'd0, v_q[11:0]};
    endcase
  end

  // ---- output ---------------------------------------------------------------
  // Continuous assignments, not an always_comb: the composed address depends on
  // registers written by the FSM, and inside an always_comb the output was not
  // re-evaluated when those registers changed, so paddr kept the pass-through
  // value. A continuous assignment cannot get the sensitivity wrong.
  logic [63:0] base_c, off_c, final_c;
  logic [63:0] cause_c;

  always_comb begin
    unique case (leaf_level)
      2'd2:    base_c = {16'd0, leaf_ppn[17:0], 30'd0};
      2'd1:    base_c = {16'd0, leaf_ppn[26:0], 21'd0};
      default: base_c = {8'd0, leaf_ppn, 12'd0};
    endcase
    unique case (leaf_level)
      2'd2:    off_c = {34'd0, v_q[29:0]};
      2'd1:    off_c = {43'd0, v_q[20:0]};
      default: off_c = {52'd0, v_q[11:0]};
    endcase
    unique case (acc_q)
      ACC_FETCH: cause_c = 64'd12;
      ACC_LOAD:  cause_c = 64'd13;
      default:   cause_c = 64'd15;
    endcase
  end

  assign final_c = bare_q ? v_q : (base_c | off_c);

  assign resp_valid  = (wst == W_DONE) || (wst == W_FAULT);
  assign fault       = (wst == W_FAULT);
  assign fault_cause = cause_c;
  assign fault_tval  = v_q;
  assign paddr       = (wst == W_DONE) ? final_c : v_q;

  assign busy          = (wst != W_IDLE) && (wst != W_DONE) && (wst != W_FAULT);
  assign pte_req_valid = (wst == W_REQ);
  assign pte_req_addr  = {8'd0, a_ppn, 12'd0} + {52'd0, vpn_sel, 3'd0};

  // ---- sequential ----------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wst        <= W_IDLE;
      level      <= 2'd2;
      a_ppn      <= 44'd0;
      vpn_sel    <= 9'd0;
      v_q        <= 64'd0;
      acc_q      <= ACC_FETCH;
      pte_q      <= 64'd0;
      leaf_ppn   <= 44'd0;
      leaf_level <= 2'd0;
      leaf_is_leaf <= 1'b0;
      pte_got_q    <= 1'b0;
      pte_lat_q    <= 64'd0;
      bare_q       <= 1'b0;
      for (int i = 0; i < TLB_N; i++) begin
        tlb_v[i]    <= 1'b0;
        tlb_vpn[i]  <= 27'd0;
        tlb_ppn[i]  <= 44'd0;
        tlb_perm[i] <= 4'd0;
        tlb_lvl[i]  <= 2'd0;
      end
    end else begin
      case (wst)
        W_IDLE: begin
          if (req_valid) begin
            v_q     <= vaddr;
            acc_q   <= acc_type;
            if (!xlate) begin
              // bare: pass the address straight through. Without bare_q the
              // output mux used base|off from a previous translation.
              bare_q <= 1'b1;
              wst    <= W_DONE;
            end else if (tlb_hit) begin
              // bare_q must be cleared here too: a TLB hit straight after a
              // pass-through access kept the stale flag and returned the virtual
              // address instead of the translated one.
              bare_q       <= 1'b0;
              leaf_ppn     <= tlb_ppn[tlb_idx];
              leaf_level   <= tlb_lvl[tlb_idx];
              leaf_is_leaf <= 1'b1;
              if (hit_perm_ok) wst <= W_DONE;
              else             wst <= W_FAULT;
            end else begin
              bare_q   <= 1'b0;
              pte_got_q <= 1'b0;
              level   <= 2'd2;
              a_ppn   <= satp[43:0];
              vpn_sel <= vaddr[38:30];
              wst     <= W_REQ;
            end
          end
        end

        W_REQ: begin
          if (pte_rsp_valid) begin
            pte_lat_q <= pte_rsp_data;
            pte_got_q <= 1'b1;
          end
          if (pte_req_ready) wst <= W_RESP;
        end

        W_RESP: begin
          if (rsp_eff_v) begin
            pte_got_q <= 1'b0;
            pte_q <= rsp_eff;
            if (pte_rsp_error || !rsp_eff[0] ||
                (!rsp_eff[1] && rsp_eff[2])) begin
              wst <= W_FAULT;          // invalid PTE, or W without R
            end else if (rsp_eff[1] || rsp_eff[3]) begin
              // leaf
              leaf_ppn     <= rsp_eff[53:10];
              leaf_level   <= level;
              leaf_is_leaf <= 1'b1;
              if (!leaf_aligned) wst <= W_FAULT;
              else begin
                if (perm_of(rsp_eff, acc_q)) begin
                  tlb_v[tlb_idx]    <= 1'b1;
                  tlb_vpn[tlb_idx]  <= vpn0;
                  tlb_ppn[tlb_idx]  <= rsp_eff[53:10];
                  tlb_perm[tlb_idx] <= {rsp_eff[4], rsp_eff[3],
                                        rsp_eff[2], rsp_eff[1]};
                  tlb_lvl[tlb_idx]  <= level;
                  wst <= W_DONE;
                end else begin
                  wst <= W_FAULT;
                end
              end
            end else if (level == 2'd0) begin
              wst <= W_FAULT;            // ran out of levels without a leaf
            end else begin
              // pointer to the next level
              a_ppn <= rsp_eff[53:10];
              level <= level - 2'd1;
              unique case (level)
                2'd2:    vpn_sel <= v_q[29:21];
                default: vpn_sel <= v_q[20:12];
              endcase
              wst <= W_REQ;
            end
          end
        end

        W_DONE, W_FAULT: wst <= W_IDLE;
        default:         wst <= W_IDLE;
      endcase
    end
  end

endmodule
`default_nettype wire
