# Binary64 adder: bit-exact model

A Python model of `rtl/fpu/rv64_fp_add.sv`, written to be transcribed to RTL line
for line. The point of building it first: the RTL and this model now fail on
**exactly the same three vectors**, which proves the RTL faithfully implements the
algorithm and the algorithm itself is wrong. Six rounds of patching the RTL were
patching a design defect, not a transcription defect.

## Result

    model: 315 vectors, 0 mismatches

PASSES. The fix was to align into a field WIDER than the 53-bit significand
(53 + 3 extra bits) so the low bits are KEPT rather than collapsed into a
single sticky. The result exponent can drop below e_big during normalisation,
which makes those low bits representable -- collapsing them made an exact sum
look like it needed rounding. That was the three-ulp defect.

The model previously reproduced the RTL's exact three failures:

    vec140  412ca37343f6148c + c11d10c5aa39744b -> ...ce expected ...cd
    vec179  c11e3ff3bf907d39 - c129f9380006c531 -> ...2a expected ...29
    vec236  412cd2c47cd21b34 + c11eb475bc3bbcd3 -> ...96 expected ...95

That is what proved the RTL faithfully implemented a wrong algorithm.

## The defect, diagnosed

`vec140`'s true sum is **exact** in units of the final significand:

    true sum in FINAL ulp units = 7940814134228173
      fractional : 0
      exact?     : True
      tie?       : False

No rounding should occur. The model rounds because the alignment sticky is
collapsed to one bit at weight zero, but `b`'s lowest bit sits at **exactly one
ulp of the final result** — the result exponent drops by one during
normalisation, so that bit is representable and must be kept, not turned into a
sticky.

## What the fix must do

Three guard bits are not enough on their own; the guard field has to be sized
against the *worst-case exponent drop*, not the input exponent difference. The
practical route is to align into a wider field (54 fraction bits plus 3 guard
bits) and let the normalisation shift the sticky up into the fraction rather than
collapsing it.

That is a rewrite of the alignment and normalise stages together, which is why
incremental patches to the RTL kept failing.

## Status

The model is correct: 315/315. The RTL is not yet: still 312/315.

Transcribing it is not mechanical -- my first attempts changed the working-format
widths without matching every dependent slice and broke the working cases. The
transcription must mirror these exactly:

    mag_big = sig_big(53) << 5              sig at [57:5]
    aligned = (sig_sml(53) << 3) >> diff    56 bits, low bits kept
    mag_sml = (aligned << 2) | sticky       aligned at [57:2]
    normalise until bit 57 is set
    frac = norm[56:5]  round = norm[4]  guard = norm[3]  sticky = |norm[2:0]

The model is the specification. No RTL change should land until it matches.
