#!/usr/bin/env python3
"""Turn a Satya PSS solve into an executable program image.

The gap this closes: Satya solves constraints and emits values, and the UVM and
cocotb benches load programs. Nothing connected the two, so the PSS model sat
beside the verification instead of driving it.

This reads the solved `fields` from Satya's JSON backend and emits RISC-V words
that a testbench can load. The values are read from the solve, never the status
line -- Satya reports "1/1 satisfied" for constraint blocks it silently ignores.

Two models are supported:

  pss/cpu/rv64_cpu_pss.pss   alu_op, word_op, memory_op, branch, csr_access, trap_case
  pss/rv64_full_matrix.pss   alu_pair, alu_imm, alu_sign_boundary, lsu_access,
                             lsu_roundtrip, posit_op, quire_op, numeric_roundtrip

The cpu-model builders hand-encode words; the matrix builders emit assembly and
go through tb/cocotb/rv64_asm.py, because 64-bit operand classes need li
sequences and the numeric ABI needs custom-0 encodings.

    ./pss/gen_pss_program.py alu_op --seed 3 -o sim/pss_prog.hex
    ./pss/gen_pss_program.py alu_pair --model pss/rv64_full_matrix.pss --seed 1
"""
import argparse, json, subprocess, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tb", "cocotb"))

from rv64_asm import assemble  # noqa: E402

SATYA = os.environ.get("SATYA", "satya")
PSS = os.path.join(HERE, "cpu", "rv64_cpu_pss.pss")
PSS_MATRIX = os.path.join(HERE, "rv64_full_matrix.pss")

M64 = (1 << 64) - 1

# ---- operand classes of pss/rv64_full_matrix.pss, in model order -------------
VALUES = [
    0,                                  # 0  zero
    1,                                  # 1  one
    -1,                                 # 2  neg_one
    2,                                  # 3  two
    -2,                                 # 4  neg_two
    0x7FFFFFFF,                         # 5  int32_max
    -0x80000000,                        # 6  int32_min (sign-extended to 64 bits)
    0x7FFFFFFFFFFFFFFF,                 # 7  int64_max
    -0x8000000000000000,                # 8  int64_min
    0xFFFFFFFF,                         # 9  ffffffff
    1 << 20,                            # 10 pow2
    -(1 << 20),                         # 11 neg_pow2
    -1,                                 # 12 all_ones
    3,                                  # 13 small_odd
    4,                                  # 14 small_even
]
CLASS_NAMES = ["zero", "one", "neg_one", "two", "neg_two", "int32_max", "int32_min",
               "int64_max", "int64_min", "ffffffff", "pow2", "neg_pow2",
               "all_ones", "small_odd", "small_even"]

IMMS = [0, 1, -1, 2047, -2048, 127, -128, 1024]      # imm_class 0..7
MAGS = [1, 2, 1 << 20, 0x7FFFFFFF]                   # magnitude_class 0..3
ALIGN = [0, 1, 2, 4, 8]                              # align_offset 0..4

# numeric ABI (rtl/rv64_num_pkg.sv), custom-0 opcode
NUM_QADD, NUM_QSUB, NUM_QMUL, NUM_QCLR, NUM_QACC, NUM_QGET = 0, 1, 2, 3, 4, 5
NUM_ADAPT, NUM_ERR = 6, 7
NUM_PADD, NUM_PSUB, NUM_PMUL, NUM_PDIV = 8, 9, 10, 11
NUM_TOINT, NUM_FROMINT = 18, 19


def num_insn(op, fmt=0, rd=0, rs1=0, rs2=0):
    """Encode a custom-0 numeric-ABI instruction."""
    return (op << 25) | (rs2 << 20) | (rs1 << 15) | (fmt << 12) | (rd << 7) | 0x0B


def s64(v):
    v &= M64
    return v - (1 << 64) if v >> 63 else v


ALU_OPS = [  # op_index -> (funct3, funct7) for OP / OP-IMM
    (0x0, 0x00), (0x1, 0x00), (0x2, 0x00), (0x3, 0x00),
    (0x4, 0x00), (0x5, 0x00), (0x6, 0x00), (0x7, 0x00),
]


