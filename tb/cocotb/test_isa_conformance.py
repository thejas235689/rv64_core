"""
test_isa_conformance.py -- the ISA profile, checked against the hardware.

isa/rv64_profile.yaml is the single source of truth for what this core claims to
be.  This module is what makes that claim enforceable.  It reads the profile and
checks four things, any one of which can drift:

  1. misa.  The DUT's misa CSR, and the Python ISS's misa, must both equal the
     value computed from the profile's extension bits.  Change one without the
     other and the build fails.
  2. Execution.  At least one instruction from every advertised extension must
     retire without raising illegal instruction (cause 2).  This is the check
     that would have caught the F/D problem on day one: misa advertised F, and
     fadd.s trapped.
  3. Not claimed.  Every extension the profile marks as not claimed must behave
     the way the profile records -- by default that means it traps with cause 2,
     so software can detect its absence.
  4. Documentation.  README.md and docs/ARCHITECTURE_FEATURE_CONTRACT.md must
     quote the profile's misa value and extension letters.  A document that
     disagrees is a failure, not a comment.

Plus two structural checks the profile makes possible: the custom CSR windows
must match the RTL's own decode, and the bus and clocking signal names must
exist on the top level.

Why this file exists: the README said "misa advertises RV64IM", the feature
contract said the same, the RTL said 0x8000000000141125, and the README also
said "C, F, D and V are rejected as illegal" while C and A were implemented.
Five contradictions, none caught, because nothing tested the documents against
the hardware.  Every check below is one of those five, made mechanical.

Run it:
    /usr/local/bin/python3 sim/run.py --suite conformance
    bash ci/run_batches.sh          # with SUITE=conformance (what CI does)
"""

import re
from pathlib import Path

import cocotb

from rv64_asm import assemble
from rv64_iss import ISS
from test_core import Harness

try:
    import yaml
except ImportError:                                   # pragma: no cover
    yaml = None

HERE = Path(__file__).resolve()
ROOT = HERE.parents[2]
PROFILE_PATH = ROOT / "isa" / "rv64_profile.yaml"
DOC_PATHS = [ROOT / "README.md",
             ROOT / "docs" / "ARCHITECTURE_FEATURE_CONTRACT.md"]

# --------------------------------------------------------------------------- profile
def load_profile(path=PROFILE_PATH):
    if yaml is None:
        raise RuntimeError(
            "PyYAML is required to read the ISA profile: pip install pyyaml")
    with open(path) as f:
        return yaml.safe_load(f)


PROFILE = load_profile()


def misa_value(profile=None):
    """misa computed from the profile: MXL in [63:62], one bit per claimed letter."""
    p = profile or PROFILE
    value = int(p["mxl"]["encoding"]) << 62
    for ext in p["misa"]["extensions"]:
        if ext.get("claimed", True):
            value |= 1 << int(ext["bit"])
    return value


def claimed_letters(profile=None):
    p = profile or PROFILE
    return {e["letter"] for e in p["misa"]["extensions"] if e.get("claimed", True)}


def not_claimed_entries(profile=None):
    p = profile or PROFILE
    return list(p.get("not_claimed") or [])


# --------------------------------------------------------------------------- programs
# Every probe program has the same skeleton.  mtvec points at an `ecall` landing
# pad, so a probe that traps ends the run with cause 11 on top of the cause it
# actually raised -- which lets one program report both "did it trap" and "did it
# finish" without any host-side bookkeeping.
PRELUDE = """
    jal   x0, start
handler:
    ecall
start:
    li    x1, 4
    csrrw x0, mtvec, x1
"""

MISA_PROG = PRELUDE + """
    csrrs x9, misa, x0
    ecall
"""

