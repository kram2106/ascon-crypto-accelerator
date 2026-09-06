`timescale 1ns/1ns
// =============================================================================
// linear_layer — ASCON linear diffusion layer (Sigma functions)
// =============================================================================
// Applies the fixed bitwise-rotation-and-XOR diffusion transform to each of
// the five 64-bit state words, per the ASCON specification.
// =============================================================================

module linear_layer (
    input  [63:0] X0, X1, X2, X3, X4,
    output [63:0] Y0, Y1, Y2, Y3, Y4
);
    assign Y0 = X0 ^ ((X0 >> 6'd19) | (X0 << 6'd45))
                   ^ ((X0 >> 6'd28) | (X0 << 6'd36));
    assign Y1 = X1 ^ ((X1 >> 6'd61) | (X1 << 6'd3))
                   ^ ((X1 >> 6'd39) | (X1 << 6'd25));
    assign Y2 = X2 ^ ((X2 >> 6'd1)  | (X2 << 6'd63))
                   ^ ((X2 >> 6'd6)  | (X2 << 6'd58));
    assign Y3 = X3 ^ ((X3 >> 6'd10) | (X3 << 6'd54))
                   ^ ((X3 >> 6'd17) | (X3 << 6'd47));
    assign Y4 = X4 ^ ((X4 >> 6'd7)  | (X4 << 6'd57))
                   ^ ((X4 >> 6'd41) | (X4 << 6'd23));
endmodule
