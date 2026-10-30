# CLIC-lite

`rtl/rv64_clic.sv` — a core-local interrupt controller, the AIA/CLIC alternative to
PLIC. The difference that matters to a CPU: **PLIC delivers one external line and
software claims a source; CLIC delivers the cause number directly**, so the trap
handler knows what fired without a claim round-trip.

Eight sources, each with a 3-bit priority (7 highest), level/edge selection and a
selective-hardware-vectoring bit. Arbitration picks the highest priority, lowest
index breaks ties. Outputs `irq`, `cause_id`, `cause_valid`.

## Status: PASSING

    CLIC_RESULT checks=10 errors=0

All ten checks pass:

- level 0 never raises `irq`
- a configured source raises `irq` with the right `cause_id` and `cause_valid`
- a deasserted level source clears on acknowledge
- higher priority wins (level 5 beats level 1)
- the lower source is delivered after the higher is acknowledged
- an edge-sensitive source latches its pending bit
- an edge source's `cause_id` is reported
- an acknowledged edge source clears

## The bug that cost three turns

The configuration interface originally split level and edge/shv across two
addresses, selected by `cfg_addr[3]`:

```c
if (cfg_addr[3] == 0) level_q[i] <= cfg_wdata[2:0];
else begin edge_q[i] <= cfg_wdata[3]; shv_q[i] <= cfg_wdata[4]; end
```

`edge_q` read back as 0 after a write. I chased the *pending* logic for two turns --
suspecting `src_q` sampling, pulse width, arbitration -- before dumping `edge_q`
itself and finding the configuration had never landed. **The write path was the bug,
not the edge detection.**

The fix is one packed word per source, which removes the address-bit scheme that
invited the mistake:

```c
cfg_wdata = {shv[4], edge[3], level[2:0]}   // one write configures one source
```

A second bug was in the testbench: `{11'd0, 1'b0, e}` puts `e` on bit 0, while the
RTL reads bit 3.

## Not integrated

`riscv_core_top` does not instantiate this. Integration needs `cause_id`/`cause_valid`
wired into the trap logic so the handler can read the vector.
