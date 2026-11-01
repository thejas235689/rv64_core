# Cache verification matrix — assessment against this core

The proposed matrix describes an Arm-style cache subsystem: multi-way, write-back,
AHB5, TrustZone, MPU attributes, DMA coherency. **This core has none of those.** Both
caches are direct-mapped, write-through, and connect to an internal SRAM bus rather
than AHB5.

Checked against the RTL, not against intent.

## What the design actually is

| Property | icache | dcache |
| --- | --- | --- |
| Mapping | direct-mapped | direct-mapped |
| Ways | 1 | 1 |
| Policy | read-only fill | **write-through** |
| Dirty lines | none | none |
| Replacement | none (indexed) | none (indexed) |
| Invalidate port | **absent** | **absent** |
| Coherence | none | none |
| Prefetch | none | none |

Both files state this in their headers. The dcache comment is explicit that
write-through is chosen so page-table walks stay coherent without an invalidation
protocol, and that write-back would need dirty lines and a flush path before Sv39
could trust it.

## Row-by-row

| Area | Applies? | State |
| --- | --- | --- |
| Cache hit | yes | `test_icache_hits`, `test_dcache_hits` pass |
| Cache miss | yes | covered by the above (fill path exercised) |
| Read-after-write | yes | dcache is write-through: a store updates the line **and** memory, so read-after-write is trivially correct and needs no separate scenario |
| Replacement | **no** | direct-mapped — no ways to fill, no victim selection, no policy |
| Dirty eviction | **no** | write-through — a line is never dirty |
| Miss under eviction | **no** | no eviction exists |
| Cache maintenance | **partial** | `test_cache_ops` exercises clean/flush/invalidate as instruction sequences, but there is **no invalidate port in either cache** — the ops act through the memory system, not a maintenance interface |
| AHB5 protocol | **no** | no AHB5 anywhere in `rtl/`. The bus is internal req/rsp with `ready`/`valid` |
| TrustZone | **no** | no secure/non-secure notion. There is PMP (physical memory protection), which is a different mechanism and does not provide TrustZone isolation |
| MPU attributes | **no** | no MPU. PMP gives R/W/X permissions, not cacheable/non-cacheable/Device attributes. The dcache header notes "no uncached-region control" |
| DMA | **no** | no DMA engine, no coherency protocol |
| Reset | **partial** | `test_reset` exists and passes; it does not specifically cover reset during an outstanding miss |
| Low power | **no** | no clock gating, no power state, no retention |

## The rows that would matter here, if rewritten

Five of the thirteen rows describe features this core does not have and will not get
without a redesign. The rows that map onto real risk in *this* design:

1. **Miss under a stalled bus** — the fill path holds the request until the response
   arrives. What happens if the bus never responds? (This is the live bug: see below.)
2. **Store that misses** — goes straight to memory and does not allocate. Worth a
   directed test that a store-then-load to the same line is correct.
3. **Straddling access** — the dcache header says the LSU guarantees it never issues
   one. That is an assumption between two modules and deserves a test, not a comment.
4. **Self-modifying code** — the icache has no invalidate port, so a store followed by
   an instruction fetch of the same address serves stale data. `fence.i` cannot help
   without a port. This is a real functional gap, not a missing test.
5. **Reset during a fill** — the FSM returns to `C_IDLE`, but a bus transaction may
   still be outstanding.

## A live bug this exercise surfaced

A seven-instruction program containing two stores **hangs**:

```
icache cst=C_IDLE  req_valid=1  hit=0  resp_valid=0   (forever)
```

The I-cache accepts an instruction fetch and never answers, and never forwards to L2.
Every simple program passes; this one does not. `tb_two_store` reproduces it. Item 1
above — a fill that never completes — is the most likely mechanism.

## Recommendation

Do not adopt the proposed matrix as-is. Roughly 60% of it verifies features that do
not exist, which makes it read as coverage while measuring nothing. Replace the
inapplicable rows with the five above, and fix the I-cache hang before adding cache
tests — a cache that cannot serve a second instruction is not ready for a
hit/miss/replacement matrix.
