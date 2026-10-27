#!/usr/bin/env bash
# =============================================================================
# synth.sh -- generic synthesis and structural checks for riscv_core_top.
#
#   bash sim/synth.sh
#
# Flow: sv2v (SystemVerilog -> Verilog-2005) then Yosys (generic mapping).
#
# sv2v is needed because Yosys's own SystemVerilog frontend cannot parse a
# function returning a packed struct, which rv64_pkg.sv uses. Converting keeps
# the RTL untouched; the simulator regressions read the original sources.
#
# Outputs: build/core_synth.v, build/synth_stat.rpt, build/synth_path.rpt
#
# What this does NOT do: no timing library, no clock constraint, no wire delay.
# It reports cell counts, flip-flop counts and the longest combinational path in
# logic levels. That is a structural sanity check, not a timing sign-off.
#
# Tools (both are single binaries; YoWASP builds work without root):
#   pip install yowasp-yosys
#   sv2v from https://github.com/zachjs/sv2v/releases
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SV2V="${SV2V:-sv2v}"
YOSYS="${YOSYS:-yosys}"

for t in "$SV2V" "$YOSYS"; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "error: $t not found. Set SV2V=/path/to/sv2v and YOSYS=/path/to/yosys" >&2
    exit 1
  fi
done

mkdir -p build

RTL_ORDER="rtl/rv64_pkg.sv rtl/rv64_alu.sv rtl/rv64_mdu.sv rtl/rv64_regfile.sv \
rtl/rv64_decoder.sv rtl/rv64_pmp.sv rtl/rv64_csr.sv rtl/rv64_mmu.sv rtl/rv64_lsu.sv \
rtl/rv64_bpu.sv rtl/rv64_predecode.sv rtl/rv64_icache.sv rtl/rv64_fetch.sv rtl/rv64_plic_lite.sv \
rtl/rv64_num_pkg.sv rtl/rv64_num_wide.sv rtl/rv64_numfile.sv rtl/rv64_num_unit.sv rtl/rv64_num_csr.sv \
rtl/riscv_core_top.sv"

echo "== sv2v: SystemVerilog -> Verilog-2005 =="
"$SV2V" $RTL_ORDER > build/core_synth.v || { echo "sv2v failed" >&2; exit 1; }
echo "   build/core_synth.v: $(wc -l < build/core_synth.v) lines"

# YoWASP builds need a large address space in constrained containers
ulimit -v unlimited 2>/dev/null || true

echo "== yosys: generic synthesis =="
"$YOSYS" -q -s sim/synth.ys || { echo "yosys failed" >&2; exit 1; }

echo
echo "== results =="
sed -n '/Printing statistics/,$p' build/synth_stat.rpt | grep -E '^\s+[0-9]+\s+\$_|^\s+[0-9]+\s+wires|^\s+[0-9]+\s+wire bits' | sed 's/^/   /'
echo
echo "   longest combinational path: $(grep -cE '^ +[0-9]+:' build/synth_path.rpt) logic levels"
grep -E '^ *ff:' build/synth_path.rpt | sed 's/^/   endpoint: /'
echo
echo "   reports: build/synth_stat.rpt build/synth_path.rpt"
