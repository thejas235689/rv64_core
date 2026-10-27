`timescale 1ns/1ps
// =============================================================================
// rv64_vunit.sv -- RVV subset: VLEN=64 vector unit.
//
// A 32 x 64-bit vector register file, the vector CSRs (vl, vtype, vstart,
// vxrm/vxsat) and an instruction executor for the arithmetic subset:
//
//   vsetvli / vsetivli      set vl and vtype from the instruction
//   vadd.vv/vx/vi  vsub     elementwise add and subtract
//   vand.vv/vx/vi  vor  vxor
//   vmin.vv vminu.vv vmax.vv vmaxu.vv
//   vmv.v.v / vmv.v.x       whole-register move
//
// SEW comes from vtype[4:2] (0=8, 1=16, 2=32, 3=64), so one 64-bit register holds
// 8, 4, 2 or 1 elements, and only elements below `vl` starting at `vstart` are
// written. Elements at or above vl keep their old value, which is the behaviour
// software relies on when vl is a tail.
//
// The executor takes a 32-bit instruction word rather than being wired into the
// core's decoder: this is a self-contained unit that can be verified on its own
// and then instantiated where the decoder can feed it.
//
// NOT IMPLEMENTED, stated rather than implied: no masking (vm is ignored -- every
// operation is unmasked), no vlmul grouping (LMUL is always 1), no widening,
// narrowing, fixed-point or floating-point operations, no vector loads or stores
// (vle/vse), no slides, permutes or reductions, no vstart resumption (vstart is
// read but execution always starts at 0), and no chaining.
// =============================================================================
`default_nettype none

