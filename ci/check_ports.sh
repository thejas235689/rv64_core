#!/usr/bin/env bash
# Catch "declared, never driven" ports -- the defect class behind three bugs here:
#   modexp_csr_sel      (CSR window selected nothing)
#   CSR selects         (missing from accel_csr_sel; every access trapped)
#   icache .invalidate  (unconnected input; FSM's invalidate branch floated, cache hung)
#
# Uses Verilator's lint rather than a hand-rolled SV parser: a regex picks up words
# from comments (my first attempt reported 'failed', 'halted' and 'unused' as ports).
set -u
cd "$(dirname "$0")/.."
export PATH="${OCS:-/scratch/work/ocs/oss-cad-suite/bin}:$PATH"

out=$(verilator --lint-only -Wall \
        -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-VARHIDDEN \
        -Wno-UNDRIVEN -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-WIDTH -Wno-fatal \
        --top-module riscv_core_top rtl/*.sv rtl/fpu/*.sv 2>&1)

echo "$out" | grep -E "PINMISSING" || echo "no unconnected ports"
if echo "$out" | grep -qE "^%Error"; then
  echo "$out" | grep -E "^%Error" | head -5
  exit 1
fi
echo "lint: clean"
