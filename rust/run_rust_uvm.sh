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
iverilog -g2012 -o "$BUILD/rv64_rustdv.vvp" -s riscv_core_top "$REPO_ROOT"/rtl/*.sv
vvp -M "$BUILD" -m rv64_tb "$BUILD/rv64_rustdv.vvp"
