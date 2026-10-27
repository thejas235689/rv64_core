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
    "rv64_bpu.sv", "rv64_predecode.sv", "rv64_bootrom.sv", "rv64_bootauth.sv", "rv64_icache.sv", "rv64_fetch.sv", "rv64_plic_lite.sv",
    "rv64_num_pkg.sv", "rv64_num_wide.sv", "rv64_numfile.sv", "rv64_num_unit.sv", "rv64_num_csr.sv",
    "rv64_xrv512_file.sv", "rv64_xrv512.sv", "rv64_vregfile.sv", "rv64_vunit.sv", "rv64_qisa.sv" , "rv64_aiacc.sv" , "rv64_xcetask.sv",
    "riscv_core_top.sv",
]

ALL_TESTS = [
    "test_alu", "test_muldiv", "test_memory", "test_control", "test_hazards",
    "test_csr", "test_traps", "test_access_fault", "test_random",
    "test_backpressure", "test_interrupt", "test_debug", "test_coverage_report",
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", default=os.environ.get("SIM", "icarus"))
    ap.add_argument("--suite", default="core", choices=["core", "plic", "pmp"],
                    help="core: full CPU regression; plic: interrupt controller unit test; "
                         "pmp: PMP matcher unit test")
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
    else:
        sources = [os.path.join(RTL_DIR, f) for f in RTL_SRCS]
        sources.append(os.path.join(TB_DIR, "tb_core_top.sv"))
        toplevel, module = "tb_core_top", "test_core"

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
    runner.test(
        hdl_toplevel=toplevel,
        test_module=module,
        testcase=args.testcase,
        build_dir=build_dir,
    )


if __name__ == "__main__":
    main()
