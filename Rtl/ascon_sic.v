// =============================================================================
// ASCON SERIAL INTERFACE CONTROLLER (SIC) - FULLY PARAMETERIZED
// =============================================================================
// Parameters:
//   AD_W  : AD  width in bits, any positive integer (default 40)
//   PT_W  : PT/CT width in bits, any positive integer (default 40)
//
// No constraint on AD_W or PT_W:
//   - Any bit width (not just multiples of 8)
//   - Multi-rate-block messages (AD_W or PT_W > 128 bits) fully supported
//   - AD_W and PT_W can differ from each other
//
// Hardware registers and counters are sized at compile time from parameters.
// Only the number of SoC clock cycles changes at runtime with message size.
// ASIC synthesis result is invariant to the test vector used.
//
// SERIAL LOAD PROTOCOL (matches tb_ascon.v / Ascon_wrapper exactly):
//   1. Assert ascon_rst for 2 cycles  (resets ASCON internal counter i to 0)
//   2. Pre-drive MSBs on last reset cycle (registered-output pipeline fix)
//   3. Drive ALL lines simultaneously for MAX_W cycles, MSB first:
//        KEY  [127:0]     right-aligned in MAX_W window (KEY_OFF = MAX_W-128)
//        NONCE[127:0]     right-aligned in MAX_W window
//        AD   [AD_W-1:0]  right-aligned in MAX_W window (AD_OFF  = MAX_W-AD_W)
//        PT/CT[PT_W-1:0]  right-aligned in MAX_W window (PT_OFF  = MAX_W-PT_W)
//   4. Pulse enc_start / dec_start
//   5. Wait for enc_ready / dec_ready
//   6. Capture CAPTURE=max(PT_W,128) cycles LSB-first: data[PT_W-1:0], tag[127:0]
//   7. Save to output registers, assert mem_ready to unfreeze CPU
//
// REGISTER MAP (byte offsets from peripheral base address):
//   0x0000  CTRL    W   [0]=enc_go  [1]=dec_go
//   0x0004  STATUS  R   [0]=enc_done [1]=dec_done [2]=busy
//   0x0008  KEY[127:96]           (word 0)
//   0x000C  KEY[95:64]            (word 1)
//   0x0010  KEY[63:32]            (word 2)
//   0x0014  KEY[31:0]             (word 3)
//   0x0018  NONCE[127:96]         (word 0)
//   0x001C  NONCE[95:64]
//   0x0020  NONCE[63:32]
//   0x0024  NONCE[31:0]
//   0x0028               AD_BASE  : ceil(AD_W/32) words, word 0 = MSB
//   AD_BASE + AD_WORDS*4 PT_BASE  : ceil(PT_W/32) words, word 0 = MSB
//   PT_BASE + PT_WORDS*4 CTIN_BASE: ceil(PT_W/32) words
//   CTIN_BASE+PT_WORDS*4 CTOUT    : ceil(PT_W/32) words (read-only)
//   CTOUT+PT_WORDS*4     PTOUT    : ceil(PT_W/32) words (read-only)
//   PTOUT+PT_WORDS*4     TAGE     : 4 words          (read-only)
//   TAGE+16              TAGD     : 4 words          (read-only)
//
//   tb_soc_top.v uses the same localparam formulas to derive all offsets.
// =============================================================================

