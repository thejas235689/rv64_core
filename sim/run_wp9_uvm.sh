#!/usr/bin/env bash
# Standalone UVM FIXTURE (not real RV64 hardware verification).
# Example: bash sim/run_wp9_uvm.sh 8
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XEZIM="${XEZIM:-xezim}"
UVM="${UVM_HOME:-$(dirname "$(dirname "$(command -v "$XEZIM" 2>/dev/null || echo /nonexistent)")")/share/uvm/src}"
if ! command -v "$XEZIM" >/dev/null 2>&1; then
  echo "Missing xezim; set XEZIM" >&2; exit 2
fi
if [[ ! -f "$UVM/uvm_pkg.sv" ]]; then
  echo "Missing UVM sources; set UVM_HOME to path ending in /src" >&2; exit 2
fi
cd "$ROOT"
extra=()
if [[ $# -gt 0 ]]; then
  if [[ ! "$1" =~ ^[1-9]$ ]]; then echo "WP_ID must be 1..9" >&2; exit 2; fi
  extra+=("+WP_ID=$1")
fi
"$XEZIM" -s wp9_top -I "$UVM" -I "$ROOT/tb/wp9" \
  -D UVM_NO_DPI -D UVM_REPORT_DISABLE_FILE_LINE \
  "$UVM/uvm_pkg.sv" tb/wp9/wp9_if.sv tb/wp9/wp9_pkg.sv tb/wp9/wp9_top.sv \
  "${extra[@]}" +UVM_TESTNAME=wp9_test
