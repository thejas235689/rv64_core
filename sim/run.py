#!/usr/bin/env python3
"""
run.py -- build and run the cocotb regression without requiring `make`.

    python3 sim/run.py                       # full suite, Icarus
    python3 sim/run.py --testcase test_alu   # one test
    python3 sim/run.py --sim verilator       # alternate simulator

The equivalent Makefile is in sim/Makefile for environments that have make.
"""

import argparse
import os
import sys
from xml.etree import ElementTree

from cocotb_tools.runner import get_runner

SIM_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SIM_DIR)
RTL_DIR = os.path.join(ROOT, "rtl")
TB_DIR = os.path.join(ROOT, "tb")

with open(os.path.join(SIM_DIR, "rtl_sources.f"), encoding="utf-8") as source_file:
    RTL_SRCS = source_file.read().split()

# The core-level cache hardening tests live in their own module. Matched by exact
# name, not by a "test_cache_" prefix: that prefix also catches test_cache_ops in
# test_core.py, which then selects the wrong module and filters every test out.
CACHE_HARDENING_TESTS = [
    "test_cache_1_back_to_back_miss_same_line",
    "test_cache_2_miss_eviction_index_conflict",
    "test_cache_3_invalidation_drops_the_line",
    "test_cache_4_store_then_load_across_miss",
    "test_cache_5_refill_ordering_two_misses",
]

# Scalar double-precision blocks, in dependency order (round before the units
# that use it, cmp last).  Shared by the "fpu" suite below.
FPU_SRCS = [
    "fpu/rv64_fp_add.sv", "fpu/rv64_fp_round.sv", "fpu/rv64_fp_mul.sv",
    "fpu/rv64_fp_div.sv", "fpu/rv64_fp_sqrt.sv", "fpu/rv64_fp_cvt.sv",
    "fpu/rv64_fp_cmp.sv", "fpu/rv64_fp_nanbox.sv",
]

ALL_TESTS = [
    "test_alu", "test_muldiv", "test_memory", "test_control", "test_hazards",
    "test_csr", "test_traps", "test_access_fault", "test_random",
    "test_backpressure", "test_interrupt", "test_debug", "test_coverage_report",
]


def _cocotb_filter(names):
    """A module name selects the whole module; a test name filters to that test."""
    if not names:
        return None
    MODULES = {"test_fpu_integration", "test_isa_conformance", "test_fpu_core",
               "test_scenarios", "test_alu_matrix", "test_alu_lsu_num",
               "test_cache_hardening", "test_dcache_unit", "test_l2arb",
               "test_l2sys", "test_plic", "test_pmp_unit", "test_fpu_unit",
               "test_pss_matrix", "tb_li", "tb_two_store"}
    if all(n in MODULES for n in names):
        return None          # run every test in the module
    return names


