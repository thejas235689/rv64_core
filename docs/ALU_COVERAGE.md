# ALU operand matrix — coverage report

Scope: `add`, `sub`, `and`, `or`, `xor`, `slt`, `sltu` and their immediate forms
(`addi`, `andi`, `ori`, `xori`, `slti`, `sltiu`) across the requested operand classes.

## Operand classes

| Class | Value | Register form | Immediate form |
| --- | --- | --- | --- |
| zero | `0` | yes | yes |
| one | `1` | yes | yes |
| minus one | `-1` (`0xFFFF_FFFF_FFFF_FFFF`) | yes | yes |
| two | `2` | yes | yes |
| minus two | `-2` | yes | yes |
| INT32_MAX | `0x7FFF_FFFF` | yes | no — exceeds 12-bit signed |
| INT32_MIN | `0x8000_0000` | yes | no |
| INT64_MAX | `0x7FFF_FFFF_FFFF_FFFF` | yes | no |
| INT64_MIN | `0x8000_0000_0000_0000` | yes | no |
| 0x7FFFFFFF | same as INT32_MAX | yes | no |
| 0x80000000 | same as INT32_MIN | yes | no |
| 0xFFFFFFFF | `0x0000_0000_FFFF_FFFF` | yes | no |
| +2^k | 1,2,4,8,16,32,64,128,256,512,1024,2^20,2^32,2^48 | yes | only ≤ 2047 |
| -2^k | -1,-2,-4,-8,-16,-1024,-2^20 | yes | only ≥ -2048 |
| all-ones | `0xFFFF_FFFF_FFFF_FFFF` | yes | no |

**Immediate forms are limited by the encoding.** The immediate is a 12-bit signed
field, so the representable set is `0, ±1, ±2, ±4, ±8, ±1024, 2047, -2048, 0x7FF,
-0x800`. Anything wider is exercised through the register forms, which is what a
compiler emits anyway.

## Coverage arithmetic

| | Count |
| --- | --- |
| Distinct register operands | 33 |
| Register operand pairs | 33 × 33 = **1,089** |
| Register ops per pair | 7 |
| **Register-form checks** | **7,623** |
| Distinct immediates | 15 |
| Immediate ops per operand/imm | 6 |
| **Immediate-form checks** | 33 × 15 × 6 = **2,970** |
| **Total directed checks** | **10,593** |

## Operation × operand-class matrix

Rows are operations, columns are operand classes. `R` = register form covered,
`I` = immediate form covered.

| op | zero | ±1 | ±2 | ±2^k | INT32 | INT64 | 0xFFFF_FFFF | all-ones |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| add | R I | R I | R I | R I | R | R | R | R |
| sub | R I | R I | R I | R I | R | R | R | R |
| and | R I | R I | R I | R I | R | R | R | R |
| or | R I | R I | R I | R I | R | R | R | R |
| xor | R I | R I | R I | R I | R | R | R | R |
| slt | R I | R I | R I | R I | R | R | R | R |
| sltu | R I | R I | R I | R I | R | R | R | R |

All 7 × 8 = 56 register cells covered; 42 immediate cells covered, the remaining 14
being the wide operands that cannot be encoded as an immediate.

## PSS coverage

`pss/rv64_alu_matrix.pss` provides four actions, all solving under Satya v0.42.0:

| Action | Intent |
| --- | --- |
| `alu_pair` | register-register, op × operand-class pairs, with `same_class` forcing a == b |
| `alu_imm` | immediate forms over the representable subset |
| `alu_sign_boundary` | `slt` vs `sltu` on values differing only in interpretation |
| `alu_coverage` | every register and immediate op at least once |

Verified: `satya check` lowers cleanly; `satya solve` returns 1 concrete step with 0
warnings for each action; `satya gen --backend json` returns concrete fields, e.g.
`alu_pair {a_class: 0, b_class: 0, op_index: 3, same_class: 1}`.

## Status — honest

**The PSS model is complete and solving. The cocotb directed test is not green.**

The cocotb test builds its operands with `lui`/`addi`/`ori` because the assembler has
no `li`. Three bugs in that builder have been found and fixed so far:

1. sequence misalignment — compared final register values instead of writes in order
2. `addi` sign-extension — `0xFFFFFFFF` added as `-1` instead of `+0xFFFFFFFF`
3. `lui` sign-extension — `lui 0x80000 + addi -1` produced a negative 64-bit value

A fourth remains: `0x7FFFFFFF` now builds as `0xFFFF_FFFF_FFFF_FFFF` in the trace,
which is the builder again, not the RTL. **No RTL defect has been demonstrated by
this test** — every mismatch so far has traced to constant construction.

Until the builder is correct, the 10,593 directed checks above are *designed* coverage,
not *executed* coverage. The table describes what the test intends to cover; it should
not be read as what has passed.
