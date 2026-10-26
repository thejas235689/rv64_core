// =============================================================================
// rv64_xcetask.sv -- bounded custom task slots with a completion / timeout
// lifecycle and an optional completion interrupt.
//
// A slot moves  IDLE -> ACTIVE -> DONE  on completion, or
//               IDLE -> ACTIVE -> TIMEOUT on expiry, or
//               ACTIVE -> IDLE on cancel, and DONE/TIMEOUT -> IDLE on free.
//
// Ownership: a task carries a 64-bit token supplied by software; completion is
// reported by slot index, and the token is kept with the slot so a consumer can
// match a completion to the task it belongs to. Completions for a slot that is
// not ACTIVE are ignored rather than silently applied to the wrong task.
//
// Control port (write = command, read = status):
//   0 CTRL     [0] enable, [1] interrupt enable
//   1 CMD      [3:0] op, [7:4] slot (0xF = auto-allocate)
//   2 TOKEN    token for START
//   3 TIMEOUT  timeout in cycles for START (0 = no timeout)
//   4 STATUS   read: 2-bit state per slot in [2*i +: 2], busy count in [31:16]
//   5 RESULT   read: result of the selected slot
//   6 DONECNT  read: number of completions since reset
//   7 PENDING  read: per-slot interrupt-pending bits
//   8 TOKRD    read: token of the selected slot
//
// ops: 0 NOP, 1 START, 2 CANCEL, 3 FREE, 4 CLEAR_IRQ
// =============================================================================
`default_nettype none

module rv64_xcetask #(
  parameter int NSLOT  = 4,
  parameter int SLOT_W = 2
) (
  input  logic              clk,
  input  logic              rst_n,

  // ---- control port --------------------------------------------------------
  input  logic              csr_we,
  input  logic [3:0]        csr_addr,
  input  logic [63:0]       csr_wdata,
  output logic [63:0]       csr_rdata,

  // ---- to the task engine --------------------------------------------------
  output logic              start_valid,
  output logic [SLOT_W-1:0] start_slot,
  output logic [63:0]       start_token,
  output logic [31:0]       start_timeout,

  // ---- from the task engine ------------------------------------------------
  input  logic              done_valid,
  input  logic [SLOT_W-1:0] done_slot,
  input  logic [63:0]       done_result,

  // ---- optional completion interrupt ---------------------------------------
  output logic              irq
);
  // slot states
  localparam logic [1:0] ST_IDLE    = 2'd0;
  localparam logic [1:0] ST_ACTIVE  = 2'd1;
  localparam logic [1:0] ST_DONE    = 2'd2;
  localparam logic [1:0] ST_TIMEOUT = 2'd3;

  // control port addresses
  localparam logic [3:0] A_CTRL    = 4'd0;
  localparam logic [3:0] A_CMD     = 4'd1;
  localparam logic [3:0] A_TOKEN   = 4'd2;
  localparam logic [3:0] A_TIMEOUT = 4'd3;
  localparam logic [3:0] A_STATUS  = 4'd4;
  localparam logic [3:0] A_RESULT  = 4'd5;
  localparam logic [3:0] A_DONECNT = 4'd6;
  localparam logic [3:0] A_PENDING = 4'd7;
  localparam logic [3:0] A_TOKRD   = 4'd8;

  // command ops
  localparam logic [3:0] OP_NOP      = 4'd0;
  localparam logic [3:0] OP_START    = 4'd1;
  localparam logic [3:0] OP_CANCEL   = 4'd2;
  localparam logic [3:0] OP_FREE     = 4'd3;
  localparam logic [3:0] OP_CLEARIRQ = 4'd4;

  // ---- state ---------------------------------------------------------------
  logic              enable_q;
  logic              irq_en_q;
  logic [63:0]       token_w_q;
  logic [31:0]       timeout_w_q;
  logic [SLOT_W-1:0] sel_q;

  logic [1:0]        state_q  [0:NSLOT-1];
  logic [63:0]       token_q  [0:NSLOT-1];
  logic [63:0]       result_q [0:NSLOT-1];
  logic [31:0]       remain_q [0:NSLOT-1];
  logic              pend_q   [0:NSLOT-1];

  logic [31:0]       donecnt_q;

  // ---- command decode ------------------------------------------------------
  logic [3:0]        op;
  logic [3:0]        slot_f;
  logic [SLOT_W-1:0] slot_sel;
  logic              auto_alloc;
  logic              slot_valid;

  assign op         = csr_wdata[3:0];
  assign slot_f     = csr_wdata[7:4];
  assign auto_alloc = (slot_f == 4'hF);
  assign slot_sel   = slot_f[SLOT_W-1:0];
  assign slot_valid = (slot_f < NSLOT);

  logic cmd_write;
  assign cmd_write = csr_we && (csr_addr == A_CMD);

  // first idle slot, for auto-allocation
  logic [SLOT_W-1:0] first_idle;
  logic              any_idle;
  always_comb begin
    first_idle = '0;
    any_idle   = 1'b0;
    for (int i = NSLOT - 1; i >= 0; i--) begin
      if (state_q[i] == ST_IDLE) begin
        first_idle = i[SLOT_W-1:0];
        any_idle   = 1'b1;
      end
    end
  end

  // ---- reads ---------------------------------------------------------------
  logic [1:0]  state_rd;
  assign state_rd = state_q[sel_q];

  always_comb begin
    csr_rdata = 64'd0;
    case (csr_addr)
      A_CTRL:    csr_rdata = {62'd0, irq_en_q, enable_q};
      A_STATUS: begin
        csr_rdata = 64'd0;
        for (int i = 0; i < NSLOT; i++) csr_rdata[2*i +: 2] = state_q[i];
        csr_rdata[31:16] = donecnt_q[15:0];
      end
      A_RESULT:  csr_rdata = result_q[sel_q];
      A_DONECNT: csr_rdata = {32'd0, donecnt_q};
      A_PENDING: begin
        csr_rdata = 64'd0;
        for (int i = 0; i < NSLOT; i++) csr_rdata[i] = pend_q[i];
      end
      A_TOKRD:   csr_rdata = token_q[sel_q];
      default:   csr_rdata = 64'd0;
    endcase
  end

  // ---- start pulse ---------------------------------------------------------
  assign start_valid   = cmd_write && enable_q && (op == OP_START) &&
                         ((auto_alloc && any_idle) ||
                          (!auto_alloc && slot_valid && (state_q[slot_sel] == ST_IDLE)));
  assign start_slot    = auto_alloc ? first_idle : slot_sel;
  assign start_token   = token_w_q;
  assign start_timeout = timeout_w_q;

  // ---- sequential ----------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      enable_q    <= 1'b0;
      irq_en_q    <= 1'b0;
      token_w_q   <= 64'd0;
      timeout_w_q <= 32'd0;
      sel_q       <= '0;
      donecnt_q   <= 32'd0;
      for (int i = 0; i < NSLOT; i++) begin
        state_q[i]  <= ST_IDLE;
        token_q[i]  <= 64'd0;
        result_q[i] <= 64'd0;
        remain_q[i] <= 32'd0;
        pend_q[i]   <= 1'b0;
      end
    end else begin
      // ---- control writes --------------------------------------------------
      if (csr_we) begin
        case (csr_addr)
          A_CTRL: begin
            enable_q <= csr_wdata[0];
            irq_en_q <= csr_wdata[1];
          end
          A_TOKEN:   token_w_q   <= csr_wdata;
          A_TIMEOUT: timeout_w_q <= csr_wdata[31:0];
          A_CMD:     sel_q       <= auto_alloc ? first_idle : slot_sel;
          default: ;
        endcase
      end

      // ---- commands --------------------------------------------------------
      if (cmd_write) begin
        case (op)
          OP_START: begin
            if (enable_q) begin
              if (auto_alloc && any_idle) begin
                state_q[first_idle]  <= ST_ACTIVE;
                token_q[first_idle]  <= token_w_q;
                remain_q[first_idle] <= timeout_w_q;
                result_q[first_idle] <= 64'd0;
                pend_q[first_idle]   <= 1'b0;
              end else if (!auto_alloc && slot_valid &&
                           (state_q[slot_sel] == ST_IDLE)) begin
                state_q[slot_sel]  <= ST_ACTIVE;
                token_q[slot_sel]  <= token_w_q;
                remain_q[slot_sel] <= timeout_w_q;
                result_q[slot_sel] <= 64'd0;
                pend_q[slot_sel]   <= 1'b0;
              end
            end
          end
          OP_CANCEL: begin
            if (slot_valid && (state_q[slot_sel] == ST_ACTIVE)) begin
              state_q[slot_sel] <= ST_IDLE;
              remain_q[slot_sel] <= 32'd0;
            end
          end
          OP_FREE: begin
            if (slot_valid && ((state_q[slot_sel] == ST_DONE) ||
                               (state_q[slot_sel] == ST_TIMEOUT))) begin
              state_q[slot_sel] <= ST_IDLE;
              pend_q[slot_sel]  <= 1'b0;
            end
          end
          OP_CLEARIRQ: begin
            if (slot_valid) pend_q[slot_sel] <= 1'b0;
          end
          default: ;
        endcase
      end

      // ---- completion from the engine --------------------------------------
      // A completion is only accepted for a slot that is actually ACTIVE, so a
      // late or duplicate response cannot land on a task that has moved on.
      if (done_valid && (done_slot < NSLOT) && (state_q[done_slot] == ST_ACTIVE)) begin
        state_q[done_slot]  <= ST_DONE;
        result_q[done_slot] <= done_result;
        pend_q[done_slot]   <= 1'b1;
        donecnt_q           <= donecnt_q + 32'd1;
      end

      // ---- timeout countdown -----------------------------------------------
      for (int i = 0; i < NSLOT; i++) begin
        if (state_q[i] == ST_ACTIVE) begin
          if (remain_q[i] != 32'd0) begin
            if (remain_q[i] == 32'd1) begin
              state_q[i] <= ST_TIMEOUT;
              pend_q[i]  <= 1'b1;
            end else begin
              remain_q[i] <= remain_q[i] - 32'd1;
            end
          end
        end
      end
    end
  end

  // reduction operators do not apply to unpacked arrays: OR the pending bits
  // explicitly, otherwise the interrupt silently never asserts
  logic any_pend;
  always_comb begin
    any_pend = 1'b0;
    for (int i = 0; i < NSLOT; i++) any_pend = any_pend | pend_q[i];
  end

  assign irq = irq_en_q & any_pend;

  // keep sel_q width referenced for lint
  logic unused_ok;
  assign unused_ok = ^state_rd;

endmodule
`default_nettype wire
