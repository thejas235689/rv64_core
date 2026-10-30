// =============================================================================
// rv64_mem_agent.sv -- memory agent: driver, monitor and agent.
//
// The driver *is* the memory model for both ports. It owns a 64 KiB array,
// answers instruction fetches and data accesses with a one-cycle response
// latency, applies byte-strobed writes, and can inject request backpressure and
// error responses. It also owns reset, so a sequence can load a program while
// the core is held in reset and then release it.
// =============================================================================
`ifndef RV64_MEM_AGENT_SV
`define RV64_MEM_AGENT_SV

class rv64_mem_driver extends uvm_driver #(rv64_mem_item);
  `uvm_component_utils(rv64_mem_driver)

  virtual rv64_uvm_if vif;

  localparam int MEM_WORDS = 8192;              // 64 KiB, indexed by addr[15:3]
  bit [63:0]     mem [0:MEM_WORDS-1];

  int unsigned   i_bp_pct, d_bp_pct;
  bit            err_en;
  bit [63:0]     err_addr;

  // response pipeline registers (one cycle of latency)
  bit            i_rsp_v_q, i_rsp_e_q;
  bit [63:0]     i_rsp_d_q;
  bit            d_rsp_v_q, d_rsp_e_q;
  bit [63:0]     d_rsp_d_q;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual rv64_uvm_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "rv64_mem_driver: no virtual interface in config_db")
    foreach (mem[i]) mem[i] = 64'd0;
    i_bp_pct = 0;
    d_bp_pct = 0;
    err_en   = 0;
    err_addr = 64'hFFFF_FFFF_FFFF_FFFF;
  endfunction

  // ---- reset all driven signals --------------------------------------------
  function void drive_idle();
    vif.rst_n         = 1'b0;
    vif.if_req_ready  = 1'b0;
    vif.if_rsp_valid  = 1'b0;
    vif.if_rsp_data   = 64'd0;
    vif.if_rsp_error  = 1'b0;
    vif.d_req_ready   = 1'b0;
    vif.d_rsp_valid   = 1'b0;
    vif.d_rsp_rdata   = 64'd0;
    vif.d_rsp_error   = 1'b0;
    vif.irq_soft      = 1'b0;
    vif.irq_timer     = 1'b0;
    vif.irq_ext       = 1'b0;
    vif.dbg_halt_req  = 1'b0;
    vif.dbg_resume_req= 1'b0;
    vif.dbg_step      = 1'b0;
    vif.dbg_reg_addr  = 5'd0;
    vif.wp_en         = 1'b0;
    vif.wp_addr       = 64'd0;
  endfunction

  task run_phase(uvm_phase phase);
    drive_idle();
    i_rsp_v_q = 0; i_rsp_e_q = 0; i_rsp_d_q = 0;
    d_rsp_v_q = 0; d_rsp_e_q = 0; d_rsp_d_q = 0;
    fork
      serve_ports();
      forever begin
        seq_item_port.get_next_item(req);
        apply_item(req);
        seq_item_port.item_done();
      end
    join
  endtask

  // ---- both ports, one loop so the timing convention is identical ----------
  task serve_ports();
    bit i_bp, d_bp;
    forever begin
      @(posedge vif.clk);
      #1;

      // drive this cycle's outputs from the registered state
      vif.if_req_ready = !i_bp;
      vif.if_rsp_valid = i_rsp_v_q;
      vif.if_rsp_data  = i_rsp_d_q;
      vif.if_rsp_error = i_rsp_e_q;

      vif.d_req_ready  = !d_bp;
      vif.d_rsp_valid  = d_rsp_v_q;
      vif.d_rsp_rdata  = d_rsp_d_q;
      vif.d_rsp_error  = d_rsp_e_q;

      // next-state: accept at most one request per port this cycle
      i_rsp_v_q = 1'b0;
      if (vif.if_req_valid && vif.if_req_ready) begin
        i_rsp_v_q = 1'b1;
        i_rsp_d_q = mem[vif.if_req_addr[15:3]];
        i_rsp_e_q = err_en && (vif.if_req_addr == err_addr);
      end

      d_rsp_v_q = 1'b0;
      if (vif.d_req_valid && vif.d_req_ready) begin
        if (vif.d_req_we) begin
          for (int b = 0; b < 8; b++) begin
            if (vif.d_req_wstrb[b])
              mem[vif.d_req_addr[15:3]][8*b +: 8] = vif.d_req_wdata[8*b +: 8];
          end
        end else begin
          d_rsp_v_q = 1'b1;
          d_rsp_d_q = mem[vif.d_req_addr[15:3]];
          d_rsp_e_q = err_en && (vif.d_req_addr == err_addr);
        end
      end

      // fresh backpressure decision for the next cycle
      i_bp = (i_bp_pct > 0) && (($urandom_range(0, 99)) < i_bp_pct);
      d_bp = (d_bp_pct > 0) && (($urandom_range(0, 99)) < d_bp_pct);
    end
  endtask

  // ---- apply a sequence item ----------------------------------------------
  function void apply_item(rv64_mem_item it);
    case (it.op)
      MEM_LOAD_PROG: begin
        foreach (mem[i]) mem[i] = 64'd0;
        if (it.prog_file != "") begin
          $readmemh(it.prog_file, mem);
          `uvm_info("MEMDRV", $sformatf("loaded program image %s", it.prog_file), UVM_LOW)
        end
      end
      MEM_RELEASE_RESET: begin
        vif.rst_n = 1'b1;
        `uvm_info("MEMDRV", "reset released", UVM_LOW)
      end
      MEM_SET_BP: begin
        i_bp_pct = it.bp_pct;
        d_bp_pct = it.bp_pct;
        `uvm_info("MEMDRV", $sformatf("backpressure set to %0d%%", it.bp_pct), UVM_LOW)
      end
      MEM_SET_ERR: begin
        err_en   = 1'b1;
        err_addr = it.err_addr;
        `uvm_info("MEMDRV", $sformatf("error armed at %016h", it.err_addr), UVM_LOW)
      end
      default: `uvm_error("MEMDRV", "unknown memory item")
    endcase
  endfunction

endclass

// ---- passive monitor on the memory ports ------------------------------------
class rv64_mem_monitor extends uvm_component;
  `uvm_component_utils(rv64_mem_monitor)

  virtual rv64_uvm_if vif;
  int unsigned n_ifetch, n_load, n_store;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual rv64_uvm_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "rv64_mem_monitor: no virtual interface in config_db")
    n_ifetch = 0; n_load = 0; n_store = 0;
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.clk);
      #1;
      if (vif.if_req_valid && vif.if_req_ready) n_ifetch++;
      if (vif.d_req_valid && vif.d_req_ready) begin
        if (vif.d_req_we) n_store++; else n_load++;
      end
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("MEMMON", $sformatf("bus activity: ifetch=%0d loads=%0d stores=%0d",
                                  n_ifetch, n_load, n_store), UVM_LOW)
  endfunction
endclass

class rv64_mem_agent extends uvm_agent;
  `uvm_component_utils(rv64_mem_agent)

  rv64_mem_driver  drv;
  rv64_mem_monitor mon;
  uvm_sequencer #(rv64_mem_item) sequencer;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sequencer = uvm_sequencer#(rv64_mem_item)::type_id::create("sequencer", this);
    drv       = rv64_mem_driver::type_id::create("drv", this);
    mon       = rv64_mem_monitor::type_id::create("mon", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sequencer.seq_item_export);
  endfunction
endclass

`endif
