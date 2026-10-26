// =============================================================================
// rv64_scoreboard.sv -- compares the DUT retirement and trap streams against
// golden vectors produced by the Python ISS (tb/cocotb/rv64_iss.py).
//
// Vector files (produced by sim/gen_uvm_vectors.py), all $readmemh format:
//   <prefix>.retire.hex  5 numbers per retirement: pc insn we waddr wdata
//   <prefix>.trap.hex    2 numbers per trap:       pc cause
//   <prefix>.counts.hex  expected retirement count, then expected trap count
//
// Using vectors from the independent ISS keeps the reference model out of the
// UVM code: the environment checks the DUT, it does not re-implement the ISA.
// =============================================================================
`ifndef RV64_SCOREBOARD_SV
`define RV64_SCOREBOARD_SV

// Declare the analysis-imp names before the class that uses them: this is what
// creates the uvm_analysis_imp_retire / uvm_analysis_imp_trap types.
`uvm_analysis_imp_decl(_retire)
`uvm_analysis_imp_decl(_trap)

class rv64_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(rv64_scoreboard)

  uvm_analysis_imp_retire #(rv64_retire_item, rv64_scoreboard) retire_imp;
  uvm_analysis_imp_trap   #(rv64_trap_item,   rv64_scoreboard) trap_imp;

  uvm_event done_ev;

  // expected vectors
  bit [63:0] exp_r [0:65535];       // 5 entries per retirement
  bit [63:0] exp_t [0:16383];       // 2 entries per trap
  bit [63:0] counts[0:1];

  int        n_retire_exp, n_trap_exp;
  int        n_retire_got, n_trap_got;
  int        n_errors;

  string     prefix;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    retire_imp = new("retire_imp", this);
    trap_imp   = new("trap_imp", this);
    done_ev    = new("done_ev");
    n_retire_exp = 0; n_trap_exp = 0;
    n_retire_got = 0; n_trap_got = 0;
    n_errors     = 0;

    if (!uvm_config_db#(string)::get(this, "", "vector_prefix", prefix)) begin
      `uvm_fatal("NOVEC", "rv64_scoreboard: no vector_prefix in config_db")
    end
    $readmemh({prefix, ".counts.hex"}, counts);
    $readmemh({prefix, ".retire.hex"}, exp_r);
    $readmemh({prefix, ".trap.hex"},   exp_t);
    n_retire_exp = counts[0];
    n_trap_exp   = counts[1];
    `uvm_info("SB", $sformatf("vectors %s: %0d expected retirements, %0d expected traps",
                              prefix, n_retire_exp, n_trap_exp), UVM_LOW)
  endfunction

  // ---- retirement comparison ----------------------------------------------
  function void write_retire(rv64_retire_item r);
    int i;
    i = n_retire_got;
    n_retire_got++;
    if (i >= n_retire_exp) begin
      // program has run past the golden window: the scoreboard does not judge it
      return;
    end

    if (r.pc !== exp_r[5*i]) begin
      `uvm_error("SB", $sformatf("retirement %0d: pc DUT=%016h expected=%016h",
                                 i, r.pc, exp_r[5*i]))
      n_errors++;
    end
    if (r.insn !== exp_r[5*i+1][31:0]) begin
      `uvm_error("SB", $sformatf("retirement %0d (pc %016h): insn DUT=%08h expected=%08h",
                                 i, r.pc, r.insn, exp_r[5*i+1][31:0]))
      n_errors++;
    end
    if (exp_r[5*i+2] != 0) begin
      if (!r.we) begin
        `uvm_error("SB", $sformatf("retirement %0d (pc %016h): expected a write to x%0d",
                                   i, r.pc, exp_r[5*i+3]))
        n_errors++;
      end else begin
        if (r.waddr !== exp_r[5*i+3][4:0]) begin
          `uvm_error("SB", $sformatf("retirement %0d (pc %016h): waddr DUT=x%0d expected=x%0d",
                                     i, r.pc, r.waddr, exp_r[5*i+3][4:0]))
          n_errors++;
        end
        if (r.wdata !== exp_r[5*i+4]) begin
          `uvm_error("SB", $sformatf("retirement %0d (pc %016h): x%0d DUT=%016h expected=%016h",
                                     i, r.pc, r.waddr, r.wdata, exp_r[5*i+4]))
          n_errors++;
        end
      end
    end else if (r.we && (r.waddr != 5'd0)) begin
      // A write indication to x0 is architecturally no write: the register file
      // suppresses it, and the core still reports the write port as enabled.
      `uvm_error("SB", $sformatf("retirement %0d (pc %016h): unexpected write to x%0d",
                                 i, r.pc, r.waddr))
      n_errors++;
    end

    if (n_retire_got == n_retire_exp) begin
      `uvm_info("SB", $sformatf("all %0d expected retirements matched", n_retire_exp), UVM_LOW)
      done_ev.trigger();
    end
  endfunction

  // ---- trap comparison ----------------------------------------------------
  function void write_trap(rv64_trap_item t);
    int j;
    j = n_trap_got;
    n_trap_got++;
    if (j >= n_trap_exp) return;

    if (t.pc !== exp_t[2*j]) begin
      `uvm_error("SB", $sformatf("trap %0d: pc DUT=%016h expected=%016h",
                                 j, t.pc, exp_t[2*j]))
      n_errors++;
    end
    if (t.cause !== exp_t[2*j+1]) begin
      `uvm_error("SB", $sformatf("trap %0d (pc %016h): cause DUT=%016h expected=%016h",
                                 j, t.pc, t.cause, exp_t[2*j+1]))
      n_errors++;
    end
  endfunction

  // ---- end of test --------------------------------------------------------
  function void check_phase(uvm_phase phase);
    if (n_retire_got < n_retire_exp) begin
      `uvm_error("SB", $sformatf("only %0d of %0d expected retirements were observed",
                                 n_retire_got, n_retire_exp))
      n_errors++;
    end
    if (n_trap_got < n_trap_exp) begin
      `uvm_error("SB", $sformatf("only %0d of %0d expected traps were observed",
                                 n_trap_got, n_trap_exp))
      n_errors++;
    end
    if (n_errors == 0) begin
      `uvm_info("SB", $sformatf("PASS: %0d retirements and %0d traps matched the golden vectors (%0d further retirements after the golden window ignored)",
                                n_retire_exp, n_trap_exp,
                                (n_retire_got > n_retire_exp) ? (n_retire_got - n_retire_exp) : 0),
                UVM_LOW)
    end else begin
      `uvm_error("SB", $sformatf("FAIL: %0d mismatches", n_errors))
    end
  endfunction
endclass

`endif
