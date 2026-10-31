#!/usr/bin/env python3
"""Fail if two CSR windows in riscv_core_top overlap.

This exists because I twice placed a new block on an address another block already
owned -- 0x7D0 (Xcetask) and then 0x7F0 (XRV512) -- and each time the new block's own
test passed while the displaced block broke silently. A per-block test cannot catch a
collision; only a whole-map check can.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOP = ROOT / "rtl" / "riscv_core_top.sv"

src = TOP.read_text()

# base -> span, from every "csr_addr >= BASE) && ... <= BASE + N" pair
bases = {}
for m in re.finditer(r"csr_addr >= (CSR_[A-Z0-9_]+)\)", src):
    bases.setdefault(m.group(1), None)
for m in re.finditer(r"\(id_ex_ctrl\.csr_addr <= \((CSR_[A-Z0-9_]+) \+ 12'd(\d+)\)\)", src):
    bases[m.group(1)] = int(m.group(2))

# resolve the base values from anywhere in rtl/
values = {}
for f in (ROOT / "rtl").glob("*.sv"):
    for m in re.finditer(r"(CSR_[A-Z0-9_]+)\s*=\s*12'h([0-9A-Fa-f]+)", f.read_text()):
        values[m.group(1)] = int(m.group(2), 16)

windows = []
for name, span in bases.items():
    if span is None or name not in values:
        continue
    lo = values[name]
    windows.append((name, lo, lo + span))

windows.sort(key=lambda w: w[1])
errors = 0
for i, (n1, lo1, hi1) in enumerate(windows):
    for n2, lo2, hi2 in windows[i + 1:]:
        if lo1 <= hi2 and lo2 <= hi1:
            print(f"OVERLAP: {n1} {lo1:#05x}-{hi1:#05x}  vs  {n2} {lo2:#05x}-{hi2:#05x}")
            errors += 1

print("\nCSR map:")
for n, lo, hi in windows:
    print(f"  {lo:#05x}-{hi:#05x}  {n}")
print(f"\n{len(windows)} windows, {errors} overlap(s)")
sys.exit(1 if errors else 0)