# One instruction (or short sequence) per advertised extension.  `reg` is the
# architectural result that proves the instruction really executed rather than
# being retired as an unknown no-op.
EXTENSION_PROBES = {
    "I": {"what": "addi x5, x0, 7",
          "src": "    addi x5, x0, 7",
          "reg": (5, 7)},
    "M": {"what": "mul x5, x1, x2",
          "src": "    addi x1, x0, 6\n    addi x2, x0, 7\n    mul x5, x1, x2",
          "reg": (5, 42)},
    "A": {"what": "amoadd.d x5, x1, (x10) then ld x6, 0(x10)",
          "src": "    li x10, 0x2000\n    addi x1, x0, 5\n"
                 "    amoadd.d x5, x1, (x10)\n    ld x6, 0(x10)",
          "reg": (6, 5)},
    "C": {"what": "c.li a0, 1 and c.nop (16-bit encodings)",
          "src": "    .hword 0x4505\n    .hword 0x0001",
          "reg": (10, 1)},
    "F": {"what": "fadd.s f3, f1, f1",
          "src": "    fmv.w.x f1, x0\n    fadd.s f3, f1, f1"},
    "D": {"what": "fadd.d f3, f1, f1",
          "src": "    fmv.d.x f1, x0\n    fadd.d f3, f1, f1\n    fmv.x.d x5, f3",
          "reg": (5, 0)},
    "S": {"what": "mret into S-mode, execute, ecall from S", "mode": "S"},
    "U": {"what": "mret into U-mode, execute, ecall from U", "mode": "U"},
}

# Entering S- or U-mode is proved by the PMP, not by an ecall cause: entry 0
# allows 0x0-0x1FFF R/W/X (code), entry 1 denies 0x2000-0x3FFF to S/U, and M-mode
# ignores both because L=0.  A load from 0x2000 therefore faults *only* if the
# privilege really changed -- a positive proof, where "nothing trapped" would not
# be one.  Without entry 0 at all, S/U fetch raises cause 1 and the test would be
# measuring that instead.
MODE_PROGRAM = """
    jal   x0, start
handler:
    csrrs x6, mstatus, x0
    ecall
entry:
    addi x5, x0, 0x5a
privcheck:
    csrrs x9, mscratch, x0
    ecall
start:
    li    x1, 4
    csrrw x0, mtvec, x1
    li    x4, 0xFFF
    csrrw x0, pmpaddr0, x4
    li    x4, 0x1F
    csrrw x0, pmpcfg0, x4
    li    x2, entry
    csrrw x0, mepc, x2
{mpp_setup}
    mret
"""

# Entering S- or U-mode is proved by a deliberate M-mode CSR access, not by the
# ecall cause (this core raises cause 11 from every mode) and not by "nothing
# trapped" (which would also be true if mret did nothing):
#
#   addi x5, x0, 0x5a        the extension's own instruction -- must NOT trap
#   csrrs x9, mscratch, x0   mscratch is an M-mode CSR (addr[9:8] = 11), so this
#                            raises cause 2 exactly when priv < M
#
# The test asserts the trap lands on the `privcheck` address and that
# mstatus.MPP says the trap came from S (1) or U (0).  PMP entry 0 (R|W|X over
# 0x0-0x1FFF, L=0) is still needed: without a matching entry, S/U may not fetch
# at all and the run would measure cause 1 instead.
MPP_SETUP = {
    # mstatus.MPP = 01 (S) / 00 (U).  Writing the whole register is fine: the
    # only fields this program needs afterwards are MPP and MPIE.
    "S": "    li    x3, 0x800\n    csrrw x0, mstatus, x3",
    "U": "    csrrw x0, mstatus, x0",
}

MPP_CODE = {"S": 1, "U": 0}


def ecall_cause(profile=None):
    """The cause this core raises for an ecall, as the profile records it."""
    p = profile or PROFILE
    for dev in (p.get("privilege", {}).get("deviations") or []):
        if dev.get("name") == "ecall_cause":
            return int(dev["observed_cause"])
    return None


async def run_program(h, src, max_cycles=3000):
    """Assemble, load, reset and run one program.

    Returns (causes, gprs, trace, labels); labels maps a source label to its
    byte address, so a test can name the instruction a trap must land on.
    """
    words, labels = assemble(src)
    h.clear()
    await h.load(words)
    await h.reset()
    await h.run(max_cycles=max_cycles, stop_on_ecall=True)
    gpr = {}
    for (_pc, _insn, we, wa, wd) in h.trace:
        if we:
            gpr[wa] = wd
    return [c for (_pc, c) in h.traps], gpr, h.trace, labels


def describe(causes):
    names = {2: "illegal", 8: "ecall_u", 9: "ecall_s", 11: "ecall_m"}
    return "[" + ", ".join(f"{c}({names[c]})" if c in names else str(c)
                           for c in causes) + "]"


