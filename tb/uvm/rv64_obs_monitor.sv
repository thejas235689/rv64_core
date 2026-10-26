// =============================================================================
// rv64_obs_monitor.sv -- passive monitor on the core's observability ports.
// Turns the retirement and trap streams into transactions for the scoreboard
// and the coverage collector.
// =============================================================================
`ifndef RV64_OBS_MONITOR_SV
`define RV64_OBS_MONITOR_SV

class rv64_obs_monitor extends uvm_component;
  `uvm_component_utils(rv64_obs_monitor)

  virtual rv64_uvm_if vif;

  uvm_analysis_port #(rv64_retire_item) retire_ap;
  uvm_analysis_port #(rv64_trap_item)   trap_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    retire_ap = new("retire_ap", this);
    trap_ap   = new("trap_ap", this);
    if (!uvm_config_db#(virtual rv64_uvm_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "rv64_obs_monitor: no virtual interface in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    rv64_retire_item r;
    rv64_trap_item   t;
    forever begin
      @(posedge vif.clk);
      #1;

      if (vif.retire_valid) begin
        r = rv64_retire_item::type_id::create("r");
        r.pc    = vif.retire_pc;
        r.insn  = vif.retire_insn;
        r.we    = vif.gpr_we;
        r.waddr = vif.gpr_waddr;
        r.wdata = vif.gpr_wdata;
        retire_ap.write(r);
      end

      if (vif.trap_valid) begin
        t = rv64_trap_item::type_id::create("t");
        t.pc    = vif.trap_pc;
        t.cause = vif.trap_cause;
        trap_ap.write(t);
      end
    end
  endtask
endclass

`endif
