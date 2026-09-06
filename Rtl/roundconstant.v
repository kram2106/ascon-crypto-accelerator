`timescale 1ns/1ns
// =============================================================================
// roundconstant — ASCON round constant addition
// =============================================================================
// Selects the round constant for the current permutation round based on the
// round counter (ctr) and total round count (rounds), and XORs it into the
// low byte of state word x2, per the ASCON specification.
// =============================================================================

module roundconstant (
    input  [63:0] x2,
    input  [3:0]  ctr,
    input  [3:0]  rounds,
    output [63:0] out
);
    reg  [7:0] rc;
    wire [3:0] index = ctr + (15 - rounds);

    always @(*) begin
        case (index)
            4'd0:  rc = 8'h3c;
            4'd1:  rc = 8'h2d;
            4'd2:  rc = 8'h1e;
            4'd3:  rc = 8'h0f;
            4'd4:  rc = 8'hf0;
            4'd5:  rc = 8'he1;
            4'd6:  rc = 8'hd2;
            4'd7:  rc = 8'hc3;
            4'd8:  rc = 8'hb4;
            4'd9:  rc = 8'ha5;
            4'd10: rc = 8'h96;
            4'd11: rc = 8'h87;
            4'd12: rc = 8'h78;
            4'd13: rc = 8'h69;
            4'd14: rc = 8'h5a;
            4'd15: rc = 8'h4b;
            default: rc = 8'h00;
        endcase
    end

    assign out = x2 ^ {56'b0, rc};
endmodule
