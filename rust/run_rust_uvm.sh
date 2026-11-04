#!/usr/bin/env bash
# Build the rustdv testbench for rv64_core and run it on Icarus.
#
#   rust/run_rust_uvm.sh [debug|release] [vector-prefix]
#
# Flow (same as rustdv's own TinyALU flow):
#   cargo build (cdylib) -> copy as build/rv64_tb.vpi
#   iverilog the DUT (no Verilog testbench: rustdv drives the top module)
#   vvp -M build -m rv64_tb -> the VPI module bootstraps the regression
#
# Prerequisite: a Rust toolchain, e.g.
#   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$(cd .. && pwd)"

PROFILE="${1:-release}"
PREFIX="${2:-sim/uvm_vectors/alu}"

# The vector prefix is repo-relative but this script runs from rust/, so it has
# to be made absolute before the testbench reads it -- otherwise every run
# fails with "program image: No such file or directory".
case "$PREFIX" in
  /*) ;;
  *) PREFIX="$REPO_ROOT/$PREFIX" ;;
esac

BUILD="${SIM_BUILD_DIR:-/tmp/rv64-tb-$(id -u)}"
mkdir -p "$BUILD"

case "$PROFILE" in
  release) (cd "$REPO_ROOT/rust" && cargo build --release) ;;
  debug)   (cd "$REPO_ROOT/rust" && cargo build) ;;
  *) echo "unknown profile: $PROFILE (use debug|release)" >&2; exit 2 ;;
esac

LIB="$REPO_ROOT/rust/target/$PROFILE/librv64_tb.so"
[ -f "$LIB" ] || LIB="$REPO_ROOT/rust/target/$PROFILE/librv64_tb.dylib"
cp "$LIB" "$BUILD/rv64_tb.vpi"

export RUSTDV_TOP=riscv_core_top
export RUSTDV_VEC_PREFIX="$PREFIX"
export RUSTDV_RANDOM_SEED="${RUSTDV_RANDOM_SEED:-1}"
export RUSTDV_RESULTS_XML="${RUSTDV_RESULTS_XML:-$BUILD/results.xml}"

# No SV testbench: the DUT alone, driven entirely from Rust over VPI.
#
# Two things about this line are load-bearing and were both wrong:
#
#   * Packages must be compiled *before* the modules that import them. Icarus
#     parses in command-line order, and a bare `rtl/*.sv` glob sorts
#     riscv_core_top.sv ahead of rv64_pkg.sv, so the top is elaborated before
#     its package exists. Name the packages first and skip them in the glob.
#   * rtl/fpu/*.sv is a subdirectory, which `rtl/*.sv` never matches. Left out,
#     elaboration dies with eight "Unknown module type" errors for the FPU
#     blocks instantiated by the core.
PKGS=("$REPO_ROOT"/rtl/rv64_pkg.sv "$REPO_ROOT"/rtl/rv64_num_pkg.sv)
MODULES=()
for f in "$REPO_ROOT"/rtl/*.sv; do
  case "$(basename "$f")" in
    rv64_pkg.sv|rv64_num_pkg.sv) continue ;;
  esac
  MODULES+=("$f")
done
iverilog -g2012 -o "$BUILD/rv64_rustdv.vvp" -s riscv_core_top \
  "${PKGS[@]}" "${MODULES[@]}" "$REPO_ROOT"/rtl/fpu/*.sv
vvp -M "$BUILD" -m rv64_tb "$BUILD/rv64_rustdv.vvp"
