// =============================================================================
// SoC Top Level
// =============================================================================
// Connects:
//   - picorv32     (native memory interface, RV32I, no IRQ, no MUL/DIV)
//   - instr_mem    (ROM)  at 0x0000_0000  (64KB window)
//   - data_mem     (SRAM) at 0x0001_0000  (64KB window)
//   - ascon_sic    (MMIO) at 0x1000_0000  (64KB window)
//
// Address decode uses a 16-bit offset (64KB window) per peripheral rather
// than an 8-bit offset (256 bytes), since the parameterized SIC's register
// map can exceed 256 bytes when AD_W or PT_W is large (each field takes
// ceil(W/32)*4 bytes; for 256-bit AD + 256-bit PT the map already reaches
// ~0x90 bytes, and TAG_DEC ends at TAGE_BASE+16+16 which can exceed 0xFF).
//
// SIC parameters: set AD_W and PT_W here to match your test vector sizes.
// These must also match the `define l and `define y in tb_soc_top.v and the
// values used to build firmware.hex.
//
// PicoRV32 reset is ACTIVE LOW (resetn). soc_top accepts active HIGH rst
// and inverts it internally.
// =============================================================================

module soc_top #(
    parameter MEM_WORDS = 256,   // 256 x 32-bit = 1 KB each for imem and dmem
    parameter AD_W      = 40,    // must match firmware and tb
    parameter PT_W      = 40     // must match firmware and tb
)(
    input clk,
    input rst            // active HIGH reset
);

    // -------------------------------------------------------------------------
    // PicoRV32 memory bus
    // -------------------------------------------------------------------------
    wire        mem_valid;
    wire        mem_instr;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [ 3:0] mem_wstrb;
    wire [31:0] mem_rdata;
    wire        mem_ready;

    // -------------------------------------------------------------------------
    // Address decode
    //   0x0000_0000 - 0x0000_FFFF : Instruction Memory
    //   0x0001_0000 - 0x0001_FFFF : Data Memory
    //   0x1000_0000 - 0x1000_FFFF : ASCON SIC  (64 KB window)
    // -------------------------------------------------------------------------
    wire sel_imem  = mem_valid && (mem_addr[31:16] == 16'h0000);
    wire sel_dmem  = mem_valid && (mem_addr[31:16] == 16'h0001);
    wire sel_ascon = mem_valid && (mem_addr[31:16] == 16'h1000);

    // -------------------------------------------------------------------------
    // Per-slave rdata / ready
    // -------------------------------------------------------------------------
    wire [31:0] imem_rdata;  wire imem_ready;
    wire [31:0] dmem_rdata;  wire dmem_ready;
    wire [31:0] ascon_rdata; wire ascon_ready;

    // -------------------------------------------------------------------------
    // Bus mux back to PicoRV32
    // -------------------------------------------------------------------------
    assign mem_rdata = sel_imem  ? imem_rdata  :
                       sel_dmem  ? dmem_rdata  :
                       sel_ascon ? ascon_rdata :
                       32'hDEAD_BEEF;

    assign mem_ready = (sel_imem  & imem_ready)  |
                       (sel_dmem  & dmem_ready)  |
                       (sel_ascon & ascon_ready);

    // -------------------------------------------------------------------------
    // PicoRV32 - PROGADDR_RESET=0 so it fetches from instr_mem on reset.
    // STACKADDR left at default (0xFFFFFFFF); start.S sets sp explicitly to
    // the top of data memory before calling main().
    // -------------------------------------------------------------------------
    // Unused PicoRV32 output ports tied to wires to suppress warnings.
    // These are lookahead (mem_la_*) and trace ports; not needed for function.
    wire        mem_la_read, mem_la_write;
    wire [31:0] mem_la_addr, mem_la_wdata;
    wire [ 3:0] mem_la_wstrb;
    wire        trace_valid;
    wire [35:0] trace_data;

    picorv32 #(
        .ENABLE_MUL      (0),
        .ENABLE_DIV      (0),
        .ENABLE_IRQ      (0),
        .ENABLE_PCPI     (0),
        .ENABLE_COUNTERS (0),
        .PROGADDR_RESET  (32'h0000_0000),
        .REGS_INIT_ZERO  (1)
    ) cpu (
        .clk         (clk),
        .resetn      (~rst),
        .mem_valid   (mem_valid),
        .mem_instr   (mem_instr),
        .mem_ready   (mem_ready),
        .mem_addr    (mem_addr),
        .mem_wdata   (mem_wdata),
        .mem_wstrb   (mem_wstrb),
        .mem_rdata   (mem_rdata),
        .trap        (),
        .pcpi_valid  (),
        .pcpi_insn   (),
        .pcpi_rs1    (),
        .pcpi_rs2    (),
        .pcpi_wr     (1'b0),
        .pcpi_rd     (32'h0),
        .pcpi_wait   (1'b0),
        .pcpi_ready  (1'b0),
        .irq         (32'h0),
        .eoi         (),
        // Lookahead interface - outputs only, tied to wires
        .mem_la_read  (mem_la_read),
        .mem_la_write (mem_la_write),
        .mem_la_addr  (mem_la_addr),
        .mem_la_wdata (mem_la_wdata),
        .mem_la_wstrb (mem_la_wstrb),
        // Trace interface - outputs only, tied to wires
        .trace_valid  (trace_valid),
        .trace_data   (trace_data)
    );

    // -------------------------------------------------------------------------
    // Instruction Memory (ROM) - loaded from firmware.hex at simulation time
    // -------------------------------------------------------------------------
    instr_mem #(
        .WORDS (MEM_WORDS)
    ) imem (
        .clk   (clk),
        .valid (sel_imem),
        .addr  (mem_addr),
        .rdata (imem_rdata),
        .ready (imem_ready)
    );

    // -------------------------------------------------------------------------
    // Data Memory (SRAM)
    // -------------------------------------------------------------------------
    data_mem #(
        .WORDS (MEM_WORDS)
    ) dmem (
        .clk   (clk),
        .valid (sel_dmem),
        .addr  (mem_addr),
        .wdata (mem_wdata),
        .wstrb (mem_wstrb),
        .rdata (dmem_rdata),
        .ready (dmem_ready)
    );

    // -------------------------------------------------------------------------
    // ASCON SIC - parameterized for AD_W and PT_W
    // -------------------------------------------------------------------------
    wire ascon_rst_wire;
    wire sic_key, sic_nonce, sic_ad, sic_pt, sic_ct_in;
    wire sic_enc_start, sic_dec_start;
    wire ascon_enc_ct,  ascon_enc_tag,  ascon_enc_ready;
    wire ascon_dec_pt,  ascon_dec_tag,  ascon_dec_ready;

    ascon_sic #(
        .AD_W (AD_W),
        .PT_W (PT_W)
    ) sic (
        .clk                 (clk),
        .rst                 (rst),
        .mem_valid           (sel_ascon),
        .mem_ready           (ascon_ready),
        .mem_addr            (mem_addr),
        .mem_wdata           (mem_wdata),
        .mem_wstrb           (mem_wstrb),
        .mem_rdata           (ascon_rdata),
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

   // -------------------------------------------------------------------------
   // Ascon (top-level ASCON module) — provides the serial interface consumed
   // by the SIC; internally wraps AsconCore's parallel FSM + permutation engine
   // -------------------------------------------------------------------------
    Ascon #(
        .k (128), .r (128), .a (12), .b (8),
        .l (AD_W), .y (PT_W), .v (1)
    ) ascon_wrap (
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

endmodule