def main():
    import sys as _sys
    if "--list-rtl" in _sys.argv:
        import argparse as _ap
        _p = _ap.ArgumentParser(add_help=False)
        _p.add_argument("--list-rtl", action="store_true")
        _p.parse_known_args()
        # Paths relative to the repository root, not bare filenames. CI consumes
        # this list from the root (`iverilog ... "${RTL[@]}"`) and a bare
        # "rv64_pkg.sv" does not exist there, so the lint step failed with
        # "rv64_pkg.sv: No such file or directory" and linted nothing.
        for f in RTL_SRCS:
            print(os.path.join("rtl", f))
        return
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", default=os.environ.get("SIM", "icarus"))
    ap.add_argument("--list-rtl", action="store_true",
                    help="print the RTL source list and exit (used by CI lint)")
    ap.add_argument("--suite", default="core",
                    choices=["core", "plic", "pmp", "fpu", "dcache", "icache", "l2arb", "l2sys",
                             "conformance", "stride"],
                    help="core: full CPU regression; plic: interrupt controller unit test; "
                         "pmp: PMP matcher unit test; fpu: scalar FPU unit test; "
                         "dcache/icache/l2arb: block-level unit suites that drive the "
                         "block's own ports; l2sys: the cache subsystem topology "
                         "(I-cache + D-cache -> L2 arbiter -> memory); conformance: "
                         "the ISA profile (isa/rv64_profile.yaml) checked against "
                         "the RTL, the ISS and the docs; stride: core stride-prefetch authorization")
    ap.add_argument("--testcase", action="append", default=None,
                    help="run only this test (repeatable)")
    ap.add_argument("--fetch-stage", action="store_true",
                    help="enable the optional fetch pipeline register in the core testbench")
    ap.add_argument("--clean", action="store_true")
    args = ap.parse_args()

    if args.suite == "pmp":
        sources = [os.path.join(RTL_DIR, "rv64_pkg.sv"),
                   os.path.join(RTL_DIR, "rv64_pmp.sv"),
                   os.path.join(TB_DIR, "tb_pmp_top.sv")]
        toplevel, module = "tb_pmp_top", "test_pmp_unit"
    elif args.suite == "plic":
        sources = [os.path.join(RTL_DIR, "rv64_plic_lite.sv"),
                   os.path.join(TB_DIR, "tb_plic_top.sv")]
        toplevel, module = "tb_plic_top", "test_plic"
    elif args.suite == "fpu":
        # The scalar FPU blocks are combinational and self-contained, so they are
        # verified against their Python models without the core in the way.  This
        # is where the thousands-of-vectors sweeps live; the core suite covers the
        # same operations end to end but can only afford tens.
        sources = [os.path.join(RTL_DIR, f) for f in FPU_SRCS]
        sources.append(os.path.join(TB_DIR, "tb_fpu_top.sv"))
        toplevel, module = "tb_fpu_top", "test_fpu_unit"
    elif args.suite == "dcache":
        # block-level: the D-cache's own request/bus ports, so a test can control
        # bus backpressure and response timing, which the core cannot reach.
        sources = [os.path.join(RTL_DIR, "rv64_dcache.sv")]
        toplevel, module = "rv64_dcache", "test_dcache_unit"
    elif args.suite == "icache":
        sources = [os.path.join(RTL_DIR, "rv64_icache.sv")]
        toplevel, module = "rv64_icache", "test_icache_unit"
    elif args.suite == "l2arb":
        sources = [os.path.join(RTL_DIR, "rv64_l2arb.sv")]
        toplevel, module = "rv64_l2arb", "test_l2arb"
    elif args.suite == "l2sys":
        # the arbiter in the topology it was written for: both caches' fill
        # streams into one memory port through rv64_l2arb.
        sources = [os.path.join(RTL_DIR, "rv64_l2arb.sv"),
                   os.path.join(RTL_DIR, "rv64_icache.sv"),
                   os.path.join(RTL_DIR, "rv64_dcache.sv"),
                   os.path.join(TB_DIR, "tb_l2sys.sv")]
        toplevel, module = "tb_l2sys", "test_l2sys"
    elif args.suite == "conformance":
        # The whole core is needed: the profile is checked by executing
        # instructions on riscv_core_top, not by inspecting files alone.
        sources = [os.path.join(RTL_DIR, f) for f in RTL_SRCS]
        sources.append(os.path.join(TB_DIR, "tb_core_top.sv"))
        toplevel, module = "tb_core_top", "test_isa_conformance"
    else:
        sources = [os.path.join(RTL_DIR, f) for f in RTL_SRCS]
        sources.append(os.path.join(TB_DIR, "tb_core_top.sv"))
        toplevel = "tb_core_top"
        module = "test_stride_platform" if args.suite == "stride" else "test_core"
    # `args.testcase or []`: without it, `run.py` with no --testcase raised
    # TypeError instead of running the whole suite.
    tests = args.testcase or []
    if any(t.startswith("test_two_store") for t in tests):
        toplevel, module = "tb_core_top", "tb_two_store"
    if any(t.startswith("test_alu_matrix") for t in tests):
        toplevel, module = "tb_core_top", "test_alu_matrix"
    if any(t.startswith(("test_alu_all", "test_lsu_all", "test_posit_quire", "test_coverage_bins"))
           for t in tests):
        toplevel, module = "tb_core_top", "test_alu_lsu_num"
    if any(t.startswith("test_scenario") for t in tests):
        toplevel, module = "tb_core_top", "test_scenarios"
    if any(t in CACHE_HARDENING_TESTS for t in tests):
        toplevel, module = "tb_core_top", "test_cache_hardening"
    if any(t.startswith("test_li") for t in tests):
        toplevel, module = "tb_core_top", "tb_li"
    if any(t.startswith("test_pss_matrix") for t in tests):
        toplevel, module = "tb_core_top", "test_pss_matrix"
    if any(t.startswith("test_pyuvm_") for t in tests):
        toplevel, module = "tb_core_top", "test_pyuvm"
    if any(t.startswith("test_fpu_core") for t in tests):
        toplevel, module = "tb_core_top", "test_fpu_core"
    # The integration suite: the same core, but it looks at the seams between the
    # FPU blocks and the core (NaN-boxing, fmt routing, frm, fflags, hazards,
    # flw/fsw) rather than at block arithmetic.
    if any(t.startswith("test_fpu_integration") for t in tests):
        toplevel, module = "tb_core_top", "test_fpu_integration"

    if args.fetch_stage and toplevel != "tb_core_top":
        ap.error("--fetch-stage requires the core testbench")
    variant = "_fetch_stage" if args.fetch_stage else ""
    build_dir = os.path.join(SIM_DIR, f"sim_build_{args.sim}_{args.suite}{variant}")
    if args.sim == "icarus":
        build_args = ["-g2012"]
    elif args.sim == "verilator":
        # --timing is required for the testbench's clock and delays; -Wno-fatal
        # keeps lint warnings from aborting the build
        build_args = ["--timing", "-Wno-fatal"]
    else:
        build_args = []

    parameters = {}
    if args.suite == "stride":
        parameters["ENABLE_STRIDE_PREFETCH"] = 1
    if args.fetch_stage:
        parameters["ENABLE_FETCH_STAGE"] = 1

    runner = get_runner(args.sim)
    runner.build(
        sources=sources,
        hdl_toplevel=toplevel,
        parameters=parameters,
        build_dir=build_dir,
        build_args=build_args,
        always=args.clean or True,
    )

    sys.path.insert(0, os.path.join(TB_DIR, "cocotb"))
    sys.path.insert(0, os.path.join(TB_DIR, "pyuvm"))
    results = runner.test(
        hdl_toplevel=toplevel,
        test_module=module,
        testcase=_cocotb_filter(args.testcase),
        build_dir=build_dir,
    )
    tests = ElementTree.parse(results).findall(".//testcase")
    if not tests:
        raise SystemExit(f"No test cases recorded in {results}")
    failed = sum(test.find("failure") is not None or test.find("error") is not None
                 for test in tests)
    if failed:
        raise SystemExit(f"{failed} test(s) failed. Results: {results}")


if __name__ == "__main__":
    main()
