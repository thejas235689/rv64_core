#!/usr/bin/env bash
# =============================================================================
# run_full_suite.sh -- the whole cocotb suite in one command.
#
# The project had 40+ tests and no single way to run them, so regressions were
# found one test at a time, usually after a change had already been published.
# This runs every @cocotb.test in tb/cocotb/test_core.py with a per-test timeout
# and prints a summary.
#
#   ./ci/run_full_suite.sh              # everything
#   ./ci/run_full_suite.sh test_alu ...  # named tests only
#   PER_TEST_TIMEOUT=180 ./ci/run_full_suite.sh
#
# Requires: cocotb, Icarus (PATH), and for the PSS tests SATYA pointing at the
# satya binary. Tests whose dependency is missing are reported SKIP, not FAIL,
# because a missing tool is not a passing test either.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
PER_TEST_TIMEOUT="${PER_TEST_TIMEOUT:-120}"
export PATH="${OCS_BIN:-/scratch/work/ocs/oss-cad-suite/bin}:$PATH"
export SATYA="${SATYA:-/scratch/work/satyabin/satya-v0.41.0-x86_64-linux/satya}"

if [ "$#" -gt 0 ]; then
  TESTS=("$@")
else
  mapfile -t TESTS < <(grep -oE "async def (test_[a-z0-9_]+)" tb/cocotb/test_core.py \
                        | sed 's/async def //' | sort)
fi

pass=0; fail=0; skip=0
failed=()
printf '%-28s %s\n' "TEST" "RESULT"
for t in "${TESTS[@]}"; do
  out=$(timeout "$PER_TEST_TIMEOUT" python3 sim/run.py --testcase "$t" 2>&1)
  if printf '%s' "$out" | grep -qE "TESTS=1 PASS=1"; then
    printf '%-28s PASS\n' "$t"; pass=$((pass+1))
  elif printf '%s' "$out" | grep -qiE "skipping|unavailable|No such file"; then
    printf '%-28s SKIP\n' "$t"; skip=$((skip+1))
  else
    printf '%-28s FAIL\n' "$t"; fail=$((fail+1)); failed+=("$t")
  fi
done

echo
echo "suite: $pass passed, $fail failed, $skip skipped, ${#TESTS[@]} total"
if [ "$fail" -ne 0 ]; then
  echo "failed: ${failed[*]}"
  exit 1
fi
