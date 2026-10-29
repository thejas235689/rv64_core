#!/usr/bin/env bash
# Static analysis for the RTL and the testbenches.
#
#   slang      a full SystemVerilog front end: elaboration plus semantic checks
#   verilator  --lint-only: width and style warnings
#
# Both are in oss-cad-suite. Exit is non-zero if slang reports anything, since
# it treats mixed timescales and multiple drivers as errors -- both of which are
# real hazards, not style opinions.
set -euo pipefail
cd "$(dirname "$0")/.."

RTL="rtl/rv64_pkg.sv rtl/rv64_num_pkg.sv rtl/rv64_alu.sv rtl/rv64_mdu.sv \
rtl/rv64_regfile.sv rtl/rv64_decoder.sv rtl/rv64_pmp.sv rtl/rv64_csr.sv \
rtl/rv64_mmu.sv rtl/rv64_l2arb.sv rtl/rv64_l2cache.sv rtl/rv64_amcce.sv rtl/rv64_dcache.sv rtl/rv64_lsu.sv rtl/rv64_bpu.sv rtl/rv64_predecode.sv rtl/rv64_bootrom.sv rtl/rv64_rvc_expand.sv rtl/rv64_sha256.sv rtl/rv64_hmac.sv rtl/rv64_bootauth_hmac.sv rtl/rv64_bootauth.sv rtl/rv64_icache.sv rtl/rv64_fetch.sv rtl/rv64_plic_lite.sv \
rtl/rv64_num_wide.sv rtl/rv64_numfile.sv rtl/rv64_num_unit.sv \
rtl/rv64_num_csr.sv rtl/rv64_xrv512_file.sv rtl/rv64_xrv512.sv rtl/rv64_vregfile.sv rtl/rv64_vunit.sv rtl/rv64_qisa.sv rtl/rv64_aiacc.sv rtl/rv64_xcetask.sv rtl/riscv_core_top.sv"

fail=0

echo "== slang: core =="
slang --top riscv_core_top $RTL || fail=1

echo "== slang: numeric vector testbench =="
slang --top tb_num_top $RTL tb/tb_num_top.sv || fail=1

echo "echo "== slang: platform blocks =="
slang --top rv64_clint rtl/rv64_clint.sv || fail=1
slang --top rv64_uart rtl/rv64_uart.sv || fail=1
slang --top rv64_dmi rtl/rv64_dmi.sv || fail=1

echo "== slang: atomic testbench ==
slang --top tb_atomic rtl/rv64_pkg.sv rtl/rv64_mmu.sv rtl/rv64_l2arb.sv rtl/rv64_l2cache.sv rtl/rv64_amcce.sv rtl/rv64_dcache.sv rtl/rv64_lsu.sv tb/tb_atomic.sv || fail=1

echo "== slang: QISA + accelerator testbench =="
slang --top tb_qisa_aiacc rtl/rv64_xrv512_file.sv rtl/rv64_xrv512.sv rtl/rv64_vregfile.sv rtl/rv64_vunit.sv rtl/rv64_qisa.sv rtl/rv64_aiacc.sv tb/tb_qisa_aiacc.sv || fail=1

echo "== slang: cocotb core testbench =="
slang --top tb_core_top $RTL tb/tb_core_top.sv || fail=1

echo "== verilator lint (RTL) =="
# -Wno-fatal: width warnings are reported and reviewed, not treated as failures
verilator --lint-only -Wno-fatal --timing --top-module riscv_core_top $RTL 2>&1 |
    grep -E "^%Warning|^%Error" | sort | uniq -c | sort -rn || true

if [ "$fail" -ne 0 ]; then
    echo "LINT: FAIL"
    exit 1
fi
echo "LINT: PASS (slang clean; verilator warnings listed above for review)"
