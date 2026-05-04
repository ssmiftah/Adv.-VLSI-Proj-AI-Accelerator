// =============================================================================
// tb_skew_buffer.sv  —  Self-checking testbench for skew_buffer
// =============================================================================
//
// Verifies the triangular shift-register bank produces the staircase pattern
// the systolic array needs.
//
// SAMPLING CONVENTION
//   The skew buffer's chains shift on posedge clk. The downstream array's PEs
//   ALSO latch on posedge clk. To verify "what the array sees," this TB:
//       1. Applies inputs at the negedge (data_in stable for the upcoming posedge).
//       2. Samples data_out at THAT SAME negedge — the value is what the
//          array would latch at the upcoming posedge.
//       3. Then advances by waiting for the posedge.
//   This way the chain hasn't shifted yet when we sample, and the formula
//   "row r is delayed by r cycles" reads literally.
//
// Run (shell):
//   $ verilator --binary -j 0 -Wall -Wno-fatal --trace --Mdir /tmp/skew_build \
//       rtl/skew_buffer.sv tb/tb_skew_buffer.sv \
//       --top-module tb_skew_buffer -o tb_skew_buffer
//   $ /tmp/skew_build/tb_skew_buffer
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module tb_skew_buffer;

    localparam int  DATA_W     = 8;
    localparam int  S          = 4;
    localparam time CLK_PERIOD = 10ns;

    logic                                 clk;
    logic                                 rst_n;
    logic                                 en;
    logic signed [S-1:0][DATA_W-1:0]      data_in;     // packed 2D
    logic signed [S-1:0][DATA_W-1:0]      data_out;    // packed 2D

    skew_buffer #(
        .DATA_W(DATA_W),
        .S     (S)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en),
        .data_in (data_in),
        .data_out(data_out)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk <= ~clk;

    // -------------------------------------------------------------------------
    // Bookkeeping
    // -------------------------------------------------------------------------
    int errors = 0;
    int checks = 0;

    task automatic check(input string label,
                         input logic signed [DATA_W-1:0] got,
                         input logic signed [DATA_W-1:0] exp);
        checks++;
        if (got !== exp) begin
            $display("[%0t] FAIL  %s : got=%0d  exp=%0d", $time, label, got, exp);
            errors++;
        end else begin
            $display("[%0t] pass  %s : %0d", $time, label, got);
        end
    endtask

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    // Apply vec at the next negedge. data_out can be sampled IMMEDIATELY after
    // (still on the negedge, before the upcoming posedge). The chain has not
    // shifted yet, so sampled values reflect the PRE-posedge state — the same
    // state the array's PEs would latch at the upcoming posedge.
    task automatic apply(input logic signed [S-1:0][DATA_W-1:0] vec);
        @(negedge clk);
        data_in = vec;
        en = 1'b1;
        #1;
    endtask

    // Wait for the upcoming posedge so the chain shifts.
    task automatic do_advance();
        @(posedge clk);
    endtask

    task automatic do_reset();
        rst_n   = 1'b0;
        en      = 1'b0;
        data_in = '0;     // packed: zero the whole bus in one shot
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("waves_skew.vcd");
        $dumpvars(0, tb_skew_buffer);

        // ---------------------------------------------------------------------
        // Scenario 1 — Reset
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 1: Reset ---");
        do_reset();
        for (int r = 0; r < S; r++)
            check($sformatf("reset.row%0d", r), data_out[r], 8'sd0);

        // ---------------------------------------------------------------------
        // Scenario 2 — Impulse on each row
        //
        // For each row r, drive an impulse on data_in[r] for one cycle, advance
        // r-1 times with zeros (so the impulse propagates from sr[0] to
        // sr[r-1]), then sample. data_out[r] should equal the impulse value.
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 2: Impulse delay ---");
        for (int r = 0; r < S; r++) begin : impulse_loop
            logic signed [S-1:0][DATA_W-1:0] impulse_vec;
            logic signed [S-1:0][DATA_W-1:0] zero_vec;
            logic signed [DATA_W-1:0]        expected;

            do_reset();

            impulse_vec     = '0;
            zero_vec        = '0;
            expected        = 8'(1 + r * 10);   // 1, 11, 21, 31
            impulse_vec[r]  = expected;

            // 1) Apply the impulse vector. data_out[r] sampled now is what the
            //    array would latch at the upcoming posedge.
            apply(impulse_vec);

            if (r == 0) begin
                // Pass-through row: data_out[0] = data_in[0] right now.
                check($sformatf("impulse.row%0d", r), data_out[r], expected);
            end
            else begin
                // 2) Advance to load the impulse into sr[0] for row r.
                do_advance();

                // 3) For rows r >= 2, advance (r-1) more times with zeros so
                //    the impulse walks down the chain to sr[r-1].
                for (int c = 1; c < r; c++) begin
                    apply(zero_vec);
                    do_advance();
                end

                // 4) Final apply with zeros, then sample BEFORE the next
                //    posedge would shift the impulse out of sr[r-1].
                apply(zero_vec);
                check($sformatf("impulse.row%0d", r), data_out[r], expected);
            end
        end

        // ---------------------------------------------------------------------
        // Scenario 3 — Staircase stream
        //
        // At iteration k, drive data_in[r] = (r * 10 + k). Sample BEFORE the
        // upcoming posedge. Expected:
        //     data_out[r] at iteration k = r * 10 + (k - r)   if k >= r
        //                                = 0                  otherwise
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 3: Staircase stream ---");
        do_reset();
        begin : stream_test
            localparam int K = 8;
            logic signed [S-1:0][DATA_W-1:0] vec;

            for (int k = 0; k < K; k++) begin
                for (int r = 0; r < S; r++) vec[r] = 8'(r * 10 + k);
                apply(vec);

                for (int r = 0; r < S; r++) begin
                    automatic int kr = k - r;
                    automatic logic signed [DATA_W-1:0] expv =
                        (kr >= 0) ? 8'(r * 10 + kr) : 8'sd0;
                    check($sformatf("stream.k=%0d.row%0d", k, r), data_out[r], expv);
                end

                do_advance();
            end
        end

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $display("\n========================================");
        $display(" Checks: %0d   Errors: %0d", checks, errors);
        if (errors == 0) $display(" RESULT: ALL TESTS PASSED");
        else             $display(" RESULT: FAILED");
        $display("========================================\n");

        $finish;
    end

    initial begin
        #(CLK_PERIOD * 2000);
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
