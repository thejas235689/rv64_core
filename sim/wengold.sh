#!/usr/bin/env bash
# WENGOLD over rv64_core: dependency graph, completeness, CDC, and singularity.
#
#   sim/wengold.sh            index + completeness + singularity + CDC
#   sim/wengold.sh sva        also emit SVA for the CLINT and the accelerator
#
# WENGOLD is the validity kernel at https://github.com/thejas235689/wengold.
# It answers "which of my previous verification results still hold after this
# change?", which is why the graph and the singularity report are the useful
# parts here: they say what a change to one RTL file can reach.
#
# pyslang is required for an accurate graph. Without it WENGOLD falls back to a
# bounded regex elaborator that misreads a function declaration as a module
# instantiation -- it reported `int` as an undefined block in rv64_num_wide
# until pyslang was installed. The script installs it if missing.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -c "import pyslang" 2>/dev/null || python3 -m pip install -q pyslang

echo "== index =="
python3 -m wengold.cli index . --backend slang --out /tmp/wengold-graph.json

echo "== completeness =="
python3 -m wengold.cli completeness .

echo "== singularity (which block voids the most evidence) =="
python3 -m wengold.cli singularity .

echo "== CDC: core top (single clock, expect no crossings) =="
python3 -m wengold.cli cdc rtl/riscv_core_top.sv

echo "== CDC: UART (asynchronous rx input) =="
python3 -m wengold.cli cdc rtl/rv64_uart.sv

if [ "${1:-}" = "sva" ]; then
    echo "== SVA for the CLINT: timer_irq implies timer_en =="
    python3 -m wengold.cli formal rtl/rv64_clint.sv \
        --property "!timer_irq || timer_en" --clock clk --reset rst_n --sva
    echo "== SVA for the accelerator: the product counter never decreases =="
    python3 -m wengold.cli formal rtl/rv64_aiacc.sv \
        --property "count >= 0" --clock clk --reset rst_n --sva
fi
