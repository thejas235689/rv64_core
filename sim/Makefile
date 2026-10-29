SIM ?= icarus
TOPLEVEL_LANG = verilog

SIM_BUILD = sim_build

ROOT      := $(abspath $(CURDIR)/..)
RTL_DIR   := $(ROOT)/rtl
TB_DIR    := $(ROOT)/tb

RTL_SRCS := \
  $(RTL_DIR)/rv64_pkg.sv \
  $(RTL_DIR)/rv64_alu.sv \
  $(RTL_DIR)/rv64_mdu.sv \
  $(RTL_DIR)/rv64_regfile.sv \
  $(RTL_DIR)/rv64_decoder.sv \
  $(RTL_DIR)/rv64_pmp.sv \
  $(RTL_DIR)/rv64_csr.sv \
  $(RTL_DIR)/rv64_mmu.sv \
  $(RTL_DIR)/rv64_l2arb.sv \
  $(RTL_DIR)/rv64_l2cache.sv \
  $(RTL_DIR)/rv64_amcce.sv \
  $(RTL_DIR)/rv64_dcache.sv \
  $(RTL_DIR)/rv64_lsu.sv \
  $(RTL_DIR)/rv64_bpu.sv \
  $(RTL_DIR)/rv64_predecode.sv \
  $(RTL_DIR)/rv64_bootrom.sv \
  $(RTL_DIR)/rv64_sha256.sv \
  $(RTL_DIR)/rv64_hmac.sv \
  $(RTL_DIR)/rv64_bootauth_hmac.sv \
  $(RTL_DIR)/rv64_bootauth.sv \
  $(RTL_DIR)/rv64_icache.sv \
  $(RTL_DIR)/rv64_fetch.sv \
  $(RTL_DIR)/rv64_plic_lite.sv \
  $(RTL_DIR)/rv64_num_pkg.sv \
  $(RTL_DIR)/rv64_num_wide.sv \
  $(RTL_DIR)/rv64_numfile.sv \
  $(RTL_DIR)/rv64_num_unit.sv \
  $(RTL_DIR)/rv64_num_csr.sv \
  $(RTL_DIR)/riscv_core_top.sv

VERILOG_SOURCES := $(RTL_SRCS) $(TB_DIR)/tb_core_top.sv

COMPILE_ARGS += -g2012
TOPLEVEL := tb_core_top
MODULE   := test_core

export PYTHONPATH := $(TB_DIR)/cocotb:$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: lint verilator-lint xezim-elab clean-all

lint:
	iverilog -g2012 -Wall -o /dev/null -s riscv_core_top $(RTL_SRCS)

verilator-lint:
	verilator --lint-only -Wall -Wno-fatal --timing -sv $(RTL_SRCS) --top-module riscv_core_top

# xezim needs the address-space rlimit lifted in constrained containers
xezim-elab:
	ulimit -v unlimited; xezim --compile -s riscv_core_top $(RTL_SRCS)

clean-all: clean
	rm -rf sim_build results.xml __pycache__
