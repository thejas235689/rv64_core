# CLIC-lite: status

`rtl/rv64_clic.sv` — a core-local interrupt controller, the AIA/CLIC alternative to
PLIC. The difference that matters to a CPU: **PLIC delivers one external line and
software claims a source; CLIC delivers the cause number directly**, so the trap
handler knows what fired without a claim round-trip.

Eight sources, each with a 3-bit priority (7 highest), level/edge selection and a
selective-hardware-vectoring bit. Arbitration picks the highest priority, lowest
index breaks ties. Outputs `irq`, `cause_id`, `cause_valid`.

## Test result

    CLIC_RESULT checks=10 errors=2

**Passing (8 of 10)**
- level 0 never raises `irq`
- a configured source raises `irq` with the right `cause_id` and `cause_valid`
- a deasserted level source clears on acknowledge
- higher priority wins (level 5 beats level 1)
- the lower source is delivered after the higher is acknowledged
- the edge source's pending bit latches *(intermittent — see below)*

**Failing (2 of 10)**
- the edge source's pending bit does not latch reliably
- consequently its `cause_id` is never reported

## What has been ruled out

The config write path is **correct**, and this was proven by finding a testbench bug
rather than an RTL bug:

    cfg_wdata = {11'd0, 1'b0, e};     // e lands on bit 0
    cfg_wdata = {12'd0, e, 2'b00};    // e lands on bit 3 -- what the RTL reads

With that fixed, `edge_q` is set correctly and `level_q` reads back as programmed
(levels 0=2, 1=1, 3=5, 5=4 in the dump). So the configuration interface works.

The arbitration loop is also sound: the five level-path checks exercise it and pass,
including priority ordering and tie-breaking.

## Remaining fault

The edge *pulse* is missed. A dump at the check shows `pending = 00000000` with the
levels correctly programmed, so the pending bit never set on the rising transition.
Either `src_q` is sampled in the wrong cycle, or the two-cycle pulse in the testbench
is shorter than the synchroniser needs. That is one focused probe away — print
`src`, `src_q`, `edge_q[5]` and `pending_q[5]` on every cycle across the pulse.

## Not integrated

`riscv_core_top` does not instantiate this. Integration needs `cause_id`/`cause_valid`
wired into the trap logic so the handler can read the vector, which is the step after
the edge fix.
