// =============================================================================
// skew_buffer.sv  —  Triangular shift-register bank for systolic input skewing
// =============================================================================
//
// Turns a flat parallel input (S rows, all valid same cycle) into a
// staircase-skewed output where row i is delayed by exactly i cycles.
//
// PURPOSE
//   The caller of the systolic array provides one column of A (or one row of
//   B) per cycle, with all S elements valid simultaneously. The array,
//   however, needs each element to arrive at PE_{i,j} on cycle (1 + i + j) —
//   the diagonal feed pattern. Skew buffers convert "flat" → "staircase"
//   without burdening the caller.
//
// ARCHITECTURE
//   For each row i in [0, S):
//     - row 0 is a pass-through (depth 0)
//     - row i >= 1 has a shift-register chain of i flops
//
// COST
//   Flops: 0 + 1 + ... + (S-1) = S*(S-1)/2
//   For S=4: 6 flops per skew_buffer × 2 buffers (A side + B side) = 12 flops
//   For S=8: 28 flops × 2 = 56 flops. Negligible.
//
// CONTROL
//   en — when low, all chains hold (the array can stall while keeping data).
// =============================================================================

`timescale 1ns/1ps

module skew_buffer #(
    parameter int DATA_W = 8,
    parameter int S      = 4
)(
    input  logic                              clk,
    input  logic                              rst_n,
    input  logic                              en,
    // Packed 2D arrays at the boundary: avoids Verilator's unpacked-array
    // port-propagation issues. Indexing `data_in[r]` still yields a
    // [DATA_W-1:0] slice exactly like an unpacked array would.
    input  logic signed [S-1:0][DATA_W-1:0]   data_in,
    output logic signed [S-1:0][DATA_W-1:0]   data_out
);

    // -------------------------------------------------------------------------
    // Per-row shift-register chains
    // -------------------------------------------------------------------------
    //
    // Strategy: use a generate-for loop. Inside the loop body, use a generate-
    // if so row 0 is a pass-through and rows 1..S-1 each declare their own
    // local shift register of depth equal to the row index.
    //
    // This keeps the design parameterized — the same source elaborates correctly
    // for any S without manual edits.
    //
    // -------------------------------------------------------------------------
    // Row 0 — combinational pass-through.
    // -------------------------------------------------------------------------
    assign data_out[0] = data_in[0];

    // -------------------------------------------------------------------------
    // Rows 1..S-1 — per-row shift register, depth = row index
    // -------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 1; i < S; i++) begin : gen_row

            begin : gen_shift

                // Per-row shift register, length = i.
                logic signed [DATA_W-1:0] sr [i];

                // -----------------------------------------------------------------
                // TODO A — write the always_ff that drives this shift register.
                //
                //   Behaviour:
                //     - On !rst_n: clear every stage sr[0..i-1] to 0.
                //     - Else if en:
                //         sr[0] <= data_in[i];                // load new value
                //         for s in 1..i-1: sr[s] <= sr[s-1];  // shift one stage
                //     - Else: hold (rely on always_ff implicit hold; no else needed).
                //
                //   Hint: use a `for (int s = 0; s < i; s++)` loop to clear, and
                //         a `for (int s = 1; s < i; s++)` loop to shift.
                //   Hint: the inner loops run at simulation/synthesis time inside
                //         a single always_ff, so they're allowed.
                // -----------------------------------------------------------------
                always_ff @(posedge clk or negedge rst_n) begin
                    // <YOUR CODE HERE>
                    if (!rst_n) begin
                        for (int s = 0; s < i; s++) begin
                            sr[s] <= '0;
                        end
                    end
                    else if (en) begin
                        sr[0] <= data_in[i];
                        for (int s = 1; s < i; s++) begin
                            sr[s] <= sr[s-1];
                        end
                    end
                end

                // -----------------------------------------------------------------
                // TODO B — drive data_out[i] from the LAST stage of the chain.
                //
                //   Hint: the deepest stage holds the value that's been delayed
                //         by exactly i cycles — that's what we want.
                // -----------------------------------------------------------------
                assign data_out[i] = sr[i-1];

            end
        end
    endgenerate

endmodule
