#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

python sim/run.py --sim verilator --suite core
python sim/run.py --sim verilator --suite core --fetch-stage
python sim/run.py --sim verilator --suite conformance
python sim/run.py --sim verilator --suite stride
python sim/run.py --sim verilator --suite stride --fetch-stage
