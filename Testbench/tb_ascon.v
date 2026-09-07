`timescale 1ns/1ns

// =============================================================================
// tb_ascon - Core-level testbench for the Ascon top module
// =============================================================================
// Directly drives the Ascon module's serial interface (bypassing the SIC/SoC)
// to validate the cryptographic core in isolation against a known NIST test
// vector, covering both encryption and decryption.
//
// Flow:
//   1. Reset the core.
//   2. Serial-load Key, Nonce, AD, PT (MSB-first, offset-based loading so
//      any combination of AD width (l) and PT width (y) - including l < 128
//      or y < 128 - loads every register correctly).
//   3. Assert enc_start -> wait for enc_ready -> capture CT & Tag_enc.
//   4. Reset, reload Key/Nonce/AD + the captured CT into the decryption path.
//   5. Assert dec_start -> wait for dec_ready -> capture PT_dec & Tag_dec.
//   6. Compare CT, Tag_enc, PT_dec, Tag_dec against expected values and
//      report PASS/FAIL.
// =============================================================================

`define k   128
`define r   128         // ASCON-AEAD128: rate = 128 bits
`define a   12
`define b   8
`define l   40          // AD length in bits
`define y   40          // PT/CT length in bits
`define v   1

`define KEY           128'h2db083053e848cefa30007336c47a5a1
`define NONCE         128'h3f3607dbce3503ba84f5843d623de056
`define AD             40'h4153434f4e
`define PT             40'h48656c6c6f

`define EXPECTED_CT    40'h4e3dad0405
`define EXPECTED_TAG  128'h75aca5ad78c4136c6b31266ab5b55698

