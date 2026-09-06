// =============================================================================
// Instruction Memory (ROM)
// =============================================================================
// Single-cycle read. Always returns mem_ready in the same cycle as mem_valid.
// Firmware is loaded via $readmemh at simulation time.
// Address bit [1:0] are always 00 for word-aligned instruction fetches.
// =============================================================================

module instr_mem #(
    parameter WORDS = 256   // number of 32-bit words = 1KB default
)(
    input         clk,
    input         valid,
    input  [31:0] addr,
    output [31:0] rdata,
    output        ready
);

    reg [31:0] mem [0:WORDS-1];

    // Load firmware hex at simulation start
    initial begin
        $readmemh("firmware.hex", mem);
    end

    // Word-aligned read: addr[31:2] indexes the word
    // addr[1:0] are always 2'b00 for RV32I instruction fetches
    assign rdata = mem[addr[31:2] & (WORDS-1)];

    // Single-cycle latency; ready same cycle as valid
    assign ready = valid;

endmodule
