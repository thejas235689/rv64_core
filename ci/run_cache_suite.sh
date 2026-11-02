#!/usr/bin/env bash
# =============================================================================
# run_cache_suite.sh -- the cache subsystem and the L2 arbiter, end to end.
#
# Four levels, because they reach different things:
#   core    the D-cache driven by real programs through riscv_core_top
#   dcache  rv64_dcache alone, with the bus modelled in Python (backpressure,
#           response timing, a second request during a fill, a cbo during a fill)
#   l2arb   rv64_l2arb alone: grant policy, held grant, response routing
#   l2sys   rv64_icache + rv64_dcache + rv64_l2arb + one memory (tb_l2sys.sv):
#           the only place two fills can be outstanding at once
# plus tb/tb_l2arb.sv, the pre-existing standalone Verilog testbench for the
# arbiter, which no regression list had ever run.
#
#   ./ci/run_cache_suite.sh          # everything
#   ./ci/run_cache_suite.sh l2arb    # one level
#
# A level passes only if its run reports FAIL=0 AND the expected number of tests
# actually ran, so a filtered-out test cannot look like a pass.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
OCS=${OCS:-/scratch/work/ocs/oss-cad-suite/bin}
export PATH="$OCS:$PATH"
PY=${PY:-/usr/local/bin/python3}
LEVEL=${1:-all}

CORE_TESTS="test_cache_1_back_to_back_miss_same_line test_cache_2_miss_eviction_index_conflict \
test_cache_3_invalidation_drops_the_line test_cache_4_store_then_load_across_miss \
test_cache_5_refill_ordering_two_misses"
DCACHE_TESTS="test_dcache_unit_back_to_back_same_line test_dcache_unit_no_second_request_during_fill \
test_dcache_unit_invalidate_during_fill test_dcache_unit_refill_ordering \
test_dcache_unit_store_then_load_across_miss"
L2ARB_TESTS="test_l2arb_lone_request_routing test_l2arb_one_ready_under_contention \
test_l2arb_grant_held_until_response test_l2arb_round_robin_fairness \
test_l2arb_write_fire_and_forget test_l2arb_no_duplicate_issue"
L2SYS_TESTS="test_l2sys_concurrent_misses test_l2sys_interleaved_traffic \
test_l2sys_store_during_icache_fill"

pass=0; fail=0; failed=""

# run_level <label> <suite> <expected-count> <tests...>
run_level() {
  local label="$1" suite="$2" want="$3"; shift 3
  local args=""
  for t in "$@"; do args="$args --testcase $t"; done
  local out rc
  out=$(timeout 280 "$PY" sim/run.py --suite "$suite" $args 2>&1); rc=$?
  local got
  got=$(printf '%s' "$out" | grep -oE "TESTS=$want PASS=$want FAIL=0" | head -1)
  if [ -n "$got" ]; then
    printf '%-10s PASS  %s\n' "$label" "$got"
    pass=$((pass+1))
  else
    printf '%-10s FAIL  (rc=$rc)\n' "$label"
    printf '%s' "$out" | grep -E "TESTS=|AssertionError|MISMATCH" | tail -3
    fail=$((fail+1)); failed="$failed $label"
  fi
}

want_all() { [ "$LEVEL" = "all" ] || [ "$LEVEL" = "$1" ]; }

if want_all core;   then run_level core   core  5 $CORE_TESTS;   fi
if want_all dcache; then run_level dcache dcache 5 $DCACHE_TESTS; fi
if want_all l2arb;  then run_level l2arb  l2arb  6 $L2ARB_TESTS;  fi
if want_all l2sys;  then run_level l2sys  l2sys  3 $L2SYS_TESTS;  fi

# ---- the pre-existing standalone arbiter testbench ---------------------------
if want_all standalone; then
  out=$(iverilog -g2012 -o sim/tb_l2arb.vvp rtl/rv64_l2arb.sv tb/tb_l2arb.sv 2>&1 && \
        vvp sim/tb_l2arb.vvp 2>&1)
  if printf '%s' "$out" | grep -q "RESULT: PASS"; then
    printf '%-10s PASS  %s\n' "tb_l2arb" "$(printf '%s' "$out" | grep -E '^tb_l2arb:' | head -1)"
    pass=$((pass+1))
  else
    printf '%-10s FAIL\n' "tb_l2arb"
    printf '%s' "$out" | tail -5
    fail=$((fail+1)); failed="$failed tb_l2arb"
  fi
fi

echo
echo "cache suite: $pass passed, $fail failed${failed:+ (failed:$failed)}"
[ "$fail" -eq 0 ]
