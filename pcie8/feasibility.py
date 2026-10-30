#!/usr/bin/env python3
"""PCIe 8.0 (draft 0.5) feasibility model.

Answers the questions G6 has to answer before any RTL is written:
what datapath width is needed, how many outstanding bytes are required to
sustain a target payload rate, and what internal buffer that implies.

Every number is labelled as either GIVEN (from the published targets) or
DERIVED (computed here), so nothing architectural is passed off as a fact.
"""

GTS_PER_LANE = 256.0          # GIVEN: announced PCIe 8.0 target, 256 GT/s per lane
LANES_X16    = 16             # GIVEN
BITS_PER_TRANSFER = 1.0       # PAM4: one bit per transfer (1 symbol = 1 bit)


def raw_per_direction_gbps():
    return GTS_PER_LANE * LANES_X16 * BITS_PER_TRANSFER / 8.0


def aggregate_gbps():
    return 2 * raw_per_direction_gbps()


def datapath_options(clock_hz=1e9):
    """Width required to carry the raw rate at a given internal clock."""
    out = []
    for width in (512, 1024, 2048, 4096, 8192):
        gbs = width * clock_hz / 8.0 / 1e9
        out.append((width, gbs))
    return out


def outstanding_bytes(bandwidth_gbs, rtt_ns):
    """Little's law: bytes in flight = rate x latency."""
    return bandwidth_gbs * 1e9 * (rtt_ns * 1e-9)


def tags_for(outstanding_b, txn_bytes):
    return int(-(-outstanding_b // txn_bytes))     # ceil


def main():
    raw = raw_per_direction_gbps()
    print("=== PCIe 8.0 raw rate (GIVEN targets, DERIVED arithmetic) ===")
    print(f"  per direction : {raw:8.1f} GB/s  ({raw/1000:.3f} TB/s)")
    print(f"  aggregate     : {aggregate_gbps():8.1f} GB/s  "
          f"({aggregate_gbps()/1000:.3f} TB/s)")
    print("  note: 1.024 TB/s aggregate is the RAW line rate, not application")
    print("        payload in one direction. Encoding, FEC, framing and")
    print("        protocol overhead all come off the top.")

    print("\n=== internal datapath width at 1 GHz (DERIVED) ===")
    for width, gbs in datapath_options():
        mark = "  <- matches raw" if abs(gbs - raw) < 1.0 else ""
        print(f"  {width:5d} bit x 1 GHz : {gbs:7.1f} GB/s{mark}")
    print("  4096 bit at 1 GHz merely MATCHES the raw rate and leaves no")
    print("  margin for bubbles. Real designs need parallel slices.")

    print("\n=== outstanding bytes required (Little's law, DERIVED) ===")
    for bw in (100, 200, 400, 512):
        for rtt in (200, 500, 1000):
            ob = outstanding_bytes(bw, rtt)
            t128 = tags_for(ob, 128)
            t512 = tags_for(ob, 512)
            print(f"  {bw:3d} GB/s x {rtt:4d} ns = {ob/1024:7.1f} KB outstanding"
                  f"  ({t128:5d} tags @128B, {t512:5d} @512B)")

    print("\n=== what this means for the tag field (DERIVED) ===")
    ob = outstanding_bytes(400, 500)
    t = tags_for(ob, 128)
    print(f"  400 GB/s at 500 ns needs ~{ob/1024:.0f} KB in flight")
    print(f"  at 128 B per read that is {t} outstanding requests")
    print(f"  PCIe Tag is 8 bits (256) or 10 bits with extended tags (1024)")
    print(f"  -> {t} exceeds 256, so extended tags AND multiple functions,")
    print(f"     or larger read sizes, are mandatory. A single-function")
    print(f"     8-bit-tag endpoint cannot reach this rate at all.")


if __name__ == "__main__":
    main()
