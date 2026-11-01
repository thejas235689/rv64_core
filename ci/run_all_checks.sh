#!/usr/bin/env bash
# Every check that has actually caught a bug in this project. Run before publishing.
#
#   ci/check_csr_map.py    three CSR collisions, none visible to a per-block test
#   ci/sweep_montmul.sh    a width bug that one passing width hid
#   ci/sweep_modexp.sh     a width bug that one passing width hid
#   cocotb suite           the CSR collision, the harness X, the NameError
#
# The cocotb suite runs in batches: a single loop over all 43 exceeds a 295s window.
set -u
cd "$(dirname "$0")/.."
OCS=${OCS:-/scratch/work/ocs/oss-cad-suite/bin}
export PATH="$OCS:$PATH"
PY=${PY:-/usr/local/bin/python3}   # NOT bare python3 -- with OCS on PATH it resolves
                                   # to their bundled interpreter and cocotb dies
pass=0; fail=0; failed=""

step() { printf '%-28s' "$1"; }

# ---- 1. CSR map --------------------------------------------------------------
step "csr map"
if "$PY" ci/check_csr_map.py > /tmp/csrmap.txt 2>&1; then
  pass=$((pass+1)); echo "PASS  $(tail -1 /tmp/csrmap.txt)"
else
  fail=$((fail+1)); failed="$failed csr-map"; echo "FAIL"; cat /tmp/csrmap.txt
fi

# ---- 2. width sweeps ---------------------------------------------------------
for s in sweep_montmul sweep_modexp; do
  step "$s"
  if "./ci/$s.sh" > /tmp/$s.txt 2>&1; then
    pass=$((pass+1)); echo "PASS  $(tail -1 /tmp/$s.txt)"
  else
    fail=$((fail+1)); failed="$failed $s"; echo "FAIL"; tail -5 /tmp/$s.txt
  fi
done

# ---- 3. cocotb, in batches of ten --------------------------------------------
if ! "$PY" -c "import cocotb" 2>/dev/null; then
  step "cocotb"; echo "SKIP  cocotb not installed"; 
else
TESTS=$("$PY" - <<'PY'
import re, pathlib
src = pathlib.Path("tb/cocotb/test_core.py").read_text()
print(" ".join(re.findall(r"^async def (test_[a-z0-9_]+)", src, re.M)))
PY
)
batch=""; n=0
for t in $TESTS; do
  batch="$batch $t"; n=$((n+1))
  if [ "$n" -eq 10 ]; then
    step "cocotb batch"
    ok=1
    for b in $batch; do
      r=$(timeout 100 "$PY" sim/run.py --testcase "$b" 2>&1 | grep -oE "PASS=[0-9]" | tail -1)
      [ "$r" = "PASS=1" ] || { ok=0; failed="$failed $b"; }
    done
    if [ "$ok" = "1" ]; then pass=$((pass+1)); echo "PASS  10 tests"
    else fail=$((fail+1)); echo "FAIL"; fi
    batch=""; n=0
  fi
done
if [ -n "$batch" ]; then
  step "cocotb batch"
  ok=1
  for b in $batch; do
    r=$(timeout 100 "$PY" sim/run.py --testcase "$b" 2>&1 | grep -oE "PASS=[0-9]" | tail -1)
    [ "$r" = "PASS=1" ] || { ok=0; failed="$failed $b"; }
  done
  if [ "$ok" = "1" ]; then pass=$((pass+1)); echo "PASS  $n tests"
  else fail=$((fail+1)); echo "FAIL"; fi
fi

fi

echo
echo "checks: $pass passed, $fail failed${failed:+ (failed:$failed)}"
[ "$fail" -eq 0 ]
