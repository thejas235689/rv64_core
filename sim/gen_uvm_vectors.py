#!/usr/bin/env python3
"""
gen_uvm_vectors.py -- generate golden vectors for the UVM environment.

The reference model is the same independent Python ISS that backs the cocotb
regression (tb/cocotb/rv64_iss.py), so the UVM scoreboard checks the DUT against
a model that was itself validated separately, rather than against a second
hand-written copy of the ISA inside the UVM code.

For each program it writes, into sim/uvm_vectors/:

    <name>.prog.hex      program image, 64-bit words (two 32-bit insns each)
    <name>.retire.hex    5 numbers per retirement: pc insn we waddr wdata
    <name>.trap.hex      2 numbers per trap:       pc cause
    <name>.counts.hex    expected retirement count, expected trap count
"""

import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tb", "cocotb"))

from rv64_asm import assemble          # noqa: E402
from rv64_iss import ISS              # noqa: E402

OUT = os.path.join(HERE, "uvm_vectors")
CAUSE_ECALL_M = 11


# --------------------------------------------------------------------------- programs
ALU_PROG = """
    lui   x1, 0x12345
    addi  x2, x0, 0x7ff
    addi  x3, x0, -1
    addi  x4, x0, 0
    addi  x5, x0, 1
    addi  x6, x0, 63
    add   x8, x1, x2
    sub   x9, x1, x2
    sll   x10, x5, x6
    slt   x11, x3, x5
    sltu  x12, x3, x5
    xor   x13, x1, x2
    srl   x14, x3, x6
    sra   x15, x3, x6
    or    x16, x1, x2
    and   x17, x1, x2
    srai  x23, x3, 3
    addw  x25, x1, x2
    subw  x26, x1, x2
    sraw  x29, x1, x6
    andn  x5, x1, x2
    orn   x6, x1, x2
    xnor  x7, x1, x2
    min   x8, x1, x3
    maxu  x11, x1, x3
    clz   x15, x1
    ctz   x16, x1
    cpop  x17, x1
    rol   x21, x1, x6
    ror   x22, x1, x6
    rev8  x26, x1
    orc.b x27, x1
    bset  x29, x1, x6
    bclr  x1, x3, x6
    bext  x3, x3, x6
    sh1add x8, x1, x2
    add.uw x11, x1, x2
    clmul x13, x1, x2
    czero.eqz x16, x1, x4
    czero.nez x17, x1, x5
    mul   x20, x1, x2
    div   x21, x1, x2
    remu  x22, x1, x2
    add   x0, x1, x2
    ecall
"""

MEM_PROG = """
    lui   x30, 0x2
    addi  x1, x0, 0x123
    sd    x1, 0(x30)
    ld    x2, 0(x30)
    sw    x1, 8(x30)
    lw    x3, 8(x30)
    lwu   x4, 8(x30)
    sh    x1, 16(x30)
    lh    x5, 16(x30)
    lhu   x6, 16(x30)
    sb    x1, 24(x30)
    lb    x7, 24(x30)
    lbu   x8, 24(x30)
    addi  x11, x0, -1
    sd    x11, 32(x30)
    ld    x12, 32(x30)
    sb    x11, 48(x30)
    lb    x15, 48(x30)
    lbu   x16, 48(x30)
    add   x20, x12, x11
    sd    x20, 64(x30)
    ld    x21, 64(x30)
    ecall
"""

TRAP_BODY = """
    lui   x5, 0x1
    csrrw x0, mtvec, x5
    addi  x1, x0, 1
    .word 0x00000000
    addi  x2, x0, 2
    csrrw x9, 0x999, x0
    addi  x3, x0, 3
    ld    x10, 4(x0)
    addi  x11, x0, 4
    sd    x11, 2(x0)
    ecall
done:
    jal   x0, done
"""

TRAP_HANDLER = """
    csrrs x20, mcause, x0
    csrrs x21, mepc, x0
    csrrs x22, mtval, x0
    addi  x21, x21, 4
    csrrw x0, mepc, x21
    mret
"""


def pad_to(src, target_addr, fill="nop"):
    words, _ = assemble(src)
    n = (target_addr - 4 * len(words)) // 4
    assert n >= 0, f"program already past {target_addr:#x}"
    if not src.endswith("\n"):
        src += "\n"
    return src + (fill + "\n") * n


