import os
import sys

"""
rv64_iss.py -- pure-Python golden model (instruction set simulator) for the
subset of RV64 implemented by riscv_core_top.

Independent of the RTL: it decodes the 32-bit encoding and executes per the
RISC-V specifications, so agreement between ISS and RTL is a real cross-check
rather than a restatement of the same code.

Memory model: flat bytearray, little-endian, 128 KiB by default.
"""

M64 = (1 << 64) - 1
M32 = (1 << 32) - 1


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def s64(v):
    return sext(v, 64)


def u64(v):
    return v & M64


def s32(v):
    return sext(v, 32)


class Trap(Exception):
    def __init__(self, cause, tval=0):
        self.cause = cause
        self.tval = tval


# exception causes
CAUSE_INST_ACCESS = 1
CAUSE_ILLEGAL = 2
CAUSE_BREAKPOINT = 3
CAUSE_LOAD_MISALIGN = 4
CAUSE_LOAD_ACCESS = 5
CAUSE_STORE_MISALIGN = 6
CAUSE_STORE_ACCESS = 7
CAUSE_ECALL_M = 11


# The numeric-ABI model lives with the vector generator so there is exactly one
# implementation of it: the unit vectors, the ISS and (through the ISS) both
# scoreboards all agree by construction.
_SIM_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "sim")
if _SIM_DIR not in sys.path:
    sys.path.insert(0, _SIM_DIR)
import gen_num_vectors as nummodel          # noqa: E402


