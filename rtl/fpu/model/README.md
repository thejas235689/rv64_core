# Binary64 adder: bit-exact model

A Python model of `rtl/fpu/rv64_fp_add.sv`, written to be transcribed to RTL line
for line. The point of building it first: the RTL and this model now fail on
**exactly the same three vectors**, which proves the RTL faithfully implements the
algorithm and the algorithm itself is wrong. Six rounds of patching the RTL were
patching a design defect, not a transcription defect.

## Result

    315 vectors, 3 mismatches

    vec140  412ca37343f6148c + c11d10c5aa39744b -> ...ce expected ...cd
    vec179  c11e3ff3bf907d39 - c129f9380006c531 -> ...2a expected ...29
    vec236  412cd2c47cd21b34 + c11eb475bc3bbcd3 -> ...96 expected ...95

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

The model is a specification, not a fix. It fails the same three vectors as the
RTL. It exists so the corrected algorithm can be developed and validated in
software at 315/315 before a single line of RTL changes.
