// =============================================================================
// rv64_seq_item.sv -- transaction and sequence item definitions.
// =============================================================================
`ifndef RV64_SEQ_ITEM_SV
`define RV64_SEQ_ITEM_SV

// ---- what the driver should do next -----------------------------------------
typedef enum bit [2:0] {
  MEM_LOAD_PROG,       // $readmemh a program image into the agent's memory
  MEM_RELEASE_RESET,   // deassert rst_n
  MEM_SET_BP,          // set request backpressure percentage
  MEM_SET_ERR          // arm an error response at one address
} rv64_mem_op_e;

class rv64_mem_item extends uvm_sequence_item;
  rv64_mem_op_e op;
  string        prog_file;
  int unsigned  bp_pct;
  bit [63:0]    err_addr;

  `uvm_object_utils_begin(rv64_mem_item)
    `uvm_field_enum(rv64_mem_op_e, op, UVM_ALL_ON)
    `uvm_field_string(prog_file, UVM_ALL_ON)
    `uvm_field_int(bp_pct, UVM_ALL_ON)
    `uvm_field_int(err_addr, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "rv64_mem_item");
    super.new(name);
  endfunction
endclass

// ---- one retired instruction, observed on the core's ports ------------------
class rv64_retire_item extends uvm_sequence_item;
  bit [63:0] pc;
  bit [31:0] insn;
  bit        we;
  bit [4:0]  waddr;
  bit [63:0] wdata;

  `uvm_object_utils_begin(rv64_retire_item)
    `uvm_field_int(pc, UVM_ALL_ON)
    `uvm_field_int(insn, UVM_ALL_ON)
    `uvm_field_int(we, UVM_ALL_ON)
    `uvm_field_int(waddr, UVM_ALL_ON)
    `uvm_field_int(wdata, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "rv64_retire_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("pc=%016h insn=%08h we=%0b x%0d=%016h",
                     pc, insn, we, waddr, wdata);
  endfunction
endclass

// ---- one taken trap ---------------------------------------------------------
class rv64_trap_item extends uvm_sequence_item;
  bit [63:0] pc;
  bit [63:0] cause;

  `uvm_object_utils_begin(rv64_trap_item)
    `uvm_field_int(pc, UVM_ALL_ON)
    `uvm_field_int(cause, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "rv64_trap_item");
    super.new(name);
  endfunction
endclass

`endif
