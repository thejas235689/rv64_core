// =============================================================================
// rv64_seq_lib.sv -- sequences driving the memory agent.
// =============================================================================
`ifndef RV64_SEQ_LIB_SV
`define RV64_SEQ_LIB_SV

class rv64_base_seq extends uvm_sequence #(rv64_mem_item);
  `uvm_object_utils(rv64_base_seq)

  function new(string name = "rv64_base_seq");
    super.new(name);
  endfunction
endclass

// ---- load a program image into the agent's memory ---------------------------
class rv64_load_seq extends rv64_base_seq;
  `uvm_object_utils(rv64_load_seq)
  string prog_file;

  function new(string name = "rv64_load_seq");
    super.new(name);
  endfunction

  task body();
    rv64_mem_item it;
    it = rv64_mem_item::type_id::create("it");
    it.op        = MEM_LOAD_PROG;
    it.prog_file = prog_file;
    start_item(it);
    finish_item(it);
  endtask
endclass

// ---- release reset ---------------------------------------------------------
class rv64_run_seq extends rv64_base_seq;
  `uvm_object_utils(rv64_run_seq)

  function new(string name = "rv64_run_seq");
    super.new(name);
  endfunction

  task body();
    rv64_mem_item it;
    it = rv64_mem_item::type_id::create("it");
    it.op = MEM_RELEASE_RESET;
    start_item(it);
    finish_item(it);
  endtask
endclass

// ---- set request backpressure ---------------------------------------------
class rv64_bp_seq extends rv64_base_seq;
  `uvm_object_utils(rv64_bp_seq)
  int unsigned pct;

  function new(string name = "rv64_bp_seq");
    super.new(name);
  endfunction

  task body();
    rv64_mem_item it;
    it = rv64_mem_item::type_id::create("it");
    it.op     = MEM_SET_BP;
    it.bp_pct = pct;
    start_item(it);
    finish_item(it);
  endtask
endclass

// ---- the full flow: load, release reset, optionally add backpressure -------
class rv64_program_seq extends rv64_base_seq;
  `uvm_object_utils(rv64_program_seq)

  string       prog_file;
  int unsigned bp_pct;

  function new(string name = "rv64_program_seq");
    super.new(name);
    bp_pct = 0;
  endfunction

  task body();
    rv64_mem_item it;
    it = rv64_mem_item::type_id::create("it");
    it.op        = MEM_LOAD_PROG;
    it.prog_file = prog_file;
    start_item(it);
    finish_item(it);

    if (bp_pct > 0) begin
      it = rv64_mem_item::type_id::create("it");
      it.op     = MEM_SET_BP;
      it.bp_pct = bp_pct;
      start_item(it);
      finish_item(it);
    end

    it = rv64_mem_item::type_id::create("it");
    it.op = MEM_RELEASE_RESET;
    start_item(it);
    finish_item(it);
  endtask
endclass

`endif
