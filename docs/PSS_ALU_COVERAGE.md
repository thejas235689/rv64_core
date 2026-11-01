# PSS coverage — rv64_alu_matrix.pss

Measured, not asserted. Every figure below comes from running
`satya gen pss/rv64_alu_matrix.pss --backend json --action <a> --seed <n>`
over a range of seeds and counting distinct solved values.

Satya v0.42.0, from the official release tarball.

## Per-field coverage — 60 seeds

Every field reaches **100%** of its declared domain.

| Action.field | Covered | Domain |
| --- | --- | --- |
| `alu_pair.op_index` | 7 / 7 = **100%** | 0..6 |
| `alu_pair.a_class` | 15 / 15 = **100%** | 0..14 |
| `alu_pair.b_class` | 15 / 15 = **100%** | 0..14 |
| `alu_imm.op_index` | 6 / 6 = **100%** | 0..5 |
| `alu_imm.a_class` | 15 / 15 = **100%** | 0..14 |
| `alu_imm.imm_class` | 8 / 8 = **100%** | 0..7 |

Distinct solutions per action from 60 seeds: `alu_pair` 56, `alu_imm` 60,
`alu_sign_boundary` 28, `alu_coverage` 59.

## Tuple coverage — 120 seeds

This is the number that matters, and it is much lower.

| Coverage goal | Achieved | Total |
| --- | --- | --- |
| `alu_pair` (op, a_class) pairs | 76 / 105 = **72%** | 105 |
| `alu_pair` (op, a_class, b_class) triples | 106 / 1575 = **6%** | 1575 |
| `alu_imm` (op, a_class, imm_class) triples | 120 / 720 = **16%** | 720 |
| `alu_sign_boundary` full tuple | 31 / 32 = **96%** | 32 |

## What this means

**The solver explores fields independently, not combinations.** Each field is uniformly
covered, but the joint space is barely touched: 120 seeds reach 6% of the 1,575
op×a×b triples. Doubling the seeds does not fix this — the space is 1,575 and a uniform
draw needs on the order of 1,575 × ln(1,575) ≈ 11,700 samples for full coupon-collector
coverage.

The `same_class` constraint works: both values of the flag appear, and when it solves to
1 the solver returns `a_class == b_class`, confirming the inline unnamed constraint form
is honoured.

`alu_sign_boundary` reaches 96% because its space is only 32 combinations, which shows
the model itself is fine — it is the *size* of the pair/triple space that defeats uniform
sampling.

## How to actually get high coverage

Three options, in order of cost:

1. **Pin one dimension per run.** Solve `alu_pair` once per `op_index` value by adding
   an equality constraint, turning one 1,575-space into seven 225-space problems. Each
   needs ~225 × ln(225) ≈ 1,220 seeds for full coverage — still large, but parallel and
   bounded per operation.
2. **Drive the matrix from the generator instead.** The class indices are already
   indices, not literals, so `gen_alu_matrix.py` can enumerate the 1,575 combinations
   directly and use the solver only for operand *values* within a class. That gives
   provable 100% triple coverage for a fixed cost.
3. **Accept per-field coverage as the goal.** If the intent is "every operation met
   every operand class at least once" — which is what the request describes — then 100%
   per field already satisfies it, and the 6% triple figure is measuring something
   stronger than was asked for.

**Recommendation: option 2.** The PSS model's job here is to describe intent and let the
solver pick values; using it to sample a combinatorial matrix is fighting the tool. The
directed cocotb test already enumerates all 1,089 pairs exhaustively, and the PSS layer
adds value by choosing *operand values* within each class, not by choosing which cells to
visit.

## Reproduce

```bash
satya check pss/rv64_alu_matrix.pss
satya gen pss/rv64_alu_matrix.pss --backend json --action alu_pair --seed 1
```

The measurement script is `pss/measure_alu_coverage.py`.
