// =============================================================================
// Data Memory (SRAM)
// =============================================================================
// Supports byte-enable writes via mem_wstrb.
// Single-cycle read and write; ready in same cycle as valid.
// Base address is 0x0001_0000; offset = addr[15:2] selects the word.
// =============================================================================

module data_mem #(
    parameter WORDS = 256
)(
    input         clk,
    input         valid,
    input  [31:0] addr,
    input  [31:0] wdata,
    input  [ 3:0] wstrb,
    output [31:0] rdata,
    output        ready
);

    reg [31:0] mem [0:WORDS-1];

    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1)
            mem[i] = 32'h0;
    end

    // Word index: use bits [15:2] of address (within the 64KB data region)
    wire [$clog2(WORDS)-1:0] word_idx = addr[$clog2(WORDS)+1:2];

    // Byte-enable write on clock edge
    always @(posedge clk) begin
        if (valid && |wstrb) begin
            if (wstrb[0]) mem[word_idx][ 7: 0] <= wdata[ 7: 0];
            if (wstrb[1]) mem[word_idx][15: 8] <= wdata[15: 8];
            if (wstrb[2]) mem[word_idx][23:16] <= wdata[23:16];
            if (wstrb[3]) mem[word_idx][31:24] <= wdata[31:24];
        end
    end

    // Combinational read
    assign rdata = mem[word_idx];
    assign ready = valid;

endmodule
