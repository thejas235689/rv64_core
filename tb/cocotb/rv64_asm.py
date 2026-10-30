"""
rv64_asm.py -- minimal RV64 assembler used to build directed test programs.

Covers RV64I, RV64M, Zba, Zbb, Zbc, Zbs, Zicond, Zicsr and the machine-mode
system instructions this core implements.  Encodings follow the ratified
RISC-V specifications (I 2.1, M 2.0, B 1.0, privileged 1.12).
"""

REGS = {f"x{i}": i for i in range(32)}
ABI = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1",
       "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
       "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
       "t3", "t4", "t5", "t6"]
for _i, _n in enumerate(ABI):
    REGS[_n] = _i
REGS["fp"] = 8

CSRS = {
    "mstatus": 0x300, "misa": 0x301, "fflags": 0x001, "frm": 0x002, "fcsr": 0x003, "satp": 0x180, "pmpcfg0": 0x3A0, "pmpaddr0": 0x3B0, "mhartid": 0xF14, "ncfg": 0x7C0, "nflags": 0x7C1, "nerr": 0x7C2, "xctask": 0x7D0, "qisa": 0x7E0, "aiacc": 0x7E8, "xrv512": 0x7F0, "mie": 0x304, "mtvec": 0x305,
    "mcounteren": 0x306, "mscratch": 0x340, "mepc": 0x341, "mcause": 0x342,
    "mtval": 0x343, "mip": 0x344, "pmpcfg0": 0x3A0,
    "mcycle": 0xB00, "minstret": 0xB02, "mcycleh": 0xB80, "minstreth": 0xB82,
    "mvendorid": 0xF11, "marchid": 0xF12, "mimpid": 0xF13, "mhartid": 0xF14,    # custom numeric ABI
    "ncfg": 0x7C0, "nflags": 0x7C1, "nerr": 0x7C2,

}
for _i in range(8):
    CSRS[f"pmpaddr{_i}"] = 0x3B0 + _i


def _r(f7, rs2, rs1, f3, rd, op=0x33):
    return ((f7 & 0x7F) << 25) | ((rs2 & 31) << 20) | ((rs1 & 31) << 15) | \
           ((f3 & 7) << 12) | ((rd & 31) << 7) | op


