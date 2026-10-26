#!/usr/bin/env python3
"""
gen_isa_sweep.py -- systematic ISA sweep for the UVM regression.

"All combinations" is made concrete and finite by exhausting each instruction's
own dimension rather than a meaningless full cross product:

  * every shift/rotate amount 0..63, for every shift instruction
  * every bit index 0..63, for every single-bit instruction
  * every load/store width x every byte-lane offset 0..7
  * every branch polarity x operand pairs (taken and not taken)
  * every MDU operation x an operand matrix including div-by-zero and INT_MIN/-1
  * every ALU operation x an operand matrix of boundary values
  * every implemented CSR, read and read-modify-write
  * every unimplemented major opcode and the reserved funct3/funct7 combinations,
    each expected to trap as illegal

Operands come from a register pool loaded once, so the program is test
instructions rather than setup instructions.

Emits, into sim/uvm_vectors/, the usual four files per program:
  <name>.prog.hex .retire.hex .trap.hex .counts.hex
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tb", "cocotb"))

from rv64_asm import assemble, CSRS        # noqa: E402
from rv64_iss import ISS                   # noqa: E402

OUT = os.path.join(HERE, "uvm_vectors")
CAUSE_ECALL_M = 11
M64 = (1 << 64) - 1

# ---- operand pool -----------------------------------------------------------
EDGE = [
    0,
    1,
    0xFFFF_FFFF_FFFF_FFFF,          # -1
    0x7FFF_FFFF_FFFF_FFFF,          # INT64_MAX
    0x8000_0000_0000_0000,          # INT64_MIN
    0xFFFF_FFFF_0000_0000,          # high word set
]
SHAMTS = [0, 1, 2, 3, 31, 32, 63, 64]

POOL_BASE = 20                       # x20..x27 hold EDGE
SH_BASE = 5                          # x5..x12 hold SHAMTS
DATA_REG = 19                        # x19 = 0x2000, data base


def li(rd, v):
    """load a 64-bit constant without an li pseudo-instruction"""
    v &= M64
    sv = v - (1 << 64) if v >> 63 else v
    if -2048 <= sv <= 2047:
        return [f"addi x{rd}, x0, {sv}"]
    hi = (v + 0x800) >> 12
    lo = v - (hi << 12)
    out = [f"lui x{rd}, {hi & 0xFFFFF}"]
    if lo:
        out.append(f"addi x{rd}, x{rd}, {lo}")
    return out


R_TYPE = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
          "andn", "orn", "xnor", "min", "minu", "max", "maxu",
          "rol", "ror", "sh1add", "sh2add", "sh3add", "add.uw",
          "clmul", "clmulr", "clmulh", "czero.eqz", "czero.nez",
          "bset", "bclr", "binv", "bext", "zext.h"]
R_TYPE_W = ["addw", "subw", "sllw", "srlw", "sraw", "rolw", "rorw"]
MDU_OPS = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
UNARY = ["clz", "ctz", "cpop", "sext.b", "sext.h", "rev8", "orc.b"]
SINGLE_BIT_IMM = ["bseti", "bclri", "binvi", "bexti"]
LOADS = ["ld", "lw", "lwu", "lh", "lhu", "lb", "lbu"]
STORES = ["sd", "sw", "sh", "sb"]
BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
SIZE_OF = {"ld": 8, "sd": 8, "lw": 4, "sw": 4, "lwu": 4,
           "lh": 2, "sh": 2, "lhu": 2, "lb": 1, "lbu": 1, "sb": 1}


def rd_for(i):
    """cycle the destination across x1..x19, and hit x0 regularly"""
    return 0 if (i % 17 == 0) else (i % 19) + 1


def li2(rd, v):
    """always exactly two instructions, so handler placement is computable"""
    v &= M64
    hi = (v + 0x800) >> 12
    lo = v - (hi << 12)
    return [f"lui x{rd}, {hi & 0xFFFFF}", f"addi x{rd}, x{rd}, {lo}"]


def build_isa_program(small=False):
    """small=True emits a reduced sweep (~400 instructions) that the UVM
    wrapper can complete at its current driver throughput."""
    n_edge   = 2 if small else len(EDGE)
    sh_max   = 4 if small else 64
    wsh_max  = 4 if small else 32
    bit_max  = 4 if small else 64
    L = []
    L.append("# ---- operand pool ----")
    for i, v in enumerate(EDGE):
        L.extend(li(POOL_BASE + i, v))
    for i, s in enumerate(SHAMTS):
        L.extend(li(SH_BASE + i, s))
    L.extend(li(DATA_REG, 0x2000))
    n = 0

    # ---- every ALU op across the operand matrix ----------------------------
    L.append("# ---- ALU: every op x operand matrix ----")
    for op in R_TYPE + R_TYPE_W + MDU_OPS:
        for a in range(n_edge):
            for b in range(n_edge):
                L.append(f"{op} x{rd_for(n)}, x{POOL_BASE+a}, x{POOL_BASE+b}")
                n += 1

    # ---- immediate forms across boundary immediates ------------------------
    L.append("# ---- I-type: every op x boundary immediates ----")
    for op in I_OPS:
        for a in range(n_edge):
            for imm in (0, 1, -1, 2047, -2048):
                L.append(f"{op} x{rd_for(n)}, x{POOL_BASE+a}, {imm}")
                n += 1

    # ---- every shift amount 0..63, immediate and register -----------------
    L.append("# ---- shifts: every immediate amount 0..63 ----")
    for op in ["slli", "srli", "srai", "rori"]:
        for a in range(3):
            for s in range(sh_max):
                L.append(f"{op} x{rd_for(n)}, x{POOL_BASE+a}, {s}")
                n += 1
    for op in ["slliw", "srliw", "sraiw"]:
        for a in range(3):
            for s in range(wsh_max):
                L.append(f"{op} x{rd_for(n)}, x{POOL_BASE+a}, {s}")
                n += 1
    L.append("# ---- shifts: register amounts from the shift pool ----")
    for op in ["sll", "srl", "sra", "rol", "ror"]:
        for a in range(n_edge):
            for si in range(len(SHAMTS)):
                L.append(f"{op} x{rd_for(n)}, x{POOL_BASE+a}, x{SH_BASE+si}")
                n += 1

    # ---- every bit index 0..63 on the immediate forms ---------------------
    L.append("# ---- single-bit: every index 0..63 (immediate forms) ----")
    for op in SINGLE_BIT_IMM:
        for a in range(3):
            for b in range(bit_max):
                L.append(f"{op} x{rd_for(n)}, x{POOL_BASE+a}, {b}")
                n += 1
    L.append("# ---- single-bit: register forms over the shift pool ----")
    for op in ["bset", "bclr", "binv", "bext"]:
        for a in range(n_edge):
            for si in range(len(SHAMTS)):
                L.append(f"{op} x{rd_for(n)}, x{POOL_BASE+a}, x{SH_BASE+si}")
                n += 1

    # ---- unary ops over the operand matrix --------------------------------
    L.append("# ---- unary ops ----")
    for op in UNARY:
        for a in range(n_edge):
            L.append(f"{op} x{rd_for(n)}, x{POOL_BASE+a}")
            n += 1

    # ---- loads and stores: every width x every byte lane ------------------
    L.append("# ---- memory: every width x every byte lane ----")
    for op in STORES:
        for off in range(8):
            L.append(f"{op} x{POOL_BASE+off % len(EDGE)}, {off}(x{DATA_REG})")
            n += 1
    for op in LOADS:
        size = SIZE_OF[op]
        for off in range(0, 8, size):
            L.append(f"{op} x{rd_for(n)}, {off}(x{DATA_REG})")
            n += 1

    # ---- every branch polarity, taken and not taken ----------------------
    L.append("# ---- branches: every polarity, both outcomes ----")
    for op in BRANCHES:
        for a, b in ((0, 1), (1, 0), (2, 2), (3, 4), (4, 3), (5, 5)):
            L.append(f"{op} x{POOL_BASE+a}, x{POOL_BASE+b}, bskip_{n}")
            L.append(f"addi x{rd_for(n)}, x0, 1")
            L.append(f"bskip_{n}: addi x{rd_for(n+1)}, x0, 2")
            n += 2

    # ---- jumps ------------------------------------------------------------
    L.append("# ---- jumps ----")
    L.append("jal x1, jtarget")
    L.append("addi x2, x0, 0x123")
    L.append("jtarget: jalr x0, 0(x1)")

    # ---- every implemented CSR -------------------------------------------
    L.append("# ---- CSRs ----")
    for name in sorted(CSRS):
        if name in ("mcycle", "minstret", "mcycleh", "minstreth"):
            continue                      # free-running, not value-compared
        if name in ("ncfg", "nflags", "nerr"):
            continue                      # numeric CSRs: the ISS does not model
                                          # them, so including them makes the
                                          # golden vectors diverge from the DUT.
                                          # They are covered by test_numeric_abi.
        L.append(f"csrrs x{rd_for(n)}, {name}, x0")
        n += 1
        # mtvec is excluded from the write sweep: clobbering it would send every
        # later trap to a garbage vector and the program would never terminate
        if name in ("mstatus", "mie", "mscratch", "mepc", "mcause",
                    "mtval", "pmpcfg0", "pmpaddr0", "pmpaddr1"):
            L.append(f"csrrw x0, {name}, x{POOL_BASE+2}")
            L.append(f"csrrs x{rd_for(n)}, {name}, x0")
            n += 1

    L.append("ecall")
    return "\n".join(L)


def build_illegal_program():
    """Every unimplemented major opcode and reserved sub-encoding must trap."""
    # 0x0B (custom-0) is implemented by the numeric ABI and must not be listed
    # as illegal; the ISS has no numeric model, so it would disagree with the
    # DUT on every such encoding
    implemented = {0x37, 0x17, 0x6F, 0x67, 0x63, 0x03, 0x23, 0x13, 0x33,
                   0x1B, 0x3B, 0x0F, 0x73, 0x0B}
    L = []

    # one instruction per unimplemented major opcode
    for op in range(128):
        if op in implemented:
            continue
        word = (op) | (1 << 7) | (1 << 12) | (1 << 15) | (1 << 20)
        L.append(f".word 0x{word:08x}")

    # reserved sub-encodings inside implemented opcodes
    for word in (
        0x00000000,      # all zero
        0xFFFFFFFF,      # all ones
        0x0000707F,      # OP funct7 = 0x7F
        0x00007013,      # OP-IMM funct3=000 with bad funct7 high bits
        0x0000701B,      # OP-IMM-32 bad funct6
        0x0000703B,      # OP-32 bad funct7
        0x00007063,      # BRANCH funct3=010 (reserved)
        0x00007003,      # LOAD funct3=111 (reserved)
        0x00007023,      # STORE funct3=111 (reserved)
        0x00007067,      # JALR funct3=001 (reserved)
        0x0000700F,      # MISC-MEM funct3=010 (reserved)
        0x00000073,      # SYSTEM funct3=000 imm=0 is ecall: legal, kept as control
        0x7B200073,      # SYSTEM with a reserved funct3
        0x00007073,      # SYSTEM funct3=111 with imm 0 (reserved)
    ):
        if word == 0x00000073:
            L.append("ecall")            # control: legal, must not trap as illegal
        else:
            L.append(f".word 0x{word:08x}")

    L.append("ecall")
    return "\n".join(L)


HANDLER = """
    csrrs x28, mcause, x0
    csrrs x29, mepc, x0
    addi  x29, x29, 4
    csrrw x0, mepc, x29
    mret
