#!/usr/bin/env bash
# =============================================================================
# run_batches.sh -- run the cocotb suite in batches, and score it honestly.
#
# Why this exists
# ---------------
# Two separate problems, both of which made CI lie about the design.
#
# 1. A single `python3 sim/run.py` for the whole suite exceeds a CI step
#    timeout, so the step is killed. A killed step reports nothing at all, and
#    the job's failure then says "timeout" rather than naming a test. Batching
#    keeps every step inside its limit and names what failed.
#
# 2. Scoring on "did the log contain UVM_ERROR" scores an aborted elaboration
#    as PASS: the run dies before anything can report an error, so the error
#    count is zero and zero errors looks like success. Measured on this repo:
#
#        $ python3 sim/run.py --testcase test_no_such_test ; echo $?
#        0                       # no test ran at all, exit code 0, no summary
#
#    and a batch of 3 with one nonexistent name:
#
#        $ python3 sim/run.py --testcase test_alu --testcase test_muldiv \
#              --testcase test_hazard_bogus
#        ** TESTS=2 PASS=2 FAIL=0 SKIP=0 **      # requested 3, ran 2, exit 0
#
#    So a requested test that silently did not run is invisible unless you
#    reconcile what you asked for against what reported. This script does that
#    reconciliation. A batch is PASS only if: the process exited 0, no
#    simulator-level error appeared, a report summary was printed, results.xml
#    contains testcase entries, and every requested test has its own row saying
#    PASS.
#
# Two bugs this replaces, from the earlier version:
#   - it counted a batch's passes only when the whole batch was green, so a
#     batch of 8 with one failure reported 0 passes and hid 7 that passed.
#     Per-test rows are now attributed individually.
#   - it classified a batch that died with FileNotFoundError as SKIP. A missing
#     file is a broken run, not a skipped test: SKIP is now only what cocotb
#     itself reports as SKIP.
#
# Usage
#   bash ci/run_batches.sh                     # core suite, all tests
#   bash ci/run_batches.sh test_alu test_csr   # named tests only
#   SUITE=plic MODULE_FILE=tb/cocotb/test_plic.py bash ci/run_batches.sh
#
# Environment
#   PYTHON         interpreter to run sim/run.py with. Default /usr/local/bin/python3
#                  -- absolute on purpose. Under oss-cad-suite's PATH a bare
#                  `python3` resolves to the suite's bundled interpreter
#                  (tabbypy3) and cocotb logs "Unexpected sys.executable value".
#   SUITE          sim/run.py --suite. Default core
#   MODULE_FILE    file to read test names from. Default tb/cocotb/test_core.py
#   BATCH_SIZE     testcases per run.py invocation. Default 8
#   BATCH_TIMEOUT  seconds per batch. Default 900
#   LOGDIR         where batch logs and results.xml copies go. Default ci/logs
#   ALLOWED_SKIP_TESTS  space-separated test names whose external dependency is
#                  declared absent (e.g. the PSS tests need the `satya` solver).
#                  A test named here that fails is reported SKIP and the run ends
#                  "PASS WITH SKIPS", never a plain PASS. Default empty: nothing
#                  is excused unless someone writes the name down on purpose.
#
# Exit: 0 only if every requested test reported PASS.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

PYTHON="${PYTHON:-/usr/local/bin/python3}"
SUITE="${SUITE:-core}"
MODULE_FILE="${MODULE_FILE:-tb/cocotb/test_core.py}"
BATCH_SIZE="${BATCH_SIZE:-8}"
BATCH_TIMEOUT="${BATCH_TIMEOUT:-900}"
LOGDIR="${LOGDIR:-ci/logs}"
ALLOWED_SKIP_TESTS="${ALLOWED_SKIP_TESTS:-}"

is_allowed_skip() {
  local t="$1" a
  for a in $ALLOWED_SKIP_TESTS; do [ "$a" = "$t" ] && return 0; done
  return 1
}

mkdir -p "$LOGDIR"

