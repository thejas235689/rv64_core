#!/usr/bin/env bash
# Run the pyuvm environment under Icarus via cocotb.
set -e
export PATH=/scratch/work/ocs/oss-cad-suite/bin:$PATH
python3 -m cocotb_tools.runner "$@" 2>/dev/null || \
python3 - <<'PY'
import os
from cocotb_tools.runner import get_runner
os.environ.setdefault("TOPLEVEL", "tb_pyuvm")
runner = get_runner("icarus")
runner.build(verilog_sources=["../rv64_fp_add.sv", "tb_pyuvm.sv"],
             hdl_toplevel="tb_pyuvm", always=True)
runner.test(hdl_toplevel="tb_pyuvm", test_module="fp_pyuvm", always=True)
PY
