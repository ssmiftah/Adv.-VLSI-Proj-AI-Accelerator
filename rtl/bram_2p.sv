// =============================================================================
// bram_2p.sv  —  Simple dual-port BRAM wrapper
// =============================================================================
//
// One write port + one read port, separate addresses. The standard Vivado
// inference template for this is a registered-read mem array — the synthesizer
// then maps it to a RAMB18 (or RAMB36 for larger depths).
//
// USAGE
//   - For A_BRAM / B_BRAM: TB / host writes via the write port; the tile
//     controller reads via the read port.
//   - For C_BRAM: the tile controller writes via the write port during drain;
//     the TB / host reads via the read port for verification.
//
// PORTS
//   wr_clk, rd_clk      : separate clocks supported (we use the same in
//                          this project — no CDC needed).
//   wr_addr, wr_data    : address + data for the write port. wr_en gates.
//   rd_addr             : address for the read port.
//   rd_data             : registered (1-cycle latency) read data.
//
// READ-LATENCY NOTE
//   rd_data is registered, so the read appears one cycle after rd_addr is
//   driven. The tile controller accounts for this by issuing addresses
//   one cycle ahead of when the array consumes the value.
//
// INIT
//   INIT_FILE   :  path to a $readmemh hex file (one row per memory entry).
//                  If empty (""), the memory is zero-initialized.
//                  Useful for sim and for FPGA bitstream pre-load.
// =============================================================================

`timescale 1ns/1ps

module bram_2p #(
    parameter int    DATA_W    = 64,         // word width in bits
    parameter int    DEPTH     = 64,         // number of words
    parameter string INIT_FILE = ""          // optional $readmemh path
) (
    // Write port
    input  logic                          wr_clk,
    input  logic                          wr_en,
    input  logic [$clog2(DEPTH)-1:0]      wr_addr,
    input  logic [DATA_W-1:0]             wr_data,

    // Read port
    input  logic                          rd_clk,
    input  logic [$clog2(DEPTH)-1:0]      rd_addr,
    output logic [DATA_W-1:0]             rd_data
);

    // Memory storage. Vivado will infer this as a RAMB18 / RAMB36 given the
    // synchronous-read structure below.
    logic [DATA_W-1:0]   mem [DEPTH];

    // -------------------------------------------------------------------------
    // Initialization (sim + bitstream)
    // -------------------------------------------------------------------------
    initial begin
        if (INIT_FILE != "") begin
            $display("[bram_2p] loading %s into mem (DEPTH=%0d, DATA_W=%0d)",
                     INIT_FILE, DEPTH, DATA_W);
            $readmemh(INIT_FILE, mem);
        end
        else begin
            for (int i = 0; i < DEPTH; i++) mem[i] = '0;
        end
    end

    // -------------------------------------------------------------------------
    // Write port — synchronous
    // -------------------------------------------------------------------------
    always_ff @(posedge wr_clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
    end

    // -------------------------------------------------------------------------
    // Read port — registered (1-cycle latency, BRAM-friendly)
    // -------------------------------------------------------------------------
    always_ff @(posedge rd_clk) begin
        rd_data <= mem[rd_addr];
    end

endmodule
