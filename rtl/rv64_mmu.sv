`timescale 1ns/1ps
// =============================================================================
// Sv39/Sv48 translation with a direct-mapped TLB and a three/four-level walker.
// Superpage translations are cached for the requested 4 KiB VPN only.
// Accessed and dirty bits are checked in hardware and managed by software.
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
  input  logic        invalidate,

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
  wire sv48_on = satp[63:60] == 4'd9;
  wire paged = sv48_on || satp[63:60] == 4'd8;
  wire canonical = sv48_on ? vaddr[63:48] == {16{vaddr[47]}}
                           : vaddr[63:39] == {25{vaddr[38]}};
  wire subject  = (priv != 2'b11) || (mprv && (acc_type != ACC_FETCH));
  wire xlate    = paged && subject;

  // ---- TLB -----------------------------------------------------------------
  logic         tlb_v    [0:TLB_N-1];
  logic [35:0]  tlb_vpn  [0:TLB_N-1];
  logic [43:0]  tlb_ppn  [0:TLB_N-1];
  logic [4:0]   tlb_perm [0:TLB_N-1];   // {u, x, w, r}
  // The page SIZE has to be cached with the entry: a 1 GB megapage and a 4 KB
  // page differ in how the offset is composed, so a hit that assumed 4 KB
  // collapsed a megapage address to zero.
  logic [1:0]   tlb_lvl  [0:TLB_N-1];

  logic [63:0] tlb_context_q, walk_context_q;
  wire [35:0] vpn0 = vaddr[47:12];
  wire [3:0]  tlb_idx = vpn0[3:0];

  wire tlb_hit = tlb_context_q == satp && tlb_v[tlb_idx] && (tlb_vpn[tlb_idx] == vpn0);

  // Permission check straight from the cached bits, for a TLB hit. Rebuilding a
  // PTE out of the entry and re-decoding it was both fragile and wrong (the
  // permission field is four bits wide, so the reconstructed PTE was malformed).
  wire [4:0] hp = tlb_perm[tlb_idx];   // {u, x, w, r}
  logic hit_perm_ok;
  always_comb begin
    hit_perm_ok = 1'b0;
    unique case (acc_type)
      ACC_FETCH: hit_perm_ok = hp[2];
      ACC_LOAD:  hit_perm_ok = hp[0] | (mxr & hp[2]);
      default:   hit_perm_ok = hp[1] & hp[4];
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
  logic [43:0] leaf_ppn;
  logic [1:0]  leaf_level;
  // A response that arrives while the walk is still issuing its request would be
  // lost: W_RESP used to sample pte_rsp_valid on a single cycle. Any response
  // seen while a walk is in flight is latched here instead.
  logic        pte_got_q;
  logic [63:0] pte_lat_q;
  logic        bare_q;         // this access bypasses translation entirely

  logic pte_error_q, access_error_q, walk_invalidated_q;

  // the response the walker should act on: live if present, else the latched one
  wire [63:0] rsp_eff   = pte_rsp_valid ? pte_rsp_data : pte_lat_q;
  wire        rsp_eff_v = pte_rsp_valid || pte_got_q;

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

  logic leaf_aligned;
  always_comb begin
    case (level)
      2'd3: leaf_aligned = rsp_eff[36:10] == 27'd0;
      2'd2: leaf_aligned = rsp_eff[27:10] == 18'd0;
      2'd1: leaf_aligned = rsp_eff[18:10] == 9'd0;
      default: leaf_aligned = 1'b1;
    endcase
  end

  logic [63:0] base_c, off_c, final_c;
  logic [63:0] cause_c;

  always_comb begin
    unique case (leaf_level)
      2'd3:    base_c = {8'd0, leaf_ppn[43:27], 39'd0};
      2'd2:    base_c = {8'd0, leaf_ppn[43:18], 30'd0};
      2'd1:    base_c = {8'd0, leaf_ppn[43:9], 21'd0};
      default: base_c = {8'd0, leaf_ppn, 12'd0};
    endcase
    unique case (leaf_level)
      2'd3:    off_c = {25'd0, v_q[38:0]};
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
  assign fault_cause = access_error_q ? ((acc_q == ACC_FETCH) ? 64'd1 :
                                         (acc_q == ACC_LOAD) ? 64'd5 : 64'd7) : cause_c;
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
      pte_error_q <= 1'b0;
      access_error_q <= 1'b0;
      walk_invalidated_q <= 1'b0;
      tlb_context_q <= '0;
      walk_context_q <= '0;
      leaf_ppn   <= 44'd0;
      leaf_level <= 2'd0;
      pte_got_q    <= 1'b0;
      pte_lat_q    <= 64'd0;
      bare_q       <= 1'b0;
      for (int i = 0; i < TLB_N; i++) begin
        tlb_v[i]    <= 1'b0;
        tlb_vpn[i]  <= 36'd0;
        tlb_ppn[i]  <= 44'd0;
        tlb_perm[i] <= 5'd0;
        tlb_lvl[i]  <= 2'd0;
      end
    end else begin
      if (invalidate) walk_invalidated_q <= 1'b1;
      if (invalidate || satp != tlb_context_q) begin
        tlb_context_q <= satp;
        for (int i = 0; i < TLB_N; i++) tlb_v[i] <= 1'b0;
      end
      case (wst)
        W_IDLE: begin
          if (req_valid) begin
            v_q     <= vaddr;
            access_error_q <= 1'b0;
            walk_invalidated_q <= invalidate;
            acc_q   <= acc_type;
            if (!xlate) begin
              // bare: pass the address straight through. Without bare_q the
              // output mux used base|off from a previous translation.
              bare_q <= 1'b1;
              wst    <= W_DONE;
            end else if (!canonical) begin
              bare_q <= 1'b0;
              wst <= W_FAULT;
            end else if (tlb_hit) begin
              // bare_q must be cleared here too: a TLB hit straight after a
              // pass-through access kept the stale flag and returned the virtual
              // address instead of the translated one.
              bare_q       <= 1'b0;
              leaf_ppn     <= tlb_ppn[tlb_idx];
              leaf_level   <= tlb_lvl[tlb_idx];
              if (hit_perm_ok) wst <= W_DONE;
              else             wst <= W_FAULT;
            end else begin
              bare_q   <= 1'b0;
              pte_got_q <= 1'b0;
              walk_context_q <= satp;
              level   <= sv48_on ? 2'd3 : 2'd2;
              a_ppn   <= satp[43:0];
              vpn_sel <= sv48_on ? vaddr[47:39] : vaddr[38:30];
              wst     <= W_REQ;
            end
          end
        end

        W_REQ: begin
          if (pte_req_ready && pte_rsp_valid) begin
            pte_error_q <= pte_rsp_error;
            pte_lat_q <= pte_rsp_data;
            pte_got_q <= 1'b1;
          end
          if (pte_req_ready) wst <= W_RESP;
        end

        W_RESP: begin
          if (rsp_eff_v) begin
            pte_got_q <= 1'b0;
            if (pte_rsp_valid ? pte_rsp_error : pte_error_q) begin
              access_error_q <= 1'b1;
              wst <= W_FAULT;
            end else if (!rsp_eff[0] || (|rsp_eff[63:54]) ||
                (!rsp_eff[1] && rsp_eff[2])) begin
              wst <= W_FAULT;          // invalid PTE, or W without R
            end else if (rsp_eff[1] || rsp_eff[3]) begin
              // leaf
              leaf_ppn     <= rsp_eff[53:10];
              leaf_level   <= level;
              if (!leaf_aligned) wst <= W_FAULT;
              else begin
                if (perm_of(rsp_eff, acc_q)) begin
                  tlb_v[v_q[15:12]]    <= walk_context_q == satp && !walk_invalidated_q && !invalidate;
                  tlb_vpn[v_q[15:12]]  <= v_q[47:12];
                  tlb_ppn[v_q[15:12]]  <= rsp_eff[53:10];
                  tlb_perm[v_q[15:12]] <= {rsp_eff[7], rsp_eff[4], rsp_eff[3],
                                        rsp_eff[2], rsp_eff[1]};
                  tlb_lvl[v_q[15:12]]  <= level;
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
                2'd3:    vpn_sel <= v_q[38:30];
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
