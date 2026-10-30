`timescale 1ns/1ps
// =============================================================================
// pcie_flit_pkg.sv -- FLIT-mode framing definitions.
//
// FLIT mode arrived with PCIe 6.0 and is the framing 8.0 continues: fixed-size
// flits carrying TLPs plus a data link payload with FEC and CRC, replacing the
// 128b/130b block framing of earlier generations. That framing change IS
// synthesizable logic, which is why it is the one piece of 8.0-adjacent work
// worth building RTL for.
//
// GIVEN  : flits are a fixed size and carry FEC + CRC in a data link payload;
//          the PAM4 line rate does not change the flit format.
// DERIVED: the exact field widths below. PCIe 8.0 is draft 0.5, so the layout
//          here is modelled on 6.0 and MUST be replaced from the selected
//          specification revision before any compliance claim is made.
// =============================================================================
`default_nettype none

package pcie_flit_pkg;

  parameter int FLIT_BYTES     = 256;
  parameter int FLIT_TLP_BYTES = 236;                        // DERIVED
  parameter int FLIT_DLP_BYTES = FLIT_BYTES - FLIT_TLP_BYTES;

  typedef struct packed {
    logic [FLIT_DLP_BYTES*8-1:0] dlp;   // FEC, CRC, framing
    logic [FLIT_TLP_BYTES*8-1:0] tlp;   // byte-continuous across flit boundaries
  } pcie_flit_t;

endpackage

`default_nettype wire
