`timescale 1ns/1ps
class fp_base_test extends uvm_test;
  `uvm_component_utils(fp_base_test)
  fp_env env;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = fp_env::type_id::create("env", this);
  endfunction
endclass

class fp_golden_test extends fp_base_test;
  `uvm_component_utils(fp_golden_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    fp_golden_seq s;
    phase.raise_objection(this);
    s = fp_golden_seq::type_id::create("s");
    s.start(env.seqr);
    phase.drop_objection(this);
  endtask
endclass
