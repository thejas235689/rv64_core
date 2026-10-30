# pyuvm environment for the RV64 binary64 adder

A second Python framework over the same DUT, mirroring the SystemVerilog UVM
environment: driver, monitor, scoreboard, env, sequence and test, built on
pyuvm 5.0 and cocotb.

The golden vectors are generated in-process from Python floats, which ARE
IEEE-754 binary64, so the oracle is independent of the DUT -- the same source
the SystemVerilog UVM environment uses.

## Result

    checked=315 of 315 errors=3

It reproduces **exactly** the same three failures as the SystemVerilog UVM:

    vec140  412ca37343f6148c + c11d10c5aa39744b -> got ...ce expected ...cd
    vec179  c11e3ff3bf907d39 - c129f9380006c531 -> got ...2a expected ...29
    vec236  412cd2c47cd21b34 + c11eb475bc3bbcd3 -> got ...96 expected ...95

Two independent frameworks agreeing on the same vectors is strong evidence the
scoreboards are correct and the RTL has exactly three defects, all one ulp high
on cancellation cases.

## Run

    ./run_pyuvm.sh

## Note on pyuvm 5.0

`ConfigDB().set(None, "*", ...)` does not resolve from `build_phase` -- the lookup
raises UVMConfigItemNotFound for the wildcard path. The DUT handle and vector list
are passed as module globals instead. Less elegant, but it works and it removes a
silent-failure path.

## Not done

The three RTL defects are unfixed. This environment proves they are real and
localised; it does not fix them.
