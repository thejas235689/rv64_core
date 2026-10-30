// =============================================================================
// rv64_tests.sv -- UVM tests.
//
// Each test names a vector prefix; the generator (sim/gen_uvm_vectors.py)
// emits <prefix>.prog.hex, .retire.hex, .trap.hex and .counts.hex from the
// Python ISS. The test loads the program, releases reset, and waits for the
// scoreboard to consume every expected retirement.
// =============================================================================
`ifndef RV64_TESTS_SV
`define RV64_TESTS_SV

class rv64_base_test extends uvm_test;
  `uvm_component_utils(rv64_base_test)

  rv64_env    env;
  string      vec_prefix;
  int unsigned bp_pct;
  int unsigned max_cycles;

  function new(string name = "rv64_base_test", uvm_component parent = null);
    super.new(name, parent);
    vec_prefix = "";
    bp_pct     = 0;
    max_cycles = 40000;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(string)::set(this, "env.sb", "vector_prefix", vec_prefix);
    env = rv64_env::type_id::create("env", this);
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    // the UVM library emits a benign QUEUEDEL warning on every sequence item;
    // silence that id so real messages stay visible
    uvm_root::get().set_report_id_action_hier("QUEUEDEL", UVM_NO_ACTION);
  endfunction

  task run_phase(uvm_phase phase);
    rv64_program_seq seq;
    phase.raise_objection(this);

    seq = rv64_program_seq::type_id::create("seq");
    seq.prog_file = {vec_prefix, ".prog.hex"};
    seq.bp_pct    = bp_pct;
    seq.start(env.agent.sequencer);

    // wait for the scoreboard to see every expected retirement, or time out
    fork
      begin
        env.sb.done_ev.wait_trigger();
        `uvm_info("TEST", "scoreboard reached the end of the golden window", UVM_LOW)
      end
      begin
        repeat (max_cycles) @(posedge env.agent.drv.vif.clk);
        `uvm_error("TEST", "timeout waiting for the scoreboard to complete")
      end
    join_any
    disable fork;

    // Drain: a trapping instruction does not retire, so the final trap lands a
    // cycle or two after the last retirement. Let it be observed before the
    // objection is dropped and the phase ends.
    repeat (50) @(posedge env.agent.drv.vif.clk);

    phase.drop_objection(this);
  endtask
endclass

// ---- directed ALU / bit-manipulation test ----------------------------------
class rv64_alu_test extends rv64_base_test;
  `uvm_component_utils(rv64_alu_test)
  function new(string name = "rv64_alu_test", uvm_component parent = null);
    super.new(name, parent);
    vec_prefix = "sim/uvm_vectors/alu";
  endfunction
endclass

// ---- trap and exception test ----------------------------------------------
class rv64_trap_test extends rv64_base_test;
  `uvm_component_utils(rv64_trap_test)
  function new(string name = "rv64_trap_test", uvm_component parent = null);
    super.new(name, parent);
    vec_prefix = "sim/uvm_vectors/trap";
  endfunction
endclass

// ---- load/store test -------------------------------------------------------
class rv64_mem_test extends rv64_base_test;
  `uvm_component_utils(rv64_mem_test)
  function new(string name = "rv64_mem_test", uvm_component parent = null);
    super.new(name, parent);
    vec_prefix = "sim/uvm_vectors/mem";
  endfunction
endclass

// ---- random instruction stream --------------------------------------------
class rv64_random_test extends rv64_base_test;
  `uvm_component_utils(rv64_random_test)
  function new(string name = "rv64_random_test", uvm_component parent = null);
    super.new(name, parent);
    vec_prefix = "sim/uvm_vectors/random";
  endfunction
endclass

// ---- systematic ISA sweep: every op x its own exhaustive dimension ---------
class rv64_isa_test extends rv64_base_test;
  `uvm_component_utils(rv64_isa_test)
  function new(string name = "rv64_isa_test", uvm_component parent = null);
    super.new(name, parent);
    vec_prefix = "sim/uvm_vectors/isa";
    max_cycles = 120000;
  endfunction
endclass

// ---- numeric ABI: fixed-Q, quire, and the four research families ----------
class rv64_numeric_test extends rv64_base_test;
  `uvm_component_utils(rv64_numeric_test)
  function new(string name = "rv64_numeric_test", uvm_component parent = null);
    super.new(name, parent);
    vec_prefix = "sim/uvm_vectors/numeric";
    max_cycles = 60000;
  endfunction
endclass

// ---- reduced ISA sweep, sized to complete at the driver's throughput ------
class rv64_isa_small_test extends rv64_base_test;
  `uvm_component_utils(rv64_isa_small_test)
  function new(string name = "rv64_isa_small_test", uvm_component parent = null);
    super.new(name, parent);
    vec_prefix = "sim/uvm_vectors/isa_small";
    max_cycles = 200000;
  endfunction
endclass

// ---- negative sweep: every unimplemented encoding must trap ---------------
class rv64_illegal_test extends rv64_base_test;
  `uvm_component_utils(rv64_illegal_test)
  function new(string name = "rv64_illegal_test", uvm_component parent = null);
    super.new(name, parent);
    vec_prefix = "sim/uvm_vectors/illegal";
    max_cycles = 40000;
  endfunction
endclass

// ---- same program with request backpressure on both ports ------------------
class rv64_backpressure_test extends rv64_base_test;
  `uvm_component_utils(rv64_backpressure_test)
  function new(string name = "rv64_backpressure_test", uvm_component parent = null);
    super.new(name, parent);
    vec_prefix = "sim/uvm_vectors/mem";
    bp_pct     = 40;
  endfunction
endclass

`endif
