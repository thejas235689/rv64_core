# Cetaceans RV64 instruction-cache research roadmap

## Baseline and first prototype

The reviewed baseline is `fe816ce`. The core has a 64-set, direct-mapped instruction cache with one 64-bit fetch beat per entry. Fetch already has branch prediction, loop tracking and predecode metadata. The cache exposes an invalidate input, but the reviewed core top ties it low. Core-level FENCE.I must therefore be verified from retirement through fetch restart, cache invalidation and stale-refill handling before it can be claimed.

A local prototype adds compile-time `ICACHE_WAYS`, invalid-way-first allocation and round-robin replacement. It keeps the default at one way and tracks accepted refills so invalidation can drain a stale reply. This document is the roadmap. Runtime adaptation, core-level FENCE.I and the other stages below are separate implementation gates.

## Stages 1–8

| Stage | Research scope | First evidence gate |
| --- | --- | --- |
| 1. Predictive fetch | AI-assisted instruction-stream prediction, multiple branch targets, context and loop awareness, temporal reuse | Compare against existing predictors using MPKI, IPC, prefetch precision and redirect recovery |
| 2. Adaptive organization | 2–16 ways, runtime resizing, 32/64/128-byte lines, power and QoS partitioning | Prove reconfiguration cannot return an obsolete line or drop an accepted fetch; quantify area and timing |
| 3. Space reliability | Multi-bit ECC, scrubbing, soft-error recovery, fault isolation, redundant critical instructions and radiation-hardened cells | Inject correctable and uncorrectable faults; characterize cells with the selected technology and radiation test plan |
| 4. Secure fetch | Randomized placement, secure partitioning, protected tags, side-channel resistance, speculative-fetch controls and root-of-trust integration | Define the threat model, test cross-domain isolation and verify authenticated instruction delivery |
| 5. AI cache policy | Neural and transformer prediction, RL replacement, phase-aware clustering and AI-guided management | Compare against simple policies under equal storage, bandwidth and energy budgets; preserve a deterministic fallback |
| 6. Advanced memory | SRAM/eDRAM, 3D stacking, STT-RAM/MRAM, ReRAM and HBM-backed instruction buffering | Model latency, endurance, energy and bandwidth before selecting a macro or package |
| 7. HPC and exascale | Shared multicore or cluster I-cache, instruction multicast, NUMA placement and chiplet fabric | Verify instruction visibility, ordering, backpressure, fairness and forward progress |
| 8. Future systems | Post-quantum instruction authentication, optical and photonic delivery, compute-in-memory and near-memory instruction engines, autonomous cache control | Separate digital interface prototypes from device and packaging experiments |

## Levels 9–18

| Level | Research question |
| --- | --- |
| 9. Self-evolving cache | Can online learning track per-process working sets and phase changes and tune replacement and prefetch distance within a bounded overhead? |
| 10. Semantic cache | Can decoded operations, dependency graphs and compiler-marked regions be reused while preserving precise traps and code invalidation? |
| 11. Compiler co-design | Can compiler hints, profile-guided hot-code clustering and linker placement reduce conflicts across workloads? |
| 12. Chiplet-aware fabric | Can coherent instruction sharing, migration and predictive code movement reduce latency across chiplets, including optical links? |
| 13. Autonomous reliability | Can aging prediction, spare-line remapping, permanent-fault detection and adjustable ECC extend useful life? |
| 14. Confidential execution | Can partitioning, speculation controls and runtime integrity checks reduce measured leakage and detect instruction tampering? |
| 15. AI-native cache | Do GNNs, transformers, RL, federated learning or dedicated accelerators justify their cost versus simpler predictors? |
| 16. Device research | How do MRAM, FeRAM, RRAM, 3D stacks, backside power and cryogenic operation affect feasible organization? |
| 17. Heterogeneous computing | Can processing-in-memory, photonic delivery and authenticated CPU/GPU/AI instruction distribution share a verifiable contract? |
| 18. Grand challenges | Can a digital twin guide architecture morphing, energy optimization, fault prediction and automated verification toward lower miss rates at very large scale? |

## Implementation order and exit criteria

1. **Fetch correctness.** Test delayed and same-cycle replies, request backpressure, redirects, fill errors and invalidation during refill. Demonstrate self-modifying code through an architectural FENCE.I test.
2. **Configurable cache.** Exercise one, two, four, eight and sixteen ways. Compare conflict traces at equal capacity as well as at equal set count. Record latency, hit rate, area and maximum clock.
3. **Adaptation.** Add explicit way masks and a quiesce/reconfiguration protocol. Design multi-beat refill and line-size changes separately. Prove no mixed-geometry hits.
4. **Reliability and isolation.** Add ECC and scrub arbitration, report uncorrectable errors, and verify partition transitions. Radiation tolerance and physical memory technologies require device-level evidence.
5. **Prediction and scale.** Benchmark simple prefetch and replacement policies before neural policies. Advance to shared and chiplet experiments only after establishing a multicore instruction-visibility contract.

Record the RTL revision, configuration, tool version, workload, seed and test results for every comparison. Keep behavioral simulation, synthesis, physical measurements and research hypotheses distinct.

## Research references

- [NASA Technical Reports Server record 19910015475](https://ntrs.nasa.gov/citations/19910015475)
- [ORNL DESTINY cache modeling project](https://impact.ornl.gov/en/publications/destiny-a-tool-for-modeling-emerging-3d-nvm-and-edram-caches/)