async def check_extension_executes(dut, letter):
    """One advertised extension: its instruction must retire and must not trap."""
    assert letter in claimed_letters(), (
        f"{letter} is not claimed by the profile ({PROFILE_PATH.name}); "
        f"claimed: {' '.join(sorted(claimed_letters()))}")
    probe = EXTENSION_PROBES[letter]
    h = Harness(dut)
    await h.startup()

    if "mode" in probe:
        mode = probe["mode"]
        src = MODE_PROGRAM.format(mpp_setup=MPP_SETUP[mode])
        causes, gpr, trace, labels = await run_program(h, src)
        assert gpr.get(5) == 0x5A, (
            f"misa advertises {letter}, but the instruction executed in {mode}-mode "
            f"did not retire its result: x5={gpr.get(5)!r} (expected 0x5a)")
        # The trap on the M-mode CSR access is the proof the privilege changed:
        # it must be an illegal instruction at exactly the `privcheck` address.
        assert causes and causes[0] == 2, (
            f"misa advertises {letter}, but the M-mode CSR access from {mode}-mode "
            f"did not raise illegal instruction, so {mode}-mode was never entered: "
            f"causes={describe(causes)}")
        trap_pc = h.traps[0][0]
        assert trap_pc == labels["privcheck"], (
            f"misa advertises {letter}, but the illegal instruction was raised at "
            f"{trap_pc:#x}, not at the M-mode CSR access at "
            f"{labels['privcheck']:#x}: causes={describe(causes)}")
        mpp = (gpr.get(6, 0) >> 11) & 0x3
        assert mpp == MPP_CODE[mode], (
            f"misa advertises {letter}, but the trap did not come from {mode}-mode: "
            f"mstatus.MPP after the trap is {mpp} (expected {MPP_CODE[mode]})")
        dut._log.info(f"{letter}: {probe['what']} -> entered {mode}-mode "
                      f"(MPP={mpp}, illegal-instruction trap on the M-mode CSR "
                      f"access at {trap_pc:#x}), x5=0x5a, causes={describe(causes)}")
        return

    causes, gpr, trace, _labels = await run_program(
        h, PRELUDE + probe["src"] + "\n    ecall\n")
    assert 2 not in causes, (
        f"misa advertises {letter}, but {probe['what']} raised illegal instruction "
        f"(cause 2): causes={describe(causes)}, retired={len(trace)}")
    assert 11 in causes, (
        f"{letter}: program did not run to completion, causes={describe(causes)}")
    if "reg" in probe:
        idx, want = probe["reg"]
        assert gpr.get(idx) == want, (
            f"misa advertises {letter}, and {probe['what']} did not trap, but it "
            f"produced the wrong result: x{idx}={gpr.get(idx)!r}, expected {want:#x}")
    dut._log.info(f"{letter}: {probe['what']} -> no trap, retired={len(trace)}")


# --------------------------------------------------------------------------- 1. misa
@cocotb.test()
async def test_profile_is_self_consistent(dut):
    """The profile's own bits must be sane before anything is compared to them."""
    bits, letters = {}, {}
    for ext in PROFILE["misa"]["extensions"]:
        letter, bit = ext["letter"], int(ext["bit"])
        assert 0 <= bit <= 25, f"{letter}: bit {bit} is outside misa[25:0]"
        assert bit not in bits, f"bit {bit} claimed by both {bits[bit]} and {letter}"
        assert letter not in letters, f"{letter} listed twice"
        bits[bit], letters[letter] = letter, bit
    assert PROFILE["xlen"] == 64, f"xlen {PROFILE['xlen']} but MXL says RV64"
    assert PROFILE["mxl"]["encoding"] == 2, "MXL 2 is RV64; anything else is not"
    assert PROFILE["mxl"]["bits"] == [63, 62], "MXL is misa[63:62]"
    for letter in ("I", "M"):
        assert letter in letters, f"{letter} must be claimed by any RV64 profile"
    value = misa_value()
    dut._log.info(f"profile {PROFILE['profile']['name']} rev "
                  f"{PROFILE['profile']['revision']}: misa = {value:#018x} "
                  f"({' '.join(sorted(letters))}, MXL={PROFILE['mxl']['encoding']})")


