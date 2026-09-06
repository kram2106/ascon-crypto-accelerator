/* =============================================================================
 * firmware.c  —  ASCON SoC firmware for PicoRV32
 * =============================================================================
 * Performs one encryption followed by one decryption via the ASCON SIC,
 * stores results in data memory, sets DONE flag for testbench.
 *
 * HOW TO CHANGE TEST VECTORS:
 *   Edit ONLY the block marked "EDIT ONLY THIS BLOCK" below.
 *   Write values exactly as they appear in the spec — full hex bytes, MSB first.
 *   No manual word-splitting required. write_field() handles it automatically.
 *
 *   Steps:
 *     1. Change AD_W and PT_W if the bit widths are different.
 *     2. Update AD_BYTES and PT_BYTES (= AD_W/8, PT_W/8).
 *     3. Replace the byte arrays for KEY, NONCE, AD, PT.
 *     4. Rebuild firmware.
 *
 * HOW TO BUILD:
 *   riscv32-unknown-elf-gcc -march=rv32i -mabi=ilp32 \
 *       -nostdlib -nostartfiles -T link.ld \
 *       -o firmware.elf start.S firmware.c
 *   riscv32-unknown-elf-objcopy -O binary firmware.elf firmware.bin
 *   python3 bin2hex.py
 *
 * RESULT LAYOUT IN DATA MEMORY (base 0x0001_0000):
 *   mem[0]                             : DONE flag (0xDEADDEAD when complete)
 *   mem[1]                             : enc_done  (1 = pass)
 *   mem[2]                             : dec_done  (1 = pass)
 *   mem[3 .. 3+PT_WORDS-1]            : CT_OUT    (MSB word first)
 *   mem[3+PT_WORDS .. 3+PT_WORDS+3]   : TAG_ENC   (4 words, MSB first)
 *   mem[3+PT_WORDS+4 .. +4+PT_WORDS-1]: PT_OUT    (MSB word first)
 *   mem[3+PT_WORDS+4+PT_WORDS .. +7]  : TAG_DEC   (4 words, MSB first)
 * ============================================================================= */

/* =============================================================================
 * *** EDIT ONLY THIS BLOCK ***
 * Write the values exactly as they appear — full hex, MSB byte first.
 * No word-splitting needed here. The write_field() function does it for you.
 * ============================================================================= */

#define AD_W     176   /* AD  width in bits — must match soc_top.v AD_W  */
#define PT_W      80   /* PT width in bits  — must match soc_top.v PT_W  */

/* KEY — always 128 bits = 16 bytes, MSB byte first */
static const unsigned char KEY[16] = {
    0x00, 0x01, 0x02, 0x03,
    0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0A, 0x0B,
    0x0C, 0x0D, 0x0E, 0x0F
};

/* NONCE — always 128 bits = 16 bytes, MSB byte first */
static const unsigned char NONCE[16] = {
    0x10, 0x11, 0x12, 0x13,
    0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1A, 0x1B,
    0x1C, 0x1D, 0x1E, 0x1F
};

/* AD — AD_W/8 bytes, MSB byte first.
 * For AD_W=40: 5 bytes. Write the 5 bytes of your AD value here.
 * Example: "ASCON" = 0x4153434f4e */
#define AD_BYTES (AD_W / 8)
static const unsigned char AD[AD_BYTES] = {
    0x30, 0x31, 0x32, 0x33,
    0x34, 0x35, 0x36, 0x37,
    0x38, 0x39, 0x3A, 0x3B,
    0x3C, 0x3D, 0x3E, 0x3F,
    0x40, 0x41, 0x42, 0x43,
    0x44, 0x45
};
/* PT — PT_W/8 bytes, MSB byte first.
 * For PT_W=40: 5 bytes. Write the 5 bytes of your PT value here.
 * Example: "Hello" = 0x48656c6c6f */
#define PT_BYTES (PT_W / 8)
static const unsigned char PT[PT_BYTES] = {
    0x12, 0x34, 0x56, 0x78,
    0x91, 0x23, 0x45, 0x67,
    0x89, 0x12
};

