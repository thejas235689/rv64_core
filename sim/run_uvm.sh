#!/usr/bin/env bash
# =============================================================================
# run_uvm.sh -- generate golden vectors and run the UVM regression under xezim.
#
#   ./sim/run_uvm.sh                      # all tests
#   ./sim/run_uvm.sh rv64_alu_test        # one test
#
# xezim is an open-source SystemVerilog simulator with a bundled UVM library.
# Set XEZIM to the binary path if it is not on PATH, and UVM_HOME to the UVM
# source directory if it is not under the xezim install.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XEZIM="${XEZIM:-xezim}"
UVM="${UVM_HOME:-$(dirname "$(dirname "$(command -v "$XEZIM" 2>/dev/null || echo /nonexistent)")")/share/uvm/src}"

if ! command -v "$XEZIM" >/dev/null 2>&1; then
  echo "error: xezim not found. Set XEZIM=/path/to/xezim" >&2
  exit 1
fi
if [ ! -f "$UVM/uvm_pkg.sv" ]; then
  echo "error: UVM sources not found at $UVM. Set UVM_HOME=/path/to/uvm/src" >&2
  exit 1
fi

cd "$ROOT"

echo "== generating golden vectors =="
python3 sim/gen_uvm_vectors.py || exit 1
python3 sim/gen_isa_sweep.py || exit 1

# xezim needs a large address space in constrained containers
ulimit -v unlimited 2>/dev/null || true

TESTS=("$@")
if [ ${#TESTS[@]} -eq 0 ]; then
  TESTS=(rv64_alu_test rv64_mem_test rv64_trap_test rv64_random_test rv64_backpressure_test rv64_isa_small_test rv64_illegal_test rv64_numeric_test rv64_bitmanip_test rv64_csr_test rv64_pmp_test rv64_atomic_test rv64_zifencei_test rv64_memwidth_test rv64_cache_test rv64_frontend_test rv64_sv39_test rv64_debug_test rv64_rvv_test rv64_xcetask_test rv64_amcce_test rv64_accel_test)
fi

RTL="rtl/rv64_pkg.sv rtl/rv64_alu.sv rtl/rv64_mdu.sv rtl/rv64_regfile.sv \
rtl/rv64_decoder.sv rtl/rv64_pmp.sv rtl/rv64_csr.sv rtl/rv64_mmu.sv rtl/rv64_l2arb.sv rtl/rv64_l2cache.sv rtl/rv64_amcce.sv rtl/rv64_dcache.sv rtl/rv64_lsu.sv \
rtl/rv64_bpu.sv rtl/rv64_predecode.sv rtl/rv64_bootrom.sv rtl/rv64_rvc_expand.sv rtl/rv64_fp_add.sv rtl/rv64_fregfile.sv rtl/rv64_sha256.sv rtl/rv64_hmac.sv rtl/rv64_bootauth_hmac.sv rtl/rv64_icache.sv rtl/rv64_fetch.sv rtl/rv64_plic_lite.sv \
rtl/rv64_num_pkg.sv rtl/rv64_num_wide.sv rtl/rv64_numfile.sv rtl/rv64_num_unit.sv rtl/rv64_num_csr.sv \
rtl/riscv_core_top.sv"

FAIL=0
for T in "${TESTS[@]}"; do
  echo
  echo "== $T =="
  OUT=$("$XEZIM" -s tb_uvm_top \
      -I "$UVM" -I "$ROOT/tb/uvm" \
      -D UVM_NO_DPI -D UVM_REPORT_DISABLE_FILE_LINE \
      "$UVM/uvm_pkg.sv" $RTL \
      tb/uvm/rv64_uvm_if.sv tb/uvm/rv64_uvm_pkg.sv tb/tb_uvm_top.sv \
      +UVM_TESTNAME="$T" 2>&1)
  echo "$OUT" | grep -E "UVM_(ERROR|FATAL|INFO).*(\[SB\]|\[TEST\]|\[COV\]|\[MEMDRV\])" | tail -8
  if echo "$OUT" | grep -qE "UVM_ERROR :|UVM_FATAL :"; then
    NERR=$(echo "$OUT" | grep -E "UVM_ERROR :" | tail -1 | awk '{print $NF}')
    NFAT=$(echo "$OUT" | grep -E "UVM_FATAL :" | tail -1 | awk '{print $NF}')
    if [ "${NERR:-0}" != "0" ] || [ "${NFAT:-0}" != "0" ]; then
      echo "  RESULT: FAIL (errors=${NERR:-0} fatals=${NFAT:-0})"
      FAIL=$((FAIL+1))
      continue
    fi
  fi
  echo "  RESULT: PASS"
done

echo
if [ $FAIL -eq 0 ]; then
  echo "UVM regression: PASS (${#TESTS[@]} tests)"
else
  echo "UVM regression: FAIL ($FAIL of ${#TESTS[@]} tests)"
  exit 1
fi
