`timescale 1ns/1ns
// =============================================================================
// Permutation — ASCON round permutation datapath
// =============================================================================
// Applies `rounds` iterations of the ASCON permutation (round constant
// addition -> substitution layer -> linear diffusion layer) to a 320-bit
// state, one round per clock cycle, starting from S when start is asserted
// and ctr == 0.
// =============================================================================

module Permutation (
    input           clk,
    input           reset,
    input   [319:0] S,
    input   [3:0]   rounds,
    input           start,
    output  [319:0] out,
    output          done
);
    reg [3:0] ctr;
    reg       done_r;

    always @(posedge clk) begin
        if (reset)
            ctr <= 0;
        else begin
            if (done_r || ~start)
                ctr <= 0;
            else
                ctr <= ctr + 1;
        end
    end

    reg  [63:0] x0_q, x1_q, x2_q, x3_q, x4_q;
    wire [63:0] x0_d, x1_d, x2_d, x3_d, x4_d;

    always @(posedge clk) begin
        if (reset)
            {x0_q, x1_q, x2_q, x3_q, x4_q} <= 0;
        else if (start) begin
            if (ctr == 0)
                {x0_q, x1_q, x2_q, x3_q, x4_q} <= S;
            else begin
                x0_q <= x0_d;
                x1_q <= x1_d;
                x2_q <= x2_d;
                x3_q <= x3_d;
                x4_q <= x4_d;
            end
        end
    end

    always @(posedge clk) begin
        if (reset)
            done_r <= 0;
        else if (~start)
            done_r <= 0;
        else
            done_r <= (ctr == rounds);
    end

    assign done = done_r;
    assign out  = {x0_q, x1_q, x2_q, x3_q, x4_q};

    wire [63:0] rc_out;
    roundconstant u0 (.x2(x2_q), .ctr(ctr), .out(rc_out), .rounds(rounds));

    wire [63:0] s10, s11, s12, s13, s14;
    sub_layer u1 (
        .x0(x0_q), .x1(x1_q), .x2(rc_out),
        .x3(x3_q), .x4(x4_q),
        .s10(s10), .s11(s11), .s12(s12), .s13(s13), .s14(s14)
    );

    linear_layer u2 (
        .X0(s10), .X1(s11), .X2(s12), .X3(s13), .X4(s14),
        .Y0(x0_d), .Y1(x1_d), .Y2(x2_d), .Y3(x3_d), .Y4(x4_d)
    );
endmodule