/* ============================================================================= */
/* END OF EDIT BLOCK — do not modify anything below this line                    */
/* ============================================================================= */

/* Derived word counts — computed automatically */
#define AD_WORDS  ((AD_W + 31) / 32)
#define PT_WORDS  ((PT_W + 31) / 32)

/* SIC peripheral base and register offsets */
#define ASCON_BASE   0x10000000UL
#define CTRL_OFF     0x0000
#define STATUS_OFF   0x0004
#define KEY_OFF      0x0008
#define NON_OFF      0x0018
#define AD_OFF       0x0028
#define PT_OFF       (AD_OFF   + AD_WORDS * 4)
#define CTIN_OFF     (PT_OFF   + PT_WORDS * 4)
#define CTOUT_OFF    (CTIN_OFF + PT_WORDS * 4)
#define PTOUT_OFF    (CTOUT_OFF+ PT_WORDS * 4)
#define TAGE_OFF     (PTOUT_OFF+ PT_WORDS * 4)
#define TAGD_OFF     (TAGE_OFF + 16)
#define REG(off)     (*(volatile unsigned int *)(ASCON_BASE + (off)))
#define CMD_ENC          0x00000001u
#define CMD_DEC          0x00000002u
#define STATUS_ENC_DONE  (1u << 0)
#define STATUS_DEC_DONE  (1u << 1)

/* Data memory result area */
#define DMEM_BASE       0x00010000UL
#define DMEM_DONE       (*(volatile unsigned int *)(DMEM_BASE +  0))
#define DMEM_ENC_STATUS (*(volatile unsigned int *)(DMEM_BASE +  4))
#define DMEM_DEC_STATUS (*(volatile unsigned int *)(DMEM_BASE +  8))
#define DMEM_CT_BASE    (DMEM_BASE + 12)
#define DMEM_TAGE_BASE  (DMEM_CT_BASE   + PT_WORDS * 4)
#define DMEM_PT_BASE    (DMEM_TAGE_BASE + 16)
#define DMEM_TAGD_BASE  (DMEM_PT_BASE   + PT_WORDS * 4)
#define DONE_MAGIC      0xDEADDEADUL

/* =============================================================================
 * write_field()
 * =============================================================================
 * Writes a byte array of total_bits width into consecutive 32-bit SIC
 * registers, MSB first. Handles any field width — full or partial last word.
 *
 * The SIC stores variable-width fields MSB-word first:
 *   Full word  (bits remaining >= 32): all 32 bits from the byte array
 *   Last word  (bits remaining <  32): lower (bits%32) bits, zero-extended
 *
 * This function assembles each 32-bit word from 4 input bytes and places
 * partial last words in the correct lower-bit position automatically.
 *
 * Example for AD_W=40, AD = {0x41,0x53,0x43,0x4F,0x4E}:
 *   word0: bytes[0..3] -> 0x4153434F  written to AD_OFF+0  (reg_ad[39:8])
 *   word1: bytes[4]    -> 0x0000004E  written to AD_OFF+4  (reg_ad[7:0])
 * ============================================================================= */
static void write_field(unsigned int base_off,
                        const unsigned char *data,
                        int total_bits)
{
    int total_words = (total_bits + 31) / 32;
    int total_bytes = (total_bits +  7) /  8;
    int w, b, byte_idx, bits_this_word, bytes_this_word, shift;
    unsigned int word;

    for (w = 0; w < total_words; w++) {
        bits_this_word  = total_bits - w * 32;
        if (bits_this_word > 32) bits_this_word = 32;
        bytes_this_word = (bits_this_word + 7) / 8;
        byte_idx        = w * 4;

        /* Pack bytes into a 32-bit word, MSB byte at the top.
         * For a partial last word (bits_this_word < 32), the assembled
         * value naturally sits in the lower bits — exactly what the SIC
         * write logic expects for reg[W%32-1:0] <= mem_wdata[W%32-1:0]. */
        word = 0;
        for (b = 0; b < bytes_this_word; b++) {
            if (byte_idx + b < total_bytes) {
                shift = (bytes_this_word - 1 - b) * 8;
                word |= ((unsigned int)data[byte_idx + b]) << shift;
            }
        }

        REG(base_off + w * 4) = word;
    }
}

