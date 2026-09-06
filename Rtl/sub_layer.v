`timescale 1ns/1ns
// =============================================================================
// sub_layer — ASCON substitution layer (5-bit S-box, bit-sliced)
// =============================================================================
// Implements the ASCON S-box as five bitwise logical equations operating in
// parallel across all 64 bit-slices of the state, using only AND/XOR/NOT
// gates (no lookup table), per the ASCON specification.
// =============================================================================

module sub_layer (
    input  [63:0] x0, x1, x2, x3, x4,
    output [63:0] s10, s11, s12, s13, s14
);
    assign s10 = (x4 & x1) ^ x3 ^ (x2 & x1) ^ x2 ^ (x1 & x0) ^ x1 ^ x0;
    assign s11 = x4 ^ (x3 & x2) ^ (x3 & x1) ^ x3 ^ x2 ^ x1 ^ x0 ^ (x2 & x1);
    assign s12 = (x4 & x3) ^ x4 ^ x2 ^ x1 ^ 64'hffffffffffffffff;
    assign s13 = (x4 & x0) ^ (x3 & x0) ^ x4 ^ x3 ^ x2 ^ x1 ^ x0;
    assign s14 = (x4 & x1) ^ x4 ^ x3 ^ (x1 & x0) ^ x1;
endmodule
