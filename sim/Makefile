SIM ?= icarus
TOPLEVEL_LANG = verilog

SIM_BUILD = sim_build

ROOT      := $(abspath $(CURDIR)/..)
RTL_DIR   := $(ROOT)/rtl
TB_DIR    := $(ROOT)/tb

RTL_SRCS := $(addprefix $(RTL_DIR)/,$(shell cat $(ROOT)/sim/rtl_sources.f))

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
