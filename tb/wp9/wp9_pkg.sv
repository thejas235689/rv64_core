package wp9_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  typedef enum int unsigned {
    WP_RVV=1, WP_POSIT=2, WP_LNS=3, WP_PREFETCH=4,
    WP_BPU=5, WP_FRONTEND=6, WP_UNUM=7, WP_CACHE=8, WP_PIPELINE=9
  } wp_kind_e;

  class wp9_item extends uvm_sequence_item;
    rand bit [3:0] wp_id;
    rand bit [7:0] op;
    rand bit [63:0] operand_a, operand_b;
    constraint legal_c { wp_id inside {[1:9]}; op inside {[0:15]}; }
    `uvm_object_utils_begin(wp9_item)
      `uvm_field_int(wp_id,UVM_ALL_ON)
      `uvm_field_int(op,UVM_ALL_ON)
      `uvm_field_int(operand_a,UVM_ALL_ON)
      `uvm_field_int(operand_b,UVM_ALL_ON)
    `uvm_object_utils_end
    function new(string name="wp9_item"); super.new(name); endfunction
  endclass

  // A deterministic fixture contract. This is NOT an architectural golden model.
  function automatic logic [63:0] fixture_expected(wp9_item t);
    return (t.operand_a ^ t.operand_b ^ {52'h0,t.wp_id,t.op});
  endfunction

  class wp9_sequencer extends uvm_sequencer #(wp9_item);
    `uvm_component_utils(wp9_sequencer)
    function new(string n,uvm_component p); super.new(n,p); endfunction
  endclass

  class wp9_driver extends uvm_driver #(wp9_item);
    `uvm_component_utils(wp9_driver)
    virtual wp9_if vif;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if(!uvm_config_db#(virtual wp9_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","wp9_if not configured")
    endfunction
    task run_phase(uvm_phase phase);
      wp9_item tr;
      vif.req_valid <= 0;
      vif.wp_id <= 0; vif.op <= 0;
      vif.operand_a <= 0; vif.operand_b <= 0;
      wait(vif.rst_n === 1'b1);
      forever begin
        seq_item_port.get_next_item(tr);
        @(negedge vif.clk);
        vif.req_valid <= 1;
        vif.wp_id <= tr.wp_id;
        vif.op <= tr.op;
        vif.operand_a <= tr.operand_a;
        vif.operand_b <= tr.operand_b;
        do @(posedge vif.clk); while(vif.req_ready !== 1'b1);
        @(negedge vif.clk);
        vif.req_valid <= 0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class wp9_monitor extends uvm_component;
    `uvm_component_utils(wp9_monitor)
    virtual wp9_if vif;
    uvm_analysis_port #(wp9_item) ap;
    function new(string n,uvm_component p);
      super.new(n,p); ap=new("ap",this);
    endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual wp9_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","wp9_if not configured")
    endfunction
    task run_phase(uvm_phase phase);
      wp9_item t;
      forever begin
        @(posedge vif.clk);
        if(vif.rst_n && vif.req_valid && vif.req_ready) begin
          t=wp9_item::type_id::create("sample");
          if($isunknown({vif.wp_id,vif.op,vif.operand_a,vif.operand_b,
                         vif.rsp_valid,vif.rsp_data,vif.rsp_error}))
            `uvm_error("XCHECK","Unknown on verification fixture handshake")
          if(vif.rsp_valid !== 1'b1 || vif.rsp_error !== 1'b0)
            `uvm_error("PROTOCOL","Fixture response missing/error")
          t.wp_id=vif.wp_id; t.op=vif.op;
          t.operand_a=vif.operand_a; t.operand_b=vif.operand_b;
          ap.write(t);
          if(vif.rsp_data !== fixture_expected(t))
            `uvm_error("MISMATCH",$sformatf("wp=%0d op=%0d expected=%h actual=%h",
                         t.wp_id,t.op,fixture_expected(t),vif.rsp_data))
        end
      end
    endtask
  endclass

  class wp9_coverage extends uvm_subscriber #(wp9_item);
    `uvm_component_utils(wp9_coverage)
    int unsigned seen[10];
    covergroup cg with function sample(int id,int op);
      option.per_instance=1;
      cp_wp: coverpoint id { bins all_wp[] = {[1:9]}; }
      cp_op: coverpoint op { bins operations[] = {[0:15]}; }
      cross cp_wp,cp_op;
    endgroup
    function new(string n,uvm_component p);super.new(n,p);cg=new();endfunction
    function void write(wp9_item t);
      if(t.wp_id < 1 || t.wp_id > 9)
        `uvm_error("BADWP","Out-of-range work package")
      else seen[t.wp_id]++;
      cg.sample(int'(t.wp_id),int'(t.op));
    endfunction
    function void report_phase(uvm_phase phase);
      for(int i=1;i<=9;i++)
        `uvm_info("COV",$sformatf("WP%0d fixture transactions=%0d",i,seen[i]),UVM_LOW)
    endfunction
  endclass

  class wp9_agent extends uvm_agent;
    `uvm_component_utils(wp9_agent)
    wp9_sequencer sqr; wp9_driver drv; wp9_monitor mon;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sqr=wp9_sequencer::type_id::create("sqr",this);
      drv=wp9_driver::type_id::create("drv",this);
      mon=wp9_monitor::type_id::create("mon",this);
    endfunction
    function void connect_phase(uvm_phase phase);
      drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  class wp9_env extends uvm_env;
    `uvm_component_utils(wp9_env)
    wp9_agent agent;
    wp9_coverage cov;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      agent=wp9_agent::type_id::create("agent",this);
      cov=wp9_coverage::type_id::create("cov",this);
    endfunction
    function void connect_phase(uvm_phase phase);
      agent.mon.ap.connect(cov.analysis_export);
    endfunction
  endclass

  class wp9_sequence extends uvm_sequence #(wp9_item);
    `uvm_object_utils(wp9_sequence)
    int only_wp=0;
    function new(string n="wp9_sequence");super.new(n);endfunction
    task body();
      wp9_item tr;
      for(int wp=1;wp<=9;wp++) begin
        if(only_wp!=0 && wp!=only_wp) continue;
        for(int op=0;op<16;op++) begin
          tr=wp9_item::type_id::create("tr");
          start_item(tr);
          if(!tr.randomize() with {wp_id==local::wp;op==local::op;})
            `uvm_fatal("RAND","Cannot randomize work-package transaction")
          finish_item(tr);
        end
      end
    endtask
  endclass

  class wp9_test extends uvm_test;
    `uvm_component_utils(wp9_test)
    wp9_env env;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      env=wp9_env::type_id::create("env",this);
    endfunction
    task run_phase(uvm_phase phase);
      wp9_sequence seq;
      int id;
      phase.raise_objection(this);
      seq=wp9_sequence::type_id::create("seq");
      if($value$plusargs("WP_ID=%d",id)) begin
        if(id<1 || id>9) `uvm_fatal("WP_ID","WP_ID must be 1..9")
        seq.only_wp=id;
      end
      seq.start(env.agent.sqr);
      repeat(3) @(posedge env.agent.mon.vif.clk);
      phase.drop_objection(this);
    endtask
  endclass
endpackage
