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

from cocotb_tools.runner import get_runner

SIM_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SIM_DIR)
RTL_DIR = os.path.join(ROOT, "rtl")
TB_DIR = os.path.join(ROOT, "tb")

RTL_SRCS = [
    "rv64_pkg.sv", "rv64_alu.sv", "rv64_mdu.sv", "rv64_regfile.sv",
    "rv64_decoder.sv", "rv64_pmp.sv", "rv64_csr.sv", "rv64_mmu.sv", "rv64_l2arb.sv", "rv64_l2cache.sv", "rv64_amcce.sv", "rv64_dcache.sv", "rv64_lsu.sv",
    "rv64_bpu.sv", "rv64_predecode.sv", "rv64_bootrom.sv", "rv64_rvc_expand.sv", "rv64_montmul.sv", "rv64_modexp.sv", "rv64_clint.sv", "rv64_uart.sv", "rv64_clic.sv", "fpu/rv64_fp_add.sv", "fpu/rv64_fp_round.sv", "fpu/rv64_fp_mul.sv",
    "fpu/rv64_fp_div.sv", "fpu/rv64_fp_sqrt.sv", "fpu/rv64_fp_cvt.sv",
    "fpu/rv64_fp_cmp.sv", "fpu/rv64_fregfile.sv", "rv64_sha256.sv", "rv64_hmac.sv", "rv64_bootauth_hmac.sv", "rv64_icache.sv", "rv64_fetch.sv", "rv64_plic_lite.sv",
    "rv64_num_pkg.sv", "rv64_num_wide.sv", "rv64_numfile.sv", "rv64_num_unit.sv", "rv64_num_csr.sv",
    "rv64_xrv512_file.sv", "rv64_xrv512.sv", "rv64_vregfile.sv", "rv64_vunit.sv", "rv64_qisa.sv" , "rv64_aiacc.sv" , "rv64_xcetask.sv",
    "riscv_core_top.sv",
]

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
    "fpu/rv64_fp_cmp.sv",
]

ALL_TESTS = [
    "test_alu", "test_muldiv", "test_memory", "test_control", "test_hazards",
    "test_csr", "test_traps", "test_access_fault", "test_random",
    "test_backpressure", "test_interrupt", "test_debug", "test_coverage_report",
]


def main():
    import sys as _sys
    if "--list-rtl" in _sys.argv:
        import argparse as _ap
        _p = _ap.ArgumentParser(add_help=False)
        _p.add_argument("--list-rtl", action="store_true")
        _p.parse_known_args()
        for f in RTL_SRCS:
            print(f)
        return
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", default=os.environ.get("SIM", "icarus"))
    ap.add_argument("--list-rtl", action="store_true",
                    help="print the RTL source list and exit (used by CI lint)")
    ap.add_argument("--suite", default="core",
                    choices=["core", "plic", "pmp", "fpu", "dcache", "icache", "l2arb", "l2sys"],
                    help="core: full CPU regression; plic: interrupt controller unit test; "
                         "pmp: PMP matcher unit test; fpu: scalar FPU unit test; "
                         "dcache/icache/l2arb: block-level unit suites that drive the "
                         "block's own ports; l2sys: the cache subsystem topology "
                         "(I-cache + D-cache -> L2 arbiter -> memory)")
    ap.add_argument("--testcase", action="append", default=None,
                    help="run only this test (repeatable)")
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
    else:
        sources = [os.path.join(RTL_DIR, f) for f in RTL_SRCS]
        sources.append(os.path.join(TB_DIR, "tb_core_top.sv"))
        toplevel, module = "tb_core_top", "test_core"
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

    build_dir = os.path.join(SIM_DIR, f"sim_build_{args.sim}_{args.suite}")
    if args.sim == "icarus":
        build_args = ["-g2012"]
    elif args.sim == "verilator":
        # --timing is required for the testbench's clock and delays; -Wno-fatal
        # keeps lint warnings from aborting the build
        build_args = ["--timing", "-Wno-fatal"]
    else:
        build_args = []

    runner = get_runner(args.sim)
    runner.build(
        sources=sources,
        hdl_toplevel=toplevel,
        build_dir=build_dir,
        build_args=build_args,
        always=args.clean or True,
    )

    sys.path.insert(0, os.path.join(TB_DIR, "cocotb"))
    sys.path.insert(0, os.path.join(TB_DIR, "pyuvm"))
    runner.test(
        hdl_toplevel=toplevel,
        test_module=module,
        testcase=args.testcase,
        build_dir=build_dir,
    )


if __name__ == "__main__":
    main()
