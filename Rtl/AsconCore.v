`timescale 1ns/1ns
// =============================================================================
// AsconCore — Unified Encryption / Decryption FSM
// =============================================================================
// Implements the ASCON authenticated encryption/decryption state machine:
// Initialization -> Associated Data -> Plaintext/Ciphertext (PTCT) ->
// Finalization -> Done.
//
// Per-block output interface:
//   Rather than buffering the full Y-bit output internally, this module
//   exposes each processed PTCT block combinationally through:
//     block_data_out   [r-1:0] — XOR result for the current block
//     block_data_valid          — asserted for one cycle when the block is valid
//     block_ctr_out    [7:0]   — current PTCT block counter (for byte-mapping
//                                 in the top-level output accumulator)
//   This keeps the output path off the state-register / key-XOR finalization
//   critical path, at the cost of requiring the top module to own the output
//   accumulator instead.
// =============================================================================

module AsconCore #(
    parameter k = 128,
    parameter r = 128,
    parameter a = 12,
    parameter b = 8,
    parameter l = 256,
    parameter y = 256,
    parameter v = 1
)(
    input           clk,
    input           rst,
    input  [k-1:0]  key,
    input  [127:0]  nonce,
    input  [l-1:0]  associated_data,
    input  [y-1:0]  plain_text,
    input  [y-1:0]  cipher_text_in,
    input           enc_start,
    input           dec_start,

    // Combinational per-block outputs
    output wire [r-1:0] block_data_out,
    output wire          block_data_valid,
    output wire [7:0]    block_ctr_out,

    output [127:0]  tag,
    output          core_ready,
    output          mode_out
);

    localparam MODE_ENC = 1'b0;
    localparam MODE_DEC = 1'b1;

    parameter c     = 320 - r;
    parameter nz_ad = ((l+1)%r == 0) ? 0 : r - ((l+1)%r);
    parameter L     = l + 1 + nz_ad;
    parameter s     = L / r;
    parameter nz_p  = ((y+1)%r == 0) ? 0 : r - ((y+1)%r);
    parameter Y     = y + 1 + nz_p;
    parameter t     = Y / r;
    parameter CTR_P = $clog2(t+1);

    localparam [7:0]  IV_rate = r >> 3;
    localparam [15:0] IV_k    = k;
    localparam [3:0]  IV_b    = b;
    localparam [3:0]  IV_a    = a;
    localparam [7:0]  IV_v    = v;

    wire [63:0] IV;
    assign IV = { 16'h0000, IV_rate, IV_k, IV_b, IV_a, 8'h00, IV_v };

    // -----------------------------------------------------------------------
    // FSM states
    // -----------------------------------------------------------------------
    localparam IDLE            = 3'd0,
               INITIALIZE      = 3'd1,
               ASSOCIATED_DATA = 3'd2,
               PTCT            = 3'd3,
               FINALIZE        = 3'd4,
               DONE            = 3'd5;

    reg [2:0] state;

    reg          mode;
    reg [319:0]  S;
    reg [127:0]  Tag;
    reg [CTR_P-1:0] block_ctr;

    reg  [319:0] P_in;
    wire [319:0] P_out;
    wire         perm_ready;
    reg          perm_start;
    reg  [3:0]   rounds;

    wire [r-1:0] Sr;
    wire [c-1:0] Sc;
    assign {Sr, Sc} = S;

    // Expose block_ctr as 8-bit wire for top-module byte-mapping
    assign block_ctr_out = {{(8-CTR_P){1'b0}}, block_ctr};

    reg [127:0]  Tag_d;
    reg          core_ready_r;

    reg [r-1:0]  P_padded_last;
    integer      local_bki;

    reg [L-1:0] A_padded;
    reg [Y-1:0] msg_padded;
    integer     ki;

    // -----------------------------------------------------------------------
    // Combinational per-block output registers (no clock — pure combinational
    // logic assigned inside the always @(*) block below).
    // -----------------------------------------------------------------------
    reg [r-1:0] block_data_r;
    reg          block_valid_r;

    assign block_data_out   = block_data_r;
    assign block_data_valid = block_valid_r;

    wire [319:0] S_key_xor = S ^ ({{r{1'b0}}, key, {(c-k){1'b0}}});

    assign tag        = core_ready_r ? Tag  : 128'b0;
    assign core_ready = core_ready_r;
    assign mode_out   = mode;

    // -----------------------------------------------------------------------
    // Sequential FSM
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            mode      <= MODE_ENC;
            S         <= 0;
            block_ctr <= 0;
        end else begin
            case (state)

                IDLE: begin
                    if (enc_start || dec_start) begin
                        S         <= {IV, key, nonce};
                        block_ctr <= 0;
                        mode      <= enc_start ? MODE_ENC : MODE_DEC;
                        state     <= INITIALIZE;
                    end
                end

                INITIALIZE: begin
                    if (perm_ready) begin
                        if (l != 0) begin
                            state <= ASSOCIATED_DATA;
                            S     <= P_out ^ {{(320-k){1'b0}}, key};
                        end else if (l == 0 && y != 0) begin
                            state <= PTCT;
                            S     <= (P_out ^ {{(320-k){1'b0}}, key})
                                     ^ {256'b0, 1'b1, 63'b0};
                        end else begin
                            state <= FINALIZE;
                            S     <= (P_out ^ {{(320-k){1'b0}}, key})
                                     ^ {256'b0, 1'b1, 63'b0};
                        end
                    end
                end

                ASSOCIATED_DATA: begin
                    if (perm_ready && block_ctr == s-1) begin
                        block_ctr <= 0;
                        S         <= P_out ^ {256'b0, 1'b1, 63'b0};
                        state     <= (y != 0) ? PTCT : FINALIZE;
                    end else if (perm_ready && block_ctr < s-1) begin
                        S         <= P_out;
                        block_ctr <= block_ctr + 1;
                    end
                end

                PTCT: begin
                    if (perm_ready && block_ctr == t-1) begin
                        block_ctr <= 0;
                        if (mode == MODE_ENC)
                            S <= {Sr ^ msg_padded[Y-1-(block_ctr*r) -: r], Sc};
                        else
                            S <= P_in;
                        state <= FINALIZE;
                    end else if (perm_ready && block_ctr < t-1) begin
                        S         <= P_out;
                        block_ctr <= block_ctr + 1;
                    end
                end

                FINALIZE: begin
                    if (perm_ready) begin
                        S     <= P_out;
                        state <= DONE;
                    end
                end

                DONE: begin
                    if (enc_start || dec_start) begin
                        state     <= IDLE;
                        block_ctr <= 0;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Tag register
    // -----------------------------------------------------------------------
    wire tag_en = (state == FINALIZE && perm_ready) |
                  (state == DONE     && (enc_start | dec_start));

    always @(posedge clk) begin
        if (rst)
            Tag <= 0;
        else if (tag_en) begin
            if (state == FINALIZE)
                Tag <= Tag_d;
            else
                Tag <= 0;
        end
    end

    // -----------------------------------------------------------------------
    // Combinational logic
    //
    // block_data_r = the current PTCT block's XOR result (r bits).
    // block_valid_r = 1 exactly when state==PTCT && perm_ready==1.
    // For the last decryption block, the byte-loop writes to both
    // block_data_r (for output) and P_padded_last (for state update).
    // -----------------------------------------------------------------------
    always @(*) begin
        Tag_d        = 128'b0;
        core_ready_r = 1'b0;
        perm_start   = 1'b0;
        rounds       = a;
        P_in         = S;
        P_padded_last= {r{1'b0}};
        block_data_r = {r{1'b0}};
        block_valid_r= 1'b0;

        // ---------- A_padded ------------------------------------------------
        A_padded = {L{1'b0}};
        for (ki = 0; ki < L/8; ki = ki + 1) begin
            if (ki < l/8)
                A_padded[(L/64 - 1 - ki/8)*64 + (ki%8)*8 +: 8] =
                    associated_data[l-1 - ki*8 -: 8];
            else if (ki == l/8)
                A_padded[(L/64 - 1 - ki/8)*64 + (ki%8)*8 +: 8] = 8'h01;
        end

        // ---------- msg_padded ----------------------------------------------
        msg_padded = {Y{1'b0}};
        if (mode == MODE_ENC) begin
            for (ki = 0; ki < Y/8; ki = ki + 1) begin
                if (ki < y/8)
                    msg_padded[(Y/64 - 1 - ki/8)*64 + (ki%8)*8 +: 8] =
                        plain_text[y-1 - ki*8 -: 8];
                else if (ki == y/8)
                    msg_padded[(Y/64 - 1 - ki/8)*64 + (ki%8)*8 +: 8] = 8'h01;
            end
        end else begin
            for (ki = 0; ki < Y/8; ki = ki + 1) begin
                if (ki < y/8)
                    msg_padded[(Y/64 - 1 - ki/8)*64 + (ki%8)*8 +: 8] =
                        cipher_text_in[y-1 - ki*8 -: 8];
                else if (ki == y/8)
                    msg_padded[(Y/64 - 1 - ki/8)*64 + (ki%8)*8 +: 8] = 8'h01;
            end
        end

        // ---------- FSM combinational ---------------------------------------
        case (state)

            IDLE: begin
                perm_start = 1'b0;
                rounds     = a;
                P_in       = S;
            end

            INITIALIZE: begin
                rounds     = a;
                P_in       = S;
                perm_start = perm_ready ? 1'b0 : 1'b1;
            end

            ASSOCIATED_DATA: begin
                rounds     = b;
                P_in       = {Sr ^ A_padded[L-1-(block_ctr*r) -: r], Sc};
                perm_start = (perm_ready && block_ctr == s-1) ? 1'b0 : 1'b1;
            end

            PTCT: begin
                rounds = b;

                if (mode == MODE_ENC) begin
                    block_data_r  = Sr ^ msg_padded[Y-1-(block_ctr*r) -: r];
                    block_valid_r = perm_ready;
                    P_in          = {block_data_r, Sc};

                end else begin // MODE_DEC
                    if (block_ctr < t-1) begin
                        // Non-last decryption block
                        block_data_r  = Sr ^ msg_padded[Y-1-(block_ctr*r) -: r];
                        block_valid_r = perm_ready;
                        P_in          = {msg_padded[Y-1-(block_ctr*r) -: r], Sc};
                    end else begin
                        // Last decryption block: partial plaintext, byte masking
                        P_padded_last = {r{1'b0}};
                        for (local_bki = 0; local_bki < r/8; local_bki = local_bki + 1) begin
                            if ((block_ctr*(r/8) + local_bki) < Y/8) begin
                                if ((block_ctr*(r/8) + local_bki) < y/8) begin
                                    block_data_r[(r/64 - 1 - local_bki/8)*64 +
                                                 (local_bki%8)*8 +: 8] =
                                        Sr[(r/64 - 1 - local_bki/8)*64 +
                                           (local_bki%8)*8 +: 8] ^
                                        msg_padded[(Y/64 - 1 -
                                                   (block_ctr*(r/8)+local_bki)/8)*64 +
                                                   ((block_ctr*(r/8)+local_bki)%8)*8 +: 8];

                                    P_padded_last[(r/64 - 1 - local_bki/8)*64 +
                                                  (local_bki%8)*8 +: 8] =
                                        Sr[(r/64 - 1 - local_bki/8)*64 +
                                           (local_bki%8)*8 +: 8] ^
                                        msg_padded[(Y/64 - 1 -
                                                   (block_ctr*(r/8)+local_bki)/8)*64 +
                                                   ((block_ctr*(r/8)+local_bki)%8)*8 +: 8];

                                end else if ((block_ctr*(r/8) + local_bki) == y/8) begin
                                    P_padded_last[(r/64 - 1 - local_bki/8)*64 +
                                                  (local_bki%8)*8 +: 8] = 8'h01;
                                end
                            end
                        end
                        block_valid_r = perm_ready;
                        P_in          = {Sr ^ P_padded_last, Sc};
                    end
                end

                perm_start = (perm_ready && block_ctr == t-1) ? 1'b0 : 1'b1;
            end

            FINALIZE: begin
                rounds     = a;
                P_in       = S_key_xor;
                perm_start = perm_ready ? 1'b0 : 1'b1;
                Tag_d      = P_out[k-1:0] ^ key;
            end

            DONE: begin
                rounds       = a;
                P_in         = 320'b0;
                perm_start   = 1'b0;
                core_ready_r = 1'b1;
            end

            default: begin
                rounds     = 4'd0;
                P_in       = S;
                perm_start = 1'b0;
            end
        endcase
    end

    Permutation p1 (
        .clk    (clk),
        .reset  (rst),
        .S      (P_in),
        .out    (P_out),
        .done   (perm_ready),
        .rounds (rounds),
        .start  (perm_start)
    );

endmodule