def random_program(n_insns, seed):
    rnd = random.Random(seed)
    r_ops = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
             "andn", "orn", "xnor", "min", "max", "minu", "maxu", "rol", "ror",
             "sh1add", "clmul", "czero.eqz", "czero.nez", "bset", "bclr", "bext"]
    w_ops = ["addw", "subw", "sllw", "srlw", "sraw", "rolw", "rorw"]
    mdu = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
    i_ops = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
    sh = ["slli", "srli", "srai", "rori"]
    un = ["clz", "ctz", "cpop", "sext.b", "sext.h", "zext.h", "rev8", "orc.b"]
    mem = [("ld", 8), ("sd", 8), ("lw", 4), ("sw", 4), ("lh", 2), ("sh", 2),
           ("lb", 1), ("sb", 1), ("lbu", 1), ("lhu", 2), ("lwu", 4)]

    lines = ["lui x30, 0x2"]
    for r in range(1, 28):
        lines.append(f"addi x{r}, x0, {rnd.randint(-2048, 2047)}")
    for _ in range(n_insns):
        k = rnd.random()
        rd = rnd.choice([0] + list(range(1, 30)))
        rs1 = rnd.randint(0, 30)
        rs2 = rnd.randint(0, 30)
        if k < 0.34:
            lines.append(f"{rnd.choice(r_ops)} x{rd}, x{rs1}, x{rs2}")
        elif k < 0.44:
            lines.append(f"{rnd.choice(w_ops)} x{rd}, x{rs1}, x{rs2}")
        elif k < 0.52:
            lines.append(f"{rnd.choice(mdu)} x{rd}, x{rs1}, x{rs2}")
        elif k < 0.68:
            lines.append(f"{rnd.choice(i_ops)} x{rd}, x{rs1}, {rnd.randint(-2048, 2047)}")
        elif k < 0.76:
            lines.append(f"{rnd.choice(sh)} x{rd}, x{rs1}, {rnd.randint(0, 63)}")
        elif k < 0.82:
            lines.append(f"{rnd.choice(un)} x{rd}, x{rs1}")
        else:
            op, size = rnd.choice(mem)
            off = rnd.randrange(0, 512, size)
            lines.append(f"{op} x{rd}, {off}(x30)")
    lines.append("ecall")
    return "\n".join(lines)