def solve(action, seed, model=PSS):
    out = subprocess.run([SATYA, "gen", model, "--action", action,
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


# =============================================================================
# pss/cpu/rv64_cpu_pss.pss builders (hand-encoded words)
# =============================================================================
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


def build_csr(f):
    """csr_access -> read or write a CSR chosen by access_kind.

    access_kind 0 = read (csrr), 1 = write (csrrw), 2 = set (csrrs).
    A read-only target must trap on write, which is what target_is_readonly is for.
    """
    kind = f["access_kind"] % 3
    readonly = f["target_is_readonly"]
    csr = 0x300 if readonly else 0x340          # mstatus (has RO bits) or mscratch
    opf = {0: 2, 1: 1, 2: 2}[kind]              # csrr/csrrw/csrrs funct3
    words = [
        0x00700313,                              # addi x6, x0, 7
        (csr << 20) | (6 << 15) | (opf << 12) | (0 << 7) | 0x73,   # csr op, rd=x0
        (csr << 20) | (2 << 12) | (7 << 7) | 0x73,                 # csrr x7, csr
        0x00000073,
    ]
    return words, {"kind": kind, "csr": csr, "readonly": readonly, "funct3": opf}


def build_trap(f):
    """trap_case -> provoke a specific exception class and check the cause.

    cause_class 0 = illegal instruction, 1 = load misaligned, 2 = ebreak.
    """
    cause = f["cause_class"] % 3
    words = []
    if cause == 0:
        words = [0xFFFFFFFF, 0x00000073]                 # an illegal encoding
        expect = 2
    elif cause == 1:
        words = [(0x100 << 12) | (10 << 7) | 0x37,       # lui x10, 0x100
                 (0x1 << 20) | (10 << 15) | (0x3 << 12) | (7 << 7) | 0x03,  # ld x7,1(x10)
                 0x00000073]
        expect = 4                                       # load address misaligned
    else:
        words = [0x00100073, 0x00000073]                 # ebreak
        expect = 3                                       # breakpoint
    return words, {"cause_class": cause, "expect_cause": expect}


BUILDERS = {"alu_op": build_alu, "branch": build_branch,
            "word_op": build_word, "memory_op": build_memory,
            "csr_access": build_csr, "trap_case": build_trap}


# =============================================================================
# pss/rv64_full_matrix.pss builders (assembly)
#
# Satya's ranges are advisory: `rand int in [0..6]` can come back as 47, and the
# cpu model shows it (op_index=47). Every field is therefore taken modulo its
# intended range, and the range actually used is recorded in the summary so the
# program can be checked against what the solver chose.
# =============================================================================
def _rng(v, lo, hi):
    """Fold a solved field back into its declared range [lo..hi].

    Satya ignores the `in [lo..hi]` range on `rand int`, so a field declared
    [5..6] can come back as 47. Wrapping from lo -- not from 0 -- keeps the
    intent for ranges that do not start at zero (op_index [5..6],
    accumulate_count [1..8]).
    """
    span = hi - lo + 1
    return lo + ((v - lo) % span)


def _cls(f, name):
    i = _rng(f[name], 0, len(VALUES) - 1)
    return i, VALUES[i]


def asm_alu_pair(f):
    """alu_pair -> li both operand classes, apply the register op, read x7."""
    op = _rng(f["op_index"], 0, 6)
    ia, a = _cls(f, "a_class")
    ib, b = _cls(f, "b_class")
    mn = ["add", "sub", "and", "or", "xor", "slt", "sltu"][op]
    a &= M64
    b &= M64
    expect = {"add": (a + b) & M64, "sub": (a - b) & M64, "and": a & b,
              "or": a | b, "xor": a ^ b,
              "slt": 1 if s64(a) < s64(b) else 0,
              "sltu": 1 if a < b else 0}[mn]
    src = f"""
    li    x5, {s64(a)}
    li    x6, {s64(b)}
    {mn}  x7, x5, x6
    ecall
    """
    return src, {"op": mn, "op_index": op, "a_class": ia, "a_class_name": CLASS_NAMES[ia],
                 "b_class": ib, "b_class_name": CLASS_NAMES[ib],
                 "a": a, "b": b, "expect_x7": expect}


def asm_alu_imm(f):
    """alu_imm -> li one operand class, apply the immediate form, read x7."""
    op = _rng(f["op_index"], 0, 5)
    ia, a = _cls(f, "a_class")
    ii = _rng(f["imm_class"], 0, len(IMMS) - 1)
    imm = IMMS[ii]
    mn = ["addi", "andi", "ori", "xori", "slti", "sltiu"][op]
    a &= M64
    simm = imm & M64 if imm >= 0 else imm & M64
    sext = imm & M64 if imm >= 0 else (imm & M64)
    expect = {"addi": (a + sext) & M64, "andi": a & sext, "ori": a | sext,
              "xori": a ^ sext,
              "slti": 1 if s64(a) < s64(sext) else 0,
              "sltiu": 1 if a < sext else 0}[mn]
    src = f"""
    li    x5, {s64(a)}
    {mn}  x7, x5, {imm}
    ecall
    """
    return src, {"op": mn, "op_index": op, "a_class": ia, "a_class_name": CLASS_NAMES[ia],
                 "imm_class": ii, "imm": imm, "a": a, "expect_x7": expect}


def asm_alu_sign_boundary(f):
    """alu_sign_boundary -> slt vs sltu on values that differ only in sign."""
    op = _rng(f["op_index"], 5, 6)          # 5 slt, 6 sltu
    an = _rng(f["a_is_negative"], 0, 1)
    bn = _rng(f["b_is_negative"], 0, 1)
    mi = _rng(f["magnitude_class"], 0, len(MAGS) - 1)
    mag = MAGS[mi]
    a = (-mag if an else mag) & M64
    b = (-mag if bn else mag) & M64
    mn = ["slt", "sltu"][op - 5]
    expect = (1 if s64(a) < s64(b) else 0) if mn == "slt" else (1 if a < b else 0)
    src = f"""
    li    x5, {s64(a)}
    li    x6, {s64(b)}
    {mn}  x7, x5, x6
    ecall
    """
    return src, {"op": mn, "op_index": op, "a_negative": an, "b_negative": bn,
                 "magnitude_class": mi, "a": a, "b": b, "expect_x7": expect}


def _lsu_setup(off):
    """Base register x10 such that x10 + off is the 8-aligned address 0x100008.

    The offset field is exercised as an immediate; the effective address stays
    aligned, so the program retires instead of taking a misaligned-access trap.
    """
    return f"li    x10, {0x100008 - off}"


def asm_lsu_access(f):
    """lsu_access -> a sized store then a load of the solved width and kind."""
    sw = _rng(f["store_width"], 0, 3)
    lk = _rng(f["load_kind"], 0, 6)
    ic, val = _cls(f, "value_class")
    oi = _rng(f["align_offset"], 0, len(ALIGN) - 1)
    off = ALIGN[oi]
    smn = ["sb", "sh", "sw", "sd"][sw]
    lmn, lsize, lsigned = [("lb", 1, True), ("lbu", 1, False), ("lh", 2, True),
                           ("lhu", 2, False), ("lw", 4, True), ("lwu", 4, False),
                           ("ld", 8, False)][lk]
    ssize = 1 << sw
    value = val & M64
    mem = value & ((1 << (8 * ssize)) - 1)
    r = mem & ((1 << (8 * lsize)) - 1)
    if lsigned and (r >> (8 * lsize - 1)) & 1:
        r |= M64 ^ ((1 << (8 * lsize)) - 1)
    src = f"""
    {_lsu_setup(off)}
    li    x6, {s64(value)}
    {smn} x6, {off}(x10)
    {lmn} x7, {off}(x10)
    ecall
    """
    return src, {"store": smn, "load": lmn, "store_width": sw, "load_kind": lk,
                 "value_class": ic, "value_class_name": CLASS_NAMES[ic],
                 "align_offset": off, "value": value, "expect_x7": r}


def asm_lsu_roundtrip(f):
    """lsu_roundtrip -> store and read back at the same width (optionally twice)."""
    w = _rng(f["width"], 0, 3)
    ic, val = _cls(f, "value_class")
    oi = _rng(f["align_offset"], 0, len(ALIGN) - 1)
    off = ALIGN[oi]
    rep = _rng(f["repeat_count"], 0, 1)
    smn = ["sb", "sh", "sw", "sd"][w]
    lmn = ["lbu", "lhu", "lwu", "ld"][w]
    size = 1 << w
    value = val & M64
    expect = value & ((1 << (8 * size)) - 1)
    store2 = f"    {smn} x6, {off}(x10)\n" if rep else ""
    src = f"""
    {_lsu_setup(off)}
    li    x6, {s64(value)}
    {smn} x6, {off}(x10)
{store2}    {lmn} x7, {off}(x10)
    ecall
    """
    return src, {"store": smn, "load": lmn, "width": w, "repeat": rep,
                 "value_class": ic, "value_class_name": CLASS_NAMES[ic],
                 "align_offset": off, "value": value, "expect_x7": expect}


def asm_posit_op(f):
    """posit_op -> int -> posit, PADD/PSUB/PMUL/PDIV or unary ADAPT/ERR, back to int."""
    op = _rng(f["op_index"], 0, 5)
    ia, a = _cls(f, "a_class")
    ib, b = _cls(f, "b_class")
    rt = _rng(f["roundtrip"], 0, 1)
    opc = [NUM_PADD, NUM_PSUB, NUM_PMUL, NUM_PDIV, NUM_ADAPT, NUM_ERR][op]
    name = ["PADD", "PSUB", "PMUL", "PDIV", "ADAPT", "ERR"][op]
    lines = [f"    li    x1, {s64(a & M64)}",
             f"    .word 0x{num_insn(NUM_FROMINT, rd=1, rs1=1):08x}"]
    if op <= 3:
        lines += [f"    li    x2, {s64(b & M64)}",
                  f"    .word 0x{num_insn(NUM_FROMINT, rd=2, rs1=2):08x}",
                  f"    .word 0x{num_insn(opc, rd=3, rs1=1, rs2=2):08x}"]
    else:
        lines += [f"    .word 0x{num_insn(opc, rd=3, rs1=1):08x}"]
    if rt:
        lines += [f"    .word 0x{num_insn(NUM_TOINT, rd=7, rs1=3):08x}"]
    lines += ["    ecall"]
    src = "\n".join(lines) + "\n"
    return src, {"op": name, "op_index": op, "a_class": ia,
                 "a_class_name": CLASS_NAMES[ia], "b_class": ib,
                 "b_class_name": CLASS_NAMES[ib], "roundtrip": rt, "a": a & M64,
                 "b": b & M64, "expect_x7": None}


def asm_quire_op(f):
    """quire_op -> QCLR, accumulate n posit products, optionally QGET."""
    op = _rng(f["op_index"], 0, 5)
    n = _rng(f["accumulate_count"], 1, 8)
    ia, a = _cls(f, "a_class")
    ib, b = _cls(f, "b_class")
    rb = _rng(f["read_back"], 0, 1)
    acc = [NUM_QADD, NUM_QSUB, NUM_QMUL, NUM_QCLR, NUM_QACC, NUM_QGET][op]
    name = ["QADD", "QSUB", "QMUL", "QCLR", "QACC", "QGET"][op]
    lines = [f"    .word 0x{num_insn(NUM_QCLR):08x}"]
    if acc in (NUM_QADD, NUM_QSUB, NUM_QMUL, NUM_QACC):
        for _ in range(n):
            lines += [f"    li    x1, {s64(a & M64)}",
                      f"    .word 0x{num_insn(NUM_FROMINT, rd=1, rs1=1):08x}",
                      f"    li    x2, {s64(b & M64)}",
                      f"    .word 0x{num_insn(NUM_FROMINT, rd=2, rs1=2):08x}",
                      f"    .word 0x{num_insn(acc, rs1=1, rs2=2):08x}"]
    if rb or acc == NUM_QGET:
        lines += [f"    .word 0x{num_insn(NUM_QGET, rd=7):08x}"]
    lines += ["    ecall"]
    src = "\n".join(lines) + "\n"
    return src, {"op": name, "op_index": op, "accumulate_count": n,
                 "a_class": ia, "a_class_name": CLASS_NAMES[ia],
                 "b_class": ib, "b_class_name": CLASS_NAMES[ib],
                 "read_back": rb, "a": a & M64, "b": b & M64, "expect_x7": None}


def asm_numeric_roundtrip(f):
    """numeric_roundtrip -> int -> posit -> (quire) -> int across the conversion edges."""
    path = _rng(f["path"], 0, 2)
    ia, a = _cls(f, "a_class")
    ib, b = _cls(f, "b_class")
    chain = _rng(f["chain_length"], 0, 2) + 1   # field is 0..2, meaning 1..3 ops
    lines = [f"    li    x1, {s64(a & M64)}",
             f"    .word 0x{num_insn(NUM_FROMINT, rd=1, rs1=1):08x}"]
    if path == 0:
        # int -> posit -> (chain of PADD) -> int
        for _ in range(chain):
            lines += [f"    .word 0x{num_insn(NUM_PADD, rd=3, rs1=1, rs2=1):08x}"]
        lines += [f"    .word 0x{num_insn(NUM_TOINT, rd=7, rs1=3):08x}"]
    else:
        # int -> posit -> quire (QACC on path 1, QMUL on path 2) -> int
        acc = NUM_QACC if path == 1 else NUM_QMUL
        lines += [f"    li    x2, {s64(b & M64)}",
                  f"    .word 0x{num_insn(NUM_FROMINT, rd=2, rs1=2):08x}",
                  f"    .word 0x{num_insn(NUM_QCLR):08x}"]
        for _ in range(chain):
            lines += [f"    .word 0x{num_insn(acc, rs1=1, rs2=2):08x}"]
        lines += [f"    .word 0x{num_insn(NUM_QGET, rd=7):08x}"]
    lines += ["    ecall"]
    src = "\n".join(lines) + "\n"
    return src, {"path": path, "chain_length": chain,
                 "a_class": ia, "a_class_name": CLASS_NAMES[ia],
                 "b_class": ib, "b_class_name": CLASS_NAMES[ib],
                 "a": a & M64, "b": b & M64, "expect_x7": None}


MATRIX_BUILDERS = {
    "alu_pair": asm_alu_pair,
    "alu_imm": asm_alu_imm,
    "alu_sign_boundary": asm_alu_sign_boundary,
    "lsu_access": asm_lsu_access,
    "lsu_roundtrip": asm_lsu_roundtrip,
    "posit_op": asm_posit_op,
    "quire_op": asm_quire_op,
    "numeric_roundtrip": asm_numeric_roundtrip,
}


def build(action, fields):
    """Return (words, summary) for either model."""
    if action in MATRIX_BUILDERS:
        src, summary = MATRIX_BUILDERS[action](fields)
        words, _ = assemble(src)
        return words, summary
    words, summary = BUILDERS[action](fields)
    return words, summary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=sorted(set(BUILDERS) | set(MATRIX_BUILDERS)))
    ap.add_argument("--model", default=None,
                    help="PSS model (default: the model that defines the action)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("-o", "--out", default="-")
    a = ap.parse_args()

    model = a.model or (PSS_MATRIX if a.action in MATRIX_BUILDERS else PSS)
    fields = solve(a.action, a.seed, model)
    words, summary = build(a.action, fields)
    text = "\n".join(f"{w:08x}" for w in words) + "\n"
    if a.out == "-":
        sys.stdout.write(text)
    else:
        open(a.out, "w").write(text)
    sys.stderr.write(f"{a.action} seed={a.seed} fields={fields} -> {summary}\n")


if __name__ == "__main__":
    main()
