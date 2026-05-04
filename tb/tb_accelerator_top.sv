// =============================================================================
// tb_accelerator_top.sv  —  End-to-end test for the matmul accelerator
// =============================================================================
//
// Drives a complete M × K · K × N matmul through accelerator_top:
//   1. Generate random A and B in software (TB).
//   2. Pack into A_BRAM / B_BRAM via the host write ports.
//   3. Pulse `start` with M_in, N_in, K_in.
//   4. Wait for `done`.
//   5. Read C_BRAM via the host read port and compare against a SystemVerilog
//      golden matmul.
//
// SCENARIOS
//   1. Identity (M=N=K=S, A=I, B=I → C=I)
//   2. Random matmul with M=N=K=S          (single output tile)
//   3. Random matmul with M=N=2S, K=2S     (4 output tiles, 2 K-blocks)
//   4. Random matmul with M=N=K=4S         (full sweep, all multiples of S)
//
// Edge-tile scenarios (M, N, K not multiples of S) are deferred to a separate
// test once the multiple-of-S cases are clean.
//
// Run:
//   $ verilator --binary -j 0 -Wall -Wno-fatal --trace --Mdir /tmp/acc_build \
//       rtl/multiplier/*.sv rtl/pe_int8.sv rtl/skew_buffer.sv \
//       rtl/systolic_array.sv rtl/bram_2p.sv rtl/tile_controller.sv \
//       rtl/accelerator_top.sv tb/tb_accelerator_top.sv \
//       --top-module tb_accelerator_top -o tb_acc
//   $ /tmp/acc_build/tb_acc
// =============================================================================