@cocotb.test()
async def test_misa_matches_profile(dut):
    """The DUT's misa must equal the value computed from the profile."""
    expected = misa_value()
    h = Harness(dut)
    await h.startup()
    causes, gpr, _, _labels = await run_program(h, MISA_PROG)
    assert 2 not in causes, f"reading misa raised illegal instruction: {describe(causes)}"
    got = gpr.get(9)
    assert got is not None, "the misa read did not write x9"
    if got != expected:
        dut_letters = sorted(e["letter"] for e in PROFILE["misa"]["extensions"]
                             if (got >> int(e["bit"])) & 1)
        dut._log.error(f"DUT misa     {got:#018x}  {' '.join(dut_letters)}")
        dut._log.error(f"profile misa {expected:#018x}  "
                       f"{' '.join(sorted(claimed_letters()))}")
        assert False, (
            f"misa drift: the DUT returns {got:#018x}, the profile "
            f"(isa/rv64_profile.yaml) computes {expected:#018x}")
    dut._log.info(f"DUT misa = {got:#018x}, matches the profile")


@cocotb.test()
async def test_misa_matches_iss(dut):
    """The Python golden model must agree with the profile too, not just the RTL."""
    expected = misa_value()
    got = ISS().csr[PROFILE["misa"]["csr"]]
    assert got == expected, (
        f"ISS drift: tb/cocotb/rv64_iss.py returns {got:#018x} for misa, the "
        f"profile computes {expected:#018x}")
    dut._log.info(f"ISS misa = {got:#018x}, matches the profile")


# --------------------------------------------------------------------------- 2. execution
@cocotb.test()
async def test_every_claimed_extension_has_a_probe(dut):
    """A letter added to the profile without an execution probe is a silent gap."""
    missing = sorted(claimed_letters() - set(EXTENSION_PROBES))
    assert not missing, (
        f"the profile claims {missing} but this test has no instruction to "
        f"execute for them; add an entry to EXTENSION_PROBES")
    extra = sorted(set(EXTENSION_PROBES) - claimed_letters())
    dut._log.info(f"probes for {len(EXTENSION_PROBES)} claimed extensions"
                  + (f" (unclaimed, ignored: {extra})" if extra else ""))


@cocotb.test()
async def test_isa_i_executes(dut):
    """RV64I: an integer instruction must retire."""
    await check_extension_executes(dut, "I")


@cocotb.test()
async def test_isa_m_executes(dut):
    """RV64M: multiply must retire."""
    await check_extension_executes(dut, "M")


@cocotb.test()
async def test_isa_a_executes(dut):
    """RV64A: an AMO must retire and actually update memory."""
    await check_extension_executes(dut, "A")


@cocotb.test()
async def test_isa_c_executes(dut):
    """RV64C: a 16-bit encoding must retire."""
    await check_extension_executes(dut, "C")


@cocotb.test()
async def test_isa_f_executes(dut):
    """RV64F: single precision must retire.

    This is the test that would have caught the F/D problem: misa advertised F
    and fadd.s trapped as illegal for as long as nothing executed it.
    """
    await check_extension_executes(dut, "F")


@cocotb.test()
async def test_isa_d_executes(dut):
    """RV64D: double precision must retire."""
    await check_extension_executes(dut, "D")


@cocotb.test()
async def test_isa_s_executes(dut):
    """RV64S: mret must be able to enter S-mode and an instruction must run there."""
    await check_extension_executes(dut, "S")


@cocotb.test()
async def test_isa_u_executes(dut):
    """RV64U: mret must be able to enter U-mode and an instruction must run there."""
    await check_extension_executes(dut, "U")