"""


def pad_to(src, target, fill="nop"):
    words, _ = assemble(src)
    n = (target - 4 * len(words)) // 4
    assert n >= 0, f"program already past {target:#x}"
    if not src.endswith("\n"):
        src += "\n"
    return src + (fill + "\n") * n


def emit(name, src, max_retire):
    """Record exactly max_retire retirements and every trap seen meanwhile.

    The window is bounded by retirement count rather than by a terminating
    instruction: a program that traps into a handler interleaves traps and
    retirements, so "run until ecall" is not a reliable stop condition. Both
    models execute the same deterministic program, so a fixed retirement count
    defines the same comparison window on both sides.
    """
    words, _ = assemble(src)
    iss = ISS()
    iss.load_words(0, words)

    retire, traps = [], []
    steps = 0
    while len(retire) < max_retire and steps < 2000000:
        r = iss.step()
        steps += 1
        if r is not None:
            retire.append(r)
        if iss.trap_log:
            traps.append(iss.trap_log[-1])
            iss.trap_log.clear()

    lines = []
    for i in range(0, len(words), 2):
        lo = words[i]
        hi = words[i + 1] if i + 1 < len(words) else 0
        lines.append(f"{(hi << 32) | lo:016x}")
    open(os.path.join(OUT, f"{name}.prog.hex"), "w").write("\n".join(lines) + "\n")

    with open(os.path.join(OUT, f"{name}.retire.hex"), "w") as f:
        for pc, insn, rd, wdata in retire:
            we = 0 if rd is None else 1
            f.write(f"{pc:016x} {insn:08x} {we:01x} {0 if rd is None else rd:02x} "
                    f"{0 if rd is None else wdata:016x}\n")

    with open(os.path.join(OUT, f"{name}.trap.hex"), "w") as f:
        for pc, cause in traps:
            f.write(f"{pc:016x} {cause:016x}\n")

    open(os.path.join(OUT, f"{name}.counts.hex"), "w").write(
        f"{len(retire):x} {len(traps):x}\n")

    print(f"  {name:10s} {len(words):6d} words  {len(retire):6d} retirements  "
          f"{len(traps):4d} traps  ({steps} ISS steps)")


def with_handler(body):
    """Place the trap handler after the program at a 16-byte aligned address.

    mtvec is set at the top of the program with a two-instruction constant load,
    so the setup size is fixed and the handler address can be computed from the
    body length without a fixpoint iteration.
    """
    words, _ = assemble(body)
    total = len(words) + 3                    # + 3 setup instructions
    handler_addr = ((total * 4) + 15) & ~15
    setup = li2(18, handler_addr) + ["csrrw x0, mtvec, x18"]
    prog = "\n".join(setup) + "\n" + body
    return pad_to(prog, handler_addr) + HANDLER


def main():
    os.makedirs(OUT, exist_ok=True)
    print("generating ISA sweep vectors from the Python ISS:")
    isa_src = with_handler(build_isa_program())
    isa_words, _ = assemble(isa_src)
    # the sweep is straight-line: one pass retires almost every instruction
    emit("isa", isa_src, max_retire=len(isa_words) - 1)

    small_src = with_handler(build_isa_program(small=True))
    small_words, _ = assemble(small_src)
    emit("isa_small", small_src, max_retire=len(small_words) - 1)

    ill_src = with_handler(build_illegal_program())
    ill_words, _ = assemble(ill_src)
    # each illegal word costs one trap plus the handler instructions
    emit("illegal", ill_src, max_retire=6 * len(ill_words))


if __name__ == "__main__":
    main()
