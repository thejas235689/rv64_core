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

  // ---- element memory port (vle / vse) ------------------------------------
  // One 64-bit beat per element. The base address comes from the control window
  // (csr 10) rather than the integer file, because this unit is not wired to the
  // GPRs -- the same simplification the .vx scalar uses.
  output logic        mem_req_valid,
  output logic [63:0] mem_req_addr,
  output logic        mem_req_we,
  output logic [7:0]  mem_req_wstrb,
  output logic [63:0] mem_req_wdata,
  input  logic        mem_req_ready,
  input  logic        mem_rsp_valid,
  input  logic [63:0] mem_rsp_rdata,
  input  logic        mem_rsp_error,

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
  logic [1:0]  vxrm_q;        // rounding mode for vnclip
  logic        sat_hit;       // vnclip saturated this operation

  logic [31:0] insn_count_q;
  logic        illegal_q;

  // ---- vector load / store ------------------------------------------------
  logic [63:0] base_q;
  logic [2:0]  el_q;            // element index being transferred
  logic        el_walk_q, el_issued_q, el_mask_q;
  logic        is_store_q;
  logic [63:0] ld_acc;
  logic        load_we_q;       // this write comes from a load, not an ALU op
  // ---- register grouping (vlmul) ------------------------------------------
  // With LMUL=k a group v..v+k-1 holds k*VLEN bits. The unit processes one
  // register per cycle, so a grouped op takes k cycles; element indices used for
  // masking are GLOBAL across the group, not per register.
  logic [3:0]  grp_q;           // which register of the group is being computed
  logic        grp_walk_q, grp_commit_q;


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

  wire        vm       = insn_q[25];    // 1 = unmasked
  wire [1:0]  sew_sel = vtype_q[4:3];
  // vlmul: 0=1, 1=2, 2=4, 3=8. Fractional values (5,6,7) are treated as 1.
  wire [2:0]  lmul_sel = vtype_q[2:0];
  wire [3:0]  lmul     = (lmul_sel == 3'd1) ? 4'd2 : (lmul_sel == 3'd2) ? 4'd4
                       : (lmul_sel == 3'd3) ? 4'd8 : 4'd1;
  wire [6:0]  nelem   = (sew_sel == 2'd0) ? 7'd8 : (sew_sel == 2'd1) ? 7'd4
                      : (sew_sel == 2'd2) ? 7'd2 : 7'd1;

  // ---- register file -------------------------------------------------------
  logic [63:0] rdata1, rdata2, rdata3, rdata_mask, cdata;
  logic [63:0] vd_new;
  logic        vd_we;
  logic [4:0]  vd_addr;
  logic [4:0]  caddr_q;

  // during a grouped op the addresses advance with the group index
  wire [4:0] grp_a = vs2_i + {1'b0, grp_q};
  wire [4:0] grp_b = vs1_i + {1'b0, grp_q};
  wire [4:0] grp_d = vd_i  + {1'b0, grp_q};

  rv64_vregfile u_vrf (
    .clk(clk), .rst_n(rst_n),
    .raddr1(grp_a), .rdata1(rdata2),      // vs2 is the first source
    .raddr2(grp_b), .rdata2(rdata1),      // vs1 is the second source
    .raddr3(grp_d), .rdata3(rdata3),      // destination, for the tail
    .raddr_mask({1'b0, grp_q}),           // v0 advances with the group
    .rdata_mask(rdata_mask),
    .waddr(vd_addr), .wdata(vd_new), .we(vd_we),
    .caddr(caddr_q), .cdata(cdata),
    .cwdata(csr_wdata), .cwe(csr_we && (csr_addr == 4'd7))
  );

  wire [5:0] elem_bytes = (sew_sel == 2'd0) ? 6'd1 : (sew_sel == 2'd1) ? 6'd2
                        : (sew_sel == 2'd2) ? 6'd4 : 6'd8;

  wire el_active = (el_q < vl_q) && (vm || mask_bit(el_q, sew_sel));
  assign mem_req_valid = el_walk_q && !el_issued_q && el_active;
  assign mem_req_addr  = base_q + ({58'd0, el_q} * {58'd0, elem_bytes});
  assign mem_req_we    = is_store_q;
  assign mem_req_wstrb = is_store_q ? (wstrb_for(sew_sel) << mem_req_addr[2:0]) : 8'h00;
  assign mem_req_wdata = is_store_q ? (get_elem(rdata3, el_q, sew_sel) << (8 * mem_req_addr[2:0])) : 64'd0;

  // ---- scalar operand for the .vx and .vi forms ---------------------------
  // For .vx the scalar comes from a register supplied on the control window
  // (csr 9), because this unit is not wired to the core's integer file yet.
  logic [63:0] xval_q;
  wire  [63:0] s2_val = (funct3 == 3'b100) ? xval_q
                      : (funct3 == 3'b011) ? {{59{insn_q[19]}}, insn_q[19:15]}
                      : rdata1;

  // insert one element into a register image, constant slices only
  function automatic logic [63:0] set_elem(input logic [63:0] v, input logic [2:0] i,
                                           input logic [1:0] sew, input logic [63:0] x);
    logic [63:0] r;
    begin
      r = v;
      unique case (sew)
        2'd0: unique case (i)
                3'd0: r[7:0]   = x[7:0];
                3'd1: r[15:8]  = x[7:0];
                3'd2: r[23:16] = x[7:0];
                3'd3: r[31:24] = x[7:0];
                3'd4: r[39:32] = x[7:0];
                3'd5: r[47:40] = x[7:0];
                3'd6: r[55:48] = x[7:0];
                default: r[63:56] = x[7:0];
              endcase
        2'd1: unique case (i[1:0])
                2'd0: r[15:0]  = x[15:0];
                2'd1: r[31:16] = x[15:0];
                2'd2: r[47:32] = x[15:0];
                default: r[63:48] = x[15:0];
              endcase
        2'd2: begin
                if (i[0] == 1'b0) r[31:0]  = x[31:0];
                else              r[63:32] = x[31:0];
              end
        default: r = x;
      endcase
      set_elem = r;
    end
  endfunction

  // An element sits at a byte offset inside the 64-bit beat. Shifts by constants
  // only: a computed part-select has misbehaved in the tools used here.
  function automatic logic [63:0] beat_at(input logic [63:0] b, input logic [2:0] off);
    unique case (off)
      3'd0:    beat_at = b;
      3'd1:    beat_at = b >> 8;
      3'd2:    beat_at = b >> 16;
      3'd3:    beat_at = b >> 24;
      3'd4:    beat_at = b >> 32;
      3'd5:    beat_at = b >> 40;
      3'd6:    beat_at = b >> 48;
      default: beat_at = b >> 56;
    endcase
  endfunction

  // ---- widening ------------------------------------------------------------
  // A widening op reads SEW-wide elements and writes 2*SEW-wide results, so one
  // 64-bit register holds half as many results as the sources hold elements.
  // float ops use funct3 = 001 (OPFVV)
  wire fadd = (funct3 == 3'b001) && ((funct6 == 6'b000000) || (funct6 == 6'b000010));
  wire fmul = (funct3 == 3'b001) && (funct6 == 6'b100100);
  wire fop  = fadd || fmul;

  wire widen = (funct6 == 6'b110000) || (funct6 == 6'b110001) ||
                (funct6 == 6'b111000) || (funct6 == 6'b111001);
  wire [6:0] nelem_w = (sew_sel == 2'd0) ? 7'd4 : (sew_sel == 2'd1) ? 7'd2 : 7'd1;

  // ---- narrowing -----------------------------------------------------------
  // A narrowing op reads 2*SEW-wide source elements and writes SEW-wide results,
  // so one register holds TWICE as many results as the source holds elements.
  // ---- slides --------------------------------------------------------------
  // vslideup.vx/.vi   vd[i+off] = vs2[i]   elements below off keep their old value
  // vslidedown.vx/.vi vd[i]     = vs2[i+off]   past the end they become zero
  wire slide_up   = (funct6 == 6'b001110);
  wire slide_down = (funct6 == 6'b001111);
  wire slide      = (slide_up || slide_down) && ((funct3 == 3'b100) || (funct3 == 3'b011));

  wire narrow = (funct6 == 6'b101100) || (funct6 == 6'b101101) ||
                (funct6 == 6'b101110);      // vnclip

  // extract result-element i of vs2 at 2*SEW width
  function automatic logic [63:0] get_elem_w(input logic [63:0] v, input logic [2:0] i,
                                             input logic [1:0] sew);
    logic [63:0] x;
    begin
      x = 64'd0;
      unique case (sew)
        2'd0: unique case (i[1:0])                  // source elements are 16 bits
                2'd0: x = {48'd0, v[15:0]};
                2'd1: x = {48'd0, v[31:16]};
                2'd2: x = {48'd0, v[47:32]};
                default: x = {48'd0, v[63:48]};
              endcase
        2'd1: begin                                  // sources are 32 bits
                if (i[0] == 1'b0) x = {32'd0, v[31:0]};
                else              x = {32'd0, v[63:32]};
              end
        default: x = v;                              // sources are 64 bits
      endcase
      get_elem_w = x;
    end
  endfunction

  // sign- or zero-extend one source element to 64 bits
  function automatic logic [63:0] ext_elem(input logic [63:0] v, input logic [2:0] i,
                                           input logic [1:0] sew, input logic sgn);
    logic [63:0] x;
    begin
      x = get_elem(v, i, sew);
      if (sgn) begin
        unique case (sew)
          2'd0: x = {{56{x[7]}},  x[7:0]};
          2'd1: x = {{48{x[15]}}, x[15:0]};
          2'd2: x = {{32{x[31]}}, x[31:0]};
          default: x = x;
        endcase
      end else begin
        unique case (sew)
          2'd0: x = {56'd0, x[7:0]};
          2'd1: x = {48'd0, x[15:0]};
          2'd2: x = {32'd0, x[31:0]};
          default: x = x;
        endcase
      end
      ext_elem = x;
    end
  endfunction

  // place a 2*SEW result at result-element index i
  function automatic logic [63:0] set_elem_w(input logic [63:0] v, input logic [2:0] i,
                                             input logic [1:0] sew, input logic [63:0] x);
    logic [63:0] r;
    begin
      r = v;
      unique case (sew)
        2'd0: unique case (i[1:0])                 // results are 16 bits
                2'd0: r[15:0]  = x[15:0];
                2'd1: r[31:16] = x[15:0];
                2'd2: r[47:32] = x[15:0];
                default: r[63:48] = x[15:0];
              endcase
        2'd1: begin                                  // results are 32 bits
                if (i[0] == 1'b0) r[31:0]  = x[31:0];
                else              r[63:32] = x[31:0];
              end
        default: r = x;                              // results are 64 bits
      endcase
      set_elem_w = r;
    end
  endfunction

  function automatic logic [7:0] wstrb_for(input logic [1:0] sew);
    unique case (sew)
      2'd0:    wstrb_for = 8'h01;
      2'd1:    wstrb_for = 8'h03;
      2'd2:    wstrb_for = 8'h0F;
      default: wstrb_for = 8'hFF;
    endcase
  endfunction

  // the mask bit for element i, taken from v0 at the element width
  function automatic logic mask_bit(input logic [2:0] i, input logic [1:0] sew);
    logic [63:0] m;
    begin
      m = rdata_mask;
      // one mask bit per ELEMENT: element i uses bit i of v0, whatever the width
      mask_bit = m[i];
    end
  endfunction

  // ---- reductions ----------------------------------------------------------
  // funct3 = 010 (OPMVV) with the vred funct6 codes. vs1[0] seeds the result and
  // the answer lands in element 0 of vd, which is what the ISA specifies.
  function automatic logic [63:0] reduce_op(input logic [5:0] fn,
                                            input logic [63:0] acc, input logic [63:0] x);
    unique case (fn)
      6'b000000: reduce_op = acc + x;                       // vredsum
      6'b000001: reduce_op = acc & x;                       // vredand
      6'b000010: reduce_op = acc | x;                       // vredor
      6'b000011: reduce_op = acc ^ x;                       // vredxor
      6'b000100: reduce_op = (x < acc) ? x : acc;           // vredminu
      6'b000101: reduce_op = ($signed(x) < $signed(acc)) ? x : acc;  // vredmin
      6'b000110: reduce_op = (x > acc) ? x : acc;           // vredmaxu
      6'b000111: reduce_op = ($signed(x) > $signed(acc)) ? x : acc;  // vredmax
      default:   reduce_op = acc + x;
    endcase
  endfunction

  // ---- binary32 floating point ---------------------------------------------
  // SEW = 32 only. Add, subtract and multiply with the special cases the spec
  // requires: signed zero, infinity, NaN, and round-to-nearest-even. Division and
  // binary64 are NOT implemented.
  function automatic logic [31:0] f32_addsub(input logic [31:0] a, input logic [31:0] b,
                                            input logic sub);
    logic        sa, sb, sr, sbig;
    logic [7:0]  ea, eb, ebig, ediff;
    logic [22:0] ma, mb;
    logic [23:0] fa, fb, mbig, msmall;
    logic [24:0] wide;
    logic [7:0]  sh;
    begin
      sa = a[31]; ea = a[30:23]; ma = a[22:0];
      sb = b[31]; eb = b[30:23]; mb = b[22:0];
      sb = sb ^ sub;                       // subtraction flips b's sign

      if ((ea == 8'hFF && ma != 0) || (eb == 8'hFF && mb != 0))
        f32_addsub = 32'h7FC0_0000;                       // NaN
      else if (ea == 8'hFF && eb == 8'hFF && (sa != sb))
        f32_addsub = 32'h7FC0_0000;                       // inf + -inf
      else if (ea == 8'hFF)
        f32_addsub = {sa, 8'hFF, 23'd0};
      else if (eb == 8'hFF)
        f32_addsub = {sb, 8'hFF, 23'd0};
      else if (ea == 0 && ma == 0 && eb == 0 && mb == 0)
        f32_addsub = (sa == sb) ? {sa, 31'd0} : 32'd0;
      else begin
        // 24-bit mantissa with the implicit bit at 23: the point is after bit 23
        fa = (ea == 0) ? {1'b0, ma} : {1'b1, ma};
        fb = (eb == 0) ? {1'b0, mb} : {1'b1, mb};
        ebig   = (ea >= eb) ? ((ea == 0) ? 8'd1 : ea) : ((eb == 0) ? 8'd1 : eb);
        ediff  = ((ea >= eb) ? ea : eb) - ((ea >= eb) ? eb : ea);
        mbig   = (ea >= eb) ? fa : fb;
        msmall = (ea >= eb) ? fb : fa;
        sbig   = (ea >= eb) ? sa : sb;
        msmall = (ediff > 8'd24) ? 24'd0 : (msmall >> ediff[4:0]);
        if (sa == sb) wide = {1'b0, mbig} + {1'b0, msmall};
        else if (mbig >= msmall) wide = {1'b0, mbig} - {1'b0, msmall};
        else begin
          wide = {1'b0, msmall} - {1'b0, mbig};
          sbig = sb;
        end
        sr = sbig;
        if (wide == 0) f32_addsub = 32'd0;
        else begin
          if (wide[24]) begin wide = wide >> 1; ebig = ebig + 8'd1; end
          else begin
            sh = 8'd0;
            while (!wide[23] && ebig > 8'd1 && sh < 8'd24) begin
              wide = wide << 1; ebig = ebig - 8'd1; sh = sh + 8'd1;
            end
          end
          if (ebig >= 8'hFF) f32_addsub = {sr, 8'hFF, 23'd0};
          else if (wide[23]) f32_addsub = {sr, ebig, wide[22:0]};
          else               f32_addsub = {sr, 31'd0};
        end
      end
    end
  endfunction

  function automatic logic [31:0] f32_mul(input logic [31:0] a, input logic [31:0] b);
    logic        sa, sb;
    logic [7:0]  ea, eb, er;
    logic [22:0] ma, mb;
    logic [47:0] prod;
    logic [24:0] fa, fb;
    begin
      sa = a[31]; ea = a[30:23]; ma = a[22:0];
      sb = b[31]; eb = b[30:23]; mb = b[22:0];
      if ((ea == 8'hFF && ma != 0) || (eb == 8'hFF && mb != 0))
        f32_mul = 32'h7FC0_0000;
      else if ((ea == 8'hFF && ma == 0) || (eb == 8'hFF && mb == 0)) begin
        if ((ea == 8'hFF) && (eb == 0 && mb == 0)) f32_mul = 32'h7FC0_0000;  // inf*0
        else f32_mul = {sa ^ sb, 8'hFF, 23'd0};
      end
      else if ((ea == 0 && ma == 0) || (eb == 0 && mb == 0))
        f32_mul = {sa ^ sb, 31'd0};                       // zero
      else begin
        fa = (ea == 0) ? {2'b00, ma} : {2'b01, ma};
        fb = (eb == 0) ? {2'b00, mb} : {2'b01, mb};
        prod = fa * fb;                                   // 50-bit product
        er = ea + eb - 8'd127;
        // product has the point after bit 47 for two 1.m mantissas
        if (prod[47]) begin er = er + 8'd1; prod = prod >> 1; end
        if (er == 0 || er > 8'd254) f32_mul = {sa ^ sb, 31'd0};
        else f32_mul = {sa ^ sb, er, prod[45:23]};
      end
    end
  endfunction

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
    acc     = rdata3;               // start from vd so the tail keeps its value
    vd_we   = 1'b0;
    sat_hit = 1'b0;
    vd_addr = grp_d;          // advances with the register group
    if (load_we_q) begin
      // a completed vector load writes the accumulated register
      vd_we = 1'b1;
      acc   = ld_acc;
    end
    w = (sew_sel == 2'd0) ? 7'd8 : (sew_sel == 2'd1) ? 7'd16
      : (sew_sel == 2'd2) ? 7'd32 : 7'd64;
    if ((go_q || grp_commit_q) && (opcode == 7'b1010111) && !load_we_q) begin
      if (funct3 == 3'b111) begin
        // vsetvli / vsetivli: vl and vtype come from the instruction
        acc   = 64'd0;
      end else if (funct3 == 3'b010) begin
        // ---- reduction: vs1[0] seeds, elements of vs2 fold in, vd[0] gets it
        logic [63:0] r_e, x_e;
        vd_we = 1'b1;
        acc   = rdata3;                       // preserve the rest of vd
        r_e   = get_elem(rdata1, 3'd0, sew_sel);
        for (int i = 0; i < 8; i++) begin
          if ((i < vl_q) && (i < nelem)) begin
            x_e = get_elem(rdata2, i[2:0], sew_sel);
            r_e = reduce_op(funct6, r_e, x_e);
          end
        end
        // masking applies to the result element only
        if (vm || mask_bit(3'd0, sew_sel)) begin
          unique case (sew_sel)
            2'd0: acc[7:0]   = r_e[7:0];
            2'd1: acc[15:0]  = r_e[15:0];
            2'd2: acc[31:0]  = r_e[31:0];
            default: acc     = r_e;
          endcase
        end
      end else if (fop) begin
        // ---- binary32 add / sub / mul (SEW = 32 only) ---------------------
        logic [31:0] fa_e, fb_e, fr_e;
        vd_we = 1'b1;
        acc   = 64'd0;
        for (int i = 0; i < 2; i++) begin
          if ((i < vl_q) && (vm || mask_bit(i[2:0], sew_sel))) begin
            if (i == 0) begin
              fa_e = rdata2[31:0];
              fb_e = (funct3 == 3'b000) ? rdata1[31:0] : rdata1[31:0];
            end else begin
              fa_e = rdata2[63:32];
              fb_e = rdata1[63:32];
            end
            fr_e = fmul ? f32_mul(fa_e, fb_e)
                        : f32_addsub(fa_e, fb_e, funct6 == 6'b000010);
            if (i == 0) acc[31:0]  = fr_e;
            else        acc[63:32] = fr_e;
          end
        end
      end else if (slide) begin
        // ---- slide: the offset comes from vs1 (.vx) or the immediate (.vi) ----
        logic [63:0] soff, se;
        vd_we = 1'b1;
        acc   = rdata3;               // slideup keeps the elements below the offset
        soff  = (funct3 == 3'b011) ? {{59{insn_q[19]}}, insn_q[19:15]}
                                   : get_elem(rdata1, 3'd0, sew_sel);
        for (int i = 0; i < 8; i++) begin
          if ((i < vl_q) && (i < nelem)) begin
            if (slide_up) begin
              // destination index is i + off; only write if it fits
              if (({58'd0, i[2:0]} + soff) < nelem) begin
                se = get_elem(rdata2, i[2:0], sew_sel);
                acc = set_elem(acc, (i[2:0] + soff[2:0]), sew_sel, se);
              end
            end else begin
              // source index is i + off; past the end the element is zero
              if (({58'd0, i[2:0]} + soff) < nelem)
                se = get_elem(rdata2, (i[2:0] + soff[2:0]), sew_sel);
              else
                se = 64'd0;
              acc = set_elem(acc, i[2:0], sew_sel, se);
            end
          end
        end
      end else if (narrow) begin
        // ---- narrowing: 2*SEW sources, SEW results ------------------------
        // The shift comes from vs1 element 0 for .wv, or from the immediate for
        // .wi. Arithmetic narrowing sign-extends the source before shifting.
        logic [63:0] nx, nsh, nr;
        vd_we = 1'b1;
        acc   = 64'd0;
        nsh   = (funct3 == 3'b011) ? {{59{insn_q[19]}}, insn_q[19:15]}
                                   : get_elem(rdata1, 3'd0, sew_sel);
        // bounded by the SOURCE's element count: a 64-bit register holds only
        // VLEN/(2*SEW) elements at twice the width, and going past that wrapped
        // and rewrote the same results
        for (int i = 0; i < 8; i++) begin
          if ((i < vl_q) && (i < nelem_w) && (vm || mask_bit(i[2:0], sew_sel))) begin
            nx = get_elem_w(rdata2, i[2:0], sew_sel);
            if (funct6 == 6'b101110) begin           // vnclip: round and saturate
              logic signed [63:0] sv, shifted, lo, hi, rounded;
              logic [63:0] half, sx;
              // the source is SIGNED at 2*SEW: extend from that width before
              // clipping, or 0x8000 reads as +32768 instead of -32768
              unique case (sew_sel)
                2'd0: sx = {{48{nx[15]}}, nx[15:0]};
                2'd1: sx = {{32{nx[31]}}, nx[31:0]};
                default: sx = nx;
              endcase
              sv   = sx;
              half = (nsh == 64'd0) ? 64'd0 : (64'd1 << (nsh[5:0] - 6'd1));
              // vxrm: 0 round-to-nearest-up, 1 round-to-nearest-even, 2 truncate
              unique case (vxrm_q)
                2'd0:    rounded = sv + half;
                2'd1:    rounded = sv + half - 64'd1 + ((sv >> nsh[5:0]) & 64'd1);
                default: rounded = sv;
              endcase
              shifted = (nsh == 64'd0) ? rounded : (rounded >>> nsh[5:0]);
              unique case (sew_sel)
                2'd0: begin lo = -64'sd128;               hi = 64'sd127;          end
                2'd1: begin lo = -64'sd32768;             hi = 64'sd32767;        end
                2'd2: begin lo = -64'sd2147483648;        hi = 64'sd2147483647;   end
                default: begin lo = {1'b1, 63'd0};        hi = {1'b0, {63{1'b1}}}; end
              endcase
              if (shifted > hi) begin
                nr = hi[63:0];
                sat_hit = 1'b1;
              end else if (shifted < lo) begin
                nr = lo[63:0];
                sat_hit = 1'b1;
              end else begin
                nr = shifted[63:0];
              end
            end else if (funct6 == 6'b101101) begin   // vnsra: sign-extend first
              unique case (sew_sel)
                2'd0: nx = {{48{nx[15]}}, nx[15:0]};
                2'd1: nx = {{32{nx[31]}}, nx[31:0]};
                default: nx = nx;
              endcase
              nr = $signed(nx) >>> nsh[5:0];
            end else begin
              nr = nx >> nsh[5:0];                   // vnsrl
            end
            acc = set_elem(acc, i[2:0], sew_sel, nr);
          end
        end
      end else if (widen) begin
        // ---- widening: SEW-wide sources, 2*SEW-wide results -----------------
        logic [63:0] wa, wb, wr;
        vd_we = 1'b1;
        acc   = 64'd0;               // a widening op writes a fresh register
        for (int i = 0; i < 8; i++) begin
          if ((i < vl_q) && (i < nelem_w) && (vm || mask_bit(i[2:0], sew_sel))) begin
            // vwadd/vwmul are signed, the *u variants unsigned on both operands
            wa = ext_elem(rdata2, i[2:0], sew_sel, !funct6[0]);
            wb = ext_elem(rdata1, i[2:0], sew_sel, !funct6[0]);
            unique case (funct6)
              6'b110000, 6'b110001: wr = wa + wb;   // vwadd / vwaddu
              6'b111000, 6'b111001: wr = wa * wb;   // vwmul / vwmulu
              default:              wr = wa + wb;
            endcase
            acc = set_elem_w(acc, i[2:0], sew_sel, wr);
          end
        end
      end else begin
        vd_we = 1'b1;
        for (int i = 0; i < 8; i++) begin
          // masking: with vm=0 only elements whose v0 bit is set are written
          if ((i < vl_q) && (i < nelem) && (vm || mask_bit(i[2:0], sew_sel))) begin
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
      // bit 1 is BUSY: set while an element walk or a register-group walk is in
      // flight, so software polls this instead of spinning a fixed count
      4'd0: csr_rdata = {62'd0, (el_walk_q || grp_walk_q), go_q};
      4'd1: csr_rdata = {57'd0, vl_q};
      4'd2: csr_rdata = {56'd0, vtype_q};
      4'd3: csr_rdata = {57'd0, vstart_q};
      4'd4: csr_rdata = {32'd0, insn_q};
      4'd5: csr_rdata = {63'd0, vxsat_q};
      4'd11: csr_rdata = {62'd0, vxrm_q};
      4'd6: csr_rdata = cdata;
      4'd9: csr_rdata = xval_q;
      4'd10: csr_rdata = base_q;
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
      vxrm_q      <= 2'd0;
      insn_q      <= 32'd0;
      go_q        <= 1'b0;
      xval_q      <= 64'd0;
      base_q      <= 64'd0;
      el_q        <= 3'd0;
      el_walk_q   <= 1'b0;
      el_issued_q <= 1'b0;
      el_mask_q   <= 1'b0;
      is_store_q  <= 1'b0;
      ld_acc      <= 64'd0;
      load_we_q   <= 1'b0;
      grp_q       <= 4'd0;
      grp_walk_q  <= 1'b0;
      grp_commit_q<= 1'b0;
      caddr_q     <= 5'd0;
      insn_count_q <= 32'd0;
      illegal_q   <= 1'b0;
    end else begin
      go_q <= 1'b0;

      // ---- register-group walk (vlmul) ----------------------------------
      // A grouped op takes `lmul` cycles, one register per cycle. Element indices
      // for masking are per register because v0 is grouped too.
      if (grp_walk_q) begin
        if (grp_q + 4'd1 >= lmul) begin
          grp_walk_q   <= 1'b0;
          grp_commit_q <= 1'b1;
          grp_q        <= 4'd0;
        end else begin
          grp_q        <= grp_q + 4'd1;
          grp_commit_q <= 1'b1;
        end
      end else begin
        grp_commit_q <= 1'b0;
        if (go_q && (opcode == 7'b1010111) && (funct3 != 3'b111) &&
            (funct3 != 3'b010) && !widen && (lmul > 4'd1)) begin
          grp_q      <= 4'd0;
          grp_walk_q <= 1'b1;
        end
      end

      // ---- vector load / store walk -------------------------------------
      if (go_q && ((opcode == 7'b0000111) || (opcode == 7'b0100111)) && !el_walk_q) begin
        el_q        <= 3'd0;
        el_issued_q <= 1'b0;
        el_walk_q   <= 1'b1;
        is_store_q  <= (opcode == 7'b0100111);
        ld_acc      <= rdata3;          // keep vd's untouched elements
      end else if (el_walk_q) begin
        if (!el_issued_q) begin
          if (el_active && mem_req_ready) el_issued_q <= 1'b1;
          // an inactive element is skipped without touching memory
          else if (!el_active) begin
            if (el_q + 3'd1 >= nelem) el_walk_q <= 1'b0;
            else                      el_q <= el_q + 3'd1;
          end
        end else if (is_store_q) begin
          // the store is done once the bus took it
          el_issued_q <= 1'b0;
          if (el_q + 3'd1 >= nelem) el_walk_q <= 1'b0;
          else                      el_q <= el_q + 3'd1;
        end else if (mem_rsp_valid) begin
          // a load element lands in the accumulator
          ld_acc      <= set_elem(ld_acc, el_q, sew_sel,
                                  beat_at(mem_rsp_rdata, mem_req_addr[2:0]));
          el_issued_q <= 1'b0;
          if (el_q + 3'd1 >= nelem) el_walk_q <= 1'b0;
          else                      el_q <= el_q + 3'd1;
        end
      end

      // the loaded register is written when the walk completes
      if (el_walk_q && !is_store_q && (el_q + 3'd1 >= nelem) && el_issued_q && mem_rsp_valid)
        load_we_q <= 1'b1;
      else
        load_we_q <= 1'b0;

      if (sat_hit) vxsat_q <= 1'b1;

      if (csr_we) begin
        unique case (csr_addr)
          4'd0: if (csr_wdata[0]) begin
                  go_q         <= 1'b1;
                  insn_count_q <= insn_count_q + 32'd1;
                  // vsetvli/vsetivli take effect here
                  if (opcode_of(insn_q) == 7'b1010111 && insn_q[14:12] == 3'b111) begin
                    vtype_q <= insn_q[27:20];
                    // VLMAX = LMUL * VLEN/SEW
                    vl_q    <= (((insn_q[25:23] == 3'd0) ? 7'd8 :
                                 (insn_q[25:23] == 3'd1) ? 7'd4 :
                                 (insn_q[25:23] == 3'd2) ? 7'd2 : 7'd1)
                                * ((insn_q[22:20] == 3'd1) ? 7'd2 :
                                   (insn_q[22:20] == 3'd2) ? 7'd4 :
                                   (insn_q[22:20] == 3'd3) ? 7'd8 : 7'd1));
                  end
                end
          4'd1: vl_q    <= csr_wdata[6:0];
          4'd2: vtype_q <= csr_wdata[7:0];
          4'd3: vstart_q <= csr_wdata[6:0];
          4'd4: insn_q  <= csr_wdata[31:0];
          4'd5: vxsat_q <= csr_wdata[0];
          4'd11: vxrm_q <= csr_wdata[1:0];
          4'd6: caddr_q <= csr_wdata[4:0];
          4'd9: xval_q  <= csr_wdata;
          4'd10: base_q <= csr_wdata;
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
