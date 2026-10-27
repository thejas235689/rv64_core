`timescale 1ns/1ps
// =============================================================================
// rv64_dmi.sv -- JTAG TAP plus a Debug Module Interface transport.
//
// This is the *transport* half of RISC-V external debug: an IEEE 1149.1 TAP
// state machine, a 5-bit instruction register, and the 41-bit DMI shift register
// ({op[1:0], data[31:0], addr[6:0]}) with the standard dtmcs/dmi instruction
// codes. It decodes onto the core's existing debug ports.
//
// WHAT IS NOT HERE, stated plainly: the abstract-command layer. There is no
// progbuf, no command queue and no system-bus access master. Register access is
// direct -- write the index to REGSEL, then read or write DATA0 -- which is
// enough to halt, inspect and resume, and is not a complete RISC-V debug module.
//
// DMI addresses:
//   0x04 DATA0      GPR data (read or write)
//   0x10 DMCONTROL  [31] haltreq, [30] resumereq, [26] step, [1] ndmreset
//   0x11 DMSTATUS   [9] allhalted, [8] allrunning
//   0x20 REGSEL     GPR index for DATA0
//
// TAP instructions: 0x01 IDCODE, 0x10 DTMCS, 0x11 DMI
// =============================================================================
`default_nettype none

module rv64_dmi (
  input  logic        tck,
  input  logic        tms,
  input  logic        tdi,
  output logic        tdo,
  input  logic        trst_n,

  // ---- to the core's debug ports -------------------------------------------
  output logic        dbg_halt_req,
  output logic        dbg_resume_req,
  output logic        dbg_step,
  input  logic        dbg_halted,
  output logic [4:0]  dbg_reg_addr,
  input  logic [63:0] dbg_reg_data,
  output logic        ndmreset
);

  // ---- TAP state machine ---------------------------------------------------
  typedef enum logic [3:0] {
    T_RESET   = 4'd0,  T_IDLE    = 4'd1,
    T_SEL_DR  = 4'd2,  T_CAP_DR  = 4'd3,  T_SHIFT_DR = 4'd4,
    T_EX1_DR  = 4'd5,  T_PAUSE_DR= 4'd6,  T_EX2_DR   = 4'd7,
    T_UPD_DR  = 4'd8,  T_SEL_IR  = 4'd9,  T_CAP_IR   = 4'd10,
    T_SHIFT_IR= 4'd11, T_EX1_IR  = 4'd12, T_PAUSE_IR = 4'd13,
    T_EX2_IR  = 4'd14, T_UPD_IR  = 4'd15
  } tap_state_e;

  tap_state_e st;

  logic [4:0]  ir;
  logic [4:0]  ir_shift;
  logic [40:0] dmi_shift;
  logic [40:0] dmi_reg;          // {op, data, addr}
  logic [31:0] idcode;

  localparam logic [4:0] IR_IDCODE = 5'h01;
  localparam logic [4:0] IR_DTMCS  = 5'h10;
  localparam logic [4:0] IR_DMI    = 5'h11;

  assign idcode = 32'h1CA1_0D01;  // version 1, part 0xCA10, mfr 0x001

  // ---- DMI registers -------------------------------------------------------
  logic [63:0] reg_data0;
  logic [4:0]  regsel;
  logic        haltreq_q, resumereq_q, step_q, ndmreset_q;

  // a read or write of DATA0/REGSEL, pulsed when Update-DR latches a DMI word
  logic        dmi_wr;
  logic        dmi_rd;
  // Update-DR is an EVENT. Qualifying the request registers on the level of
  // dmi_wr made them re-assert every TCK, so a one-shot like resumereq never
  // self-cleared.
  logic        dmi_update;
  logic [6:0]  dmi_addr;
  logic [31:0] dmi_wdata;

  assign dmi_wr    = (dmi_reg[40:39] == 2'b10);
  assign dmi_rd    = (dmi_reg[40:39] == 2'b01);
  assign dmi_addr  = dmi_reg[6:0];
  assign dmi_wdata = dmi_reg[38:7];

  assign dbg_halt_req   = haltreq_q;
  assign dbg_resume_req = resumereq_q;
  assign dbg_step       = step_q;
  assign dbg_reg_addr   = regsel;
  assign ndmreset       = ndmreset_q;

  // Read data for the current DMI address. The earlier version returned the
  // DATA0 value whatever the address was, so a DMSTATUS read came back as the
  // GPR contents -- the address has to be decoded.
  logic [31:0] data0_out;
  always_comb begin
    case (dmi_addr)
      7'h04:   data0_out = (reg_data0 != 64'd0) ? reg_data0[31:0] : dbg_reg_data[31:0];
      7'h10:   data0_out = {haltreq_q, resumereq_q, 3'd0, step_q, 24'd0, ndmreset_q, 1'b0};
      7'h11:   data0_out = {22'd0, dbg_halted, ~dbg_halted, 8'd0};
      7'h20:   data0_out = {27'd0, regsel};
      default: data0_out = 32'd0;
    endcase
  end

  // ---- TAP FSM -------------------------------------------------------------
  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n) begin
      st         <= T_RESET;
      ir         <= IR_IDCODE;
      ir_shift   <= 5'd0;
      dmi_shift  <= 41'd0;
      dmi_reg    <= 41'd0;
    end else begin
      case (st)
        T_RESET:   if (tms) st <= T_RESET; else st <= T_IDLE;
        T_IDLE:    if (tms) st <= T_SEL_DR; else st <= T_IDLE;
        T_SEL_DR:  if (tms) st <= T_SEL_IR; else st <= T_CAP_DR;
        T_CAP_DR: begin
          if (tms) st <= T_EX1_DR; else st <= T_SHIFT_DR;
          // Capture-DR loads the response word for a DMI read
          if (ir == IR_DMI) dmi_shift <= {2'b10, data0_out[31:0], dmi_addr};
        end
        T_SHIFT_DR: begin
          if (tms) st <= T_EX1_DR;
          else begin
            dmi_shift <= {tdi, dmi_shift[40:1]};
            ir_shift  <= {tdi, ir_shift[4:1]};
          end
        end
        T_EX1_DR:  if (tms) st <= T_UPD_DR; else st <= T_PAUSE_DR;
        T_PAUSE_DR:if (tms) st <= T_EX2_DR; else st <= T_PAUSE_DR;
        T_EX2_DR:  if (tms) st <= T_UPD_DR; else st <= T_SHIFT_DR;
        T_UPD_DR: begin
          if (tms) st <= T_SEL_DR; else st <= T_IDLE;
          // latch the DMI word only when the DMI instruction is selected
          if (ir == IR_DMI) dmi_reg <= dmi_shift;
        end
        T_SEL_IR:  if (tms) st <= T_RESET; else st <= T_CAP_IR;
        T_CAP_IR:  if (tms) st <= T_EX1_IR; else st <= T_SHIFT_IR;
        T_SHIFT_IR:begin
          if (tms) st <= T_EX1_IR;
          else     ir_shift <= {tdi, ir_shift[4:1]};
        end
        T_EX1_IR:  if (tms) st <= T_UPD_IR; else st <= T_PAUSE_IR;
        T_PAUSE_IR:if (tms) st <= T_EX2_IR; else st <= T_PAUSE_IR;
        T_EX2_IR:  if (tms) st <= T_UPD_IR; else st <= T_SHIFT_IR;
        T_UPD_IR: begin
          if (tms) st <= T_SEL_DR; else st <= T_IDLE;
          ir <= ir_shift;
        end
        default:   st <= T_RESET;
      endcase
    end
  end

  // ---- TDO -----------------------------------------------------------------
  logic tdo_r;
  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n) tdo_r <= 1'b0;
    else if (st == T_SHIFT_DR) tdo_r <= (ir == IR_DMI) ? dmi_shift[0] : idcode[0];
    else if (st == T_SHIFT_IR) tdo_r <= ir_shift[0];
  end
  assign tdo = tdo_r;

  // one TCK pulse when Update-DR latches a DMI word
  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n) dmi_update <= 1'b0;
    else         dmi_update <= (st == T_UPD_DR) && (ir == IR_DMI);
  end

  // ---- DMI register semantics ---------------------------------------------
  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n) begin
      reg_data0   <= 64'd0;
      regsel      <= 5'd0;
      haltreq_q   <= 1'b0;
      resumereq_q <= 1'b0;
      step_q      <= 1'b0;
      ndmreset_q  <= 1'b0;
    end else begin
      // the request pulses are one TCK wide, as the DMI protocol specifies
      resumereq_q <= 1'b0;
      step_q      <= 1'b0;

      if (dmi_update && dmi_wr) begin
        unique case (dmi_addr)
          7'h04: reg_data0 <= {32'd0, dmi_wdata};
          7'h10: begin
            haltreq_q   <= dmi_wdata[31];
            resumereq_q <= dmi_wdata[30];
            step_q      <= dmi_wdata[26];
            ndmreset_q  <= dmi_wdata[1];
          end
          7'h20: regsel <= dmi_wdata[4:0];
          default: ;
        endcase
      end
    end
  end


endmodule
`default_nettype wire
