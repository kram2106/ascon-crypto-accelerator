`timescale 1ns/1ns
// =============================================================================
// Ascon (Top Module) — Merged Encryption/Decryption Wrapper
// =============================================================================
// Top-level ASCON AEAD core. Wraps AsconCore and handles:
//   - Serial shift-in of key, nonce, associated data, and plaintext/ciphertext
//   - Accumulation of per-block ciphertext/plaintext output (out_hold) using
//     a purely combinational per-block interface from AsconCore
//   - Serial shift-out of the final output data and authentication tag
//
// Output accumulation design note:
//   AsconCore exposes each processed block combinationally (block_data_out,
//   block_data_valid, block_ctr_out) instead of buffering the full output
//   internally. This keeps AsconCore's critical path shorter, since it avoids
//   an additional Y-bit output register sitting alongside the state register
//   and key-XOR finalization logic. The top module instead owns a single
//   y-bit accumulator (out_hold) that assembles these blocks using the same
//   byte-mapping AsconCore would have used internally.
//
//   Serialization of out_hold begins only after core_ready asserts, since at
//   1 bit/cycle the serializer cannot drain a full r-bit block before the
//   next b-round permutation completes.
// =============================================================================

module Ascon #(
    parameter k = 128,
    parameter r = 128,
    parameter a = 12,
    parameter b = 8,
    parameter l = 256,
    parameter y = 256,
    parameter v = 1
)(
    input  clk,
    input  rst,

    // Serial inputs shared by both modes
    input  keyxSI,
    input  noncexSI,
    input  associated_dataxSI,

    // Encryption side
    input  plain_textxSI,
    input  enc_startxSI,
    output reg enc_cipher_textxSO,
    output reg enc_tagxSO,
    output     enc_readyxSO,

    // Decryption side
    input  cipher_textxSI,
    input  dec_startxSI,
    output reg dec_plain_textxSO,
    output reg dec_tagxSO,
    output     dec_readyxSO
);

    // -----------------------------------------------------------------------
    // CNT_MAX for input shift counter
    // -----------------------------------------------------------------------
    localparam CNT_MAX = (k  >= 128 ? k  : 128) >= l ?
                         (k  >= 128 ? k  : 128) >= y ?
                         (k  >= 128 ? k  : 128)       : y
                       : l >= y ? l : y;

    // -----------------------------------------------------------------------
    // bswap128 — single shared byte-swap for all 128-bit quantities
    // -----------------------------------------------------------------------
    function [127:0] bswap128;
        input [127:0] x;
        integer bi;
        begin
            for (bi = 0; bi < 16; bi = bi + 1) begin
                if (bi < 8)
                    bswap128[127 - bi*8 -: 8] = x[64 + bi*8 +: 8];
                else
                    bswap128[127 - bi*8 -: 8] = x[(bi-8)*8 +: 8];
            end
        end
    endfunction

    // -----------------------------------------------------------------------
    // Serial input shift registers
    // -----------------------------------------------------------------------
    reg [k-1:0] key;
    reg [127:0] nonce;
    reg [l-1:0] associated_data;
    reg [y-1:0] plain_text;
    reg [y-1:0] cipher_text_in;
    reg [8:0]   i;

    // -----------------------------------------------------------------------
    // Output serialisation counter
    // -----------------------------------------------------------------------
    reg [8:0] j;

    // -----------------------------------------------------------------------
    // Endianness-corrected key / nonce
    // -----------------------------------------------------------------------
    wire [127:0] key_le   = bswap128(key[127:0]);
    wire [127:0] nonce_le = bswap128(nonce[127:0]);

    // -----------------------------------------------------------------------
    // Start gating: wait until all inputs have been shifted in
    // -----------------------------------------------------------------------
    wire inputs_ready = (i >= k) && (i >= 128) && (i >= l) && (i >= y);
    wire enc_start    = inputs_ready & enc_startxSI;
    wire dec_start    = inputs_ready & dec_startxSI;

    // -----------------------------------------------------------------------
    // Core outputs
    // -----------------------------------------------------------------------
    wire [r-1:0] core_block_out;    // combinational: XOR result for current PTCT block
    wire          core_block_valid; // combinational: 1 when core_block_out is valid
    wire [7:0]    core_block_ctr;   // PTCT block counter (for byte-mapping in out_hold)
    wire [127:0]  core_tag_out;
    wire           core_ready;
    wire           core_mode;

    wire [127:0] tag_be = bswap128(core_tag_out[127:0]);

    assign enc_readyxSO = core_ready & ~core_mode;
    assign dec_readyxSO = core_ready &  core_mode;

    // -----------------------------------------------------------------------
    // out_hold: y-bit output accumulator.
    //
    // For block B, local byte lgi (0-based within block),
    // absolute gi = B*(r/8) + lgi:
    //   out_hold[y-1 - gi*8 -: 8] =
    //       core_block_out[(r/64-1 - lgi/8)*64 + (lgi%8)*8 +: 8]
    //   (when gi < y/8, i.e. the byte falls within the y-bit output)
    //
    // Applied each time core_block_valid fires. After all blocks, out_hold
    // holds the complete output word, ready for serialisation.
    // -----------------------------------------------------------------------
    reg [y-1:0] out_hold;

    integer top_lgi, top_gi;

    always @(posedge clk) begin
        if (rst) begin
            out_hold <= {y{1'b0}};
        end else begin
            if (enc_start || dec_start) begin
                out_hold <= {y{1'b0}};
            end else if (core_block_valid) begin
                for (top_lgi = 0; top_lgi < r/8; top_lgi = top_lgi + 1) begin
                    top_gi = core_block_ctr * (r/8) + top_lgi;
                    if (top_gi < y/8) begin
                        out_hold[y-1 - top_gi*8 -: 8] <=
                            core_block_out[(r/64-1 - top_lgi/8)*64 +
                                           (top_lgi%8)*8 +: 8];
                    end
                end
            end
        end
    end

    wire [y-1:0] data_out_w = out_hold;

    // -----------------------------------------------------------------------
    // Serial input shift + output serialisation.
    // Serialises data_out_w[j] then tag_be[j] once core_ready fires.
    // -----------------------------------------------------------------------
    wire output_en = enc_start | dec_start | core_ready;

    always @(posedge clk) begin
        if (rst) begin
            key                <= 0;
            nonce              <= 0;
            associated_data    <= 0;
            plain_text         <= 0;
            cipher_text_in     <= 0;
            i                  <= 0;
            j                  <= 0;
            enc_cipher_textxSO <= 0;
            enc_tagxSO         <= 0;
            dec_plain_textxSO  <= 0;
            dec_tagxSO         <= 0;
        end else begin
            if (i < k)   key             <= {key[k-2:0],            keyxSI};
            if (i < 128) nonce           <= {nonce[126:0],           noncexSI};
            if (i < l)   associated_data <= {associated_data[l-2:0], associated_dataxSI};
            if (i < y)   plain_text      <= {plain_text[y-2:0],      plain_textxSI};
            if (i < y)   cipher_text_in  <= {cipher_text_in[y-2:0],  cipher_textxSI};

            if (i <= CNT_MAX) i <= i + 1;

            if (output_en) begin
                if (enc_start || dec_start)
                    j <= 0;
                else begin   // core_ready = 1
                    if (~core_mode) begin
                        enc_cipher_textxSO <= (j < y)   ? data_out_w[j] : 1'b0;
                        enc_tagxSO         <= (j < 128) ? tag_be[j]     : 1'b0;
                    end else begin
                        dec_plain_textxSO  <= (j < y)   ? data_out_w[j] : 1'b0;
                        dec_tagxSO         <= (j < 128) ? tag_be[j]     : 1'b0;
                    end
                    j <= j + 1;
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // Single AsconCore instance
    // -----------------------------------------------------------------------
    AsconCore #(
        .k(k), .r(r), .a(a), .b(b), .l(l), .y(y), .v(v)
    ) core (
        .clk             (clk),
        .rst             (rst),
        .key             (key_le),
        .nonce           (nonce_le),
        .associated_data (associated_data),
        .plain_text      (plain_text),
        .cipher_text_in  (cipher_text_in),
        .enc_start       (enc_start),
        .dec_start       (dec_start),
        .block_data_out  (core_block_out),
        .block_data_valid(core_block_valid),
        .block_ctr_out   (core_block_ctr),
        .tag             (core_tag_out),
        .core_ready      (core_ready),
        .mode_out        (core_mode)
    );

endmodule
