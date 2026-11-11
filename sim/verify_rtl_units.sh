#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

build_dir=$(mktemp -d)
trap 'rm -rf -- "$build_dir"' EXIT

run_unit() {
    local testbench=$1 success_message=$2
    shift 2
    "${IVERILOG:-iverilog}" -g2012 -s "$testbench" -o "$build_dir/unit.vvp" \
        "$@" "tb/$testbench.sv"
    "${VVP:-vvp}" "$build_dir/unit.vvp" | tee "$build_dir/unit.log"
    grep -Fq "$success_message" "$build_dir/unit.log"
}

run_unit tb_bpu_indirect 'PASS: indirect target' rtl/rv64_bpu.sv
run_unit tb_icache_hit_under_miss 'I-cache tagged hit-under-miss checks passed' rtl/rv64_icache.sv
run_unit tb_icache_stride 'I-cache stride prefetch checks passed' rtl/rv64_icache.sv
run_unit tb_fetch_cache 'RESULT: PASS' rtl/rv64_rvc_expand.sv rtl/rv64_predecode.sv \
    rtl/rv64_fetch.sv rtl/rv64_icache.sv
