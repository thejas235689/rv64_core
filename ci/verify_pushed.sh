#!/usr/bin/env bash
# =============================================================================
# verify_pushed.sh -- verify what is actually on the remote, not the working tree.
#
# This exists because the most expensive mistakes in this project were all the
# same mistake: a change was verified in the working tree and then either not
# published, or published with a different tree. Three examples:
#
#   - id_ex_is_fp was declared and read but never latched; the FPU silently used
#     the wrong writeback path
#   - the FP RAW interlock was described in a commit message and was not present
#     in the tree that commit published (grep returned 0)
#   - a base_tree publish replaced a 117-file tree with 15 files
#
# In every case the working tree was correct and the pushed ref was not. So this
# script clones the remote fresh and runs everything against that clone.
#
#   ./ci/verify_pushed.sh [branch]
# =============================================================================
set -uo pipefail

BRANCH="${1:-main}"
REPO="${REPO_URL:-https://github.com/thejas235689/rv64_core.git}"
WORK="$(mktemp -d)"
FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  PASS  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=1; }

say "=== clone $REPO ($BRANCH) into a fresh tree ==="
if ! GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 --branch "$BRANCH" "$REPO" "$WORK/repo"; then
  say "  FAIL  clone"; exit 1
fi
cd "$WORK/repo" || exit 1
say "  HEAD  $(git log --oneline -1)"

say "=== structure ==="
n_files=$(git ls-files | wc -l)
say "  files: $n_files"
[ "$n_files" -ge 100 ] && ok "file count plausible ($n_files)" || bad "only $n_files files -- a tree was probably replaced"

for f in rtl/riscv_core_top.sv rtl/rv64_decoder.sv tb/cocotb/test_core.py docs/VERIFICATION_REPORT.md; do
  [ -f "$f" ] && ok "present $f" || bad "MISSING $f"
done

say "=== the checks that have actually caught bugs here ==="
# every signal the datapath reads must be latched or assigned
if grep -qE "id_ex_is_fp[[:space:]]*<=[[:space:]]*dec_ctrl\.is_fp" rtl/riscv_core_top.sv; then
  ok "id_ex_is_fp is latched"
else
  bad "id_ex_is_fp is not latched (declared-but-never-assigned)"
fi
if grep -q "FP RAW interlock" rtl/riscv_core_top.sv; then
  ok "FP RAW interlock present"
else
  bad "FP RAW interlock missing"
fi
if grep -q "mem_wb_reg_we && !mem_wb_is_fp" rtl/riscv_core_top.sv; then
  ok "integer file gated against FP writes"
else
  bad "FP result can leak into the integer file"
fi

say "=== elaboration (slang, if available) ==="
if command -v slang >/dev/null 2>&1; then
  if slang --top riscv_core_top rtl/*.sv rtl/fpu/*.sv >/dev/null 2>&1; then
    ok "elaborates"
  else
    bad "elaboration failed"
  fi
else
  say "  SKIP  slang not on PATH"
fi

say "=== result ==="
if [ "$FAIL" -eq 0 ]; then
  say "PUSHED REF VERIFIED"
  rm -rf "$WORK"
else
  say "PUSHED REF FAILED -- do not trust the working tree, it is not what shipped"
  say "clone left at $WORK/repo for inspection"
fi
exit "$FAIL"