module ascon_sic #(
    parameter AD_W = 40,    // AD  width in bits (any positive integer)
    parameter PT_W = 40     // PT/CT width in bits (any positive integer)
)(
    input         clk,
    input         rst,

    // PicoRV32 native memory interface
    input         mem_valid,
    output reg    mem_ready,
    input  [31:0] mem_addr,
    input  [31:0] mem_wdata,
    input  [ 3:0] mem_wstrb,
    output reg [31:0] mem_rdata,

    // SIC controls ASCON reset (so it can reset ASCON's internal counter)
    output reg    ascon_rst,

    // ASCON serial interface
    output reg    keyxSO,
    output reg    noncexSO,
    output reg    associated_dataxSO,
    output reg    plain_textxSO,
    output reg    enc_startxSO,
    input         enc_cipher_textxSI,
    input         enc_tagxSI,
    input         enc_readyxSI,
    output reg    cipher_textxSO,
    output reg    dec_startxSO,
    input         dec_plain_textxSI,
    input         dec_tagxSI,
    input         dec_readyxSI
);

    // =========================================================================
    // Compile-time constants derived from AD_W and PT_W
    // =========================================================================

    // Number of 32-bit bus words per field
    localparam AD_WORDS = (AD_W + 31) / 32;
    localparam PT_WORDS = (PT_W + 31) / 32;

    // Serial load window: must cover KEY(128) and the larger of AD_W, PT_W
    localparam MAX_AD_PT = (AD_W >= PT_W) ? AD_W : PT_W;
    localparam MAX_W     = (MAX_AD_PT >= 128) ? MAX_AD_PT : 128;

    // Output capture window: must cover CT/PT(PT_W) and TAG(128)
    localparam CAPTURE   = (PT_W >= 128) ? PT_W : 128;

    // MSB-alignment offsets: signal MSB is at bit_cnt = MAX_W-1-OFF
    localparam KEY_OFF   = MAX_W - 128;   // 0 when MAX_W==128
    localparam AD_OFF    = MAX_W - AD_W;
    localparam PT_OFF    = MAX_W - PT_W;

    // Counter width: 16 bits supports fields up to 65535 bits
    localparam CNT_W = 16;

    // Register map base offsets (byte addresses relative to peripheral base)
    localparam [15:0] KEY_BASE   = 16'h0008;
    localparam [15:0] NON_BASE   = 16'h0018;
    localparam [15:0] AD_BASE    = 16'h0028;
    localparam [15:0] PT_BASE    = AD_BASE   + AD_WORDS * 4;
    localparam [15:0] CTIN_BASE  = PT_BASE   + PT_WORDS * 4;
    localparam [15:0] CTOUT_BASE = CTIN_BASE + PT_WORDS * 4;
    localparam [15:0] PTOUT_BASE = CTOUT_BASE+ PT_WORDS * 4;
    localparam [15:0] TAGE_BASE  = PTOUT_BASE+ PT_WORDS * 4;
    localparam [15:0] TAGD_BASE  = TAGE_BASE + 16;

    // =========================================================================
    // Storage registers
    // =========================================================================
    reg [127:0]    reg_key;
    reg [127:0]    reg_nonce;
    reg [AD_W-1:0] reg_ad;
    reg [PT_W-1:0] reg_pt;
    reg [PT_W-1:0] reg_ct_in;

    reg [PT_W-1:0] reg_ct_out;    // read-only output
    reg [PT_W-1:0] reg_pt_out;    // read-only output
    reg [127:0]    reg_tag_enc;   // read-only output
    reg [127:0]    reg_tag_dec;   // read-only output
    reg            enc_done;
    reg            dec_done;

    // =========================================================================
    // FSM
    // =========================================================================
    localparam ST_IDLE        = 3'd0;
    localparam ST_RESET_ASCON = 3'd1;
    localparam ST_LOAD        = 3'd2;
    localparam ST_PULSE_START = 3'd3;
    localparam ST_WAIT_READY  = 3'd4;
    localparam ST_CAPTURE     = 3'd5;
    localparam ST_SAVE        = 3'd6;
    localparam ST_DONE        = 3'd7;

    reg [2:0]          state;
    reg                doing_enc;
    reg [CNT_W-1:0]    bit_cnt;
    reg [CNT_W-1:0]    cap_cnt;
    reg [CNT_W-1:0]    rst_cnt;
    reg [PT_W-1:0]     cap_data;
    reg [127:0]        cap_tag;

    wire busy = (state != ST_IDLE) && (state != ST_DONE);

    // =========================================================================
    // Address decode
    // =========================================================================
    wire [15:0] offset        = mem_addr[15:0];
    wire        is_write      = mem_valid && (mem_wstrb != 4'b0000);
    wire        is_read       = mem_valid && (mem_wstrb == 4'b0000);
    wire        ctrl_start_wr = is_write && (offset == 16'h0000)
                                         && (mem_wdata[1:0] != 2'b00);

    // =========================================================================
    // Bit-extraction functions for serial output
    //
    // bit_cnt runs MAX_W-1 downto 0 (MSB first).
    // Signal MSB maps to bit_cnt = MAX_W-1-OFF, LSB to bit_cnt = OFF.
    // For bit_cnt < OFF the signal window has passed -> drive 0.
    // =========================================================================

    function get_key_bit;
        input [CNT_W-1:0] bc;
        input [127:0]     r;
        begin
            if (bc >= KEY_OFF)
                get_key_bit = r[bc - KEY_OFF];
            else
                get_key_bit = 1'b0;
        end
    endfunction

    function get_ad_bit;
        input [CNT_W-1:0] bc;
        input [AD_W-1:0]  r;
        begin
            if (bc >= AD_OFF)
                get_ad_bit = r[bc - AD_OFF];
            else
                get_ad_bit = 1'b0;
        end
    endfunction

    function get_pt_bit;
        input [CNT_W-1:0] bc;
        input [PT_W-1:0]  r;
        begin
            if (bc >= PT_OFF)
                get_pt_bit = r[bc - PT_OFF];
            else
                get_pt_bit = 1'b0;
        end
    endfunction

    // =========================================================================
    // Word-extraction functions for register map reads
    //
    // For a W-bit field stored MSB-first:
    //   word w (0=MSB) covers bits [W-1-w*32 : max(0, W-32-w*32)]
    //   The last word may be a partial < 32 bits, zero-extended to 32.
    // =========================================================================

    function [31:0] field_word_ad;
        input [AD_W-1:0] v;
        input integer    w;         // 0 = MSB word
        integer          hi, lo, width_this;
        reg [31:0]       result;
        integer          j;
        begin
            hi         = AD_W - 1 - w*32;
            lo         = (hi >= 31) ? hi - 31 : 0;
            width_this = hi - lo + 1;
            result     = 32'h0;
            for (j = 0; j < width_this; j = j + 1)
                result[j] = v[lo + j];
            field_word_ad = result;
        end
    endfunction

    function [31:0] field_word_pt;
        input [PT_W-1:0] v;
        input integer    w;
        integer          hi, lo, width_this;
        reg [31:0]       result;
        integer          j;
        begin
            hi         = PT_W - 1 - w*32;
            lo         = (hi >= 31) ? hi - 31 : 0;
            width_this = hi - lo + 1;
            result     = 32'h0;
            for (j = 0; j < width_this; j = j + 1)
                result[j] = v[lo + j];
            field_word_pt = result;
        end
    endfunction

    // =========================================================================
    // mem_rdata combinational mux
    // =========================================================================
    integer rw;
    always @(*) begin
        mem_rdata = 32'hDEAD_BEEF;
        if (is_read) begin
            if (offset == 16'h0000)
                mem_rdata = 32'h0;
            else if (offset == 16'h0004)
                mem_rdata = {29'h0, busy, dec_done, enc_done};

            // KEY (4 fixed words)
            else if (offset >= KEY_BASE && offset < KEY_BASE + 16) begin
                rw = (offset - KEY_BASE) >> 2;
                case (rw)
                    0: mem_rdata = reg_key[127:96];
                    1: mem_rdata = reg_key[95:64];
                    2: mem_rdata = reg_key[63:32];
                    3: mem_rdata = reg_key[31:0];
                    default: mem_rdata = 32'h0;
                endcase
            end

            // NONCE (4 fixed words)
            else if (offset >= NON_BASE && offset < NON_BASE + 16) begin
                rw = (offset - NON_BASE) >> 2;
                case (rw)
                    0: mem_rdata = reg_nonce[127:96];
                    1: mem_rdata = reg_nonce[95:64];
                    2: mem_rdata = reg_nonce[63:32];
                    3: mem_rdata = reg_nonce[31:0];
                    default: mem_rdata = 32'h0;
                endcase
            end

            // AD (AD_WORDS words)
            else if (offset >= AD_BASE && offset < AD_BASE + AD_WORDS*4) begin
                rw = (offset - AD_BASE) >> 2;
                mem_rdata = field_word_ad(reg_ad, rw);
            end

            // PT (PT_WORDS words)
            else if (offset >= PT_BASE && offset < PT_BASE + PT_WORDS*4) begin
                rw = (offset - PT_BASE) >> 2;
                mem_rdata = field_word_pt(reg_pt, rw);
            end

            // CT_IN (PT_WORDS words)
            else if (offset >= CTIN_BASE && offset < CTIN_BASE + PT_WORDS*4) begin
                rw = (offset - CTIN_BASE) >> 2;
                mem_rdata = field_word_pt(reg_ct_in, rw);
            end

            // CT_OUT (PT_WORDS words, read-only)
            else if (offset >= CTOUT_BASE && offset < CTOUT_BASE + PT_WORDS*4) begin
                rw = (offset - CTOUT_BASE) >> 2;
                mem_rdata = field_word_pt(reg_ct_out, rw);
            end

            // PT_OUT (PT_WORDS words, read-only)
            else if (offset >= PTOUT_BASE && offset < PTOUT_BASE + PT_WORDS*4) begin
                rw = (offset - PTOUT_BASE) >> 2;
                mem_rdata = field_word_pt(reg_pt_out, rw);
            end

            // TAG_ENC (4 words, read-only)
            else if (offset >= TAGE_BASE && offset < TAGE_BASE + 16) begin
                rw = (offset - TAGE_BASE) >> 2;
                case (rw)
                    0: mem_rdata = reg_tag_enc[127:96];
                    1: mem_rdata = reg_tag_enc[95:64];
                    2: mem_rdata = reg_tag_enc[63:32];
                    3: mem_rdata = reg_tag_enc[31:0];
                    default: mem_rdata = 32'h0;
                endcase
            end

            // TAG_DEC (4 words, read-only)
            else if (offset >= TAGD_BASE && offset < TAGD_BASE + 16) begin
                rw = (offset - TAGD_BASE) >> 2;
                case (rw)
                    0: mem_rdata = reg_tag_dec[127:96];
                    1: mem_rdata = reg_tag_dec[95:64];
                    2: mem_rdata = reg_tag_dec[63:32];
                    3: mem_rdata = reg_tag_dec[31:0];
                    default: mem_rdata = 32'h0;
                endcase
            end
        end
    end

    // =========================================================================
    // mem_ready
    // =========================================================================
    always @(*) begin
        if (mem_valid && !ctrl_start_wr)
            mem_ready = 1'b1;
        else if (state == ST_DONE)
            mem_ready = 1'b1;
        else
            mem_ready = 1'b0;
    end

    // =========================================================================
    // Register file WRITES
    //
    // Variable-width fields are written word-by-word (MSB word first, w=0).
    // Word w of a W-bit field occupies bits:
    //   full word  (W - w*32 >= 32): field[W-1-w*32 -: 32]
    //   last word  (W - w*32 <  32): field[W%32-1   :  0]   (zero-extended bus write)
    //
    // The for-loop over ww is unrolled at elaboration; synthesises as a
    // priority-encoded write mux, not runtime variable indexing.
    // =========================================================================
    integer ww;

    always @(posedge clk) begin
        if (rst) begin
            reg_key    <= 128'h0;
            reg_nonce  <= 128'h0;
            reg_ad     <= {AD_W{1'b0}};
            reg_pt     <= {PT_W{1'b0}};
            reg_ct_in  <= {PT_W{1'b0}};
        end else if (is_write && !ctrl_start_wr) begin

            // KEY (4 fixed words)
            if (offset == KEY_BASE + 0)  reg_key[127:96] <= mem_wdata;
            if (offset == KEY_BASE + 4)  reg_key[95:64]  <= mem_wdata;
            if (offset == KEY_BASE + 8)  reg_key[63:32]  <= mem_wdata;
            if (offset == KEY_BASE + 12) reg_key[31:0]   <= mem_wdata;

            // NONCE (4 fixed words)
            if (offset == NON_BASE + 0)  reg_nonce[127:96] <= mem_wdata;
            if (offset == NON_BASE + 4)  reg_nonce[95:64]  <= mem_wdata;
            if (offset == NON_BASE + 8)  reg_nonce[63:32]  <= mem_wdata;
            if (offset == NON_BASE + 12) reg_nonce[31:0]   <= mem_wdata;

            // AD: AD_WORDS words, word 0 = MSB
            for (ww = 0; ww < AD_WORDS; ww = ww + 1) begin
                if (offset == AD_BASE + ww*4) begin
                    if (AD_W - ww*32 >= 32)
                        reg_ad[AD_W - 1 - ww*32 -: 32] <= mem_wdata;
                    else
                        reg_ad[AD_W%32 - 1 : 0]         <= mem_wdata[AD_W%32-1:0];
                end
            end

            // PT: PT_WORDS words, word 0 = MSB
            for (ww = 0; ww < PT_WORDS; ww = ww + 1) begin
                if (offset == PT_BASE + ww*4) begin
                    if (PT_W - ww*32 >= 32)
                        reg_pt[PT_W - 1 - ww*32 -: 32] <= mem_wdata;
                    else
                        reg_pt[PT_W%32 - 1 : 0]         <= mem_wdata[PT_W%32-1:0];
                end
            end

            // CT_IN: PT_WORDS words, word 0 = MSB
            for (ww = 0; ww < PT_WORDS; ww = ww + 1) begin
                if (offset == CTIN_BASE + ww*4) begin
                    if (PT_W - ww*32 >= 32)
                        reg_ct_in[PT_W - 1 - ww*32 -: 32] <= mem_wdata;
                    else
                        reg_ct_in[PT_W%32 - 1 : 0]         <= mem_wdata[PT_W%32-1:0];
                end
            end

        end
    end

    // =========================================================================
    // Main FSM
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state              <= ST_IDLE;
            doing_enc          <= 1'b0;
            bit_cnt            <= {CNT_W{1'b0}};
            cap_cnt            <= {CNT_W{1'b0}};
            rst_cnt            <= {CNT_W{1'b0}};
            cap_data           <= {PT_W{1'b0}};
            cap_tag            <= 128'h0;
            enc_done           <= 1'b0;
            dec_done           <= 1'b0;
            reg_ct_out         <= {PT_W{1'b0}};
            reg_pt_out         <= {PT_W{1'b0}};
            reg_tag_enc        <= 128'h0;
            reg_tag_dec        <= 128'h0;
            ascon_rst          <= 1'b1;
            keyxSO             <= 1'b0;
            noncexSO           <= 1'b0;
            associated_dataxSO <= 1'b0;
            plain_textxSO      <= 1'b0;
            cipher_textxSO     <= 1'b0;
            enc_startxSO       <= 1'b0;
            dec_startxSO       <= 1'b0;
        end else begin
            enc_startxSO <= 1'b0;
            dec_startxSO <= 1'b0;

            case (state)

                // ----------------------------------------------------------------
                ST_IDLE: begin
                    ascon_rst          <= 1'b0;
                    keyxSO             <= 1'b0;
                    noncexSO           <= 1'b0;
                    associated_dataxSO <= 1'b0;
                    plain_textxSO      <= 1'b0;
                    cipher_textxSO     <= 1'b0;
                    if (ctrl_start_wr) begin
                        doing_enc <= mem_wdata[0];
                        enc_done  <= 1'b0;
                        dec_done  <= 1'b0;
                        rst_cnt   <= {CNT_W{1'b0}};
                        state     <= ST_RESET_ASCON;
                    end
                end

                // ----------------------------------------------------------------
                // Hold ascon_rst=1 for 2 cycles.
                // On cycle rst_cnt==1: pre-drive the MSBs of all serial outputs
                // while still asserting rst=0 on the same edge.
                // This ensures ASCON's i=0 capture (first clock after reset
                // releases) sees valid data, not the stale zeros from before.
                // ----------------------------------------------------------------
                ST_RESET_ASCON: begin
                    ascon_rst <= 1'b1;
                    if (rst_cnt == {{(CNT_W-1){1'b0}}, 1'b1}) begin
                        ascon_rst          <= 1'b0;
                        keyxSO             <= get_key_bit(MAX_W - 1, reg_key);
                        noncexSO           <= get_key_bit(MAX_W - 1, reg_nonce);
                        associated_dataxSO <= get_ad_bit (MAX_W - 1, reg_ad);
                        plain_textxSO      <= doing_enc ?
                                             get_pt_bit(MAX_W-1, reg_pt)    : 1'b0;
                        cipher_textxSO     <= doing_enc ? 1'b0 :
                                             get_pt_bit(MAX_W-1, reg_ct_in);
                        bit_cnt <= MAX_W - 2;     // MSB (MAX_W-1) already driven
                        state   <= ST_LOAD;
                    end else begin
                        rst_cnt <= rst_cnt + {{(CNT_W-1){1'b0}}, 1'b1};
                    end
                end

                // ----------------------------------------------------------------
                // Serial load: bit_cnt counts MAX_W-2 downto 0
                // ----------------------------------------------------------------
                ST_LOAD: begin
                    ascon_rst          <= 1'b0;
                    keyxSO             <= get_key_bit(bit_cnt, reg_key);
                    noncexSO           <= get_key_bit(bit_cnt, reg_nonce);
                    associated_dataxSO <= get_ad_bit (bit_cnt, reg_ad);
                    plain_textxSO      <= doing_enc ?
                                         get_pt_bit(bit_cnt, reg_pt)    : 1'b0;
                    cipher_textxSO     <= doing_enc ? 1'b0 :
                                         get_pt_bit(bit_cnt, reg_ct_in);
                    if (bit_cnt == {CNT_W{1'b0}})
                        state <= ST_PULSE_START;
                    else
                        bit_cnt <= bit_cnt - {{(CNT_W-1){1'b0}}, 1'b1};
                end

                // ----------------------------------------------------------------
                ST_PULSE_START: begin
                    keyxSO             <= 1'b0;
                    noncexSO           <= 1'b0;
                    associated_dataxSO <= 1'b0;
                    plain_textxSO      <= 1'b0;
                    cipher_textxSO     <= 1'b0;
                    if (doing_enc) enc_startxSO <= 1'b1;
                    else           dec_startxSO <= 1'b1;
                    cap_cnt  <= {CNT_W{1'b0}};
                    cap_data <= {PT_W{1'b0}};
                    cap_tag  <= 128'h0;
                    state    <= ST_WAIT_READY;
                end

                // ----------------------------------------------------------------
                ST_WAIT_READY: begin
                    if ( doing_enc && enc_readyxSI) begin
                        cap_cnt <= {CNT_W{1'b0}};
                        state   <= ST_CAPTURE;
                    end
                    if (!doing_enc && dec_readyxSI) begin
                        cap_cnt <= {CNT_W{1'b0}};
                        state   <= ST_CAPTURE;
                    end
                end

                // ----------------------------------------------------------------
                // Capture: CAPTURE = max(PT_W, 128) cycles, LSB first.
                //   cap_data[0] = LSB, cap_data[PT_W-1] = MSB
                //   cap_tag[0]  = LSB, cap_tag[127]     = MSB
                // ----------------------------------------------------------------
                ST_CAPTURE: begin
                    if (cap_cnt < 128) begin
                        if (doing_enc) cap_tag[cap_cnt] <= enc_tagxSI;
                        else           cap_tag[cap_cnt] <= dec_tagxSI;
                    end
                    if (cap_cnt < PT_W) begin
                        if (doing_enc) cap_data[cap_cnt] <= enc_cipher_textxSI;
                        else           cap_data[cap_cnt] <= dec_plain_textxSI;
                    end
                    if (cap_cnt == (CAPTURE - 1))
                        state <= ST_SAVE;
                    else
                        cap_cnt <= cap_cnt + {{(CNT_W-1){1'b0}}, 1'b1};
                end

                // ----------------------------------------------------------------
                // One pipeline cycle for NBA on cap_tag[127] to resolve
                // ----------------------------------------------------------------
                ST_SAVE: begin
                    if (doing_enc) begin
                        reg_ct_out  <= cap_data;
                        reg_tag_enc <= cap_tag;
                        enc_done    <= 1'b1;
                    end else begin
                        reg_pt_out  <= cap_data;
                        reg_tag_dec <= cap_tag;
                        dec_done    <= 1'b1;
                    end
                    state <= ST_DONE;
                end

                // ----------------------------------------------------------------
                // mem_ready pulses HIGH here -> CPU unfreezes
                // ----------------------------------------------------------------
                ST_DONE: begin
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