/* =============================================================================
 * write_128() — fixed 128-bit field (KEY, NONCE): always 4 full 32-bit words
 * ============================================================================= */
static void write_128(unsigned int base_off, const unsigned char *data)
{
    int w;
    for (w = 0; w < 4; w++)
        REG(base_off + w * 4) =
            ((unsigned int)data[w*4 + 0] << 24) |
            ((unsigned int)data[w*4 + 1] << 16) |
            ((unsigned int)data[w*4 + 2] <<  8) |
            ((unsigned int)data[w*4 + 3]);
}

/* =============================================================================
 * read_words_to_dmem() — copies N 32-bit words from SIC to data memory
 * ============================================================================= */
static void read_words_to_dmem(unsigned int sic_off,
                                unsigned int dmem_addr,
                                int n)
{
    int i;
    volatile unsigned int *dst = (volatile unsigned int *)dmem_addr;
    for (i = 0; i < n; i++)
        dst[i] = REG(sic_off + i * 4);
}

/* =============================================================================
 * main
 * ============================================================================= */
int main(void)
{
    unsigned int status;

    /* ------------------------------------------------------------------
     * PHASE 1: Load KEY, NONCE, AD, PT into SIC registers.
     *
     * write_128()   — 128-bit KEY and NONCE, always 4 full words.
     * write_field() — variable-width AD and PT, auto word-split.
     *                 Pass the raw byte array and bit width; no manual
     *                 splitting or zero-padding required.
     * ------------------------------------------------------------------ */
    write_128  (KEY_OFF, KEY);
    write_128  (NON_OFF, NONCE);
    write_field(AD_OFF,  AD, AD_W);
    write_field(PT_OFF,  PT, PT_W);

    /* ------------------------------------------------------------------
     * PHASE 2: Trigger encryption.
     * SIC holds mem_ready LOW until the full operation is complete
     * (ASCON reset → parallel load → enc_start → capture → save).
     * CPU stalls at this single store — no polling loop needed.
     * ------------------------------------------------------------------ */
    REG(CTRL_OFF) = CMD_ENC;

    /* ------------------------------------------------------------------
     * PHASE 3: Save encryption results to data memory.
     * ------------------------------------------------------------------ */
    status = REG(STATUS_OFF);
    DMEM_ENC_STATUS = (status & STATUS_ENC_DONE) ? 1u : 0u;
    read_words_to_dmem(CTOUT_OFF, DMEM_CT_BASE,   PT_WORDS);
    read_words_to_dmem(TAGE_OFF,  DMEM_TAGE_BASE, 4);

    /* ------------------------------------------------------------------
     * PHASE 4: Feed captured CT back into SIC as CT_IN for decryption.
     * KEY, NONCE, AD stay in SIC registers — no rewrite needed.
     * ------------------------------------------------------------------ */
    {
        int i;
        volatile unsigned int *ct = (volatile unsigned int *)DMEM_CT_BASE;
        for (i = 0; i < PT_WORDS; i++)
            REG(CTIN_OFF + i * 4) = ct[i];
    }

    /* ------------------------------------------------------------------
     * PHASE 5: Trigger decryption. Same stall mechanism.
     * ------------------------------------------------------------------ */
    REG(CTRL_OFF) = CMD_DEC;

    /* ------------------------------------------------------------------
     * PHASE 6: Save decryption results to data memory.
     * ------------------------------------------------------------------ */
    status = REG(STATUS_OFF);
    DMEM_DEC_STATUS = (status & STATUS_DEC_DONE) ? 1u : 0u;
    read_words_to_dmem(PTOUT_OFF, DMEM_PT_BASE,   PT_WORDS);
    read_words_to_dmem(TAGD_OFF,  DMEM_TAGD_BASE, 4);

    /* ------------------------------------------------------------------
     * PHASE 7: Set DONE flag. Written absolutely last so testbench only
     * reads DMEM after all results are in place.
     * ------------------------------------------------------------------ */
    DMEM_DONE = DONE_MAGIC;

    while (1);
    return 0;
}