# --------------------------------------------------------------------------- 3. not claimed
@cocotb.test()
async def test_ecall_cause_matches_profile(dut):
    """The ecall cause this core raises must be the one the profile records.

    The profile records a deviation here (privilege.deviations[ecall_cause]):
    this core raises cause 11 from every privilege mode, where the spec wants 9
    from S and 8 from U.  Pinning the recorded value means the RTL cannot be
    fixed without the profile being updated in the same commit, and the profile
    cannot quietly start claiming spec behaviour the RTL does not have.
    """
    recorded = ecall_cause()
    assert recorded is not None, (
        "the profile no longer records an ecall_cause deviation; if the RTL was "
        "fixed, delete this test and record the spec causes instead")
    h = Harness(dut)
    await h.startup()
    src = MODE_PROGRAM.format(mpp_setup=MPP_SETUP["S"]).replace(
        "privcheck:\n    csrrs x9, mscratch, x0\n", "")
    causes, _gpr, _trace, _labels = await run_program(h, src)
    assert causes, "the ecall from S-mode raised no trap at all"
    assert causes[0] == recorded, (
        f"ecall from S-mode raised cause {causes[0]}, the profile records "
        f"{recorded}; causes={describe(causes)}")
    dut._log.info(f"ecall from S-mode raises cause {causes[0]}, as the profile "
                  f"records (spec wants 9)")


@cocotb.test()
async def test_not_claimed_extensions(dut):
    """Every not-claimed extension must behave exactly as the profile records.

    Default expectation is `traps`: the instruction raises cause 2, so software
    can tell the extension is absent.  An entry may record `retires_as_noop`
    with a deviation note instead; then the test requires that it does NOT trap,
    which pins the deviation just as tightly -- if the RTL ever changes, this
    fails and the profile has to be updated in the same commit.
    """
    entries = not_claimed_entries()
    assert entries, "the profile lists nothing under not_claimed"
    h = Harness(dut)
    await h.startup()
    problems, notes = [], []

    for entry in entries:
        letter = entry["letter"]
        probe = entry.get("probe") or {}
        word = probe.get("word")
        assert word is not None, f"{letter}: not_claimed entry has no probe instruction"
        expect = entry.get("expect", "traps")
        assert expect in ("traps", "retires_as_noop"), \
            f"{letter}: unknown expectation {expect!r}"
        src = PRELUDE + f"    .word {word:#010x}\n    ecall\n"
        causes, _gpr, trace, _labels = await run_program(h, src, max_cycles=400)
        trapped = 2 in causes
        if expect == "traps":
            if not trapped:
                problems.append(
                    f"{letter} ({entry.get('name')}): the profile says this "
                    f"extension is not claimed and its probe "
                    f"{probe.get('name', hex(word))} ({word:#010x}) must trap as "
                    f"illegal, but it retired without cause 2 "
                    f"(causes={describe(causes)}, retired={len(trace)})")
            else:
                notes.append(f"{letter}: {probe.get('name', hex(word))} traps as required")
        else:                                        # retires_as_noop
            if trapped:
                problems.append(
                    f"{letter} ({entry.get('name')}): the profile records that "
                    f"{probe.get('name', hex(word))} retires as a no-op, but it "
                    f"raised cause 2; the RTL and the profile disagree "
                    f"(causes={describe(causes)})")
            else:
                notes.append(
                    f"{letter}: {probe.get('name', hex(word))} retires as a no-op "
                    f"as recorded -- deviation, not a silent waiver")

    dut._log.info("not claimed: " + "; ".join(notes))
    assert not problems, "\n".join(problems)


# --------------------------------------------------------------------------- 4. documentation
HEX_TOKEN = re.compile(r"0[xX][0-9a-fA-F_]+")
LETTER_RUN = re.compile(r"(?<![A-Za-z])([A-Z](?: [A-Z])+)(?![A-Za-z])")
# single letters that can appear in a misa list
MISA_LETTERS = set("IMFADQLCBJNPSUHXGTVE")


@cocotb.test()
async def test_documentation_matches_profile(dut):
    """README.md and the feature contract must quote the profile, not their own value.

    Fails on: a 64-bit misa value that differs from the profile's computed one,
    a misa extension-letter list that differs, or a file that stops stating a
    misa value at all (a document that says nothing cannot be checked).
    """
    expected = misa_value()
    want = claimed_letters()
    problems = []

    for path in DOC_PATHS:
        assert path.exists(), f"{path} is missing"
        stated = False
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            if "misa" not in line.lower():
                continue
            for token in HEX_TOKEN.findall(line):
                digits = token[2:].replace("_", "")
                if len(digits) != 16:
                    continue
                stated = True
                got = int(digits, 16)
                if got != expected:
                    problems.append(
                        f"{path.name}:{lineno}: misa value {token} != profile "
                        f"{expected:#018x}")
            for run in LETTER_RUN.findall(line):
                letters = run.split()
                if len(letters) < 2 or not set(letters) <= MISA_LETTERS:
                    continue
                if set(letters) != want:
                    problems.append(
                        f"{path.name}:{lineno}: misa letters '{run}' != profile "
                        f"'{' '.join(sorted(want))}'")
        if not stated:
            problems.append(f"{path.name}: no misa value found on any line "
                            f"mentioning misa")

    if problems:
        dut._log.error(f"profile says misa = {expected:#018x} "
                       f"({' '.join(sorted(want))})")
        for problem in problems:
            dut._log.error(f"  {problem}")
    assert not problems, (
        f"{len(problems)} documentation disagreement(s) with "
        f"isa/rv64_profile.yaml:\n" + "\n".join(problems))


