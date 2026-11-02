// =============================================================================
// rv64_alu_lsu_num_cov.sv -- coverage bins for ALU, LSU, posit and quire.
//
// Mirrors the bin names in pss/rv64_full_matrix.pss so a PSS run and a UVM run can be
// scored against the same intent. Bins are declared explicitly rather than using
// `bins x = default` for the axes that matter, because an implicit default bin reports
// coverage for values nobody thought about.
// =============================================================================
`ifndef RV64_ALU_LSU_NUM_COV_SV
`define RV64_ALU_LSU_NUM_COV_SV

// retire classes used by the existing classifier
typedef enum {
  AC_ADD, AC_SUB, AC_AND, AC_OR, AC_XOR, AC_SLT, AC_SLTU,
  AC_ADDI, AC_ANDI, AC_ORI, AC_XORI, AC_SLTI, AC_SLTIU,
  AC_LOAD, AC_STORE, AC_POSIT, AC_QUIRE, AC_OTHER
} ac_class_e;

// operand class, derived from the value in the retiring instruction's rd
typedef enum {
  OC_ZERO, OC_ONE, OC_NEG_ONE, OC_TWO, OC_NEG_TWO,
  OC_INT32_MAX, OC_INT32_MIN, OC_INT64_MAX, OC_INT64_MIN,
  OC_FFFFFFFF, OC_POW2, OC_NEG_POW2, OC_ALL_ONES, OC_OTHER
} oc_class_e;