`timescale 1ns/1ps

module tb_accelerator_top;

    localparam int    DATA_W = 8;
    localparam int    ACC_W  = 32;
    localparam int    S      = 8;
    localparam int    MAX_M  = 64;
    localparam int    MAX_N  = 64;
    localparam int    MAX_K  = 64;
    parameter  string MULT_TYPE = "DSP";
    localparam time   CLK_PERIOD = 10ns;

    localparam int A_DEPTH = (MAX_M * MAX_K) / S;
    localparam int B_DEPTH = (MAX_K * MAX_N) / S;
    localparam int C_DEPTH = (MAX_M * MAX_N) / S;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic                              clk;
    logic                              rst_n;
    logic                              start, busy, done;
    logic [$clog2(MAX_M+1)-1:0]        M_in;
    logic [$clog2(MAX_N+1)-1:0]        N_in;
    logic [$clog2(MAX_K+1)-1:0]        K_in;

    logic                              a_host_wr_en;
    logic [$clog2(A_DEPTH)-1:0]        a_host_wr_addr;
    logic [S*DATA_W-1:0]               a_host_wr_data;

    logic                              b_host_wr_en;
    logic [$clog2(B_DEPTH)-1:0]        b_host_wr_addr;
    logic [S*DATA_W-1:0]               b_host_wr_data;

    logic [$clog2(C_DEPTH)-1:0]        c_host_rd_addr;
    logic [S*ACC_W-1:0]                c_host_rd_data;

    accelerator_top #(
        .DATA_W      (DATA_W),
        .ACC_W       (ACC_W),
        .S           (S),
        .MAX_M       (MAX_M),
        .MAX_N       (MAX_N),
        .MAX_K       (MAX_K),
        .MULT_TYPE   (MULT_TYPE)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .busy           (busy),
        .done           (done),
        .M_in           (M_in),
        .N_in           (N_in),
        .K_in           (K_in),
        .a_host_wr_en   (a_host_wr_en),
        .a_host_wr_addr (a_host_wr_addr),
        .a_host_wr_data (a_host_wr_data),
        .b_host_wr_en   (b_host_wr_en),
        .b_host_wr_addr (b_host_wr_addr),
        .b_host_wr_data (b_host_wr_data),
        .c_host_rd_addr (c_host_rd_addr),
        .c_host_rd_data (c_host_rd_data)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk <= ~clk;

    // -------------------------------------------------------------------------
    // Software model storage
    // -------------------------------------------------------------------------
    logic signed [DATA_W-1:0]   A_sw [MAX_M][MAX_K];
    logic signed [DATA_W-1:0]   B_sw [MAX_K][MAX_N];
    logic signed [ACC_W-1:0]    C_sw [MAX_M][MAX_N];   // golden
    logic signed [ACC_W-1:0]    C_hw [MAX_M][MAX_N];   // captured from C_BRAM

    // -------------------------------------------------------------------------
    // Bookkeeping
    // -------------------------------------------------------------------------
    int errors = 0;
    int checks = 0;

    task automatic check_cell(input string scenario,
                              input int i, j,
                              input logic signed [ACC_W-1:0] got,
                              input logic signed [ACC_W-1:0] exp);
        checks++;
        if (got !== exp) begin
            $display("[%0t] FAIL  %s.C[%0d][%0d] : got=%0d exp=%0d",
                     $time, scenario, i, j, got, exp);
            errors++;
        end
    endtask

    // -------------------------------------------------------------------------
    // Compute golden C = A · B (for an M × K · K × N matmul)
    // -------------------------------------------------------------------------
    task automatic compute_golden(input int M, N, K);
        for (int i = 0; i < M; i++) begin
            for (int j = 0; j < N; j++) begin
                C_sw[i][j] = '0;
                for (int kk = 0; kk < K; kk++) begin
                    C_sw[i][j] += ACC_W'(A_sw[i][kk]) * ACC_W'(B_sw[kk][j]);
                end
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Load A_sw into A_BRAM via the host write port.
    // BRAM word at addr (k * M_TILES + tile_p) holds A[tile_p*S+0..S-1][k].
    // -------------------------------------------------------------------------
    task automatic load_a_bram(input int M, K);
        int M_TILES;
        logic [S*DATA_W-1:0] word;
        M_TILES = (M + S - 1) / S;

        for (int k = 0; k < K; k++) begin
            for (int p = 0; p < M_TILES; p++) begin
                word = '0;
                for (int i = 0; i < S; i++) begin
                    int row = p*S + i;
                    if (row < M)
                        word[i*DATA_W +: DATA_W] = A_sw[row][k];
                    // else: zero-padded
                end
                @(negedge clk);
                a_host_wr_en   = 1'b1;
                a_host_wr_addr = ($clog2(A_DEPTH))'(k * M_TILES + p);
                a_host_wr_data = word;
                @(posedge clk);
            end
        end
        @(negedge clk);
        a_host_wr_en = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Load B_sw into B_BRAM.
    // BRAM word at addr (k * N_TILES + tile_r) holds B[k][tile_r*S+0..S-1].
    // -------------------------------------------------------------------------
    task automatic load_b_bram(input int K, N);
        int N_TILES;
        logic [S*DATA_W-1:0] word;
        N_TILES = (N + S - 1) / S;

        for (int k = 0; k < K; k++) begin
            for (int r = 0; r < N_TILES; r++) begin
                word = '0;
                for (int j = 0; j < S; j++) begin
                    int col = r*S + j;
                    if (col < N)
                        word[j*DATA_W +: DATA_W] = B_sw[k][col];
                end
                @(negedge clk);
                b_host_wr_en   = 1'b1;
                b_host_wr_addr = ($clog2(B_DEPTH))'(k * N_TILES + r);
                b_host_wr_data = word;
                @(posedge clk);
            end
        end
        @(negedge clk);
        b_host_wr_en = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Read C_BRAM and unpack into C_hw.
    // BRAM word at addr (output_row * N_TILES + tile_r) holds
    //    C[output_row][tile_r*S+0..S-1].
    // -------------------------------------------------------------------------
    task automatic read_c_bram(input int M, N);
        int N_TILES;
        logic [S*ACC_W-1:0] word;
        N_TILES = (N + S - 1) / S;

        for (int row = 0; row < M; row++) begin
            for (int r = 0; r < N_TILES; r++) begin
                @(negedge clk);
                c_host_rd_addr = ($clog2(C_DEPTH))'(row * N_TILES + r);
                @(posedge clk);
                @(negedge clk);
                word = c_host_rd_data;
                for (int j = 0; j < S; j++) begin
                    int col = r*S + j;
                    if (col < N)
                        C_hw[row][col] = word[j*ACC_W +: ACC_W];
                end
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Run one full matmul scenario
    // -------------------------------------------------------------------------
    task automatic run_scenario(input string label,
                                input int M, N, K);
        int n_fail_before;
        $display("\n--- %s : M=%0d N=%0d K=%0d ---", label, M, N, K);

        // Generate inputs (already in A_sw / B_sw; caller must have populated)
        compute_golden(M, N, K);

        // Reset DUT
        rst_n = 1'b0;
        start = 1'b0;
        a_host_wr_en = 1'b0;
        b_host_wr_en = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Load BRAMs
        load_a_bram(M, K);
        load_b_bram(K, N);

        // Pulse start with workload dimensions
        @(negedge clk);
        M_in  = M[$clog2(MAX_M+1)-1:0];
        N_in  = N[$clog2(MAX_N+1)-1:0];
        K_in  = K[$clog2(MAX_K+1)-1:0];
        start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;

        // Wait for done
        wait (done == 1'b1);
        @(posedge clk);

        // Read back and compare
        read_c_bram(M, N);
        n_fail_before = errors;
        for (int i = 0; i < M; i++)
            for (int j = 0; j < N; j++)
                check_cell(label, i, j, C_hw[i][j], C_sw[i][j]);

        if (errors == n_fail_before)
            $display("[%0t] %s : %0d cells PASS", $time, label, M*N);
        else
            $display("[%0t] %s : %0d cells FAILED", $time, label, errors - n_fail_before);
    endtask

    // -------------------------------------------------------------------------
    // Generators for A and B
    // -------------------------------------------------------------------------
    task automatic gen_identity(input int N);
        for (int i = 0; i < MAX_M; i++)
            for (int j = 0; j < MAX_K; j++) A_sw[i][j] = '0;
        for (int i = 0; i < MAX_K; i++)
            for (int j = 0; j < MAX_N; j++) B_sw[i][j] = '0;
        for (int i = 0; i < N; i++) begin
            A_sw[i][i] = 8'sd1;
            B_sw[i][i] = 8'sd1;
        end
    endtask

    task automatic gen_random(input int M, N, K);
        for (int i = 0; i < MAX_M; i++)
            for (int j = 0; j < MAX_K; j++) A_sw[i][j] = '0;
        for (int i = 0; i < MAX_K; i++)
            for (int j = 0; j < MAX_N; j++) B_sw[i][j] = '0;
        for (int i = 0; i < M; i++)
            for (int k = 0; k < K; k++) A_sw[i][k] = DATA_W'($random);
        for (int k = 0; k < K; k++)
            for (int j = 0; j < N; j++) B_sw[k][j] = DATA_W'($random);
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("waves_acc.vcd");
        $dumpvars(0, tb_accelerator_top);

        $display("================================================");
        $display(" tb_accelerator_top  S=%0d  MULT_TYPE=%s", S, MULT_TYPE);
        $display("================================================");

        // Init
        a_host_wr_en   = 1'b0;
        a_host_wr_addr = '0;
        a_host_wr_data = '0;
        b_host_wr_en   = 1'b0;
        b_host_wr_addr = '0;
        b_host_wr_data = '0;
        c_host_rd_addr = '0;
        M_in           = '0;
        N_in           = '0;
        K_in           = '0;
        start          = 1'b0;
        rst_n          = 1'b0;

        // Scenario 1 — Identity
        gen_identity(S);
        run_scenario("identity_S",  S,  S,  S);

        // Scenario 2 — Random, single output tile
        gen_random(S, S, S);
        run_scenario("random_S",    S,  S,  S);

        // Scenario 3 — Random, 2×2 output tiles, 2 K-blocks
        gen_random(2*S, 2*S, 2*S);
        run_scenario("random_2S",   2*S, 2*S, 2*S);

        // Scenario 4 — Random, full 4×4 output tiles
        gen_random(4*S, 4*S, 4*S);
        run_scenario("random_4S",   4*S, 4*S, 4*S);

        // Scenario 5 — EDGE TILES: each dimension is non-multiple of S.
        //   M=20 (M_TILES=3, M_REM=4):    last tile-row is partial
        //   N=15 (N_TILES=2, N_REM=7):    last tile-col is partial
        //   K=12 (K_BLOCKS=2, K_REM=4):   last K-block is partial
        // Exercises every edge case at once.
        gen_random(20, 15, 12);
        run_scenario("edge_M20_N15_K12", 20, 15, 12);

        // Scenario 6 — Edge tiles in just one dimension (K only).
        //   K_REM = 5, M and N both multiples of S.
        gen_random(S, S, S+5);
        run_scenario("edge_K_only",      S,  S,  S+5);

        // Summary
        $display("\n========================================");
        $display(" Checks: %0d   Errors: %0d", checks, errors);
        if (errors == 0) $display(" RESULT: ALL TESTS PASSED");
        else             $display(" RESULT: FAILED");
        $display("========================================\n");

        $finish;
    end

    // Watchdog
    initial begin
        #(CLK_PERIOD * 200_000);
        $display("TIMEOUT");
        $finish;
    end

endmodule
