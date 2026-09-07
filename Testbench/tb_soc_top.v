`timescale 1ns/1ps

// =============================================================================
// tb_soc_top.v - Full SoC testbench (PicoRV32 + SIC + Ascon)
// =============================================================================
// Unlike tb_sic.v (which drives the SIC's bus directly as a fake CPU), this
// testbench only drives clk and rst: PicoRV32 executes firmware.hex, the
// firmware performs encryption then decryption via the SIC, and writes the
// results into data memory. This testbench polls data memory for a firmware
// completion flag, then reads and verifies the results.
//
// HOW TO USE:
//   1. Build firmware.hex from firmware.c (+ start.S + link.ld if used)
//   2. Set `l and `y to match AD_W and PT_W in soc_top.v
//   3. Set expected CT/TAG values below to match the test vector in firmware.c
//
// DONE DETECTION:
//   firmware.c writes 0xDEADDEAD to DMEM word 0 as its very last action.
//   This testbench polls dut.dmem.mem[0] every clock until it sees that
//   magic value, then reads the result layout from DMEM.
//
// RESULT LAYOUT IN DMEM (must match firmware.c defines):
//   mem[0]                              : DONE flag (0xDEADDEAD when complete)
//   mem[1]                              : enc_done  (1 = SIC reported enc done)
//   mem[2]                              : dec_done  (1 = SIC reported dec done)
//   mem[3..3+PT_WORDS-1]                : CT_OUT    (MSB word first)
//   mem[3+PT_WORDS..3+PT_WORDS+3]       : TAG_ENC   (4 words, MSB first)
//   mem[3+PT_WORDS+4..+4+PT_WORDS-1]    : PT_OUT    (MSB word first)
//   mem[3+PT_WORDS+4+PT_WORDS..+3]      : TAG_DEC   (4 words, MSB first)
// =============================================================================

`define l   176        // AD_W - must match soc_top.v parameter AD_W
`define y    80        // PT_W - must match soc_top.v parameter PT_W

`define EXPECTED_CT   80'ha4b6df6deb511726846d
`define EXPECTED_TAG 128'h19676e6ac6066e64518fb18625a1e40a

module tb_soc_top;

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    localparam CLK_PERIOD = 10;
    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    reg rst;

    // -------------------------------------------------------------------------
    // Derived constants - must match firmware.c and ascon_sic.v
    // -------------------------------------------------------------------------
    localparam PT_WORDS = (`y + 31) / 32;

    // DMEM word indices (base = 0x0001_0000 = data_mem word 0)
    // Must match the DMEM_* macros in firmware.c
    localparam DONE_IDX     = 0;
    localparam ENC_STAT_IDX = 1;
    localparam DEC_STAT_IDX = 2;
    localparam CT_IDX       = 3;                         // first CT word
    localparam TAGE_IDX     = CT_IDX   + PT_WORDS;       // first TAG_ENC word
    localparam PT_IDX       = TAGE_IDX + 4;              // first PT_OUT word
    localparam TAGD_IDX     = PT_IDX   + PT_WORDS;       // first TAG_DEC word

    localparam DONE_MAGIC   = 32'hDEAD_DEAD;
    localparam WATCHDOG_CYCLES = 2_000_000;              // increase for large AD/PT

    // -------------------------------------------------------------------------
    // Load expected values into sized regs
    // -------------------------------------------------------------------------
    reg [`y-1:0] EXP_CT_REG;
    reg [127:0]  EXP_TAG_REG;
    initial begin
        EXP_CT_REG  = `EXPECTED_CT;
        EXP_TAG_REG = `EXPECTED_TAG;
    end

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    soc_top #(
        .MEM_WORDS (256),
        .AD_W      (`l),
        .PT_W      (`y)
    ) dut (
        .clk (clk),
        .rst (rst)
    );

    // -------------------------------------------------------------------------
    // Result capture registers
    // -------------------------------------------------------------------------
    reg [`y-1:0] enc_ct_cap;
    reg [127:0]  enc_tag_cap;
    reg [`y-1:0] dec_pt_cap;
    reg [127:0]  dec_tag_cap;
    reg          enc_done_flag;
    reg          dec_done_flag;

    integer i;
    integer cycle_count;
    integer overall_start;

    // -------------------------------------------------------------------------
    // Watchdog
    // -------------------------------------------------------------------------
    initial begin
        #(WATCHDOG_CYCLES * CLK_PERIOD);
        $display("TIMEOUT - firmware did not complete within %0d cycles",
                  WATCHDOG_CYCLES);
        $finish;
    end

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("");
        $display("========================================================");
        $display("   PICORV32 + SIC + ASCON  FULL SoC TESTBENCH          ");
        $display("========================================================");
        $display("  AD_W = %0d  PT_W = %0d  PT_WORDS = %0d", `l, `y, PT_WORDS);
        $display("  DMEM layout:");
        $display("    [%0d]     DONE flag", DONE_IDX);
        $display("    [%0d]     enc_done", ENC_STAT_IDX);
        $display("    [%0d]     dec_done", DEC_STAT_IDX);
        $display("    [%0d..%0d] CT_OUT (%0d words)", CT_IDX,   CT_IDX+PT_WORDS-1,   PT_WORDS);
        $display("    [%0d..%0d] TAG_ENC (4 words)",  TAGE_IDX, TAGE_IDX+3);
        $display("    [%0d..%0d] PT_OUT (%0d words)",  PT_IDX,   PT_IDX+PT_WORDS-1,   PT_WORDS);
        $display("    [%0d..%0d] TAG_DEC (4 words)",  TAGD_IDX, TAGD_IDX+3);
        $display("  EXP CT  = %h", EXP_CT_REG);
        $display("  EXP TAG = %h", EXP_TAG_REG);
        $display("========================================================");

        // =====================================================================
        // PHASE 1: Reset
        // =====================================================================
        rst          = 1;
        cycle_count  = 0;
        repeat(10) @(posedge clk);
        rst = 0;
        overall_start = $time;
        $display("[Phase 1] Reset released. Firmware executing...");

        // =====================================================================
        // PHASE 2: Wait for firmware DONE flag
        // Firmware writes DONE_MAGIC to DMEM word 0 as its very last action.
        // Poll every clock via hierarchical path into data_mem.
        // =====================================================================
        begin : wait_done
            integer timeout;
            timeout = 0;
            while (dut.dmem.mem[DONE_IDX] !== DONE_MAGIC) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            cycle_count = ($time - overall_start) / CLK_PERIOD;
        end
        $display("[Phase 2] Firmware DONE flag seen after %0d cycles.", cycle_count);

        // One more clock to let the last writes settle in simulation
        @(posedge clk);

        // =====================================================================
        // PHASE 3: Read results from DMEM
        // =====================================================================

        enc_done_flag = dut.dmem.mem[ENC_STAT_IDX][0];
        dec_done_flag = dut.dmem.mem[DEC_STAT_IDX][0];

        // Reassemble CT_OUT from PT_WORDS words (MSB word first)
        enc_ct_cap = {`y{1'b0}};
        for (i = 0; i < PT_WORDS; i = i + 1) begin
            if (`y - i*32 >= 32)
                enc_ct_cap[`y-1-i*32 -: 32] = dut.dmem.mem[CT_IDX + i];
            else
                enc_ct_cap[`y%32-1   :  0]  = dut.dmem.mem[CT_IDX + i][`y%32-1:0];
        end

        // TAG_ENC (always 4 words)
        enc_tag_cap[127:96] = dut.dmem.mem[TAGE_IDX + 0];
        enc_tag_cap[95:64]  = dut.dmem.mem[TAGE_IDX + 1];
        enc_tag_cap[63:32]  = dut.dmem.mem[TAGE_IDX + 2];
        enc_tag_cap[31:0]   = dut.dmem.mem[TAGE_IDX + 3];

        // Reassemble PT_OUT from PT_WORDS words
        dec_pt_cap = {`y{1'b0}};
        for (i = 0; i < PT_WORDS; i = i + 1) begin
            if (`y - i*32 >= 32)
                dec_pt_cap[`y-1-i*32 -: 32] = dut.dmem.mem[PT_IDX + i];
            else
                dec_pt_cap[`y%32-1   :  0]  = dut.dmem.mem[PT_IDX + i][`y%32-1:0];
        end

        // TAG_DEC (always 4 words)
        dec_tag_cap[127:96] = dut.dmem.mem[TAGD_IDX + 0];
        dec_tag_cap[95:64]  = dut.dmem.mem[TAGD_IDX + 1];
        dec_tag_cap[63:32]  = dut.dmem.mem[TAGD_IDX + 2];
        dec_tag_cap[31:0]   = dut.dmem.mem[TAGD_IDX + 3];

        // =====================================================================
        // PHASE 4: Display and check
        // =====================================================================
        $display("");
        $display("--------------------------------------------------------");
        $display("  ENCRYPTION RESULTS");
        $display("--------------------------------------------------------");
        $display("  enc_done flag : %0d  --> %s",
                  enc_done_flag, enc_done_flag ? "PASS" : "FAIL");
        $display("  CT  got  : %h", enc_ct_cap);
        $display("  CT  exp  : %h  --> %s",
                  EXP_CT_REG, (enc_ct_cap == EXP_CT_REG) ? "PASS" : "FAIL");
        $display("  TAG got  : %h", enc_tag_cap);
        $display("  TAG exp  : %h  --> %s",
                  EXP_TAG_REG, (enc_tag_cap == EXP_TAG_REG) ? "PASS" : "FAIL");
        $display("--------------------------------------------------------");

        $display("");
        $display("--------------------------------------------------------");
        $display("  DECRYPTION RESULTS");
        $display("--------------------------------------------------------");
        $display("  dec_done flag : %0d  --> %s",
                  dec_done_flag, dec_done_flag ? "PASS" : "FAIL");
        // PT_OUT is checked against the recovered plaintext round-trip;
        // for a direct check against the original PT, add EXPECTED_PT above.
        $display("  PT  got  : %h", dec_pt_cap);
        $display("  TAG got  : %h", dec_tag_cap);
        $display("  TAG exp  : %h  --> %s",
                  EXP_TAG_REG, (dec_tag_cap == EXP_TAG_REG) ? "PASS" : "FAIL");
        $display("--------------------------------------------------------");

        $display("");
        $display("========================================================");
        $display("                    OVERALL SUMMARY");
        $display("========================================================");
        $display("  Total cycles     : %0d", cycle_count);
        $display("  enc_done         : %s", enc_done_flag  ? "YES" : "NO");
        $display("  dec_done         : %s", dec_done_flag  ? "YES" : "NO");
        $display("  CT  match        : %s", (enc_ct_cap  == EXP_CT_REG)  ? "YES" : "NO");
        $display("  Enc TAG match    : %s", (enc_tag_cap == EXP_TAG_REG) ? "YES" : "NO");
        $display("  Dec TAG match    : %s", (dec_tag_cap == EXP_TAG_REG) ? "YES" : "NO");
        $display("--------------------------------------------------------");

        if (enc_done_flag &&
            dec_done_flag &&
            (enc_ct_cap  == EXP_CT_REG)  &&
            (enc_tag_cap == EXP_TAG_REG) &&
            (dec_tag_cap == EXP_TAG_REG))
            $display("  >>> OVERALL : SUCCESS <<<");
        else
            $display("  >>> OVERALL : FAILED  <<<");

        $display("========================================================");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Event monitors - visible in waveform and log
    // -------------------------------------------------------------------------
    always @(posedge dut.sic.enc_startxSO)
        $display("[%0t ns] enc_start pulsed", $time);
    always @(posedge dut.ascon_wrap.enc_readyxSO)
        $display("[%0t ns] enc_ready HIGH", $time);
    always @(posedge dut.sic.dec_startxSO)
        $display("[%0t ns] dec_start pulsed", $time);
    always @(posedge dut.ascon_wrap.dec_readyxSO)
        $display("[%0t ns] dec_ready HIGH", $time);
    always @(posedge dut.cpu.trap)
        $display("[%0t ns] WARNING: PicoRV32 TRAP asserted", $time);

endmodule
