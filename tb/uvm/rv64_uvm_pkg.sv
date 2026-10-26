// =============================================================================
// rv64_uvm_pkg.sv -- the UVM environment package.
// Include order matters: items, then components that use them, then tests.
// =============================================================================
`ifndef RV64_UVM_PKG_SV
`define RV64_UVM_PKG_SV

package rv64_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "rv64_seq_item.sv"
  `include "rv64_mem_agent.sv"
  `include "rv64_obs_monitor.sv"
  `include "rv64_scoreboard.sv"
  `include "rv64_coverage.sv"
  `include "rv64_env.sv"
  `include "rv64_seq_lib.sv"
  `include "rv64_tests.sv"
endpackage

`endif
