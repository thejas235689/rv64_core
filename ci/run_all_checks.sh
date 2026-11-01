#!/usr/bin/env bash
# Every check that has actually caught a bug in this project.
#
#   ci/run_all_checks.sh            all sections
#   ci/run_all_checks.sh static     CSR map only
#   ci/run_all_checks.sh sweeps     width sweeps only
#   ci/run_all_checks.sh cocotb     the 43-test suite only
#
# Sections exist because the whole thing exceeds a 295s command window.
set -u
cd "$(dirname "$0")/.."
OCS=${OCS:-/scratch/work/ocs/oss-cad-suite/bin}
export PATH="$OCS:$PATH"
# NOT bare python3: with OCS on PATH it resolves to their bundled interpreter and
# cocotb dies with "Unexpected sys.executable value".
PY=${PY:-/usr/local/bin/python3}

SECTION=${1:-all}
pass=0; fail=0; failed=""

step() { printf '%-24s' "$1"; }
want() { [ "$SECTION" = "all" ] || [ "$SECTION" = "$1" ]; }

# ---- static: CSR map ---------------------------------------------------------
if want static; then
  step "csr map"
  if "$PY" ci/check_csr_map.py > /tmp/csrmap.txt 2>&1; then
    pass=$((pass+1)); echo "PASS  $(tail -1 /tmp/csrmap.txt)"
  else
    fail=$((fail+1)); failed="$failed csr-map"; echo "FAIL"; cat /tmp/csrmap.txt
  fi
fi

# ---- sweeps ------------------------------------------------------------------
if want sweeps; then
  for s in sweep_montmul sweep_modexp; do
    step "$s"
    if "./ci/$s.sh" > "/tmp/$s.txt" 2>&1; then
      pass=$((pass+1)); echo "PASS  $(tail -1 "/tmp/$s.txt")"
    else
      fail=$((fail+1)); failed="$failed $s"; echo "FAIL"; tail -4 "/tmp/$s.txt"
    fi
  done
fi

# ---- cocotb, in batches of ten -----------------------------------------------
if want cocotb; then
  if ! "$PY" -c "import cocotb" 2>/dev/null; then
    step "cocotb"; echo "SKIP  cocotb not installed"
  else
    TESTS=$("$PY" - <<'PY'
import re, pathlib
src = pathlib.Path("tb/cocotb/test_core.py").read_text()
print(" ".join(re.findall(r"^async def (test_[a-z0-9_]+)", src, re.M)))
PY
)
    batch=""; n=0
    run_batch() {
      local ok=1 b r
      for b in $batch; do
        r=$(timeout 100 "$PY" sim/run.py --testcase "$b" 2>&1 | grep -oE "PASS=[0-9]" | tail -1)
        [ "$r" = "PASS=1" ] || { ok=0; failed="$failed $b"; }
      done
      step "cocotb batch"
      if [ "$ok" = "1" ]; then pass=$((pass+1)); echo "PASS  $n tests"
      else fail=$((fail+1)); echo "FAIL"; fi
    }
    for t in $TESTS; do
      batch="$batch $t"; n=$((n+1))
      if [ "$n" -eq 10 ]; then run_batch; batch=""; n=0; fi
    done
    [ -n "$batch" ] && run_batch
  fi
fi

echo
echo "checks: $pass passed, $fail failed${failed:+ (failed:$failed)}"
[ "$fail" -eq 0 ]
