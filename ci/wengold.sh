#!/usr/bin/env bash
# Run WENGOLD against this project.
#
# WENGOLD is the validity kernel that answers "which of my previous verification
# results still hold?" after a change. That is precisely the question this project
# has gotten wrong repeatedly: a latch that was declared but never driven, an
# interlock described in a commit and absent from the published tree, a stale clone
# verified instead of the pushed ref. A dependency graph would have named the blast
# radius of each of those.
#
# Install (upstream is a Python package; there is no console script on PATH here):
#   git clone https://github.com/thejas235689/wengold.git ../wengold
#   pip install pyslang            # optional but strongly preferred
#
# Usage:
#   ./ci/wengold.sh index          # build the dependency graph
#   ./ci/wengold.sh completeness   # files vs blocks, and what is missing
#   ./ci/wengold.sh cdc            # clock-domain crossings
#   ./ci/wengold.sh classify       # which prior results a change invalidates
set -uo pipefail
WENGOLD_SRC="${WENGOLD_SRC:-/scratch/work/wengold}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

run() {
  python3 -c "
import sys; sys.path.insert(0,'$WENGOLD_SRC')
from wengold.cli import main
sys.argv = ['wengold'] + sys.argv[1:]
main()
" "$@"
}

case "${1:-index}" in
  index)        run index rtl --backend "${BACKEND:-regex}" --out ../wengold_graph.json ;;
  completeness) run completeness rtl ;;
  cdc)          run cdc "${2:-rtl/riscv_core_top.sv}" ;;
  classify)     shift; run classify "$@" ;;
  *)            run "$@" ;;
esac
