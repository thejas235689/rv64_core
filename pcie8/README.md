# PCIe 8.0 research track

This is the G6 research track from `docs/COMPLETION_PLAN.md`, not a controller.

## What is here

`feasibility.py` -- the G6 evidence. Derives the datapath width and outstanding
bytes for the announced 256 GT/s x16 targets. Its main finding: sustaining 400 GB/s
at a 500 ns round trip needs ~1563 outstanding 128-byte reads, which exceeds the
10-bit extended Tag field (1024). A single-function endpoint with standard 8-bit
tags cannot reach the target rate at all.

`rtl/flit_pkg.sv`, `rtl/flit_pack.sv` -- FLIT-mode framing. FLIT mode (introduced in
6.0, continued in 8.0) replaces 128b/130b block framing with fixed-size flits, which
is synthesizable logic. The 256 GT/s line rate and PAM4 are SERDES, not RTL.

`uvm/` -- a UVM environment (driver, monitor, scoreboard, sequencer, two tests).

`pss/flit_pss.pss` -- a PSS model of the packing scenarios, solved with Satya v0.41.0.

## Status

The UVM environment runs under xezim and **fails on a real RTL bug**: the packer's
scoreboard reports 235 byte-ordering errors per flit. Byte 0 lands correctly at the
top of the flit and bytes 1..235 read back as zero, so the accumulator is not
carrying earlier bytes upward as it shifts. The UVM environment is doing its job;
the RTL is not correct yet.

Satya parses and solves the PSS model (4 actions, 0 warnings).

## Not claimed

PCIe 8.0 is draft 0.5. The flit field widths here are modelled on 6.0 and are
marked DERIVED in the package header. No compliance claim is made.