class rv64_alu_lsu_num_cov;

  ac_class_e ac;
  oc_class_e oc;
  bit        is_load, is_store, is_wide;
  bit [2:0]  width;          // 1,2,4,8 bytes
  bit [3:0]  align_off;      // 0,1,2,4,8
  int        samples = 0;

  covergroup cg_alu;
    cp_ac: coverpoint ac {
      bins add   = {AC_ADD};   bins sub  = {AC_SUB};
      bins and_  = {AC_AND};   bins or_  = {AC_OR};
      bins xor_  = {AC_XOR};   bins slt  = {AC_SLT};  bins sltu = {AC_SLTU};
      bins addi  = {AC_ADDI};  bins andi = {AC_ANDI};
      bins ori   = {AC_ORI};   bins xori = {AC_XORI};
      bins slti  = {AC_SLTI};  bins sltiu = {AC_SLTIU};
    }
    cp_oc: coverpoint oc {
      bins zero       = {OC_ZERO};        bins one      = {OC_ONE};
      bins neg_one    = {OC_NEG_ONE};     bins two      = {OC_TWO};
      bins neg_two    = {OC_NEG_TWO};     bins int32_max = {OC_INT32_MAX};
      bins int32_min  = {OC_INT32_MIN};   bins int64_max = {OC_INT64_MAX};
      bins int64_min  = {OC_INT64_MIN};   bins ffffffff = {OC_FFFFFFFF};
      bins pow2       = {OC_POW2};        bins neg_pow2 = {OC_NEG_POW2};
      bins all_ones   = {OC_ALL_ONES};
    }
    // every operation against every operand class is the coverage we actually want
    ac_x_oc: cross cp_ac, cp_oc;
  endgroup

  covergroup cg_lsu;
    cp_load:  coverpoint is_load;
    cp_store: coverpoint is_store;
    cp_width: coverpoint width {
      bins b1 = {1}; bins b2 = {2}; bins b4 = {4}; bins b8 = {8};
    }
    cp_align: coverpoint align_off {
      bins a0 = {0}; bins a1 = {1}; bins a2 = {2}; bins a4 = {4}; bins a8 = {8};
    }
    width_x_align: cross cp_width, cp_align;
  endgroup

  covergroup cg_num;
    cp_posit: coverpoint ac {
      bins padd = {AC_POSIT};
    }
    cp_quire: coverpoint ac {
      bins qadd = {AC_QUIRE};
    }
    cp_wide: coverpoint is_wide;
  endgroup

  // Plain class, not a uvm_component: it hangs off rv64_coverage's write() rather
  // than subscribing to the analysis port itself. (It used to declare
  // new(string, uvm_component parent) and call super.new(name, parent), which a
  // class with no base class does not have.)
  function new(string name = "alu_cov");
    cg_alu = new(); cg_lsu = new(); cg_num = new();
  endfunction

  // called by rv64_coverage, which owns the analysis export
  function void sample_item(rv64_retire_item t);

    ac = classify_ac(t.insn);
    oc = classify_oc(t.wdata);
    is_load  = classify_load(t.insn);
    is_store = classify_store(t.insn);
    width    = classify_width(t.insn);
    align_off= 4'(t.wdata & 4'hF);
    is_wide  = (t.wdata[63:32] != 0);
    samples++;
    cg_alu.sample(); cg_lsu.sample(); cg_num.sample();
  endfunction

  function ac_class_e classify_ac(bit [31:0] insn);
    bit [6:0] opc = insn[6:0];
    bit [2:0] f3  = insn[14:12];
    if (opc == 7'b0110011) begin
      case (f3)
        3'b000: return insn[30] ? AC_SUB : AC_ADD;
        3'b111: return AC_AND;
        3'b110: return AC_OR;
        3'b100: return AC_XOR;
        3'b010: return AC_SLT;
        3'b011: return AC_SLTU;
        default: return AC_OTHER;
      endcase
    end
    if (opc == 7'b0010011) begin
      case (f3)
        3'b000: return AC_ADDI;  3'b111: return AC_ANDI;
        3'b110: return AC_ORI;   3'b100: return AC_XORI;
        3'b010: return AC_SLTI;  3'b011: return AC_SLTIU;
        default: return AC_OTHER;
      endcase
    end
    if (opc == 7'b0000011) return AC_LOAD;
    if (opc == 7'b0100011) return AC_STORE;
    if (opc == 7'b0001011) return (insn[29:25] <= 5'd11) ? AC_POSIT : AC_QUIRE;
    return AC_OTHER;
  endfunction

  function oc_class_e classify_oc(bit [63:0] v);
    case (v)
      64'd0:                     return OC_ZERO;
      64'd1:                     return OC_ONE;
      64'hFFFF_FFFF_FFFF_FFFF:   return OC_NEG_ONE;
      64'd2:                     return OC_TWO;
      64'hFFFF_FFFF_FFFF_FFFE:   return OC_NEG_TWO;
      64'h0000_0000_7FFF_FFFF:   return OC_INT32_MAX;
      64'hFFFF_FFFF_8000_0000:   return OC_INT32_MIN;
      64'h7FFF_FFFF_FFFF_FFFF:   return OC_INT64_MAX;
      64'h8000_0000_0000_0000:   return OC_INT64_MIN;
      64'h0000_0000_FFFF_FFFF:   return OC_FFFFFFFF;
      default:                   return OC_OTHER;
    endcase
  endfunction

  function bit classify_load(bit [31:0] i);  return (i[6:0] == 7'b0000011); endfunction
  function bit classify_store(bit [31:0] i); return (i[6:0] == 7'b0100011); endfunction

  function bit [2:0] classify_width(bit [31:0] i);
    case (i[13:12])
      2'b00: return 3'd1;
      2'b01: return 3'd2;
      2'b10: return 3'd4;
      2'b11: return 3'd8;
      default: return 3'd0;
    endcase
  endfunction

  function void report();
    // $display, not uvm_info: the regression runner filters simulator output and a
    // coverage number nobody sees is a coverage number nobody acts on.
    // uvm_info with ID "COV": sim/run_uvm.sh greps for UVM_INFO.*[COV] and drops
    // everything else, including $display. The log filter, not the simulator, decides
    // what a reader sees.
    `uvm_info("COV", $sformatf("alu  = %0.1f%%  (%0d samples)",
              cg_alu.get_inst_coverage(), samples), UVM_LOW)
    `uvm_info("COV", $sformatf("lsu  = %0.1f%%", cg_lsu.get_inst_coverage()), UVM_LOW)
    `uvm_info("COV", $sformatf("num  = %0.1f%%", cg_num.get_inst_coverage()), UVM_LOW)
  endfunction
endclass

`endif
