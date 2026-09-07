`timescale 1ns/1ps

// =============================================================================
// tb_sic.v - SIC + Ascon Integration Testbench
// =============================================================================
// Drives the ASCON SIC entirely through its memory-mapped bus interface
// (as PicoRV32 would), rather than driving the Ascon core's serial pins
// directly. Validates the SIC's register map, bus protocol, and its
// serialization/deserialization to and from the Ascon core.
//
// Supports:
//   - Any AD_W and PT_W (not constrained to multiples of 8)
//   - Multi-rate-block messages (AD_W or PT_W > 128 bits)
//   - AD_W != PT_W
//
// Bus field protocol:
//   Variable-width fields (AD, PT, CT) are written/read as ceil(W/32)
//   consecutive 32-bit words, MSB word first (word 0 = MSB). Tasks
//   sic_write_field / sic_read_field handle this automatically for any
//   width using a word loop - no manual bit-slicing needed.
// =============================================================================

`define k   128
`define r   128
`define a   12
`define b   8
`define l   176        // AD width in bits
`define y    80        // PT/CT width in bits

`define KEY          128'h000102030405060708090A0B0C0D0E0F
`define NONCE        128'h101112131415161718191A1B1C1D1E1F
`define AD           176'h303132333435363738393A3B3C3D3E3F404142434445
`define PT           80'h12345678912345678912
`define EXPECTED_CT  80'ha4b6df6deb511726846d
`define EXPECTED_TAG 128'h19676e6ac6066e64518fb18625a1e40a

module tb_sic;

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    localparam CLK_PERIOD = 10;
    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    reg rst;

    // -------------------------------------------------------------------------
    // Load `defines into sized regs (Verilog-2001: can't slice `define directly)
    // -------------------------------------------------------------------------
    reg [127:0]   KEY_REG;
    reg [127:0]   NON_REG;
    reg [`l-1:0]  AD_REG;
    reg [`y-1:0]  PT_REG;
    reg [`y-1:0]  EXP_CT_REG;
    reg [127:0]   EXP_TAG_REG;

    initial begin
        KEY_REG     = `KEY;
        NON_REG     = `NONCE;
        AD_REG      = `AD;
        PT_REG      = `PT;
        EXP_CT_REG  = `EXPECTED_CT;
        EXP_TAG_REG = `EXPECTED_TAG;
    end

    // -------------------------------------------------------------------------
    // Derived constants (must match ascon_sic.v localparams exactly)
    // -------------------------------------------------------------------------
    localparam AD_WORDS  = (`l + 31) / 32;
    localparam PT_WORDS  = (`y + 31) / 32;

    localparam MAX_AD_PT = (`l >= `y) ? `l : `y;
    localparam MAX_W     = (MAX_AD_PT >= 128) ? MAX_AD_PT : 128;
    localparam CAPTURE   = (`y >= 128) ? `y : 128;

    localparam KEY_OFF   = MAX_W - 128;
    localparam NON_OFF   = MAX_W - 128;
    localparam AD_OFF    = MAX_W - `l;
    localparam PT_OFF    = MAX_W - `y;

    // Register map offsets (must match ascon_sic.v localparams)
    localparam [31:0] BASE       = 32'h1000_0000;
    localparam [15:0] CTRL       = 16'h0000;
    localparam [15:0] STATUS     = 16'h0004;
    localparam [15:0] KEY_BASE   = 16'h0008;
    localparam [15:0] NON_BASE   = 16'h0018;
    localparam [15:0] AD_BASE    = 16'h0028;
    localparam [15:0] PT_BASE    = AD_BASE   + AD_WORDS * 4;
    localparam [15:0] CTIN_BASE  = PT_BASE   + PT_WORDS * 4;
    localparam [15:0] CTOUT_BASE = CTIN_BASE + PT_WORDS * 4;
    localparam [15:0] PTOUT_BASE = CTOUT_BASE+ PT_WORDS * 4;
    localparam [15:0] TAGE_BASE  = PTOUT_BASE+ PT_WORDS * 4;
    localparam [15:0] TAGD_BASE  = TAGE_BASE + 16;

    // -------------------------------------------------------------------------
    // Bus signals
    // -------------------------------------------------------------------------
    reg         mem_valid;
    reg  [31:0] mem_addr;
    reg  [31:0] mem_wdata;
    reg  [ 3:0] mem_wstrb;
    wire [31:0] mem_rdata;
    wire        mem_ready;
    wire        ascon_rst_wire;

    // Serial wires SIC <-> Ascon
    wire sic_key, sic_nonce, sic_ad;
    wire sic_pt,  sic_ct_in;
    wire sic_enc_start, sic_dec_start;
    wire ascon_enc_ct,  ascon_enc_tag,  ascon_enc_ready;
    wire ascon_dec_pt,  ascon_dec_tag,  ascon_dec_ready;

    // =========================================================================
    // DUT instantiation
    // =========================================================================

    ascon_sic #(
        .AD_W (`l),
        .PT_W (`y)
    ) sic_dut (
        .clk                 (clk),
        .rst                 (rst),
        .mem_valid           (mem_valid),
        .mem_ready           (mem_ready),
        .mem_addr            (mem_addr),
        .mem_wdata           (mem_wdata),
        .mem_wstrb           (mem_wstrb),
        .mem_rdata           (mem_rdata),
        .ascon_rst           (ascon_rst_wire),
        .keyxSO              (sic_key),
        .noncexSO            (sic_nonce),
        .associated_dataxSO  (sic_ad),
        .plain_textxSO       (sic_pt),
        .cipher_textxSO      (sic_ct_in),
        .enc_startxSO        (sic_enc_start),
        .dec_startxSO        (sic_dec_start),
        .enc_cipher_textxSI  (ascon_enc_ct),
        .enc_tagxSI          (ascon_enc_tag),
        .enc_readyxSI        (ascon_enc_ready),
        .dec_plain_textxSI   (ascon_dec_pt),
        .dec_tagxSI          (ascon_dec_tag),
        .dec_readyxSI        (ascon_dec_ready)
    );

    Ascon #(
        .k (`k), .r (`r), .a (`a), .b (`b),
        .l (`l), .y (`y), .v (1)
    ) ascon_dut (
        .clk                 (clk),
        .rst                 (ascon_rst_wire),
        .keyxSI              (sic_key),
        .noncexSI            (sic_nonce),
        .associated_dataxSI  (sic_ad),
        .plain_textxSI       (sic_pt),
        .enc_startxSI        (sic_enc_start),
        .enc_cipher_textxSO  (ascon_enc_ct),
        .enc_tagxSO          (ascon_enc_tag),
        .enc_readyxSO        (ascon_enc_ready),
        .cipher_textxSI      (sic_ct_in),
        .dec_startxSI        (sic_dec_start),
        .dec_plain_textxSO   (ascon_dec_pt),
        .dec_tagxSO          (ascon_dec_tag),
        .dec_readyxSO        (ascon_dec_ready)
    );

    // =========================================================================
    // Basic bus tasks
    // =========================================================================

    task sic_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_addr  = addr;
            mem_wdata = data;
            mem_wstrb = 4'b1111;
            @(posedge clk);
            while (!mem_ready) @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_wstrb = 4'b0000;
        end
    endtask

    task sic_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_addr  = addr;
            mem_wstrb = 4'b0000;
            @(posedge clk);
            while (!mem_ready) @(posedge clk);
            data = mem_rdata;
            @(negedge clk);
            mem_valid = 1'b0;
        end
    endtask

    // =========================================================================
    // sic_write_field
    //
    // Writes an arbitrary-width field to the SIC via ceil(W/32) consecutive
    // 32-bit bus writes, word 0 = MSB word:
    //   full word  (W - w*32 >= 32): sends data[W-1-w*32 -: 32]
    //   last word  (W - w*32 <  32): sends data[W%32-1:0] zero-extended
    //
    // Usage: sic_write_field(base_addr, reg_value, width_in_bits)
    // =========================================================================

    reg [MAX_W-1:0] wf_data;
    integer wf_w, wf_nwords, wf_bits_left, wf_word_bits;
    reg [31:0] wf_word;

    task sic_write_field;
        input [31:0]    base_addr;
        input [MAX_W-1:0] data;    // field value, right-aligned (LSB at bit 0)
        input integer   width;     // field width in bits
        integer         w;
        reg [31:0]      word;
        integer         hi, lo, wb;
        begin
            for (w = 0; w < (width + 31) / 32; w = w + 1) begin
                hi = width - 1 - w*32;
                lo = (hi >= 31) ? hi - 31 : 0;
                wb = hi - lo + 1;  // number of valid bits in this word
                word = (data >> lo) & ((wb == 32) ? 32'hFFFF_FFFF
                                                   : ((32'h1 << wb) - 1));
                sic_write(base_addr + w*4, word);
            end
        end
    endtask

    // =========================================================================
    // sic_read_field
    //
    // Reads an arbitrary-width field from ceil(W/32) consecutive 32-bit
    // registers and reassembles it into a MAX_W-bit staging register.
    // Word 0 = MSB word; result is right-aligned (result[W-1:0]).
    // =========================================================================

    reg [MAX_W-1:0] rf_result;
    integer rf_w, rf_hi, rf_lo, rf_wb;
    reg [31:0] rf_word;

    task sic_read_field;
        input  [31:0]    base_addr;
        input  integer   width;
        output [MAX_W-1:0] result;
        integer          w;
        reg [31:0]       word;
        integer          hi, lo, wb;
        reg [MAX_W-1:0]  accum;
        begin
            accum = {MAX_W{1'b0}};
            for (w = 0; w < (width + 31) / 32; w = w + 1) begin
                sic_read(base_addr + w*4, word);
                hi = width - 1 - w*32;
                lo = (hi >= 31) ? hi - 31 : 0;
                wb = hi - lo + 1;
                accum = accum | (({MAX_W{1'b0}} | (word & ((wb == 32) ? 32'hFFFF_FFFF
                                                                        : ((32'h1<<wb)-1))))
                                  << lo);
            end
            result = accum;
        end
    endtask

    // =========================================================================
    // Result capture registers
    // =========================================================================
    reg [31:0]     rd;
    reg [MAX_W-1:0] field_buf;       // temp for sic_read_field
    reg [`y-1:0]   enc_ct_cap;
    reg [127:0]    enc_tag_cap;
    reg [`y-1:0]   dec_pt_cap;
    reg [127:0]    dec_tag_cap;

    integer enc_start_t, dec_start_t, overall_t;
    integer enc_cyc, dec_cyc, tot_cyc;

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        mem_valid   = 0;
        mem_addr    = 0;
        mem_wdata   = 0;
        mem_wstrb   = 0;
        enc_ct_cap  = 0;
        enc_tag_cap = 0;
        dec_pt_cap  = 0;
        dec_tag_cap = 0;

        $display("");
        $display("========================================================");
        $display("   SIC + ASCON  FULL VERIFICATION TESTBENCH            ");
        $display("========================================================");
        $display("  k=%0d r=%0d a=%0d b=%0d l=%0d y=%0d", `k,`r,`a,`b,`l,`y);
        $display("  AD_WORDS=%0d  PT_WORDS=%0d", AD_WORDS, PT_WORDS);
        $display("  MAX_W=%0d  CAPTURE=%0d", MAX_W, CAPTURE);
        $display("  KEY_OFF=%0d  AD_OFF=%0d  PT_OFF=%0d", KEY_OFF, AD_OFF, PT_OFF);
        $display("  AD_BASE=0x%04h  PT_BASE=0x%04h  CTIN_BASE=0x%04h",
                  AD_BASE, PT_BASE, CTIN_BASE);
        $display("  CTOUT_BASE=0x%04h  PTOUT_BASE=0x%04h", CTOUT_BASE, PTOUT_BASE);
        $display("  TAGE_BASE=0x%04h  TAGD_BASE=0x%04h", TAGE_BASE, TAGD_BASE);
        $display("  KEY     = %h", KEY_REG);
        $display("  NONCE   = %h", NON_REG);
        $display("  AD      = %h", AD_REG);
        $display("  PT      = %h", PT_REG);
        $display("  EXP CT  = %h", EXP_CT_REG);
        $display("  EXP TAG = %h", EXP_TAG_REG);
        $display("========================================================");

        // =====================================================================
        // PHASE 1: Reset
        // =====================================================================
        rst = 1;
        repeat(5) @(posedge clk);
        rst = 0;
        repeat(3) @(posedge clk);
        overall_t = $time;

        // =====================================================================
        // PHASE 2: Write KEY, NONCE, AD, PT
        //
        // KEY / NONCE: always 4 x 32-bit words (128 bits), sliced from reg.
        // AD / PT: variable width, written word-by-word via sic_write_field,
        //          supporting any bit width including multi-block sizes.
        // =====================================================================
        $display("[Phase 2] Writing KEY, NONCE, AD, PT...");

        sic_write(BASE + KEY_BASE + 0,  KEY_REG[127:96]);
        sic_write(BASE + KEY_BASE + 4,  KEY_REG[95:64]);
        sic_write(BASE + KEY_BASE + 8,  KEY_REG[63:32]);
        sic_write(BASE + KEY_BASE + 12, KEY_REG[31:0]);

        sic_write(BASE + NON_BASE + 0,  NON_REG[127:96]);
        sic_write(BASE + NON_BASE + 4,  NON_REG[95:64]);
        sic_write(BASE + NON_BASE + 8,  NON_REG[63:32]);
        sic_write(BASE + NON_BASE + 12, NON_REG[31:0]);

        sic_write_field(BASE + AD_BASE, {{(MAX_W-`l){1'b0}}, AD_REG}, `l);
        sic_write_field(BASE + PT_BASE, {{(MAX_W-`y){1'b0}}, PT_REG}, `y);

        $display("[Phase 2] Done.");

        // =====================================================================
        // PHASE 3: Trigger ENCRYPTION
        // SIC stalls mem_ready until it completes the full serial operation.
        // =====================================================================
        $display("[Phase 3] Triggering encryption...");
        enc_start_t = $time;
        sic_write(BASE + CTRL, 32'h0000_0001);
        enc_cyc = ($time - enc_start_t) / CLK_PERIOD;
        $display("[Phase 3] Encryption done in %0d cycles.", enc_cyc);

        // =====================================================================
        // PHASE 4: Read and verify encryption results
        // =====================================================================
        sic_read(BASE + STATUS, rd);
        if (rd[0] !== 1'b1) $display("  FAIL: enc_done not set (STATUS=%h)", rd);
        else                 $display("  PASS: enc_done set");

        sic_read_field(BASE + CTOUT_BASE, `y, field_buf);
        enc_ct_cap = field_buf[`y-1:0];

        sic_read(BASE + TAGE_BASE + 0,  rd); enc_tag_cap[127:96] = rd;
        sic_read(BASE + TAGE_BASE + 4,  rd); enc_tag_cap[95:64]  = rd;
        sic_read(BASE + TAGE_BASE + 8,  rd); enc_tag_cap[63:32]  = rd;
        sic_read(BASE + TAGE_BASE + 12, rd); enc_tag_cap[31:0]   = rd;

        $display("");
        $display("--------------------------------------------------------");
        $display("  ENCRYPTION RESULTS");
        $display("--------------------------------------------------------");
        $display("  CT  got : %h", enc_ct_cap);
        $display("  CT  exp : %h  --> %s",
                  EXP_CT_REG, (enc_ct_cap == EXP_CT_REG) ? "PASS" : "FAIL");
        $display("  TAG got : %h", enc_tag_cap);
        $display("  TAG exp : %h  --> %s",
                  EXP_TAG_REG, (enc_tag_cap == EXP_TAG_REG) ? "PASS" : "FAIL");
        $display("--------------------------------------------------------");

        // =====================================================================
        // PHASE 5: Write CT_IN for decryption (captured CT)
        // KEY, NONCE, AD remain in SIC registers - no rewrite needed.
        // =====================================================================
        $display("[Phase 5] Writing CT_IN = captured CT...");
        sic_write_field(BASE + CTIN_BASE,
                        {{(MAX_W-`y){1'b0}}, enc_ct_cap}, `y);
        $display("[Phase 5] Done.");

        // =====================================================================
        // PHASE 6: Trigger DECRYPTION
        // =====================================================================
        $display("[Phase 6] Triggering decryption...");
        dec_start_t = $time;
        sic_write(BASE + CTRL, 32'h0000_0002);
        dec_cyc = ($time - dec_start_t) / CLK_PERIOD;
        $display("[Phase 6] Decryption done in %0d cycles.", dec_cyc);

        // =====================================================================
        // PHASE 7: Read and verify decryption results
        // =====================================================================
        sic_read(BASE + STATUS, rd);
        if (rd[1] !== 1'b1) $display("  FAIL: dec_done not set (STATUS=%h)", rd);
        else                 $display("  PASS: dec_done set");

        sic_read_field(BASE + PTOUT_BASE, `y, field_buf);
        dec_pt_cap = field_buf[`y-1:0];

        sic_read(BASE + TAGD_BASE + 0,  rd); dec_tag_cap[127:96] = rd;
        sic_read(BASE + TAGD_BASE + 4,  rd); dec_tag_cap[95:64]  = rd;
        sic_read(BASE + TAGD_BASE + 8,  rd); dec_tag_cap[63:32]  = rd;
        sic_read(BASE + TAGD_BASE + 12, rd); dec_tag_cap[31:0]   = rd;

        tot_cyc = ($time - overall_t) / CLK_PERIOD;

        $display("");
        $display("--------------------------------------------------------");
        $display("  DECRYPTION RESULTS");
        $display("--------------------------------------------------------");
        $display("  PT  got : %h", dec_pt_cap);
        $display("  PT  exp : %h  --> %s",
                  PT_REG, (dec_pt_cap == PT_REG) ? "PASS" : "FAIL");
        $display("  TAG got : %h", dec_tag_cap);
        $display("  TAG exp : %h  --> %s",
                  EXP_TAG_REG, (dec_tag_cap == EXP_TAG_REG) ? "PASS" : "FAIL");
        $display("--------------------------------------------------------");

        // =====================================================================
        // PHASE 8: Overall summary
        // =====================================================================
        $display("");
        $display("========================================================");
        $display("                    OVERALL SUMMARY");
        $display("========================================================");
        $display("  Enc cycles : %0d", enc_cyc);
        $display("  Dec cycles : %0d", dec_cyc);
        $display("  Total      : %0d", tot_cyc);
        $display("--------------------------------------------------------");
        $display("  CT  match  : %s", (enc_ct_cap  == EXP_CT_REG)  ? "YES" : "NO");
        $display("  Enc TAG    : %s", (enc_tag_cap == EXP_TAG_REG) ? "YES" : "NO");
        $display("  PT  match  : %s", (dec_pt_cap  == PT_REG)      ? "YES" : "NO");
        $display("  Dec TAG    : %s", (dec_tag_cap == EXP_TAG_REG) ? "YES" : "NO");
        $display("--------------------------------------------------------");
        if ((enc_ct_cap  == EXP_CT_REG)  &&
            (enc_tag_cap == EXP_TAG_REG) &&
            (dec_pt_cap  == PT_REG)      &&
            (dec_tag_cap == EXP_TAG_REG))
            $display("  >>> OVERALL : SUCCESS <<<");
        else
            $display("  >>> OVERALL : FAILED  <<<");
        $display("========================================================");
        $display("");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Timeout watchdog
    // -------------------------------------------------------------------------
    initial begin
        #100_000_000;
        $display("TIMEOUT - exceeded watchdog limit");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Event monitors
    // -------------------------------------------------------------------------
    always @(posedge sic_enc_start)   $display("[%0t] enc_start pulsed", $time);
    always @(posedge ascon_enc_ready) $display("[%0t] enc_ready HIGH",   $time);
    always @(posedge sic_dec_start)   $display("[%0t] dec_start pulsed", $time);
    always @(posedge ascon_dec_ready) $display("[%0t] dec_ready HIGH",   $time);

endmodule