if [ ! -x "$PYTHON" ]; then
  echo "FATAL: interpreter not executable: $PYTHON" >&2
  exit 2
fi

# ---------------------------------------------------------------- test discovery
if [ "$#" -gt 0 ]; then
  TESTS=("$@")
else
  if [ ! -f "$MODULE_FILE" ]; then
    echo "FATAL: no such module file: $MODULE_FILE" >&2
    exit 2
  fi
  mapfile -t TESTS < <(grep -oE '^async def (test_[a-z0-9_]+)' "$MODULE_FILE" \
                        | sed 's/async def //' | sort)
fi

if [ "${#TESTS[@]}" -eq 0 ]; then
  echo "FATAL: discovered no tests in $MODULE_FILE -- refusing to report a green suite" >&2
  exit 2
fi

# ---------------------------------------------------------------- error patterns
# Deliberately NOT a bare /ERROR/ match. Under oss-cad-suite's PATH, cocotb's
# embedded interpreter logs one ERROR line per run that is harmless:
#   ERROR pygpi: Unexpected sys.executable value (expected .../python3, got .../tabbypy3)
# because the suite's `vvp` wrapper forces PYTHONEXECUTABLE. Matching every
# "ERROR" would fail every run; matching only real failure signals does not.
#
# The Python-exception patterns are anchored to column 0 on purpose. A traceback
# the *runner* died on starts at the beginning of a line; a traceback that a test
# merely printed inside a cocotb log message is indented as a continuation. The
# PSS tests here print a satya traceback inside a WARNING and then pass -- an
# unanchored /Traceback/ marked the whole batch unsound and failed six tests that
# had passed.
SIMERR_RE='(:[0-9]+: (syntax )?error:|^Traceback \(most recent call last\):|^[A-Za-z]*Error:|^RuntimeError|Segmentation fault|core dumped|Killed|command not found|Simulation (error|aborted)|UVM_FATAL|UVM_ERROR[[:space:]]*:[[:space:]]*[1-9])'

total=0; pass=0; fail=0; skip=0
declare -a failed_names=()

echo "run_batches: suite=$SUITE module=$MODULE_FILE tests=${#TESTS[@]} batch=$BATCH_SIZE timeout=${BATCH_TIMEOUT}s"
echo "run_batches: interpreter=$PYTHON ($("$PYTHON" -V 2>&1))"
echo

