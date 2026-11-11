`timescale 1ns/1ps
`default_nettype none

// Bounded Type-I Unum arithmetic for the custom numeric ABI.
// esizesize = fsizesize = 2. Starting at bit zero, the fields are fsize-1,
// esize-1, ubit, fraction, exponent and sign. Bits above sign must be zero.
// Exponent and fraction widths are each 1..4. Inputs are exact finite values.
// For this subset, an all-ones exponent is reserved at every width.
// Results use four-bit exponent and fraction fields. An inexact result sets
// ubit and encodes the open interval from the truncated magnitude to the next
// greater magnitude, with the sign applied to both endpoints.
module rv64_num_unum (
  input  logic [2:0]  fmt,  // 0 add, 1 subtract
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic [63:0] result,
  output logic        invalid,
  output logic        overflow,
  output logic        inexact
);
  localparam logic [20:0] MAX_FINITE_UNITS = 21'd253952; // 248 * 2^10

  typedef struct packed {
    logic invalid;
    logic signed [20:0] units;
  } operand_t;

  function automatic operand_t decode(input logic [63:0] raw);
    operand_t operand;
    int unsigned fraction_width, exponent_width, exponent, fraction, bias;
    int unsigned sign_index, exponent_mask, fraction_mask, significand, shift;
    logic signed [20:0] units;
    fraction_width = int'(raw[1:0]) + 1;
    exponent_width = int'(raw[3:2]) + 1;
    sign_index = 5 + fraction_width + exponent_width;
    fraction_mask = (1 << fraction_width) - 1;
    exponent_mask = (1 << exponent_width) - 1;
    fraction = int'(raw >> 5) & fraction_mask;
    exponent = int'(raw >> (5 + fraction_width)) & exponent_mask;
    bias = (1 << (exponent_width - 1)) - 1;
    significand = fraction;
    if (exponent != 0) significand |= 1 << fraction_width;
    // Every input is an integer multiple of 2^-10, including subnormals.
    shift = (exponent == 0 ? 1 : exponent) + 10 - bias - fraction_width;
    units = 21'(significand << shift);
    operand.units = raw[sign_index] ? -units : units;
    operand.invalid = raw[4] || exponent == exponent_mask ||
                      (raw >> (sign_index + 1)) != 0;
    return operand;
  endfunction

  operand_t lhs, rhs;
  logic signed [20:0] sum;
  logic [20:0] magnitude, discarded_mask;
  logic [3:0] encoded_exponent, encoded_fraction;
  int leading_bit, discard_bits;

  always_comb begin
    lhs = decode(a);
    rhs = decode(b);
    sum = fmt == 3'd1 ? $signed(lhs.units) - $signed(rhs.units)
                      : $signed(lhs.units) + $signed(rhs.units);
    magnitude = sum[20] ? $unsigned(-sum) : $unsigned(sum);
    invalid = fmt > 3'd1 || lhs.invalid || rhs.invalid;
    overflow = !invalid && magnitude > MAX_FINITE_UNITS;

    leading_bit = 0;
    for (int bit_index = 0; bit_index < 21; bit_index++)
      if (magnitude[bit_index]) leading_bit = bit_index;

    discard_bits = leading_bit < 4 ? 0 : leading_bit - 4;
    discarded_mask = (21'd1 << discard_bits) - 21'd1;
    encoded_exponent = leading_bit < 4 ? 4'd0 : 4'(leading_bit - 3);
    encoded_fraction = 4'(magnitude >> discard_bits);
    inexact = !invalid && !overflow && (|(magnitude & discarded_mask));
    result = '0;
    if (!invalid && !overflow)
      result[13:0] = {sum[20], encoded_exponent, encoded_fraction, inexact, 4'hf};
  end
endmodule

`default_nettype wire
