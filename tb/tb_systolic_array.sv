// =============================================================================
// tb_systolic_array.sv  —  Self-checking testbench for systolic_array
// =============================================================================
//
// SCENARIOS (per docs/phase2/00_design_decisions.md §8):
//   1. Reset                        — all c_drain outputs read 0.
//   2. Identity matmul              — A = I_S, B = I_S → C = I_S.
//   3. Random INT8 matmul           — K = S, signed values, golden = SV-side
//                                     reference computed by compute_golden().
//   4. Negative inputs (signed)     — random with mixed signs.
//
// TIMING MODEL
//   Phase 1 (compute):  K cycles streaming column-k of A and row-k of B.
//   Phase 2 (flush):    FLUSH_CYC cycles with zero inputs and en=1 so any
//                       in-flight MAC settles into c_reg without contamination.
//   Phase 3 (drain):    S cycles with drain_en=1; capture c_drain on each.
//                       Because the drain shifts DOWN, the first capture is
//                       the BOTTOM row of C and the last is the TOP row.
//
// Run (shell):
//   $ verilator --binary -j 0 -Wall -Wno-fatal --trace --Mdir /tmp/sa_build \
//       rtl/pe_int8.sv rtl/skew_buffer.sv rtl/systolic_array.sv \
//       tb/tb_systolic_array.sv \
//       --top-module tb_systolic_array -o tb_systolic_array
//   $ /tmp/sa_build/tb_systolic_array
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module tb_systolic_array;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int    DATA_W       = 8;
    localparam int    ACC_W        = 32;
    localparam int    S            = 8;
    // Phase 4 variant under test. Override at compile time with the -G flag
    // (e.g.  $ verilator ...  -GMULT_TYPE='"LUT"'  ...).
    parameter  string MULT_TYPE    = "DSP";
    parameter  int    MULT_TRUNC_L = 0;
    parameter  int    MULT_BAM_B   = 0;
    // Flush must cover the corner PE's worst-case path:
    //   skew (S-1) + forwarding hops (S-1) + MAC pipeline (2 stages) = 2S - 1
    // We use 2*S for a small safety margin.
    // (Phase 4 reverted to 2-stage MAC so all multiplier variants are
    //  compared on the same pipeline depth.)
    localparam int  FLUSH_CYC  = 2 * S;
    localparam time CLK_PERIOD = 10ns;

    // -------------------------------------------------------------------------
    // DUT signals (packed 2D buses per the project convention)
    // -------------------------------------------------------------------------
    logic                                 clk;
    logic                                 rst_n;
    logic                                 en;
    logic signed [S-1:0][DATA_W-1:0]      a_col;
    logic signed [S-1:0][DATA_W-1:0]      b_row;
    logic [S-1:0]                         clear_col;
    logic                                 drain_en;
    logic signed [S-1:0][ACC_W-1:0]       c_drain;

    systolic_array #(
        .DATA_W      (DATA_W),
        .ACC_W       (ACC_W),
        .S           (S),
        .MULT_TYPE   (MULT_TYPE),
        .MULT_TRUNC_L(MULT_TRUNC_L),
        .MULT_BAM_B  (MULT_BAM_B)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (en),
        .a_col    (a_col),
        .b_row    (b_row),
        .clear_col(clear_col),
        .drain_en (drain_en),
        .c_drain  (c_drain)
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

    // Per-variant tolerance. 0 for exact variants; for approximate variants
    // we set this from the test scenario based on the theoretical bound.
    int tolerance = 0;

    // Error-stats accumulators (cleared at the start of each scenario).
    int           err_count;     // # of cells checked
    longint       err_abs_sum;   // sum of |error|
    longint       err_sq_sum;    // sum of error^2
    int           err_abs_max;   // max |error|

    task automatic clear_error_stats();
        err_count    = 0;
        err_abs_sum  = 0;
        err_sq_sum   = 0;
        err_abs_max  = 0;
    endtask

    task automatic print_error_stats(input string scenario);
        real mae;
        real mse;
        if (err_count == 0) begin
            $display("  stats[%s] : no checks", scenario);
            return;
        end
        mae = real'(err_abs_sum) / real'(err_count);
        mse = real'(err_sq_sum)  / real'(err_count);
        $display("  stats[%s] : N=%0d  max|err|=%0d  MAE=%0.2f  MSE=%0.2f",
                 scenario, err_count, err_abs_max, mae, mse);
    endtask

    task automatic check(input string label,
                         input logic signed [ACC_W-1:0] got,
                         input logic signed [ACC_W-1:0] exp);
        longint err;
        longint abs_err;
        checks++;
        err     = longint'(got) - longint'(exp);
        abs_err = (err < 0) ? -err : err;

        // Update stats
        err_count   += 1;
        err_abs_sum += abs_err;
        err_sq_sum  += err * err;
        if (abs_err > err_abs_max) err_abs_max = int'(abs_err);

        if (abs_err > tolerance) begin
            $display("[%0t] FAIL  %s : got=%0d exp=%0d (|err|=%0d > tol=%0d)",
                     $time, label, got, exp, abs_err, tolerance);
            errors++;
        end else if (abs_err == 0) begin
            $display("[%0t] pass  %s : %0d", $time, label, got);
        end else begin
            $display("[%0t] pass  %s : %0d (|err|=%0d ≤ tol=%0d)",
                     $time, label, got, abs_err, tolerance);
        end
    endtask

    // -------------------------------------------------------------------------
    // Compute golden — pure SV reference
    //   K is passed as a parameter so we can stress K > S in later scenarios.
    // -------------------------------------------------------------------------
    function automatic void compute_golden(
        input  int                       K_in,
        input  logic signed [DATA_W-1:0] A_mat [S][16],   // up to K=16
        input  logic signed [DATA_W-1:0] B_mat [16][S],
        output logic signed [ACC_W-1:0]  C_mat [S][S]
    );
        for (int i = 0; i < S; i++) begin
            for (int j = 0; j < S; j++) begin
                C_mat[i][j] = '0;
                for (int kk = 0; kk < K_in; kk++) begin
                    C_mat[i][j] +=
                        ACC_W'(A_mat[i][kk]) * ACC_W'(B_mat[kk][j]);
                end
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Drive helpers
    // -------------------------------------------------------------------------
    task automatic do_reset();
        rst_n     = 1'b0;
        en        = 1'b0;
        drain_en  = 1'b0;
        clear_col = '0;
        a_col     = '0;
        b_row     = '0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    endtask

    // Drive ONE compute cycle: present column k of A and row k of B.
    task automatic drive_compute(
        input logic signed [S-1:0][DATA_W-1:0] a_col_v,
        input logic signed [S-1:0][DATA_W-1:0] b_row_v
    );
        @(negedge clk);
        a_col     = a_col_v;
        b_row     = b_row_v;
        en        = 1'b1;
        drain_en  = 1'b0;
        clear_col = '0;
        @(posedge clk);
    endtask

    // Drive ONE idle cycle: zeros, en still high so pipeline keeps moving.
    task automatic drive_idle();
        @(negedge clk);
        a_col     = '0;
        b_row     = '0;
        en        = 1'b1;
        drain_en  = 1'b0;
        clear_col = '0;
        @(posedge clk);
    endtask

    // Drive ONE drain cycle. Caller samples c_drain BEFORE this returns
    // (i.e., before the posedge inside this task) by reading c_drain
    // after the @(negedge clk) but before @(posedge clk). To allow that
    // we split: caller asserts drain via assert_drain(), reads c_drain,
    // then advances by drain_advance().
    task automatic assert_drain();
        @(negedge clk);
        a_col     = '0;
        b_row     = '0;
        en        = 1'b1;
        drain_en  = 1'b1;
        clear_col = '0;
        #1;   // small settle so c_drain reflects current PE c_regs
    endtask

    task automatic drain_advance();
        @(posedge clk);
    endtask

    // -------------------------------------------------------------------------
    // Run a full matmul (drive + flush + drain + capture into captured_C)
    //
    // captured_C[r][c] receives C[r][c] as the array reports it.
    // -------------------------------------------------------------------------
    task automatic run_matmul(
        input  int                       K_in,
        input  logic signed [DATA_W-1:0] A_mat [S][16],
        input  logic signed [DATA_W-1:0] B_mat [16][S],
        output logic signed [ACC_W-1:0]  captured_C [S][S]
    );
        logic signed [S-1:0][DATA_W-1:0] a_col_v;
        logic signed [S-1:0][DATA_W-1:0] b_row_v;

        // Phase 1: stream K columns of A and rows of B.
        for (int k = 0; k < K_in; k++) begin
            for (int i = 0; i < S; i++) a_col_v[i] = A_mat[i][k];
            for (int j = 0; j < S; j++) b_row_v[j] = B_mat[k][j];
            drive_compute(a_col_v, b_row_v);
        end

        // Phase 2: flush.
        repeat (FLUSH_CYC) drive_idle();

        // Phase 3: drain. First capture is the BOTTOM row.
        // captured_C[S-1] is bottom row, captured_C[0] is top row, so we
        // index "S-1-d" to put the d-th capture in the right slot.
        for (int d = 0; d < S; d++) begin
            assert_drain();
            for (int j = 0; j < S; j++) captured_C[S-1-d][j] = c_drain[j];
            drain_advance();
        end

        // Return to idle.
        @(negedge clk);
        drain_en = 1'b0;
        en       = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Compare captured matrix against golden, print one PASS/FAIL per cell
    // -------------------------------------------------------------------------
    task automatic compare_matrices(
        input string                     label,
        input logic signed [ACC_W-1:0]   got [S][S],
        input logic signed [ACC_W-1:0]   exp [S][S]
    );
        for (int i = 0; i < S; i++)
            for (int j = 0; j < S; j++)
                check($sformatf("%s.C[%0d][%0d]", label, i, j), got[i][j], exp[i][j]);
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin
        // Storage for matrices (A is S×K, B is K×S, capped at K=16 for sim).
        logic signed [DATA_W-1:0]  A_mat       [S][16];
        logic signed [DATA_W-1:0]  B_mat       [16][S];
        logic signed [ACC_W-1:0]   golden_C    [S][S];
        logic signed [ACC_W-1:0]   captured_C  [S][S];

        $dumpfile("waves_sa.vcd");
        $dumpvars(0, tb_systolic_array);

        $display("================================================");
        $display(" tb_systolic_array");
        $display("   S = %0d, MULT_TYPE = %s", S, MULT_TYPE);
        $display("   MULT_TRUNC_L = %0d, MULT_BAM_B = %0d", MULT_TRUNC_L, MULT_BAM_B);
        $display("================================================");

        // Tolerance per variant. Approximate variants set their bound from the
        // theoretical worst-case error per matmul cell.
        if (MULT_TYPE == "TRUNC")
            // Truncation: per multiply |err| ≤ 2^L − 1; over K accumulations.
            tolerance = S * ((1 << MULT_TRUNC_L) - 1);
        else if (MULT_TYPE == "MITCHELL")
            // Mitchell: max relative error per multiply ≈ 11.1% of |a·b|.
            // Worst-case |a·b| for INT8 = 128 · 128 = 16384. Over K = S
            // accumulations the worst-case bound is K · 0.111 · 16384.
            // We use K · 2^(2*DATA_W-1) / 8 = K · 4096 to be safely loose.
            tolerance = S * (1 << (2*DATA_W - 1)) / 8;
        else if (MULT_TYPE == "BAM")
            // BAM: max |error per mul| ≈ 2 · 2^(DATA_W-B-1) · (2^B - 1) · 2^B
            //                                 + (2^B - 1)^2.
            // Loose upper bound: S · 2^(DATA_W + B + 2).
            tolerance = S * (1 << (DATA_W + MULT_BAM_B + 2));
        else
            tolerance = 0;

        $display("   Tolerance for this variant: %0d", tolerance);

        // ---------------------------------------------------------------------
        // Scenario 1 — Reset
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 1: Reset ---");
        clear_error_stats();
        do_reset();
        for (int j = 0; j < S; j++)
            check($sformatf("reset.c_drain[%0d]", j), c_drain[j], 32'sd0);
        print_error_stats("reset");

        // ---------------------------------------------------------------------
        // Scenario 2 — Identity matmul: I·I = I
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 2: Identity matmul (I·I = I) ---");
        clear_error_stats();
        do_reset();
        for (int i = 0; i < S; i++)
            for (int k = 0; k < 16; k++)
                A_mat[i][k] = (k < S && i == k) ? 8'sd1 : 8'sd0;
        for (int k = 0; k < 16; k++)
            for (int j = 0; j < S; j++)
                B_mat[k][j] = (k < S && k == j) ? 8'sd1 : 8'sd0;
        compute_golden(S, A_mat, B_mat, golden_C);
        run_matmul(S, A_mat, B_mat, captured_C);
        compare_matrices("identity", captured_C, golden_C);
        print_error_stats("identity");

        // ---------------------------------------------------------------------
        // Scenario 3 — Random INT8 matmul, K = S
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 3: Random INT8 matmul (K = S) ---");
        clear_error_stats();
        do_reset();
        for (int i = 0; i < S; i++)
            for (int k = 0; k < 16; k++)
                A_mat[i][k] = (k < S) ? DATA_W'($random) : 8'sd0;
        for (int k = 0; k < 16; k++)
            for (int j = 0; j < S; j++)
                B_mat[k][j] = (k < S) ? DATA_W'($random) : 8'sd0;
        compute_golden(S, A_mat, B_mat, golden_C);
        run_matmul(S, A_mat, B_mat, captured_C);
        compare_matrices("random", captured_C, golden_C);
        print_error_stats("random");

        // ---------------------------------------------------------------------
        // Scenario 4 — Signed correctness with negatives
        //   A and B both have a deliberate mix of negative and positive values.
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 4: Signed (negative) inputs ---");
        clear_error_stats();
        do_reset();
        for (int i = 0; i < S; i++) begin
            for (int k = 0; k < 16; k++) begin
                A_mat[i][k] = (k < S) ? 8'(((i + k) % 2) ?  (i + k + 1) : -(i + k + 1)) : 8'sd0;
            end
        end
        for (int k = 0; k < 16; k++) begin
            for (int j = 0; j < S; j++) begin
                B_mat[k][j] = (k < S) ? 8'(((k + j) % 2) ?  -(k + j + 2) : (k + j + 2)) : 8'sd0;
            end
        end
        compute_golden(S, A_mat, B_mat, golden_C);
        run_matmul(S, A_mat, B_mat, captured_C);
        compare_matrices("signed", captured_C, golden_C);
        print_error_stats("signed");

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
        #(CLK_PERIOD * 5000);
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