batch_no=0
idx=0
while [ "$idx" -lt "${#TESTS[@]}" ]; do
  batch_no=$((batch_no + 1))
  batch=("${TESTS[@]:idx:BATCH_SIZE}")
  idx=$((idx + BATCH_SIZE))

  log="$LOGDIR/batch_$(printf '%02d' "$batch_no").log"
  argv=("sim/run.py" "--suite" "$SUITE")
  for t in "${batch[@]}"; do argv+=("--testcase" "$t"); done

  echo "--- batch $batch_no: ${#batch[@]} test(s): ${batch[*]}"
  timeout "$BATCH_TIMEOUT" "$PYTHON" "${argv[@]}" >"$log" 2>&1
  rc=$?

  # ---- batch-level verdict -------------------------------------------------
  reason=""
  if [ "$rc" -eq 124 ]; then
    reason="timeout after ${BATCH_TIMEOUT}s"
  elif [ "$rc" -ne 0 ]; then
    reason="exit $rc"
  fi

  simerr=$(grep -nE "$SIMERR_RE" "$log" | grep -v 'Unexpected sys.executable' | head -2)
  if [ -n "$simerr" ]; then
    reason="${reason:+$reason; }simulator-level error: $(printf '%s' "$simerr" | head -1 | cut -c1-160)"
  fi

  summary=$(grep -oE 'TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+' "$log" | tail -1)
  if [ -z "$summary" ]; then
    reason="${reason:+$reason; }no report summary (no TESTS= line: the run never reached its report phase)"
  fi

  # cocotb writes results.xml into the build dir. An aborted elaboration leaves
  # a file with no testcase entries, so count them rather than testing existence.
  xml=$(ls -t sim/sim_build_${SIM_ALIAS:-icarus}_${SUITE}/results.xml 2>/dev/null | head -1)
  if [ -n "$xml" ]; then
    cp "$xml" "$LOGDIR/results_batch_$(printf '%02d' "$batch_no").xml" 2>/dev/null
    n_tc=$(grep -o '<testcase' "$xml" 2>/dev/null | wc -l)
    if [ "${n_tc:-0}" -eq 0 ]; then
      reason="${reason:+$reason; }results.xml has no testcase entries"
    fi
  else
    reason="${reason:+$reason; }no results.xml produced"
  fi

  # ---- per-test attribution ------------------------------------------------
  # A batch with one failing test still attributes the other seven: that was
  # the bug that made a batch of 8 with one failure report 0 passes.
  declare -A row=()
  while read -r name status; do
    [ -z "${name:-}" ] && continue
    row["${name#*.}"]="$status"
  done < <(grep -oE '^[[:space:]]*\*\* [A-Za-z0-9_.]+ +(PASS|FAIL|SKIP) ' "$log" \
             | sed -E 's/^[[:space:]]*\*+ +//; s/ +$//; s/ +/ /g')

  for t in "${batch[@]}"; do
    total=$((total + 1))
    status="${row[$t]:-}"
    if [ -n "$reason" ] && [ -z "$status" ]; then
      # A broken batch cannot vouch for a test it never reported on.
      printf '  %-40s %-6s %s\n' "$t" "FAIL" "$reason"
      fail=$((fail + 1)); failed_names+=("$t")
    elif [ -z "$status" ]; then
      # Requested, never reported: cocotb filtered it out and still exited 0.
      printf '  %-40s %-6s %s\n' "$t" "FAIL" "requested but no result row -- the test did not run"
      fail=$((fail + 1)); failed_names+=("$t")
    elif [ "$status" = "PASS" ] && [ -n "$reason" ]; then
      # The row says PASS but the batch as a whole is unsound. Do not report a
      # pass we cannot stand behind; say which.
      printf '  %-40s %-6s %s\n' "$t" "FAIL" "row says PASS but batch unsound: $reason"
      fail=$((fail + 1)); failed_names+=("$t")
    else
      case "$status" in
        PASS) printf '  %-40s %-6s\n' "$t" "PASS"; pass=$((pass + 1)) ;;
        FAIL)
          if is_allowed_skip "$t"; then
            printf '  %-40s %-6s %s\n' "$t" "SKIP" "declared absent dependency (ALLOWED_SKIP_TESTS) -- proves nothing"
            skip=$((skip + 1))
          else
            printf '  %-40s %-6s\n' "$t" "FAIL"; fail=$((fail + 1)); failed_names+=("$t")
          fi ;;
        SKIP) printf '  %-40s %-6s %s\n' "$t" "SKIP" "cocotb reported SKIP"; skip=$((skip + 1)) ;;
        *)    printf '  %-40s %-6s\n' "$t" "FAIL"; fail=$((fail + 1)); failed_names+=("$t") ;;
      esac
    fi
  done
  unset row

  if [ -n "$summary" ]; then
    echo "  summary: $summary  (log: $log)"
  else
    echo "  summary: MISSING  (log: $log)"
  fi
  if [ -n "$reason" ]; then
    echo "  batch verdict: FAIL -- $reason"
    echo "  --- last 25 lines of $log ---"
    tail -25 "$log" | sed 's/^/  | /'
  fi
  echo
done

# ---------------------------------------------------------------- final report
echo "==============================================================="
echo "suite: $pass passed, $fail failed, $skip skipped, $total total"
if [ "$fail" -ne 0 ]; then
  echo "failed: ${failed_names[*]}"
  echo "RESULT: FAIL"
  exit 1
fi
if [ "$skip" -ne 0 ]; then
  # Not a failure, but not a pass either: a skipped test proves nothing.
  echo "RESULT: PASS WITH SKIPS (${skip} test(s) proved nothing)"
  exit 0
fi
echo "RESULT: PASS"