# --------------------------------------------------------------------------- emit
def write_prog(path, words):
    lines = []
    for i in range(0, len(words), 2):
        lo = words[i]
        hi = words[i + 1] if i + 1 < len(words) else 0
        lines.append(f"{(hi << 32) | lo:016x}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def build(name, src):
    words, _ = assemble(src)
    iss = ISS()
    iss.load_words(0, words)

    retire = []
    traps = []
    steps = 0
    while steps < 60000:
        r = iss.step()
        steps += 1
        if r is not None:
            retire.append(r)
        if iss.trap_log:
            traps.append(iss.trap_log[-1])
            iss.trap_log.clear()
            if traps[-1][1] == CAUSE_ECALL_M:
                break

    write_prog(os.path.join(OUT, f"{name}.prog.hex"), words)

    with open(os.path.join(OUT, f"{name}.retire.hex"), "w") as f:
        for pc, insn, rd, wdata in retire:
            we = 0 if rd is None else 1
            waddr = 0 if rd is None else rd
            wd = 0 if rd is None else wdata
            f.write(f"{pc:016x} {insn:08x} {we:01x} {waddr:02x} {wd:016x}\n")

    with open(os.path.join(OUT, f"{name}.trap.hex"), "w") as f:
        for pc, cause in traps:
            f.write(f"{pc:016x} {cause:016x}\n")

    with open(os.path.join(OUT, f"{name}.counts.hex"), "w") as f:
        f.write(f"{len(retire):x} {len(traps):x}\n")

    print(f"  {name:8s} {len(words):4d} words  {len(retire):5d} retirements  "
          f"{len(traps):2d} traps")


BITMANIP_PROG = """
  lui   x5, 0x12345
  addi  x5, x5, 0x678
  addi  x6, x0, 7
  slli  x7, x5, 3
  sh1add x8, x5, x6
  clz   x9, x5
  ctz   x10, x5
  cpop  x11, x5
  clmul x12, x5, x6
  andn  x13, x5, x6
  orn   x14, x5, x6
  xnor  x15, x5, x6
  min   x16, x5, x6
  max   x17, x5, x6
  rol   x18, x5, x6
  ror   x19, x5, x6
  bclr  x20, x5, x6
  bext  x21, x5, x6
  binv  x22, x5, x6
  ecall
"""

CSR_PROG = """
  addi  x5, x0, 0x123
  csrrw x0, mscratch, x5
  csrrs x6, mscratch, x0
  csrrs x7, mscratch, x0
  csrrc x8, mscratch, x0
  csrrs x9, misa, x0
  csrrs x10, mhartid, x0
  csrrs x11, mstatus, x0
  addi  x12, x0, 0x5
  csrrw x0, fcsr, x12
  csrrs x13, fcsr, x0
  csrrs x14, fflags, x0
  csrrs x15, frm, x0
  ecall
"""


PMP_PROG = """
  lui   x5, 0x80000
  srli  x5, x5, 12
  csrrw x0, pmpaddr0, x5
  addi  x6, x0, 0x0F
  csrrw x0, pmpcfg0, x6
  csrrs x7, pmpcfg0, x0
  csrrs x8, pmpaddr0, x0
  ecall
"""

ATOMIC_PROG = """
  lui   x10, 0x100
  addi  x5, x0, 42
  sd    x5, 0(x10)
  .word 0x005533af          # amoadd.d x7, x5, (x10)
  .word 0x085533af          # amoswap.d x7, x5, (x10)
  .word 0x205533af          # amoxor.d x7, x5, (x10)
  .word 0x605533af          # amoand.d x7, x5, (x10)
  .word 0x405533af          # amoor.d x7, x5, (x10)
  .word 0x805533af          # amomin.d x7, x5, (x10)
  .word 0xa05533af          # amomax.d x7, x5, (x10)
  .word 0xc05533af          # amominu.d x7, x5, (x10)
  .word 0xe05533af          # amomaxu.d x7, x5, (x10)
  .word 0x100538af          # lr.d x17, (x10)
  .word 0x1855392f          # sc.d x18, x5, (x10)
  ecall
"""

ZIFENCEI_PROG = """
  lui   x10, 0x100
  addi  x5, x0, 7
  sd    x5, 0(x10)
  fence.i
  ld    x6, 0(x10)
  addi  x7, x0, 9
  fence
  addi  x8, x0, 11
  ecall
"""

MEMWIDTH_PROG = """
  lui   x10, 0x100
  addi  x5, x0, 0x7F
  sb    x5, 0(x10)
  lbu   x6, 0(x10)
  lb    x7, 0(x10)
  sh    x5, 2(x10)
  lhu   x8, 2(x10)
  lh    x9, 2(x10)
  sw    x5, 4(x10)
  lwu   x11, 4(x10)
  lw    x12, 4(x10)
  sd    x5, 8(x10)
  ld    x13, 8(x10)
  ecall
"""


# Encodings the assembler has no mnemonics for are written as .word, with the
# meaning in a comment so the program stays readable.
SV39_PROG = """
  lui   x10, 0x100
  addi  x5, x0, 0x55
  sd    x5, 0(x10)
  ld    x6, 0(x10)
  .word 0x12000073          # sfence.vma x0, x0
  csrrs x7, satp, x0
  ld    x8, 0(x10)
  .word 0x12000073          # sfence.vma again after the reload
  ld    x9, 8(x10)
  ecall
"""

CACHE_PROG = """
  lui   x10, 0x100
  addi  x5, x0, 1
  sd    x5, 0(x10)
  ld    x6, 0(x10)
  ld    x7, 0(x10)
  ld    x8, 0(x10)
  addi  x9, x0, 2
  sd    x9, 64(x10)
  ld    x11, 64(x10)
  ld    x12, 64(x10)
  addi  x13, x0, 3
  sd    x13, 128(x10)
  ld    x14, 128(x10)
  ecall
"""

DEBUG_PROG = """
  addi  x5, x0, 11
  addi  x6, x0, 22
  .word 0x00100073          # ebreak -> debug entry
  addi  x7, x0, 33
  ecall
"""

RVV_PROG = """
  lui   x10, 0x100
  .word 0x0C007057          # vsetvli x0, x0, e64, m1
  .word 0x02053207          # vle64.v v4, (x10)
  .word 0x02428257          # vle64.v v4, (x5)  -- placeholder second load
  .word 0x020502D7          # vse64.v v4, (x10)
  ecall
"""

XCETASK_PROG = """
  addi  x5, x0, 0x11
  .word 0x7D02A073          # csrrs x0, 0x7D0, x5   (xcetask window)
  .word 0x7D0022F3          # csrrs x5, 0x7D0, x0
  addi  x6, x0, 0x22
  .word 0x7D02A073          # csrrs x0, 0x7D0, x5
  .word 0x7D002373          # csrrs x6, 0x7D0, x0
  ecall
"""

FRONTEND_PROG = """
  lui   x10, 0x100
  addi  x5, x0, 3
  sd    x5, 0(x10)
  ld    x6, 0(x10)
  .word 0x00000013          # nop
  .word 0x00000013          # nop
  ld    x7, 0(x10)
  addi  x8, x0, 4
  .word 0x00000013          # nop between dependent ops
  add   x9, x7, x8
  ecall
"""


SV39_BODY = """
  lui   x5, 0x1
  csrrw x0, mtvec, x5
  lui   x10, 0x100
  addi  x6, x0, 0x55
  sd    x6, 0(x10)
  ld    x7, 0(x10)
  .word 0x12000073          # sfence.vma x0, x0
  csrrs x8, satp, x0
  ld    x9, 0(x10)
  .word 0x12000073          # sfence.vma again
  ld    x11, 8(x10)
  ecall
"""

DEBUG_BODY = """
  lui   x5, 0x1
  csrrw x0, mtvec, x5
  addi  x6, x0, 11
  addi  x7, x0, 22
  .word 0x00100073          # ebreak -> handler advances mepc by 4
  addi  x8, x0, 33
  addi  x9, x0, 44
  ecall
"""

RVV_BODY = """
  lui   x5, 0x1
  csrrw x0, mtvec, x5
  lui   x10, 0x100
  .word 0x0C007057          # vsetvli x0, x0, e64, m1
  .word 0x02057207          # vle64.v v4, (x10)
  .word 0x020502D7          # vse64.v v4, (x10)
  ld    x7, 0(x10)
  ecall
"""

XCETASK_BODY = """
  lui   x5, 0x1
  csrrw x0, mtvec, x5
  addi  x6, x0, 0x11
  .word 0x7D032073          # csrrs x0, 0x7D0, x6
  .word 0x7D002373          # csrrs x6, 0x7D0, x0
  addi  x7, x0, 0x22
  .word 0x7D03A073          # csrrs x0, 0x7D0, x7
  .word 0x7D0033F3          # csrrs x7, 0x7D0, x0
  ecall
"""

def main():
    os.makedirs(OUT, exist_ok=True)
    print("generating UVM golden vectors from the Python ISS:")
    build("alu", ALU_PROG)
    build("mem", MEM_PROG)
    build("trap", pad_to(TRAP_BODY, 0x1000, ".word 0") + TRAP_HANDLER)
    build("random", random_program(120, 7))
    build("bitmanip", BITMANIP_PROG)
    build("csr", CSR_PROG)
    build("pmp", PMP_PROG)
    build("atomic", ATOMIC_PROG)
    build("zifencei", ZIFENCEI_PROG)
    build("memwidth", MEMWIDTH_PROG)
    build("cache", CACHE_PROG)
    build("frontend", FRONTEND_PROG)
    build("sv39", pad_to(SV39_BODY, 0x1000, ".word 0") + TRAP_HANDLER)
    build("debug", pad_to(DEBUG_BODY, 0x1000, ".word 0") + TRAP_HANDLER)
    build("rvv", pad_to(RVV_BODY, 0x1000, ".word 0") + TRAP_HANDLER)
    build("xcetask", pad_to(XCETASK_BODY, 0x1000, ".word 0") + TRAP_HANDLER)
    print(f"vectors written to {OUT}")


if __name__ == "__main__":
    main()
