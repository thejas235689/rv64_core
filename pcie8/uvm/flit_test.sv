`timescale 1ns/1ps
class flit_base_test extends uvm_test;
  `uvm_component_utils(flit_base_test)
  flit_env env;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = flit_env::type_id::create("env", this);
  endfunction
endclass

class flit_exact_test extends flit_base_test;
  `uvm_component_utils(flit_exact_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    flit_seq s;
    phase.raise_objection(this);
    s = flit_seq::type_id::create("s");
    s.n = 236;
    s.start(env.seqr);
    phase.drop_objection(this);
  endtask
endclass

class flit_span_test extends flit_base_test;
  `uvm_component_utils(flit_span_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    flit_seq s;
    phase.raise_objection(this);
    s = flit_seq::type_id::create("s");
    s.n = 300;                      // spans a flit boundary
    s.start(env.seqr);
    phase.drop_objection(this);
  endtask
endclass