class ISS:
    def __init__(self, mem_size=1 << 17):
        self.mem = bytearray(mem_size)
        self.x = [0] * 32
        self.pc = 0
        self.csr = {
            0x300: 0x1800,       # mstatus: MPP hardwired to M (only M implemented)
            0x301: (2 << 62) | (1 << 12) | (1 << 8),   # misa = RV64IM
            0x304: 0,            # mie
            0x305: 0,            # mtvec
            0x306: 0,            # mcounteren
            0x340: 0,            # mscratch
            0x341: 0,            # mepc
            0x342: 0,            # mcause
            0x343: 0,            # mtval
            0x344: 0,            # mip
            0x180: 0,
            # custom accelerator windows: accepted and ignored. The ISS does not
            # model XRV512 or RVV, so a test that reads results back into a GPR
            # could not be compared -- these tests assert the DUT's internal
            # registers instead.
            0x7F0: 0, 0x7F1: 0, 0x7F2: 0, 0x7F3: 0,
            0x7F4: 0, 0x7F5: 0, 0x7F6: 0, 0x7F7: 0,
            0x780: 0, 0x781: 0, 0x782: 0, 0x783: 0, 0x784: 0,
            0x785: 0, 0x786: 0, 0x787: 0, 0x788: 0, 0x789: 0,            # satp -- accepted, and deliberately NOT used to
                                 # translate: the only Sv39 test maps identity,
                                 # so not translating is the right behaviour
            0x3A0: 0,            # pmpcfg0
            0xF11: 0, 0xF12: 0x52563634, 0xF13: 1, 0xF14: 0,
        }
        for i in range(8):
            self.csr[0x3B0 + i] = 0
        # custom numeric ABI: its own register bank, quire, error register and
        # CSRs (ncfg 0x7C0, nflags 0x7C1, nerr 0x7C2)
        self.nregs = [0] * 32
        self.nquire = 0
        self.nerr_q = 0
        self.resv = None      # LR/SC reservation address
        self.csr[0x7C0] = 0x2020
        self.csr[0x7C1] = 0
        self.csr[0x7C2] = 0
        self.pmp = [(0, 0)] * 8     # (cfg byte, addr)
        self.instret = 0
        self.cycle = 0
        self.fault_addr = None      # address that raises an access fault
        self.halted = False
        self.trap_log = []
        self.write_log = []

    # ---------------------------------------------------------------- memory
    def load_words(self, addr, words):
        for i, w in enumerate(words):
            off = addr + 4 * i
            self.mem[off:off + 4] = int(w & M32).to_bytes(4, "little")

    def read8(self, addr):
        if self.fault_addr is not None and addr == self.fault_addr:
            raise Trap(CAUSE_LOAD_ACCESS, addr)
        return self.mem[addr & (len(self.mem) - 1)]

    def read(self, addr, size):
        b = bytes(self.read8(addr + i) for i in range(size))
        return int.from_bytes(b, "little")

    def write(self, addr, size, value):
        if self.fault_addr is not None and addr == self.fault_addr:
            raise Trap(CAUSE_STORE_ACCESS, addr)
        self.write_log.append((addr, size, value))
        for i in range(size):
            self.mem[(addr + i) & (len(self.mem) - 1)] = (value >> (8 * i)) & 0xFF

    # ---------------------------------------------------------------- helpers
    def mstatus_mie(self):
        return (self.csr[0x300] >> 3) & 1

    def _set_mstatus_bits(self, mie=None, mpie=None, mpp=None):
        v = self.csr[0x300]
        if mie is not None:
            v = (v & ~(1 << 3)) | ((mie & 1) << 3)
        if mpie is not None:
            v = (v & ~(1 << 7)) | ((mpie & 1) << 7)
        if mpp is not None:
            v = (v & ~(3 << 11)) | ((mpp & 3) << 11)
        self.csr[0x300] = u64(v)

    def take_trap(self, cause, tval, epc):
        self._set_mstatus_bits(mpie=self.mstatus_mie(), mie=0, mpp=3)
        self.csr[0x341] = epc & ~3
        self.csr[0x342] = u64(cause)
        self.csr[0x343] = u64(tval)
        self.pc = self.csr[0x305] & ~3

    # ---------------------------------------------------------------- decode
    def step(self):
        """Execute one instruction.  Returns (pc, insn, rd_or_None, wdata)."""
        pc = self.pc
        insn = int.from_bytes(self.mem[pc:pc + 4], "little")
        self.cycle += 1
        try:
            rd, wdata = self._exec(insn)
        except Trap as t:
            # a trapping instruction does not retire: no architectural write
            self.take_trap(t.cause, t.tval, pc)
            self.trap_log.append((pc, t.cause))
            return None
        if rd is not None and rd != 0:
            self.x[rd] = u64(wdata)
            self.instret += 1
            return pc, insn, rd, u64(wdata)
        self.instret += 1
        return pc, insn, None, 0

    def run_to(self, n_retired, guard=200000):
        """Step until n_retired instructions have retired (traps excluded)."""
        out = []
        steps = 0
        while len(out) < n_retired and steps < guard:
            r = self.step()
            steps += 1
            if r is not None:
                out.append(r)
        return out

    def _exec(self, insn):
        op = insn & 0x7F
        rd = (insn >> 7) & 31
        f3 = (insn >> 12) & 7
        rs1 = (insn >> 15) & 31
        rs2 = (insn >> 20) & 31
        f7 = (insn >> 25) & 0x7F
        a = self.x[rs1]
        b = self.x[rs2]
        imm_i = sext(insn >> 20, 12)
        imm_s = sext(((insn >> 25) << 5) | ((insn >> 7) & 31), 12)
        imm_b = sext(((insn >> 31) << 12) | (((insn >> 7) & 1) << 11) |
                     (((insn >> 25) & 0x3F) << 5) | (((insn >> 8) & 0xF) << 1), 13)
        imm_u = sext(insn & 0xFFFFF000, 32)
        imm_j = sext(((insn >> 31) << 20) | (((insn >> 12) & 0xFF) << 12) |
                     (((insn >> 20) & 1) << 11) | (((insn >> 21) & 0x3FF) << 1), 21)
        npc = (self.pc + 4) & M64

        if op == 0x0B:                                    # custom-0: numeric ABI
            self.pc = npc
            nop = f7 & 0x1F
            if f7 & 0x60:
                raise Trap(CAUSE_ILLEGAL, insn)
            na = self.nregs[rs1]
            nb = self.nregs[rs2]
            # bridges are handled in the core, not the unit, so the model
            # module does not name them: funct7 0x12 = to-int, 0x13 = from-int
            if nop == 0x13:
                self.nregs[rd] = a
                return None, 0
            if nop == 0x12:
                return rd, na
            # fmt (funct3) selects the width for posit / LNS / RNS, so it has
            # to reach the model or every non-16-bit vector disagrees
            ny, nflags, nerr_now, nqnext, nerr_next = nummodel.model(
                nop, na, nb, self.csr[0x7C0], self.nquire, self.nerr_q, f3)
            self.nquire = nqnext
            self.nerr_q = nerr_next
            self.csr[0x7C1] = (self.csr[0x7C1] | nflags) & 0xFF
            self.csr[0x7C2] = nerr_now
            self.nregs[rd] = ny
            return None, 0

        if op == 0x37:                                    # LUI
            self.pc = npc
            return rd, imm_u
        if op == 0x17:                                    # AUIPC
            val = u64(self.pc + imm_u)
            self.pc = npc
            return rd, val
        if op == 0x6F:                                    # JAL
            self.pc = u64(self.pc + imm_j)
            return rd, npc
        if op == 0x67:                                    # JALR
            if f3 != 0:
                raise Trap(CAUSE_ILLEGAL, insn)
            self.pc = u64((a + imm_i) & ~1)
            return rd, npc
        if op == 0x63:                                    # BRANCH
            t = {0: a == b, 1: a != b, 4: s64(a) < s64(b), 5: s64(a) >= s64(b),
                 6: a < b, 7: a >= b}
            if f3 not in t:
                raise Trap(CAUSE_ILLEGAL, insn)
            self.pc = u64(self.pc + imm_b) if t[f3] else npc
            return None, 0
        if op == 0x03:                                    # LOAD
            size = {0: 1, 1: 2, 2: 4, 3: 8, 4: 1, 5: 2, 6: 4}
            if f3 not in size:
                raise Trap(CAUSE_ILLEGAL, insn)
            n = size[f3]
            addr = u64(a + imm_i)
            if addr % n:
                raise Trap(CAUSE_LOAD_MISALIGN, addr)
            v = self.read(addr, n)
            if f3 in (0, 1, 2):
                v = sext(v, 8 * n)
            self.pc = npc
            return rd, u64(v)
        if op == 0x23:                                    # STORE
            size = {0: 1, 1: 2, 2: 4, 3: 8}
            if f3 not in size:
                raise Trap(CAUSE_ILLEGAL, insn)
            n = size[f3]
            addr = u64(a + imm_s)
            if addr % n:
                raise Trap(CAUSE_STORE_MISALIGN, addr)
            self.write(addr, n, b)
            self.pc = npc
            return None, 0
        if op == 0x2F:                                    # AMO / LR / SC
            f5 = (insn >> 27) & 0x1F
            size = {2: 4, 3: 8}
            if f3 not in size:
                raise Trap(CAUSE_ILLEGAL, insn)
            n = size[f3]
            addr = u64(a)
            if addr % n:
                cause = CAUSE_LOAD_MISALIGN if f5 == 0x02 else CAUSE_STORE_MISALIGN
                raise Trap(cause, addr)
            self.pc = npc
            bits = 8 * n
            mask = (1 << bits) - 1

            def sxs(v):
                v &= mask
                return v - (1 << bits) if v & (1 << (bits - 1)) else v

            if f5 == 0x02:                                # LR
                v = self.read(addr, n)
                self.resv = addr
                return rd, u64(sext(v, bits))
            if f5 == 0x03:                                # SC
                if self.resv == addr:
                    self.write(addr, n, b & mask)
                    self.resv = None
                    return rd, 0
                self.resv = None
                return rd, 1
            old = self.read(addr, n)
            o, sb = old & mask, b & mask
            so, ss = sxs(old), sxs(b)
            if f5 == 0x01:
                new = sb                                   # AMOSWAP
            elif f5 == 0x00:
                new = (o + sb) & mask                      # AMOADD
            elif f5 == 0x04:
                new = (o ^ sb) & mask                      # AMOXOR
            elif f5 == 0x0C:
                new = (o | sb) & mask                      # AMOOR
            elif f5 == 0x08:
                new = (o & sb) & mask                      # AMOAND
            elif f5 == 0x10:
                new = o if so < ss else sb                 # AMOMIN
            elif f5 == 0x14:
                new = o if so > ss else sb                 # AMOMAX
            elif f5 == 0x18:
                new = o if o < sb else sb                  # AMOMINU
            elif f5 == 0x1C:
                new = o if o > sb else sb                  # AMOMAXU
            else:
                raise Trap(CAUSE_ILLEGAL, insn)
            self.write(addr, n, new)
            return rd, u64(sext(old, bits))

        if op == 0x13:                                    # OP-IMM
            self.pc = npc
            return rd, self._op_imm(f3, insn, a, imm_i, rd)
        if op == 0x1B:                                    # OP-IMM-32
            self.pc = npc
            return rd, self._op_imm32(f3, insn, a, imm_i)
        if op == 0x33:                                    # OP
            self.pc = npc
            return rd, self._op(f7, f3, a, b, insn)
        if op == 0x3B:                                    # OP-32
            self.pc = npc
            return rd, self._op32(f7, f3, a, b, insn)
        if op == 0x0F:                                    # MISC-MEM
            if f3 > 1:
                raise Trap(CAUSE_ILLEGAL, insn)
            self.pc = npc
            return None, 0
        if op == 0x73:                                    # SYSTEM
            if f3 == 0:
                if insn == 0x00000073:                    # ecall
                    raise Trap(CAUSE_ECALL_M, 0)
                if insn == 0x00100073:                    # ebreak
                    raise Trap(CAUSE_BREAKPOINT, 0)
                if insn == 0x30200073:                    # mret
                    self._set_mstatus_bits(mie=(self.csr[0x300] >> 7) & 1, mpie=1, mpp=3)
                    self.pc = self.csr[0x341] & ~3
                    return None, 0
                if insn == 0x10500073:                    # wfi
                    self.pc = npc
                    return None, 0
                raise Trap(CAUSE_ILLEGAL, insn)
            return self._csr(f3, insn, rd, rs1)
        raise Trap(CAUSE_ILLEGAL, insn)

    # ---------------------------------------------------------------- ALU
    def _op_imm(self, f3, insn, a, imm, rd):
        f6 = (insn >> 26) & 0x3F
        sub = (insn >> 20) & 0x3F
        if f3 == 0:
            return u64(a + imm)
        if f3 == 2:
            return int(s64(a) < imm)
        if f3 == 3:
            return int(a < u64(imm))
        if f3 == 4:
            return a ^ u64(imm)
        if f3 == 6:
            return a | u64(imm)
        if f3 == 7:
            return a & u64(imm)
        if f3 == 1:
            if f6 == 0x00:
                return u64(a << (imm & 0x3F))
            if f6 == 0x18:
                return {0: self._clz(a), 1: self._ctz(a), 2: bin(a).count("1"),
                        4: u64(sext(a, 8)), 5: u64(sext(a, 16))}.get(sub, None) \
                       if sub in (0, 1, 2, 4, 5) else self._illegal(insn)
            if f6 == 0x0A:
                return a | (1 << (imm & 0x3F))
            if f6 == 0x12:
                return a & ~(1 << (imm & 0x3F))
            if f6 == 0x1A:
                return a ^ (1 << (imm & 0x3F))
            raise Trap(CAUSE_ILLEGAL, insn)
        # f3 == 5
        if (insn >> 20) == 0x287:
            return int.from_bytes(bytes(0xFF if (a >> (8 * i)) & 0xFF else 0
                                        for i in range(8)), "little")
        if (insn >> 20) == 0x6B8:
            return int.from_bytes(bytes((a >> (8 * i)) & 0xFF for i in range(7, -1, -1)),
                                  "little")
        if f6 == 0x00:
            return u64(a >> (imm & 0x3F))
        if f6 == 0x10:
            return u64(s64(a) >> (imm & 0x3F))
        if f6 == 0x18:
            s = imm & 0x3F
            return u64((a >> s) | (a << ((64 - s) & 63))) if s else a
        if f6 == 0x12:
            return (a >> (imm & 0x3F)) & 1
        raise Trap(CAUSE_ILLEGAL, insn)

    def _op_imm32(self, f3, insn, a, imm):
        f6 = (insn >> 26) & 0x3F
        lo = a & M32
        if f3 == 0:
            return u64(s32(lo + imm))
        if f3 == 1:
            if f6 == 0x02:
                return u64((a & M32) << (imm & 0x3F))
            if f6 == 0x00:
                return u64(s32(lo << (imm & 0x1F)))
            raise Trap(CAUSE_ILLEGAL, insn)
        if f3 == 5:
            if f6 == 0x00:
                return u64(s32(lo >> (imm & 0x1F)))
            if f6 == 0x10:
                return u64(s32(s32(lo) >> (imm & 0x1F)))
            raise Trap(CAUSE_ILLEGAL, insn)
        raise Trap(CAUSE_ILLEGAL, insn)

    def _op(self, f7, f3, a, b, insn):
        if f7 == 0x00:
            return {0: u64(a + b), 1: u64(a << (b & 0x3F)), 2: int(s64(a) < s64(b)),
                    3: int(a < b), 4: a ^ b, 5: u64(a >> (b & 0x3F)),
                    6: a | b, 7: a & b}[f3]
        if f7 == 0x20:
            if f3 == 0:
                return u64(a - b)
            if f3 == 5:
                return u64(s64(a) >> (b & 0x3F))
            if f3 == 7:
                return a & ~b
            if f3 == 6:
                return a | ~b
            if f3 == 4:
                return ~(a ^ b)
            raise Trap(CAUSE_ILLEGAL, insn)
        if f7 == 0x01:
            return self._mdu(f3, a, b)
        if f7 == 0x05:
            if f3 == 4:
                return a if s64(a) < s64(b) else b
            if f3 == 5:
                return a if a < b else b
            if f3 == 6:
                return a if s64(a) > s64(b) else b
            if f3 == 7:
                return a if a > b else b
            return self._clmul(f3, a, b)
        if f7 == 0x14:
            return a | (1 << (b & 0x3F))
        if f7 == 0x24:
            if f3 == 1:
                return a & ~(1 << (b & 0x3F))
            return (a >> (b & 0x3F)) & 1
        if f7 == 0x34:
            return a ^ (1 << (b & 0x3F))
        if f7 == 0x30:
            s = b & 0x3F
            if f3 == 1:
                return u64((a << s) | (a >> ((64 - s) & 63))) if s else a
            if f3 == 5:
                return u64((a >> s) | (a << ((64 - s) & 63))) if s else a
            raise Trap(CAUSE_ILLEGAL, insn)
        if f7 == 0x10:
            if f3 == 2:
                return u64((a << 1) + b)
            if f3 == 4:
                return u64((a << 2) + b)
            if f3 == 6:
                return u64((a << 3) + b)
            raise Trap(CAUSE_ILLEGAL, insn)
        if f7 == 0x07:
            if f3 == 5:
                return 0 if a == b else b
            if f3 == 7:
                return b if a == b else 0
            raise Trap(CAUSE_ILLEGAL, insn)
        if f7 == 0x04 and f3 == 4 and (insn >> 20) & 31 == 0:
            return a & 0xFFFF
        raise Trap(CAUSE_ILLEGAL, insn)

    def _op32(self, f7, f3, a, b, insn):
        lo_a, lo_b = a & M32, b & M32
        if f7 == 0x00:
            if f3 == 0:
                return u64(s32(lo_a + lo_b))
            if f3 == 1:
                return u64(s32(lo_a << (b & 0x1F)))
            if f3 == 5:
                return u64(s32(lo_a >> (b & 0x1F)))
            raise Trap(CAUSE_ILLEGAL, insn)
        if f7 == 0x20:
            if f3 == 0:
                return u64(s32(lo_a - lo_b))
            if f3 == 5:
                return u64(s32(s32(lo_a) >> (b & 0x1F)))
            raise Trap(CAUSE_ILLEGAL, insn)
        if f7 == 0x04:
            if f3 == 0:
                return u64((a & M32) + b)
            if f3 == 4 and (insn >> 20) & 31 == 0:
                return a & 0xFFFF
            raise Trap(CAUSE_ILLEGAL, insn)
        if f7 == 0x30:
            s = b & 0x1F
            if f3 == 1:
                return u64(s32((lo_a << s) | (lo_a >> ((32 - s) & 31)))) if s else u64(s32(lo_a))
            if f3 == 5:
                return u64(s32((lo_a >> s) | (lo_a << ((32 - s) & 31)))) if s else u64(s32(lo_a))
            raise Trap(CAUSE_ILLEGAL, insn)
        raise Trap(CAUSE_ILLEGAL, insn)

    # ---------------------------------------------------------------- MDU
    def _mdu(self, f3, a, b):
        sa, sb = s64(a), s64(b)
        if f3 == 0:
            return u64(sa * sb)
        if f3 == 1:
            return u64((sa * sb) >> 64)
        if f3 == 2:
            return u64((sa * b) >> 64)
        if f3 == 3:
            return u64((a * b) >> 64)
        if f3 == 4:
            if b == 0:
                return M64
            if sa == -(1 << 63) and sb == -1:
                return u64(1 << 63)
            q = abs(sa) // abs(sb)
            return u64(-q if (sa < 0) != (sb < 0) else q)
        if f3 == 5:
            return M64 if b == 0 else a // b
        if f3 == 6:
            if b == 0:
                return a
            if sa == -(1 << 63) and sb == -1:
                return 0
            r = abs(sa) % abs(sb)
            return u64(-r if sa < 0 else r)
        if f3 == 7:
            return a if b == 0 else a % b
        return 0

    @staticmethod
    def _clz(a):
        return 64 if a == 0 else 64 - a.bit_length()

    @staticmethod
    def _ctz(a):
        if a == 0:
            return 64
        n = 0
        while not (a >> n) & 1:
            n += 1
        return n

    def _clmul(self, f3, a, b):
        prod = 0
        for i in range(64):
            if (b >> i) & 1:
                prod ^= a << i
        if f3 == 1:
            return prod & M64
        if f3 == 2:
            return (prod >> 63) & M64
        if f3 == 3:
            return (prod >> 64) & M64
        raise Trap(CAUSE_ILLEGAL, 0)

    # ---------------------------------------------------------------- CSR
    def _csr(self, f3, insn, rd, rs1):
        addr = (insn >> 20) & 0xFFF
        src = rs1 if (f3 >> 2) else self.x[rs1]
        self.pc = (self.pc + 4) & M64
        if addr == 0xB00 or addr == 0xB02 or addr == 0xB80 or addr == 0xB82:
            # counters: read-only for verification purposes
            return rd, 0
        if addr not in self.csr:
            raise Trap(CAUSE_ILLEGAL, insn)
        old = self.csr[addr]
        op = f3 & 3
        if op == 1:
            new = src
        elif op == 2:
            new = old | src if src else old
        elif op == 3:
            new = old & ~src if src else old
        else:
            raise Trap(CAUSE_ILLEGAL, insn)
        if op == 1 or src:
            if addr == 0x300:
                self._set_mstatus_bits(mie=(new >> 3) & 1, mpie=(new >> 7) & 1,
                                       mpp=(new >> 11) & 3)
            elif addr == 0x305:
                self.csr[addr] = new & ~3
            elif addr == 0x341:
                self.csr[addr] = new & ~3
            elif addr == 0x7C1:
                # sticky flags: write-one-to-clear
                self.csr[addr] = u64(self.csr[addr] & ~new)
            elif addr == 0x344:
                pass
            else:
                self.csr[addr] = u64(new)
        return rd, old

    @staticmethod
    def _illegal(insn):
        raise Trap(CAUSE_ILLEGAL, insn)