def _i(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | ((rs1 & 31) << 15) | ((f3 & 7) << 12) | \
           ((rd & 31) << 7) | op


def _s(imm, rs2, rs1, f3, op):
    imm &= 0xFFF
    return (((imm >> 5) & 0x7F) << 25) | ((rs2 & 31) << 20) | ((rs1 & 31) << 15) | \
           ((f3 & 7) << 12) | ((imm & 0x1F) << 7) | op


def _b(imm, rs2, rs1, f3, op):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
           ((rs2 & 31) << 20) | ((rs1 & 31) << 15) | ((f3 & 7) << 12) | \
           (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | op


def _u(imm, rd, op):
    return ((imm & 0xFFFFF) << 12) | ((rd & 31) << 7) | op


def _j(imm, rd, op):
    imm &= 0x1FFFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | \
           ((rd & 31) << 7) | op


# ---------------------------------------------------------------- opcode tables
R_TYPE = {
    "add": (0x00, 0), "sub": (0x20, 0), "sll": (0x00, 1), "slt": (0x00, 2),
    "sltu": (0x00, 3), "xor": (0x00, 4), "srl": (0x00, 5), "sra": (0x20, 5),
    "or": (0x00, 6), "and": (0x00, 7),
    "mul": (0x01, 0), "mulh": (0x01, 1), "mulhsu": (0x01, 2), "mulhu": (0x01, 3),
    "div": (0x01, 4), "divu": (0x01, 5), "rem": (0x01, 6), "remu": (0x01, 7),
    "andn": (0x20, 7), "orn": (0x20, 6), "xnor": (0x20, 4),
    "min": (0x05, 4), "minu": (0x05, 5), "max": (0x05, 6), "maxu": (0x05, 7),
    "clmul": (0x05, 1), "clmulr": (0x05, 2), "clmulh": (0x05, 3),
    "bset": (0x14, 1), "bclr": (0x24, 1), "binv": (0x34, 1), "bext": (0x24, 5),
    "rol": (0x30, 1), "ror": (0x30, 5),
    "sh1add": (0x10, 2), "sh2add": (0x10, 4), "sh3add": (0x10, 6),
    "czero.eqz": (0x07, 5), "czero.nez": (0x07, 7),
}
R_TYPE_W = {
    "addw": (0x00, 0), "subw": (0x20, 0), "sllw": (0x00, 1),
    "srlw": (0x00, 5), "sraw": (0x20, 5), "rolw": (0x30, 1), "rorw": (0x30, 5),
    "add.uw": (0x04, 0),
}
I_TYPE = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SHIFT_IMM = {"slli": (1, 0x00), "srli": (5, 0x00), "srai": (5, 0x10), "rori": (5, 0x18)}
SHIFT_IMM_W = {"slliw": (1, 0x00), "srliw": (5, 0x00), "sraiw": (5, 0x10), "slli.uw": (1, 0x02)}
UNARY_IMM = {"clz": 0x600, "ctz": 0x601, "cpop": 0x602, "sext.b": 0x604,
             "sext.h": 0x605, "orc.b": 0x287, "rev8": 0x6B8}
SINGLE_BIT_IMM = {"bseti": 0x0A, "bclri": 0x12, "binvi": 0x1A}  # 6-bit funct6 fields
BEXTI_F6 = 0x12
LOADS = {"lb": 0, "lh": 1, "lw": 2, "ld": 3, "lbu": 4, "lhu": 5, "lwu": 6}
STORES = {"sb": 0, "sh": 1, "sw": 2, "sd": 3}
BRANCHES = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}
CSR_OPS = {"csrrw": 1, "csrrs": 2, "csrrc": 3, "csrrwi": 5, "csrrsi": 6, "csrrci": 7}


def _reg(tok):
    t = tok.strip()
    if t in REGS:
        return REGS[t]
    if t.startswith("x"):
        return int(t[1:])
    raise ValueError(f"bad register {tok!r}")


def _imm(tok, labels=None, here=None):
    t = tok.strip()
    if labels is not None and t in labels:
        return labels[t] - here
    return int(t, 0)


def encode(mn, ops, labels=None, here=0):
    """Encode one instruction.  ops are already tokenised strings."""
    if mn in R_TYPE:
        f7, f3 = R_TYPE[mn]
        return _r(f7, _reg(ops[2]), _reg(ops[1]), f3, _reg(ops[0]))
    if mn in R_TYPE_W:
        f7, f3 = R_TYPE_W[mn]
        return _r(f7, _reg(ops[2]), _reg(ops[1]), f3, _reg(ops[0]), op=0x3B)
    if mn == "zext.h":
        return _r(0x04, 0, _reg(ops[1]), 4, _reg(ops[0]))
    if mn in I_TYPE:
        return _i(_imm(ops[2], labels, here), _reg(ops[1]), I_TYPE[mn], _reg(ops[0]), 0x13)
    if mn in SHIFT_IMM:
        f3, f6 = SHIFT_IMM[mn]
        return _i((f6 << 6) | (_imm(ops[2], labels, here) & 0x3F),
                  _reg(ops[1]), f3, _reg(ops[0]), 0x13)
    if mn in SHIFT_IMM_W:
        f3, f6 = SHIFT_IMM_W[mn]
        return _i((f6 << 6) | (_imm(ops[2], labels, here) & 0x1F),
                  _reg(ops[1]), f3, _reg(ops[0]), 0x1B)
    if mn in UNARY_IMM:
        f3 = 5 if mn in ("orc.b", "rev8") else 1
        return _i(UNARY_IMM[mn], _reg(ops[1]), f3, _reg(ops[0]), 0x13)
    if mn == "bexti":
        return _i((BEXTI_F6 << 6) | (_imm(ops[2], labels, here) & 0x3F),
                  _reg(ops[1]), 5, _reg(ops[0]), 0x13)
    if mn in SINGLE_BIT_IMM:
        f6 = SINGLE_BIT_IMM[mn]
        return _i((f6 << 6) | (_imm(ops[2], labels, here) & 0x3F),
                  _reg(ops[1]), 1, _reg(ops[0]), 0x13)
    if mn == "addiw":
        return _i(_imm(ops[2], labels, here), _reg(ops[1]), 0, _reg(ops[0]), 0x1B)
    if mn in LOADS:
        return _i(_imm(ops[1].split("(")[0] or "0", labels, here),
                  _reg(ops[1].split("(")[1].rstrip(")")), LOADS[mn], _reg(ops[0]), 0x03)
    if mn in STORES:
        return _s(_imm(ops[1].split("(")[0] or "0", labels, here),
                  _reg(ops[0]), _reg(ops[1].split("(")[1].rstrip(")")), STORES[mn], 0x23)
    if mn in BRANCHES:
        return _b(_imm(ops[2], labels, here), _reg(ops[1]), _reg(ops[0]), BRANCHES[mn], 0x63)
    if mn == "lui":
        return _u(_imm(ops[1], labels, here), _reg(ops[0]), 0x37)
    if mn == "auipc":
        return _u(_imm(ops[1], labels, here), _reg(ops[0]), 0x17)
    if mn == "jal":
        if len(ops) == 1:
            return _j(_imm(ops[0], labels, here), 1, 0x6F)
        return _j(_imm(ops[1], labels, here), _reg(ops[0]), 0x6F)
    if mn == "jalr":
        if len(ops) == 1:
            return _i(0, _reg(ops[0]), 0, 1, 0x67)
        if "(" in ops[1]:
            off = ops[1].split("(")[0] or "0"
            return _i(_imm(off, labels, here), _reg(ops[1].split("(")[1].rstrip(")")),
                      0, _reg(ops[0]), 0x67)
        return _i(_imm(ops[2], labels, here), _reg(ops[1]), 0, _reg(ops[0]), 0x67)
    if mn in CSR_OPS:
        f3 = CSR_OPS[mn]
        csr = CSRS[ops[1]] if ops[1] in CSRS else int(ops[1], 0)
        src = int(ops[2], 0) if mn.endswith("i") else _reg(ops[2])
        return _i(csr, src, f3, _reg(ops[0]), 0x73)
    if mn == "ecall":
        return 0x00000073
    if mn == "ebreak":
        return 0x00100073
    if mn == "mret":
        return 0x30200073
    if mn == "wfi":
        return 0x10500073
    if mn == "fence":
        return 0x0FF0000F
    if mn == "fence.i":
        return 0x0000100F
    if mn == "pause":
        return 0x0100000F
    if mn == "nop":
        return _i(0, 0, 0, 0, 0x13)
    raise ValueError(f"unknown mnemonic {mn!r}")


def assemble(src):
    """Assemble a multi-line string.  Returns (list_of_words, labels).

    The stream is built byte-accurately so `.hword` can emit a compressed
    instruction and the next instruction lands at pc+2, which is what a straddle
    test needs.  Everything is packed into 32-bit words at the end.
    """
    labels = {}
    stream = bytearray()
    pending = []          # (mnemonic, operands, byte offset)

    for raw in src.splitlines():
        line = raw.split("#")[0].strip()
        if not line:
            continue
        while line.endswith(":"):
            labels[line[:-1]] = len(stream)
            line = ""
        if not line:
            continue
        if ":" in line and not line.startswith("."):
            head, rest = line.split(":", 1)
            labels[head.strip()] = len(stream)
            line = rest.strip()
            if not line:
                continue
        if line.startswith(".word"):
            for w in line.split()[1:]:
                stream += (int(w, 0) & 0xFFFFFFFF).to_bytes(4, "little")
            continue
        if line.startswith(".hword"):
            for h in line.split()[1:]:
                stream += (int(h, 0) & 0xFFFF).to_bytes(2, "little")
            continue
        pending.append((line.split()[0], line.split()[1:], len(stream)))
        stream += b"\x00\x00\x00\x00"   # placeholder, encoded below

    # encode the real instructions into their reserved slots
    for mn, ops, off in pending:
        flat = []
        for o in ops:
            flat.extend([q.strip() for q in o.split(",") if q.strip()])
        w = encode(mn, flat, labels, off) & 0xFFFFFFFF
        stream[off:off + 4] = w.to_bytes(4, "little")

    while len(stream) % 4:
        stream += b"\x00"
    words = [int.from_bytes(stream[i:i + 4], "little") for i in range(0, len(stream), 4)]
    return words, labels
