// =============================================================================
// rv64_coverage.sv -- functional coverage collected from the retire stream.
// =============================================================================
`ifndef RV64_COVERAGE_SV
`define RV64_COVERAGE_SV

typedef enum {
  CLS_LUI, CLS_AUIPC, CLS_JAL, CLS_JALR, CLS_BRANCH, CLS_LOAD, CLS_STORE,
  CLS_OP, CLS_OP_IMM, CLS_OP32, CLS_OP_IMM32, CLS_MULDIV, CLS_BITMANIP,
  CLS_CSR, CLS_SYSTEM, CLS_OTHER
} rv64_insn_class_e;

function automatic rv64_insn_class_e rv64_classify(bit [31:0] insn);
  bit [6:0] op;
  bit [6:0] f7;
  op = insn[6:0];
  f7 = insn[31:25];
  case (op)
    7'h37: return CLS_LUI;
    7'h17: return CLS_AUIPC;
    7'h6F: return CLS_JAL;
    7'h67: return CLS_JALR;
    7'h63: return CLS_BRANCH;
    7'h03: return CLS_LOAD;
    7'h23: return CLS_STORE;
    7'h13: return CLS_OP_IMM;
    7'h1B: return CLS_OP_IMM32;
    7'h3B: return CLS_OP32;
    7'h33: begin
      if (f7 == 7'h01)                     return CLS_MULDIV;
      if (f7 inside {7'h05, 7'h14, 7'h24, 7'h34, 7'h10, 7'h07, 7'h20, 7'h30})
                                           return CLS_BITMANIP;
      return CLS_OP;
    end
    7'h73: return (insn[14:12] == 3'b000) ? CLS_SYSTEM : CLS_CSR;
    7'h0F: return CLS_SYSTEM;
    default: return CLS_OTHER;
  endcase
endfunction

class rv64_coverage extends uvm_subscriber #(rv64_retire_item);
  `uvm_component_utils(rv64_coverage)

  rv64_insn_class_e cls;
  bit               we;
  bit [4:0]         rd;

  covergroup cg_retire;
    option.per_instance = 1;
    option.name         = "rv64_retire_cg";

    cp_class: coverpoint cls {
      bins lui       = {CLS_LUI};
      bins auipc     = {CLS_AUIPC};
      bins jal       = {CLS_JAL};
      bins jalr      = {CLS_JALR};
      bins branch    = {CLS_BRANCH};
      bins load      = {CLS_LOAD};
      bins store     = {CLS_STORE};
      bins op        = {CLS_OP};
      bins op_imm    = {CLS_OP_IMM};
      bins op32      = {CLS_OP32};
      bins op_imm32  = {CLS_OP_IMM32};
      bins muldiv    = {CLS_MULDIV};
      bins bitmanip  = {CLS_BITMANIP};
      bins csr       = {CLS_CSR};
      bins system    = {CLS_SYSTEM};
    }

    cp_wr: coverpoint we {
      bins no_write = {0};
      bins write    = {1};
    }

    cp_rd: coverpoint rd {
      bins zero = {0};
      bins ra   = {1};
      bins arg  = {[10:17]};
      bins rest = default;
    }

    x_wr_class: cross cp_class, cp_wr;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_retire = new();
  endfunction

  function void write(rv64_retire_item t);
    cls = rv64_classify(t.insn);
    we  = t.we;
    rd  = t.waddr;
    cg_retire.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("retire coverage = %0.1f%%", cg_retire.get_inst_coverage()), UVM_LOW)
  endfunction
endclass

`endif
