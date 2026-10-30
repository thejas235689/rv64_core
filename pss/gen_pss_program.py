#!/usr/bin/env python3
"""Turn a Satya PSS solve into an executable program image.

The gap this closes: Satya solves constraints and emits values, and the UVM and
cocotb benches load programs. Nothing connected the two, so the PSS model sat
beside the verification instead of driving it.

This reads the solved `fields` from Satya's JSON backend and emits RISC-V words
that a testbench can load. The values are read from the solve, never the status
line -- Satya reports "1/1 satisfied" for constraint blocks it silently ignores.

    ./pss/gen_pss_program.py alu_op --seed 3 -o sim/pss_prog.hex
"""
import argparse, json, subprocess, sys, os

SATYA = os.environ.get("SATYA", "satya")
PSS = os.path.join(os.path.dirname(__file__), "cpu", "rv64_cpu_pss.pss")

ALU_OPS = [  # op_index -> (funct3, funct7) for OP / OP-IMM
    (0x0, 0x00), (0x1, 0x00), (0x2, 0x00), (0x3, 0x00),
    (0x4, 0x00), (0x5, 0x00), (0x6, 0x00), (0x7, 0x00),
]


def solve(action, seed):
    out = subprocess.run([SATYA, "gen", PSS, "--action", action,
                          "--backend", "json", "--seed", str(seed)],
                         capture_output=True, text=True, check=True)
    d = json.loads(out.stdout)
    st = d["steps"][0]
    sat = st["constraints"]
    if sat["satisfied"] != sat["total"]:
        raise SystemExit(f"unsatisfied constraints: {sat}")
    return st["fields"]


def enc_r(f7, rs2, rs1, f3, rd, op=0x33):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def build_alu(f):
    """alu_op -> addi x5, x0, A ; addi x6, x0, B ; <op> x7, x5, x6"""
    op = f["op_index"] % 8
    f3, f7 = ALU_OPS[op]
    a = (f["operand_class"] * 37) & 0x7FF
    b = (f["operand_class"] * 53 + 11) & 0x7FF
    words = [
        0x00500313 | 0,                       # addi x6, x0, 5   (sentinel)
        ((a & 0xFFF) << 20) | (5 << 7) | 0x13,   # addi x5, x0, a
        ((b & 0xFFF) << 20) | (6 << 7) | 0x13,   # addi x6, x0, b
        enc_r(f7, 6, 5, f3, 7),                  # op x7, x5, x6
        0x00000073,                              # ecall
    ]
    return words, {"op_index": op, "funct3": f3, "funct7": f7, "a": a, "b": b}


def build_branch(f):
    """branch -> b<cond> over one addi, then ecall"""
    pol = f["polarity"] % 8
    off = f["offset"] & 0xFFE
    taken = f["taken"]
    # beq x0,x0 always taken; bne x0,x0 never taken
    f3 = 0x0 if taken else 0x1
    words = [
        0x00100313,                              # addi x6, x0, 1
        # B-type: imm[12|10:5] rs2 rs1 f3 imm[4:1|11] opcode
        (((off >> 1) & 0xF) << 8) | (((off >> 5) & 0x3F) << 25) | (0 << 20) | (0 << 15)
        | (f3 << 12) | (((off >> 11) & 1) << 7) | 0x63,
        0x00200313,                              # addi x6, x0, 2  (skipped if taken)
        0x00000073,
    ]
    return words, {"polarity": pol, "taken": taken, "offset": off, "funct3": f3}


def build_word(f):
    """word_op -> addw/subw/sllw/srlw/sraw on values whose sign differs at bit 31."""
    op = f["op_index"] % 5
    neg = f["operand_is_negative"]
    a = 0x7FFFFFF0 if neg else 0x10
    b = (f["operand_class"] * 7 + 1) & 0x1F
    # funct3/funct7 for the OP-32 forms
    W = [(0x0, 0x20), (0x0, 0x20), (0x1, 0x00), (0x5, 0x00), (0x5, 0x20)]
    f3, f7 = W[op]
    words = [
        # lui x5, 0x80000 -> x5 = 0x80000000 (bit31 set, bit32 clear)
        (0x80000 << 12) | (5 << 7) | 0x37,
        ((b & 0xFFF) << 20) | (6 << 7) | 0x13,          # addi x6, x0, b
        enc_r(f7, 6, 5, f3, 7, op=0x3B),                 # <op>w x7, x5, x6
        0x00000073,
    ]
    return words, {"op_index": op, "funct3": f3, "funct7": f7, "a": 0x80000000, "b": b}


def build_memory(f):
    """memory_op -> a sized load or store at a chosen alignment."""
    width = f["width_code"] % 4          # 0=B 1=H 2=W 3=D
    is_store = f["is_store"]
    align = f["align_code"] % 4
    f3 = [0x0, 0x1, 0x2, 0x3][width]
    off = align if width == 0 else (align * 2 if width == 1 else align * 4)
    base = 0x100000
    words = [
        (0x100 << 12) | (10 << 7) | 0x37,                # lui x10, 0x100 (0x100000)
        0x02A00313 if False else ((0x2A << 20) | (6 << 7) | 0x13),   # addi x6, x0, 0x2A
        # store then load the same width/offset
        ((off >> 5) << 25) | (6 << 20) | (10 << 15) | (f3 << 12) | ((off & 0x1F) << 7) | 0x23,
        ((off & 0xFFF) << 20) | (10 << 15) | (f3 << 12) | (7 << 7) | 0x03,
        0x00000073,
    ]
    return words, {"width": width, "funct3": f3, "offset": off,
                   "is_store": is_store, "expect": 0x2A}


BUILDERS = {"alu_op": build_alu, "branch": build_branch,
            "word_op": build_word, "memory_op": build_memory}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=sorted(BUILDERS))
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("-o", "--out", default="-")
    a = ap.parse_args()

    fields = solve(a.action, a.seed)
    words, summary = BUILDERS[a.action](fields)
    text = "\n".join(f"{w:08x}" for w in words) + "\n"
    if a.out == "-":
        sys.stdout.write(text)
    else:
        open(a.out, "w").write(text)
    sys.stderr.write(f"{a.action} seed={a.seed} fields={fields} -> {summary}\n")


if __name__ == "__main__":
    main()