# --------------------------------------------------------------------------- structure
def rtl_csr_windows():
    """The custom CSR windows as rtl/riscv_core_top.sv actually decodes them."""
    values = {}
    for src in (ROOT / "rtl").glob("*.sv"):
        for m in re.finditer(r"(CSR_[A-Z0-9_]+)\s*=\s*12'h([0-9A-Fa-f]+)",
                             src.read_text()):
            values[m.group(1)] = int(m.group(2), 16)
    top = (ROOT / "rtl" / "riscv_core_top.sv").read_text()
    windows = set()
    # "<base> + 12'dN" form
    for m in re.finditer(r"csr_addr >= (CSR_[A-Z0-9_]+)\)[\s\S]{0,160}?"
                         r"csr_addr <= \((CSR_[A-Z0-9_]+) \+ 12'd(\d+)\)", top):
        lo, hi = values.get(m.group(1)), values.get(m.group(2))
        if lo is not None and hi is not None:
            windows.add((lo, hi + int(m.group(3))))
    # ">= A && <= B" form (the numeric window)
    for m in re.finditer(r"csr_addr >= (CSR_[A-Z0-9_]+)\)[\s\S]{0,160}?"
                         r"csr_addr <= (CSR_[A-Z0-9_]+)\)", top):
        lo, hi = values.get(m.group(1)), values.get(m.group(2))
        if lo is not None and hi is not None:
            windows.add((lo, hi))
    return windows


@cocotb.test()
async def test_csr_windows_match_rtl(dut):
    """The profile's custom CSR windows must be the ones the RTL decodes."""
    profile_windows = {(int(w["base"]), int(w["top"]))
                       for w in PROFILE["csr_map"]["custom_windows"]}
    rtl_windows = rtl_csr_windows()
    assert rtl_windows, ("parsed no CSR windows out of rtl/riscv_core_top.sv -- "
                         "the decode changed shape and this check is blind")
    missing = sorted(profile_windows - rtl_windows)
    extra = sorted(rtl_windows - profile_windows)
    fmt = lambda ws: ", ".join(f"{lo:#05x}-{hi:#05x}" for lo, hi in ws)
    assert not missing and not extra, (
        f"CSR window drift: in the profile but not the RTL: [{fmt(missing)}]; "
        f"in the RTL but not the profile: [{fmt(extra)}]")
    dut._log.info(f"{len(profile_windows)} custom CSR windows match the RTL decode")


@cocotb.test()
async def test_bus_and_clocking_contract(dut):
    """Every signal the profile names in the bus and clocking sections must exist."""
    missing = []
    for port in PROFILE["bus"]["ports"]:
        for group in ("request", "response"):
            for signal in port[group]:
                if not hasattr(dut, signal):
                    missing.append(f"{port['name']}.{group}: {signal}")
    reset = PROFILE["clocking"]["reset"]
    for signal in (PROFILE["clocking"]["clock"], reset["name"]):
        if not hasattr(dut, signal):
            missing.append(f"clocking: {signal}")
    assert PROFILE["clocking"]["clock_domains"] == 1, \
        "this core is single-domain; the profile must say so"
    assert reset["active_low"] and reset["style"] == "synchronous", \
        "rst_n is synchronous active-low; the profile must say so"
    assert not missing, ("the profile names signals the top level does not have: "
                         + ", ".join(missing))
    dut._log.info(f"{len(PROFILE['bus']['ports'])} bus ports and "
                  f"{PROFILE['clocking']['clock']}/{reset['name']} present on "
                  f"riscv_core_top")
