// =============================================================================
// rv64_env.sv -- environment: memory agent, observability monitor, scoreboard,
// coverage collector.
// =============================================================================
`ifndef RV64_ENV_SV
`define RV64_ENV_SV

class rv64_env extends uvm_env;
  `uvm_component_utils(rv64_env)

  rv64_mem_agent    agent;
  rv64_obs_monitor  obs;
  rv64_scoreboard   sb;
  rv64_coverage     cov;
  rv64_alu_lsu_num_cov alu_cov;   // ALU / LSU / posit / quire bins

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = rv64_mem_agent::type_id::create("agent", this);
    obs   = rv64_obs_monitor::type_id::create("obs", this);
    sb    = rv64_scoreboard::type_id::create("sb", this);
    cov   = rv64_coverage::type_id::create("cov", this);
    alu_cov = rv64_alu_lsu_num_cov::type_id::create("alu_cov", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    obs.retire_ap.connect(sb.retire_imp);
    obs.retire_ap.connect(cov.analysis_export);
    obs.retire_ap.connect(alu_cov.analysis_export);
    obs.trap_ap.connect(sb.trap_imp);
  endfunction
endclass

`endif
