// =============================================================================
// tb_pe_int8.sv  —  Self-checking testbench for pe_int8
// =============================================================================
//
// Six scenarios from docs/phase1/00_design_decisions.md §8:
//   1. Reset behaviour
//   2. Single MAC
//   3. Forwarding (a_out, b_out one-cycle delay)
//   4. Multi-MAC accumulation vs. golden reference
//   5. clear_acc mid-stream
//   6. Signed (negative input) correctness
//
// Run with Verilator (shell):
//   $ verilator --binary -j 0 -Wall -Wno-fatal --trace \
//       rtl/pe_int8.sv tb/tb_pe_int8.sv --top-module tb_pe_int8 -o tb_pe_int8
//   $ ./obj_dir/tb_pe_int8
//
// Outputs:
//   - PASS/FAIL lines on stdout per scenario
//   - waves.vcd  (open with: gtkwave waves.vcd)
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module tb_pe_int8;

    // -------------------------------------------------------------------------
    // Parameters and DUT signals
    // -------------------------------------------------------------------------
    localparam int DATA_W = 8;
    localparam int ACC_W  = 32;
    localparam time CLK_PERIOD = 10ns;   // 100 MHz

    logic                       clk;
    logic                       rst_n;
    logic                       en;
    logic                       clear_acc;
    logic                       drain_en;
    logic signed [DATA_W-1:0]   a_in;
    logic signed [DATA_W-1:0]   b_in;
    logic signed [ACC_W-1:0]    c_drain_in;
    logic signed [DATA_W-1:0]   a_out;
    logic signed [DATA_W-1:0]   b_out;
    logic signed [ACC_W-1:0]    c_out;
    logic signed [ACC_W-1:0]    c_drain_out;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    pe_int8 #(
        .DATA_W(DATA_W),
        .ACC_W (ACC_W)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .en          (en),
        .clear_acc   (clear_acc),
        .drain_en    (drain_en),
        .a_in        (a_in),
        .b_in        (b_in),
        .c_drain_in  (c_drain_in),
        .a_out       (a_out),
        .b_out       (b_out),
        .c_out       (c_out),
        .c_drain_out (c_drain_out)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk <= ~clk;

    // -------------------------------------------------------------------------
    // Pass / fail bookkeeping
    // -------------------------------------------------------------------------
    int errors = 0;
    int checks = 0;

    task automatic check(input string label,
                         input logic signed [ACC_W-1:0] got,
                         input logic signed [ACC_W-1:0] exp);
        checks++;
        if (got !== exp) begin
            $display("[%0t] FAIL  %s : got=%0d (0x%08h)  exp=%0d (0x%08h)",
                     $time, label, got, got, exp, exp);
            errors++;
        end else begin
            $display("[%0t] pass  %s : %0d", $time, label, got);
        end
    endtask

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    // Drive ONE complete MAC. Two cycles, both with en=1:
    //   Cycle 1 — present (av, bv); posedge latches them into a_reg/b_reg.
    //   Cycle 2 — drive zeros; posedge folds (av*bv) into c_reg AND latches
    //             zeros into a_reg/b_reg so the next call starts clean.
    // On return: c_out reflects c_reg += av*bv; en is still 1; a_reg=b_reg=0.
    task automatic drive_pair(input logic signed [DATA_W-1:0] av,
                              input logic signed [DATA_W-1:0] bv);
        @(negedge clk);
        a_in = av;
        b_in = bv;
        en   = 1'b1;
        @(posedge clk);    // a_reg <= av, b_reg <= bv
        @(negedge clk);
        a_in = '0;
        b_in = '0;
        en   = 1'b1;       // KEEP en high so the next posedge accumulates
        @(posedge clk);    // c_reg <= c_reg + av*bv ; a_reg/b_reg <= 0
    endtask

    task automatic do_reset();
        rst_n      = 1'b0;
        en         = 1'b0;
        clear_acc  = 1'b0;
        drain_en   = 1'b0;       // tied off by default in single-PE TB
        a_in       = '0;
        b_in       = '0;
        c_drain_in = '0;         // tied off by default in single-PE TB
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    endtask

    // -------------------------------------------------------------------------
    // Main stimulus
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_pe_int8);

        // ---------------------------------------------------------------------
        // Scenario 1 — Reset behaviour
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 1: Reset ---");
        do_reset();
        check("reset.a_out", {{(ACC_W-DATA_W){1'b0}}, a_out}, '0);
        check("reset.b_out", {{(ACC_W-DATA_W){1'b0}}, b_out}, '0);
        check("reset.c_out", c_out, '0);

        // ---------------------------------------------------------------------
        // Scenario 2 — Single MAC: 5 * 7 = 35
        // ---------------------------------------------------------------------
        // Timeline (relative to drive_pair's @posedge):
        //   T0  : a_reg=5,  b_reg=7        c_reg unchanged (0)
        //   T1  : prod=35   c_reg <= 0+35  → c_reg becomes 35 at end of T1
        //   T2  : c_out reads as 35
        $display("\n--- Scenario 2: Single MAC 5*7 ---");
        do_reset();
        drive_pair(8'sd5, 8'sd7);
        @(posedge clk);                    // accumulator updates
        @(negedge clk);
        check("single_mac", c_out, 32'sd35);

        // ---------------------------------------------------------------------
        // Scenario 3 — Forwarding latency
        // ---------------------------------------------------------------------
        // a_out / b_out should equal whatever was driven on a_in / b_in
        // exactly ONE cycle earlier.
        $display("\n--- Scenario 3: Forwarding ---");
        do_reset();
        @(negedge clk);
        a_in = 8'sd42;   b_in = -8'sd17;   en = 1'b1;
        @(posedge clk);                    // latches into a_reg/b_reg
        @(negedge clk);                    // sample one half-cycle later
        check("fwd.a_out", {{(ACC_W-DATA_W){a_out[DATA_W-1]}}, a_out}, 32'sd42);
        check("fwd.b_out", {{(ACC_W-DATA_W){b_out[DATA_W-1]}}, b_out}, -32'sd17);
        a_in = '0; b_in = '0; en = 1'b0;

        // ---------------------------------------------------------------------
        // Scenario 4 — Multi-MAC accumulation vs golden
        // ---------------------------------------------------------------------
        // Stream K random pairs, compute golden sum in the TB, compare.
        $display("\n--- Scenario 4: Multi-MAC accumulation ---");
        do_reset();
        begin : multi_mac
            localparam int K = 16;
            logic signed [DATA_W-1:0] av, bv;
            logic signed [ACC_W-1:0]  golden;
            golden = '0;
            for (int k = 0; k < K; k++) begin
                av = DATA_W'($random);    // explicit truncation to DATA_W
                bv = DATA_W'($random);
                golden = golden + ACC_W'(av) * ACC_W'(bv);
                drive_pair(av, bv);
            end
            // After the last drive_pair, we still need 1 more cycle for the
            // final MAC to land in c_reg.
            @(posedge clk);
            @(negedge clk);
            check("multi_mac.K=16", c_out, golden);
        end

        // ---------------------------------------------------------------------
        // Scenario 5 — clear_acc mid-stream
        // ---------------------------------------------------------------------
        // Accumulate a few values, assert clear_acc for one cycle, verify
        // c_reg returns to 0, then keep accumulating cleanly.
        $display("\n--- Scenario 5: clear_acc mid-stream ---");
        do_reset();
        drive_pair(8'sd10, 8'sd10);    // c_reg → 100 (after 1 more cycle)
        drive_pair(8'sd10, 8'sd10);    // c_reg → 200
        @(posedge clk);                // let last MAC settle
        @(negedge clk);
        check("pre_clear", c_out, 32'sd200);

        // Pulse clear_acc for one cycle WITH en=0 — verifies option (b):
        // clear must take effect even while the rest of the pipeline is stalled.
        @(negedge clk);
        en        = 1'b0;
        clear_acc = 1'b1;
        @(posedge clk);          // c_reg <= 0 even though en=0
        @(negedge clk);
        clear_acc = 1'b0;
        en        = 1'b1;
        check("post_clear", c_out, 32'sd0);

        drive_pair(8'sd3, 8'sd4);      // c_reg → 12
        @(posedge clk);
        @(negedge clk);
        check("after_clear_mac", c_out, 32'sd12);

        // ---------------------------------------------------------------------
        // Scenario 6 — Signed correctness with negatives
        // ---------------------------------------------------------------------
        // (-50) * 4 + 30 * (-7) = -200 + (-210) = -410
        $display("\n--- Scenario 6: Signed inputs ---");
        do_reset();
        drive_pair(-8'sd50, 8'sd4);
        drive_pair(8'sd30, -8'sd7);
        @(posedge clk);
        @(negedge clk);
        check("signed_acc", c_out, -32'sd410);

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

    // Watchdog
    initial begin
        #(CLK_PERIOD * 2000);
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
