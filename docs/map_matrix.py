"""Map the verification matrix onto the evidence that actually exists.

A principal verification engineer's rule: an item is Covered only if a named,
runnable test exercises it. Anything else is Open, however plausible the RTL looks.
"""
import json, collections

ITEMS = json.load(open('matrix_items.json'))

# area -> (evidence, level, caveat)
EVIDENCE = {
 "Integer":      ("cocotb test_alu (79 instr), test_control; UVM rv64_alu_test", "L1", ""),
 "Mul/Div":      ("cocotb test_muldiv (8 ops, div0, INT_MIN/-1)", "L1", ""),
 "Bitmanip":     ("cocotb test_alu (Zba/Zbb/Zbc/Zbs ops)", "L1", ""),
 "Atomics":      ("cocotb test_atomic (LR/SC + 9 AMOs); tb_lsu 22 checks", "L1", ""),
 "Privilege":    ("cocotb test_csr, test_sv39_identity", "L1", ""),
 "Sv39":         ("cocotb test_sv39_identity; tb_mmu", "L1", ""),
 "Front end":    ("cocotb test_control, test_hazards, test_rvc_in_core", "L1", ""),
 "Prediction":   ("cocotb test_predictor_stress", "L1", ""),
 "Caches":       ("cocotb test_icache_hits, test_dcache_hits, test_l2_in_path; tb_icache 19, tb_dcache 18", "L1", ""),
 "AMCCE":        ("cocotb test_amcce_bypass; tb_amcce", "L1", ""),
 "Memory ops":   ("cocotb test_memory; tb_lsu 22 checks", "L1", ""),
 "Zifencei":     ("cocotb test_cache_ops; tb_icache (invalidate)", "L1", ""),
 "PMP":          ("cocotb test_pmp; tb_pmp_top; 5/5 unit", "L1", ""),
 "System":       ("cocotb test_traps, test_csr, test_wfi, test_reset", "L1", ""),
 "Interrupts":   ("cocotb test_interrupt", "L1",
                  "PLIC-lite is verified standalone but NOT instantiated in the core; irq_* are top-level inputs"),
 "Debug":        ("cocotb test_debug, test_ebreak_debug", "L1", ""),
 "Boot":         ("tb_bootseq 6 checks; tb_bootauth_hmac 6 checks", "L1",
                  "BOOT_ROM defaults to 0; the ROM path is not in the default build"),
 "Crypto":       ("tb_sha256 5 checks; tb_hmac RFC 4231", "L0", ""),
 "Numeric":      ("cocotb test_numeric_abi, test_numeric_sweep; tb_num_top", "L1", ""),
 "QISA":         ("tb_qisa_aiacc", "L0", ""),
 "AI accel":     ("tb_qisa_aiacc", "L0", ""),
 "XRV512":       ("cocotb test_xrv512_in_core; tb_xrv512", "L1", ""),
 "RVV":          ("cocotb test_rvv_in_core, test_vle_in_core; tb_vunit 42 checks", "L1", ""),
 "Xcetask":      ("cocotb test_xcetask", "L1", ""),
 "Observability":("34 top-level output ports; every cocotb test compares retire_pc/insn/rd/wdata", "L1", ""),
 "Cross-cutting":("cocotb test_random (56k instr, 5 seeds), test_backpressure, test_isa_sweep_fast, test_reset; lint; Yosys", "L1", ""),
}

OPEN_AREAS = {   # areas with no covering test at all
}

by_area = collections.defaultdict(list)
for it in ITEMS:
    by_area[it['area']].append(it)

lines = []
covered = open_n = 0
for area in sorted(by_area):
    ev = EVIDENCE.get(area)
    for it in by_area[area]:
        # An area-level mapping does NOT prove an item. "Covered" would mean a
        # named test exercises THIS scenario; all that is established here is that
        # the area has some test. Saying "Covered" for 174 items because 26 areas
        # each have a test is precisely the "it looks plausible" trap.
        if ev:
            status = "Area-tested"
            covered += 1
        else:
            status = "Open"
            open_n += 1
        lines.append((it['id'], area, it['priority'], status,
                      ev[0] if ev else "", ev[2] if ev else ""))

print(f"items: {len(ITEMS)}   area-tested: {covered}   open: {open_n}")
unmapped = sorted(set(by_area) - set(EVIDENCE))
print("areas with no evidence:", unmapped if unmapped else "none")

with open('matrix_status.csv','w') as f:
    f.write("id,area,priority,status,evidence,caveat\n")
    for r in lines:
        f.write(",".join('"%s"' % str(c).replace('"',"'") for c in r) + "\n")
print("wrote matrix_status.csv")
