# CLIC-lite: status

`rtl/rv64_clic.sv` — a core-local interrupt controller, the AIA/CLIC alternative to
PLIC. The difference that matters to a CPU: **PLIC delivers one external line and
software claims a source; CLIC delivers the cause number directly**, so the trap
handler knows what fired without a claim round-trip.

Eight sources, each with a 3-bit priority (7 highest), level/edge selection, and a
selective-hardware-vectoring bit. Arbitration picks the highest priority, lowest
index breaks ties. Outputs `irq`, `cause_id` and `cause_valid`.

## Test result

    CLIC_RESULT checks=10 errors=2
    CLIC: FAIL

**Passing (8 of 10):**
- level 0 never raises `irq`
- a configured source raises `irq` with the right `cause_id` and `cause_valid`
- a deasserted level source clears on acknowledge
- higher priority wins (`level 5` beats `level 1`)
- the lower source is delivered after the higher one is acknowledged

**Failing (2 of 10):**
- an edge-sensitive source does not latch its pending bit
- consequently the edge source's `cause_id` is never reported

## Diagnosis

The configuration write reaches `edge_q` correctly (`cfg_addr[3]` selects the
edge/shv word, `[2:0]` the source), and the pending logic is:

    if (ack && ack_id == i)        pending[i] <= 0;
    else if (edge_q[i])            if (src[i] && !src_q[i]) pending[i] <= 1;
    else                           pending[i] <= src[i];

The level path works, so `pending_q` and the arbitration are sound. The edge path is
not setting pending on the rising transition — most likely `src_q` is updated in the
same `always_ff` and the comparison samples the wrong cycle, which would be the same
class of non-blocking-ordering mistake that cost time on the Montgomery multiplier.

## Why this is committed as-is

The level-sensitive path is complete and tested, and CLIC's value over PLIC is the
vectored cause delivery, which works. The edge path is one fix away. Shipping the
file with a testbench that says exactly what passes and what does not is more useful
than either hiding the failure or withholding the working 80%.

Not integrated into `riscv_core_top` yet — that needs the cause delivery wired into
the trap logic, which is the next step after the edge fix.
