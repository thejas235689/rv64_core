// =============================================================================
// rv64_num_pkg.sv -- definitions for the custom numeric ABI.
//
// The numeric side of the machine has its own 32 x 64-bit register bank, its own
// configuration CSR and its own sticky-flag CSR. Nothing here overlaps with the
// integer register file or the machine CSRs.
//
// Operation encoding (used by the numeric unit now, and by the custom-0 opcode
// when the pipeline path is wired in):
//   NUM_QFMT   fixed-Q Q32.32: add / sub / mul
//   NUM_QUIRE  128-bit exact accumulator: clear / accumulate / read
//   NUM_ADAPT  adaptive precision: truncate to a configured mantissa width
//   NUM_ERR    report the error bound of the last operation
//
// Posit, logarithmic, residue and IEEE-format families have their opcodes
// reserved here (NUM_PADD .. NUM_FMUL) so the encoding is fixed, but they are
// not implemented in this increment and decode to an invalid operation.
// =============================================================================
`default_nettype none
`ifndef RV64_NUM_PKG_SV
`define RV64_NUM_PKG_SV

package rv64_num_pkg;

  // ---------------------------------------------------------------- formats
  // fmt field for the families that take a width/format selector
  localparam logic [2:0] FMT_P8   = 3'd0;   // posit<8,1>
  localparam logic [2:0] FMT_P16  = 3'd1;   // posit<16,1>
  localparam logic [2:0] FMT_P32  = 3'd2;   // posit<32,1>
  localparam logic [2:0] FMT_FP16 = 3'd3;
  localparam logic [2:0] FMT_FP32 = 3'd4;
  localparam logic [2:0] FMT_FP64 = 3'd5;
  localparam logic [2:0] FMT_Q32  = 3'd6;   // Q32.32 fixed point
  localparam logic [2:0] FMT_RNS  = 3'd7;   // 4 x 8-bit prime residues

  // ------------------------------------------------------------- operations
  localparam logic [4:0] NUM_QADD  = 5'd0;   // fixed-Q add
  localparam logic [4:0] NUM_QSUB  = 5'd1;   // fixed-Q subtract
  localparam logic [4:0] NUM_QMUL  = 5'd2;   // fixed-Q multiply
  localparam logic [4:0] NUM_QCLR  = 5'd3;   // quire = 0
  localparam logic [4:0] NUM_QACC  = 5'd4;   // quire += a*b (exact)
  localparam logic [4:0] NUM_QGET  = 5'd5;   // y = quire rounded to Q32.32
  localparam logic [4:0] NUM_ADAPT = 5'd6;   // truncate a to cfg precision
  localparam logic [4:0] NUM_ERR   = 5'd7;   // error bound of the last operation
  // reserved: posit / logarithmic / residue / IEEE research families
  localparam logic [4:0] NUM_PADD  = 5'd8;
  localparam logic [4:0] NUM_PSUB  = 5'd9;
  localparam logic [4:0] NUM_PMUL  = 5'd10;
  localparam logic [4:0] NUM_PDIV  = 5'd11;
  localparam logic [4:0] NUM_LNMUL = 5'd12;
  localparam logic [4:0] NUM_LNDIV = 5'd13;
  localparam logic [4:0] NUM_RADD  = 5'd14;
  localparam logic [4:0] NUM_RMUL  = 5'd15;
  localparam logic [4:0] NUM_FADD  = 5'd16;
  localparam logic [4:0] NUM_FMUL  = 5'd17;
  // bridges between the numeric bank and the integer register file, without
  // which software could never observe a numeric result
  localparam logic [4:0] NUM_TOINT   = 5'd18;   // int rd  <- numeric nrs1
  localparam logic [4:0] NUM_FROMINT = 5'd19;   // numeric nrd <- int rs1

  // ------------------------------------------------------------------ ncfg
  // Configuration CSR layout.
  localparam int CFG_ROUND_SHIFT  = 0;    // [1:0] 0 truncate, 1 round-half-up
  localparam int CFG_SAT_SHIFT    = 2;    // [2]   saturate instead of wrap
  localparam int CFG_PREC_SHIFT   = 8;    // [14:8] adaptive mantissa width (1..64)
  localparam int CFG_ES_SHIFT     = 16;   // [17:16] posit exponent size
  localparam int CFG_PREC_W       = 7;    // width of the precision field
  localparam int CFG_ERREN_SHIFT  = 20;   // [20]  track error bounds
  localparam int CFG_ADAPT_SHIFT  = 21;   // [21]  apply adaptive precision to ops
  localparam int CFG_RSV_SHIFT    = 22;   // [63:22] reserved, read as zero

  localparam logic [63:0] CFG_RESET = 64'h0000_0000_0000_2020; // prec=32, no round

  // ---------------------------------------------------------------- nflags
  // Sticky flag CSR layout. A bit stays set until software writes a one to it.
  localparam int FLAG_OVERFLOW   = 0;
  localparam int FLAG_UNDERFLOW  = 1;
  localparam int FLAG_INEXACT    = 2;
  localparam int FLAG_INVALID    = 3;
  localparam int FLAG_DIVZERO    = 4;
  localparam int FLAG_SATURATE   = 5;
  localparam int FLAG_PRECISION  = 6;
  localparam int FLAG_QUIRE_OVF  = 7;

  // ------------------------------------------------------------------ CSRs
  localparam logic [11:0] CSR_NCFG   = 12'h7C0;   // custom numeric configuration
  localparam logic [11:0] CSR_NFLAGS = 12'h7C1;   // sticky flags
  localparam logic [11:0] CSR_NERR   = 12'h7C2;   // error bound of last operation

  // ------------------------------------------------------------- custom-0
  localparam logic [6:0] OPCODE_CUSTOM0 = 7'b0001011;

endpackage

`endif
`default_nettype wire