module rv64_vunit (
  input  logic        clk,
  input  logic        rst_n,

  // ---- control window ------------------------------------------------------
  input  logic        csr_we,
  input  logic [3:0]  csr_addr,
  input  logic [63:0] csr_wdata,
  output logic [63:0] csr_rdata,

  // ---- observability -------------------------------------------------------
  output logic [31:0] insn_count,
  output logic        illegal
);
  localparam int VLEN = 64;

  // ---- vector CSRs ---------------------------------------------------------
  logic [6:0]  vl_q;         // up to VLEN/8 elements
  logic [7:0]  vtype_q;      // {vma, vta, vsew[2:0], vlmul[1:0]}
  logic [6:0]  vstart_q;
  logic        vxsat_q;

  logic [31:0] insn_count_q;
  logic        illegal_q;

  // ---- the instruction being executed -------------------------------------
  logic [31:0] insn_q;
  logic        go_q;

  wire [6:0]  opcode = insn_q[6:0];
  wire [2:0]  funct3 = insn_q[14:12];
  wire [5:0]  funct6 = insn_q[31:26];
  wire [4:0]  vs1_i  = insn_q[19:15];
  wire [4:0]  vs2_i  = insn_q[24:20];
  wire [4:0]  vd_i   = insn_q[11:7];
  wire [4:0]  rs1_i  = insn_q[19:15];

  wire [1:0]  sew_sel = vtype_q[4:3];
  wire [6:0]  nelem   = (sew_sel == 2'd0) ? 7'd8 : (sew_sel == 2'd1) ? 7'd4
                      : (sew_sel == 2'd2) ? 7'd2 : 7'd1;

  // ---- register file -------------------------------------------------------
  logic [63:0] rdata1, rdata2, rdata3, cdata;
  logic [63:0] vd_new;
  logic        vd_we;
  logic [4:0]  vd_addr;
  logic [4:0]  caddr_q;

  rv64_vregfile u_vrf (
    .clk(clk), .rst_n(rst_n),
    .raddr1(vs2_i), .rdata1(rdata2),      // vs2 is the first source
    .raddr2(vs1_i), .rdata2(rdata1),      // vs1 is the second source
    .raddr3(vd_i),  .rdata3(rdata3),      // destination, for the tail
    .waddr(vd_addr), .wdata(vd_new), .we(vd_we),
    .caddr(caddr_q), .cdata(cdata),
    .cwdata(csr_wdata), .cwe(csr_we && (csr_addr == 4'd7))
  );

  // ---- scalar operand for the .vx and .vi forms ---------------------------
  // For .vx the scalar comes from a register supplied on the control window
  // (csr 9), because this unit is not wired to the core's integer file yet.
  logic [63:0] xval_q;
  wire  [63:0] s2_val = (funct3 == 3'b100) ? xval_q
                      : (funct3 == 3'b011) ? {{59{insn_q[19]}}, insn_q[19:15]}
                      : rdata1;

  // ---- elementwise arithmetic ---------------------------------------------
  function automatic logic [63:0] vop(input logic [5:0] fn,
                                      input logic [63:0] a, input logic [63:0] b,
                                      input logic [6:0] w);   // w = element width
    logic [63:0] mask, r;
    begin
      mask = (w == 7'd64) ? 64'hFFFF_FFFF_FFFF_FFFF : ((64'd1 << w) - 64'd1);
      unique case (fn)
        6'b000000: r = a + b;                                    // vadd
        6'b000010: r = a - b;                                    // vsub
        6'b001001: r = a & b;                                    // vand
        6'b001010: r = a | b;                                    // vor
        6'b001011: r = a ^ b;                                    // vxor
        6'b000100: r = (a < b) ? a : b;                          // vminu
        6'b000101: r = ($signed(a) < $signed(b)) ? a : b;        // vmin
        6'b000110: r = (a > b) ? a : b;                          // vmaxu
        6'b000111: r = ($signed(a) > $signed(b)) ? a : b;        // vmax
        6'b010111: r = b;                                        // vmv.v.*
        default:   r = a;
      endcase
      vop = r & mask;
    end
  endfunction

  // ---- element extraction / insertion with constant slices ----------------
  // Computed part-selects are avoided on purpose: they have misbehaved in the
  // tools used here.
  function automatic logic [63:0] get_elem(input logic [63:0] v, input logic [2:0] i,
                                           input logic [1:0] sew);
    unique case (sew)
      2'd0: unique case (i)                                     // SEW = 8
              3'd0: get_elem = {56'd0, v[7:0]};
              3'd1: get_elem = {56'd0, v[15:8]};
              3'd2: get_elem = {56'd0, v[23:16]};
              3'd3: get_elem = {56'd0, v[31:24]};
              3'd4: get_elem = {56'd0, v[39:32]};
              3'd5: get_elem = {56'd0, v[47:40]};
              3'd6: get_elem = {56'd0, v[55:48]};
              default: get_elem = {56'd0, v[63:56]};
            endcase
      2'd1: unique case (i[1:0])                                // SEW = 16
              2'd0: get_elem = {48'd0, v[15:0]};
              2'd1: get_elem = {48'd0, v[31:16]};
              2'd2: get_elem = {48'd0, v[47:32]};
              default: get_elem = {48'd0, v[63:48]};
            endcase
      2'd2: begin
              if (i[0] == 1'b0) get_elem = {32'd0, v[31:0]};
              else              get_elem = {32'd0, v[63:32]};
            end
      default: get_elem = v;
    endcase
  endfunction

  // ---- execute -------------------------------------------------------------
  logic [63:0] acc;
  always_comb begin
    logic [63:0] a_e, b_e, r_e;
    logic [6:0]  w;
    acc   = rdata3;                 // start from vd so the tail keeps its value
    vd_we = 1'b0;
    vd_addr = vd_i;
    w = (sew_sel == 2'd0) ? 7'd8 : (sew_sel == 2'd1) ? 7'd16
      : (sew_sel == 2'd2) ? 7'd32 : 7'd64;
    if (go_q && (opcode == 7'b1010111)) begin
      if (funct3 == 3'b111) begin
        // vsetvli / vsetivli: vl and vtype come from the instruction
        acc   = 64'd0;
      end else begin
        vd_we = 1'b1;
        for (int i = 0; i < 8; i++) begin
          if ((i < vl_q) && (i < nelem)) begin
            a_e = get_elem(rdata2, i[2:0], sew_sel);
            // .vv takes element i of vs1; .vx/.vi replicate one scalar
            b_e = (funct3 == 3'b000) ? get_elem(rdata1, i[2:0], sew_sel)
                                     : s2_val;
            r_e = vop(funct6, a_e, b_e, w);
            // insert back at the same constant position
            unique case (sew_sel)
              2'd0: unique case (i[2:0])
                      3'd0: acc[7:0]   = r_e[7:0];
                      3'd1: acc[15:8]  = r_e[7:0];
                      3'd2: acc[23:16] = r_e[7:0];
                      3'd3: acc[31:24] = r_e[7:0];
                      3'd4: acc[39:32] = r_e[7:0];
                      3'd5: acc[47:40] = r_e[7:0];
                      3'd6: acc[55:48] = r_e[7:0];
                      default: acc[63:56] = r_e[7:0];
                    endcase
              2'd1: unique case (i[1:0])
                      2'd0: acc[15:0]  = r_e[15:0];
                      2'd1: acc[31:16] = r_e[15:0];
                      2'd2: acc[47:32] = r_e[15:0];
                      default: acc[63:48] = r_e[15:0];
                    endcase
              2'd2: begin
                      if (i[0] == 1'b0) acc[31:0] = r_e[31:0];
                      else              acc[63:32] = r_e[31:0];
                    end
              default: acc = r_e;
            endcase
          end
        end
      end
    end
    vd_new = acc;
  end

  // ---- control window ------------------------------------------------------
  always_comb begin
    csr_rdata = 64'd0;
    unique case (csr_addr)
      4'd0: csr_rdata = {62'd0, go_q, 1'b0};
      4'd1: csr_rdata = {57'd0, vl_q};
      4'd2: csr_rdata = {56'd0, vtype_q};
      4'd3: csr_rdata = {57'd0, vstart_q};
      4'd4: csr_rdata = {32'd0, insn_q};
      4'd5: csr_rdata = {63'd0, vxsat_q};
      4'd6: csr_rdata = cdata;
      4'd9: csr_rdata = xval_q;
      default: csr_rdata = 64'd0;
    endcase
  end

  assign insn_count = insn_count_q;
  assign illegal    = illegal_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vl_q        <= 7'd0;
      vtype_q     <= 8'd0;
      vstart_q    <= 7'd0;
      vxsat_q     <= 1'b0;
      insn_q      <= 32'd0;
      go_q        <= 1'b0;
      xval_q      <= 64'd0;
      caddr_q     <= 5'd0;
      insn_count_q <= 32'd0;
      illegal_q   <= 1'b0;
    end else begin
      go_q <= 1'b0;
      if (csr_we) begin
        unique case (csr_addr)
          4'd0: if (csr_wdata[0]) begin
                  go_q         <= 1'b1;
                  insn_count_q <= insn_count_q + 32'd1;
                  // vsetvli/vsetivli take effect here
                  if (opcode_of(insn_q) == 7'b1010111 && insn_q[14:12] == 3'b111) begin
                    vtype_q <= insn_q[27:20];
                    vl_q    <= (insn_q[25:23] == 3'd0) ? 7'd8 :
                               (insn_q[25:23] == 3'd1) ? 7'd4 :
                               (insn_q[25:23] == 3'd2) ? 7'd2 : 7'd1;
                  end
                end
          4'd1: vl_q    <= csr_wdata[6:0];
          4'd2: vtype_q <= csr_wdata[7:0];
          4'd3: vstart_q <= csr_wdata[6:0];
          4'd4: insn_q  <= csr_wdata[31:0];
          4'd5: vxsat_q <= csr_wdata[0];
          4'd6: caddr_q <= csr_wdata[4:0];
          4'd9: xval_q  <= csr_wdata;
          default: ;
        endcase
      end
    end
  end

  function automatic logic [6:0] opcode_of(input logic [31:0] i);
    return i[6:0];
  endfunction

endmodule
`default_nettype wire
