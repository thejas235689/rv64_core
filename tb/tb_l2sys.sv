`timescale 1ns/1ps
// =============================================================================
// tb_l2sys.sv -- the L2 arbiter in the topology it was written for.
//
// rv64_l2arb was orphaned: it exists to merge the I-cache fill stream and the
// D-cache bus port onto one memory port, but riscv_core_top never instantiates it
// because the two caches have separate memory ports there (if_req_* goes straight
// to the fetch bus / boot ROM, d_req_* goes through u_l2 and u_l3). This harness
// puts the two real caches behind the arbiter and one memory in front of it, so
// the arbiter is exercised with real cache traffic and with both ports live at
// once -- without changing riscv_core_top's port list, which would touch six
// testbenches, the UVM environment and the Rust BFM.
//
// The memory is modelled in cocotb (m_req_* / m_rsp_*), so a test can stall the
// bus and choose when responses land.
// =============================================================================
`default_nettype none

module tb_l2sys (
  input  logic        clk,
  input  logic        rst_n,

  // ---- instruction side: the I-cache's core-facing port (driven by cocotb) ---
  input  logic        ic_req_valid,
  input  logic [63:0] ic_req_addr,
  output logic        ic_req_ready,
  output logic        ic_resp_valid,
  output logic [63:0] ic_resp_data,
  output logic        ic_resp_miss,
  output logic        ic_resp_error,
  output logic [31:0] ic_hits,
  output logic [31:0] ic_misses,

  // ---- data side: the D-cache's core-facing port (driven by cocotb) ---------
  input  logic        dc_req_valid,
  input  logic [63:0] dc_req_addr,
  input  logic        dc_req_we,
  input  logic [7:0]  dc_req_wstrb,
  input  logic [63:0] dc_req_wdata,
  output logic        dc_req_ready,
  output logic        dc_rsp_valid,
  output logic [63:0] dc_rsp_rdata,
  output logic        dc_rsp_error,
  output logic [31:0] dc_hits,
  output logic [31:0] dc_misses,

  // ---- the shared memory port behind the arbiter ----------------------------
  output logic        m_req_valid,
  output logic [63:0] m_req_addr,
  output logic        m_req_we,
  output logic [7:0]  m_req_wstrb,
  output logic [63:0] m_req_wdata,
  input  logic        m_req_ready,
  input  logic        m_rsp_valid,
  input  logic [63:0] m_rsp_rdata,
  input  logic        m_rsp_error,

  // ---- arbiter observability -----------------------------------------------
  output logic        grant_a,
  output logic        busy,
  output logic [31:0] grant_a_count,
  output logic [31:0] grant_b_count
);
  // I-cache fill side -> arbiter port A
  logic        a_fill_valid, a_fill_ready, a_fill_rsp_valid, a_fill_rsp_error;
  logic [63:0] a_fill_addr, a_fill_rsp_data;

  // D-cache bus side -> arbiter port B
  logic        b_req_valid, b_req_ready, b_rsp_valid, b_rsp_error;
  logic [63:0] b_req_addr, b_req_wdata, b_rsp_rdata;
  logic [7:0]  b_req_wstrb;
  logic        b_req_we;

  logic        dc_mgmt_done, dc_acc_hit, dc_acc_miss;

  // ---- the instruction cache ------------------------------------------------
  rv64_icache u_icache (
    .clk            (clk),
    .rst_n          (rst_n),
    .req_valid      (ic_req_valid),
    .req_addr       (ic_req_addr),
    .req_ready      (ic_req_ready),
    .resp_valid     (ic_resp_valid),
    .resp_data      (ic_resp_data),
    .resp_miss      (ic_resp_miss),
    .resp_error     (ic_resp_error),
    .fill_valid     (a_fill_valid),
    .fill_addr      (a_fill_addr),
    .fill_ready     (a_fill_ready),
    .fill_rsp_valid (a_fill_rsp_valid),
    .fill_rsp_data  (a_fill_rsp_data),
    .fill_rsp_error (a_fill_rsp_error),
    // the port that was once unconnected in riscv_core_top; tied off here for the
    // same reason it is tied off there (no fence.i commit signal exists yet)
    .invalidate     (1'b0),
    .hit_count      (ic_hits),
    .miss_count     (ic_misses)
  );

  // ---- the data cache -------------------------------------------------------
  rv64_dcache u_dcache (
    .clk            (clk),
    .rst_n          (rst_n),
    .req_valid      (dc_req_valid),
    .req_addr       (dc_req_addr),
    .req_we         (dc_req_we),
    .req_wstrb      (dc_req_wstrb),
    .req_wdata      (dc_req_wdata),
    .req_ready      (dc_req_ready),
    .rsp_valid      (dc_rsp_valid),
    .rsp_rdata      (dc_rsp_rdata),
    .rsp_error      (dc_rsp_error),
    .bus_req_valid  (b_req_valid),
    .bus_req_addr   (b_req_addr),
    .bus_req_we     (b_req_we),
    .bus_req_wstrb  (b_req_wstrb),
    .bus_req_wdata  (b_req_wdata),
    .bus_req_ready  (b_req_ready),
    .bus_rsp_valid  (b_rsp_valid),
    .bus_rsp_rdata  (b_rsp_rdata),
    .bus_rsp_error  (b_rsp_error),
    .mgmt_valid     (1'b0),
    .mgmt_zero      (1'b0),
    .mgmt_addr      (64'd0),
    .mgmt_done      (dc_mgmt_done),
    .bypass         (1'b0),
    .acc_hit        (dc_acc_hit),
    .acc_miss       (dc_acc_miss),
    .hit_count      (dc_hits),
    .miss_count     (dc_misses)
  );

  // ---- the arbiter under test ----------------------------------------------
  rv64_l2arb u_arb (
    .clk           (clk),
    .rst_n         (rst_n),

    .a_req_valid   (a_fill_valid),
    .a_req_addr    (a_fill_addr),
    .a_req_we      (1'b0),
    .a_req_wstrb   (8'd0),
    .a_req_wdata   (64'd0),
    .a_rsp_valid   (a_fill_rsp_valid),
    .a_rsp_rdata   (a_fill_rsp_data),
    .a_rsp_error   (a_fill_rsp_error),
    .a_req_ready   (a_fill_ready),

    .b_req_valid   (b_req_valid),
    .b_req_addr    (b_req_addr),
    .b_req_we      (b_req_we),
    .b_req_wstrb   (b_req_wstrb),
    .b_req_wdata   (b_req_wdata),
    .b_rsp_valid   (b_rsp_valid),
    .b_rsp_rdata   (b_rsp_rdata),
    .b_rsp_error   (b_rsp_error),
    .b_req_ready   (b_req_ready),

    .req_valid     (m_req_valid),
    .req_addr      (m_req_addr),
    .req_we        (m_req_we),
    .req_wstrb     (m_req_wstrb),
    .req_wdata     (m_req_wdata),
    .l2_req_ready  (m_req_ready),
    .rsp_valid     (m_rsp_valid),
    .rsp_rdata     (m_rsp_rdata),
    .rsp_error     (m_rsp_error),

    .grant_a       (grant_a),
    .busy          (busy),
    .grant_a_count (grant_a_count),
    .grant_b_count (grant_b_count)
  );

endmodule
`default_nettype wire