module tb_ascon;

    // -----------------------------------------------------------------------
    // Clock
    // -----------------------------------------------------------------------
    parameter PERIOD = 20;
    reg clk = 0;
    always #(PERIOD/2) clk = ~clk;

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    reg  rst                  = 1;
    reg  keyxSI               = 0;
    reg  noncexSI             = 0;
    reg  associated_dataxSI   = 0;
    reg  plain_textxSI        = 0;   // to enc core
    reg  cipher_textxSI       = 0;   // to dec core
    reg  enc_startxSI         = 0;
    reg  dec_startxSI         = 0;

    wire enc_cipher_textxSO;
    wire enc_tagxSO;
    wire enc_readyxSO;
    wire dec_plain_textxSO;
    wire dec_tagxSO;
    wire dec_readyxSO;

    // -----------------------------------------------------------------------
    // Capture registers
    // -----------------------------------------------------------------------
    reg [`y-1:0]  enc_ct_cap  = 0;
    reg [127:0]   enc_tag_cap = 0;
    reg [`y-1:0]  dec_pt_cap  = 0;
    reg [127:0]   dec_tag_cap = 0;

    // -----------------------------------------------------------------------
    // Serial-send registers
    // -----------------------------------------------------------------------
    reg [127:0]  key_send   = `KEY;
    reg [127:0]  nonce_send = `NONCE;
    reg [`l-1:0] ad_send    = `AD;
    reg [`y-1:0] pt_send    = `PT;
    reg [`y-1:0] ct_send    = 0;   // filled from enc_ct_cap after encryption

    // -----------------------------------------------------------------------
    // MAX_W: number of serial-load cycles - must cover every shift register.
    // -----------------------------------------------------------------------
    localparam MAX_W = (`l >= `y) ? ((`l >= 128) ? `l : 128)
                                  : ((`y >= 128) ? `y : 128);

    // -----------------------------------------------------------------------
    // CAPTURE: number of serial-output cycles - must cover CT/PT and TAG.
    // -----------------------------------------------------------------------
    localparam CAPTURE = (`y >= 128) ? `y : 128;

    // -----------------------------------------------------------------------
    // Per-signal MSB-alignment offsets inside the MAX_W-wide shift window.
    // -----------------------------------------------------------------------
    localparam KEY_OFF   = MAX_W - 128;
    localparam NONCE_OFF = MAX_W - 128;
    localparam AD_OFF    = MAX_W - `l;
    localparam PT_OFF    = MAX_W - `y;
    localparam CT_OFF    = MAX_W - `y;

    integer i;
    integer enc_start_time, dec_start_time, overall_start_time;
    integer enc_cycles, dec_cycles, total_cycles;

    // -----------------------------------------------------------------------
    // DUT instantiation
    // -----------------------------------------------------------------------
    Ascon #(`k, `r, `a, `b, `l, `y, `v) dut (
        .clk                 (clk),
        .rst                 (rst),
        .keyxSI              (keyxSI),
        .noncexSI            (noncexSI),
        .associated_dataxSI  (associated_dataxSI),
        .plain_textxSI       (plain_textxSI),
        .enc_startxSI        (enc_startxSI),
        .enc_cipher_textxSO  (enc_cipher_textxSO),
        .enc_tagxSO          (enc_tagxSO),
        .enc_readyxSO        (enc_readyxSO),
        .cipher_textxSI      (cipher_textxSI),
        .dec_startxSI        (dec_startxSI),
        .dec_plain_textxSO   (dec_plain_textxSO),
        .dec_tagxSO          (dec_tagxSO),
        .dec_readyxSO        (dec_readyxSO)
    );

    // -----------------------------------------------------------------------
    // Waveform dump
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("tb_ascon.vcd");
        $dumpvars(0, tb_ascon);
    end

    // =======================================================================
    // Main stimulus
    // =======================================================================
    initial begin
        // -------------------------------------------------------------------
        // Banner & parameters
        // -------------------------------------------------------------------
        $display("");
        $display("========================================================");
        $display("           ASCON WRAPPER - FULL SYSTEM TESTBENCH        ");
        $display("========================================================");
        $display("  PARAMETERS:");
        $display("    k=%0d  r=%0d  a=%0d  b=%0d  l=%0d  y=%0d  v=%0d",
                  `k, `r, `a, `b, `l, `y, `v);
        $display("    MAX_W=%0d  CAPTURE=%0d", MAX_W, CAPTURE);
        $display("    KEY_OFF=%0d  NONCE_OFF=%0d  AD_OFF=%0d  PT_OFF=%0d  CT_OFF=%0d",
                  KEY_OFF, NONCE_OFF, AD_OFF, PT_OFF, CT_OFF);
        $display("  INPUTS:");
        $display("    KEY   : %h", `KEY);
        $display("    NONCE : %h", `NONCE);
        $display("    AD    : %h", `AD);
        $display("    PT    : %h", `PT);
        $display("  EXPECTED:");
        $display("    CT    : %h", `EXPECTED_CT);
        $display("    TAG   : %h", `EXPECTED_TAG);
        $display("========================================================");

        // -------------------------------------------------------------------
        // Phase 1 - Reset
        // -------------------------------------------------------------------
        rst = 1;
        repeat(4) @(posedge clk);
        overall_start_time = $time;

        // -------------------------------------------------------------------
        // Phase 2 - Serial load enc core: Key, Nonce, AD, PT
        //
        // Offset-based MSB-first loading: each signal is gated by its own
        // offset so shorter signals (l < 128 or y < 128) are zero-padded on
        // the left automatically.
        // -------------------------------------------------------------------
        $display("");
        $display("[Phase 2] Serial loading enc core (%0d cycles)...", MAX_W);

        key_send   = `KEY;
        nonce_send = `NONCE;
        ad_send    = `AD;
        pt_send    = `PT;
        ct_send    = 0;

        @(negedge clk);
        rst                = 0;
        // First bit: index MAX_W-1 in the shifted window
        keyxSI             = (MAX_W-1 >= KEY_OFF)   ? key_send  [MAX_W-1 - KEY_OFF]   : 1'b0;
        noncexSI           = (MAX_W-1 >= NONCE_OFF) ? nonce_send[MAX_W-1 - NONCE_OFF] : 1'b0;
        associated_dataxSI = (MAX_W-1 >= AD_OFF)    ? ad_send   [MAX_W-1 - AD_OFF]    : 1'b0;
        plain_textxSI      = (MAX_W-1 >= PT_OFF)    ? pt_send   [MAX_W-1 - PT_OFF]    : 1'b0;
        cipher_textxSI     = 1'b0;

        for (i = MAX_W-2; i >= 0; i = i - 1) begin
            @(negedge clk);
            keyxSI             = (i >= KEY_OFF)   ? key_send  [i - KEY_OFF]   : 1'b0;
            noncexSI           = (i >= NONCE_OFF) ? nonce_send[i - NONCE_OFF] : 1'b0;
            associated_dataxSI = (i >= AD_OFF)    ? ad_send   [i - AD_OFF]    : 1'b0;
            plain_textxSI      = (i >= PT_OFF)    ? pt_send   [i - PT_OFF]    : 1'b0;
            cipher_textxSI     = 1'b0;
        end

        @(negedge clk);
        keyxSI = 0; noncexSI = 0; associated_dataxSI = 0;
        plain_textxSI = 0; cipher_textxSI = 0;
        repeat(2) @(posedge clk);
        $display("[Phase 2] Serial load complete.");

        // -------------------------------------------------------------------
        // Phase 3 - Trigger encryption
        // -------------------------------------------------------------------
        $display("");
        $display("[Phase 3] Starting encryption ...");
        enc_start_time = $time;

        @(negedge clk);
        enc_startxSI = 1;
        @(negedge clk);
        enc_startxSI = 0;

        begin : wait_enc
            integer timeout;
            timeout = 0;
            while (!enc_readyxSO && timeout < 2000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 2000) begin
                $display("ERROR: Timeout waiting for enc_readyxSO");
                $finish;
            end
        end

        enc_cycles = ($time - enc_start_time) / PERIOD;
        $display("[Phase 3] Encryption complete in %0d cycles.", enc_cycles);

        // -------------------------------------------------------------------
        // Phase 4 - Capture CT and Tag from enc core (outputs LSB-first).
        // Loop runs CAPTURE = max(y,128) times; CT is gated at y bits,
        // TAG is gated at 128 bits.
        // -------------------------------------------------------------------
        @(posedge clk);
        enc_ct_cap[0]  = enc_cipher_textxSO;
        enc_tag_cap[0] = enc_tagxSO;

        for (i = 1; i < CAPTURE; i = i + 1) begin
            @(posedge clk);
            if (i < `y)  enc_ct_cap[i]  = enc_cipher_textxSO;
            if (i < 128) enc_tag_cap[i] = enc_tagxSO;
        end

        $display("");
        $display("--------------------------------------------------------");
        $display("  ENCRYPTION RESULTS");
        $display("--------------------------------------------------------");
        $display("  Cycles (enc)    : %0d", enc_cycles);
        $display("  Captured CT     : %h", enc_ct_cap);
        $display("  Expected CT     : %h  --> %s",
                  `EXPECTED_CT, (enc_ct_cap == `EXPECTED_CT) ? "PASS" : "FAIL");
        $display("  Captured Tag    : %h", enc_tag_cap);
        $display("  Expected Tag    : %h  --> %s",
                  `EXPECTED_TAG, (enc_tag_cap == `EXPECTED_TAG) ? "PASS" : "FAIL");
        $display("--------------------------------------------------------");

        // -------------------------------------------------------------------
        // Phase 5 - Reset both cores, then reload with:
        //           Key, Nonce, AD (same as enc) + CAPTURED CT from enc.
        // Uses the same offset-based MSB-first loading as Phase 2, with
        // CT_OFF for the cipher_text shift register.
        // -------------------------------------------------------------------
        $display("");
        $display("[Phase 5] Reloading dec core with captured CT ...");

        ct_send    = enc_ct_cap;
        key_send   = `KEY;
        nonce_send = `NONCE;
        ad_send    = `AD;

        // Reset so wrapper internal counters go back to 0
        @(negedge clk);
        rst = 1;
        repeat(2) @(posedge clk);

        @(negedge clk);
        rst                = 0;
        // First bit: index MAX_W-1 in the shifted window
        keyxSI             = (MAX_W-1 >= KEY_OFF)   ? key_send  [MAX_W-1 - KEY_OFF]   : 1'b0;
        noncexSI           = (MAX_W-1 >= NONCE_OFF) ? nonce_send[MAX_W-1 - NONCE_OFF] : 1'b0;
        associated_dataxSI = (MAX_W-1 >= AD_OFF)    ? ad_send   [MAX_W-1 - AD_OFF]    : 1'b0;
        plain_textxSI      = 1'b0;
        cipher_textxSI     = (MAX_W-1 >= CT_OFF)    ? ct_send   [MAX_W-1 - CT_OFF]    : 1'b0;

        for (i = MAX_W-2; i >= 0; i = i - 1) begin
            @(negedge clk);
            keyxSI             = (i >= KEY_OFF)   ? key_send  [i - KEY_OFF]   : 1'b0;
            noncexSI           = (i >= NONCE_OFF) ? nonce_send[i - NONCE_OFF] : 1'b0;
            associated_dataxSI = (i >= AD_OFF)    ? ad_send   [i - AD_OFF]    : 1'b0;
            plain_textxSI      = 1'b0;
            cipher_textxSI     = (i >= CT_OFF)    ? ct_send   [i - CT_OFF]    : 1'b0;
        end

        @(negedge clk);
        keyxSI = 0; noncexSI = 0; associated_dataxSI = 0;
        plain_textxSI = 0; cipher_textxSI = 0;
        repeat(2) @(posedge clk);
        $display("[Phase 5] Dec core reload complete.");

        // -------------------------------------------------------------------
        // Phase 6 - Trigger decryption
        // -------------------------------------------------------------------
        $display("");
        $display("[Phase 6] Starting decryption ...");
        dec_start_time = $time;

        @(negedge clk);
        dec_startxSI = 1;
        @(negedge clk);
        dec_startxSI = 0;

        begin : wait_dec
            integer timeout;
            timeout = 0;
            while (!dec_readyxSO && timeout < 2000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 2000) begin
                $display("ERROR: Timeout waiting for dec_readyxSO");
                $finish;
            end
        end

        dec_cycles = ($time - dec_start_time) / PERIOD;
        $display("[Phase 6] Decryption complete in %0d cycles.", dec_cycles);

        // -------------------------------------------------------------------
        // Phase 6b - Capture PT and Tag from dec core (outputs LSB-first).
        // -------------------------------------------------------------------
        @(posedge clk);
        dec_pt_cap[0]  = dec_plain_textxSO;
        dec_tag_cap[0] = dec_tagxSO;

        for (i = 1; i < CAPTURE; i = i + 1) begin
            @(posedge clk);
            if (i < `y)  dec_pt_cap[i]  = dec_plain_textxSO;
            if (i < 128) dec_tag_cap[i] = dec_tagxSO;
        end

        total_cycles = ($time - overall_start_time) / PERIOD;

        // -------------------------------------------------------------------
        // Phase 7 - Results
        // -------------------------------------------------------------------
        $display("");
        $display("--------------------------------------------------------");
        $display("  DECRYPTION RESULTS");
        $display("--------------------------------------------------------");
        $display("  Cycles (dec)    : %0d", dec_cycles);
        $display("  Captured PT     : %h", dec_pt_cap);
        $display("  Expected PT     : %h  --> %s",
                  `PT, (dec_pt_cap == `PT) ? "PASS" : "FAIL");
        $display("  Captured Tag    : %h", dec_tag_cap);
        $display("  Expected Tag    : %h  --> %s",
                  `EXPECTED_TAG, (dec_tag_cap == `EXPECTED_TAG) ? "PASS" : "FAIL");
        $display("--------------------------------------------------------");

        $display("");
        $display("========================================================");
        $display("                   OVERALL SUMMARY");
        $display("========================================================");
        $display("  Encryption cycles : %0d", enc_cycles);
        $display("  Decryption cycles : %0d", dec_cycles);
        $display("  Total cycles      : %0d", total_cycles);
        $display("--------------------------------------------------------");
        $display("  CT  match         : %s", (enc_ct_cap  == `EXPECTED_CT)  ? "YES" : "NO");
        $display("  Enc Tag match     : %s", (enc_tag_cap == `EXPECTED_TAG) ? "YES" : "NO");
        $display("  PT  match         : %s", (dec_pt_cap  == `PT)           ? "YES" : "NO");
        $display("  Dec Tag match     : %s", (dec_tag_cap == `EXPECTED_TAG) ? "YES" : "NO");
        $display("--------------------------------------------------------");

        if ((enc_ct_cap  == `EXPECTED_CT)  &&
            (enc_tag_cap == `EXPECTED_TAG) &&
            (dec_pt_cap  == `PT)           &&
            (dec_tag_cap == `EXPECTED_TAG)) begin
            $display("  >>> OVERALL CRYPTOGRAPHY : SUCCESS <<<");
        end else begin
            $display("  >>> OVERALL CRYPTOGRAPHY : FAILED  <<<");
        end

        $display("========================================================");
        $display("");
        $finish;
    end

endmodule
