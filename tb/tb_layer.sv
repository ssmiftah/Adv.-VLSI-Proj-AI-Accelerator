// =============================================================================
// tb_layer.sv  —  Phase 6A layer-level testbench
// =============================================================================
//
// Drives accelerator_top with a real conv layer (lowered to matmul via im2col
// in Python; see scripts/phase6/gen_layer.py).
//
// Flow:
//   1. Reset.
//   2. Read a.memh and b.memh into local arrays (NOT via INIT_FILE — exercise
//      the host-write path that the eventual UART bridge will use).
//   3. Stream the loaded words into A_BRAM / B_BRAM through the host write
//      ports, one S-wide word per cycle.
//   4. Drive M_in/N_in/K_in, pulse start, wait for done.
//   5. Sweep c_host_rd_addr over the M*N_TILES used C_BRAM rows; capture
//      c_host_rd_data into an array; $writememh it to c_dut.memh.
//   6. $finish.
//
// Parameters MULT_TYPE / MULT_TRUNC_L / MULT_BAM_B are overridable from the
// build-tool -G... flag (e.g. -GMULT_TYPE=BAM -GMULT_BAM_B=2).
// =============================================================================

`timescale 1ns/1ps

module tb_layer;

    // -------------------------------------------------------------------------
    // DUT parameters (overridable from -G...)
    // -------------------------------------------------------------------------
    parameter int    DATA_W       = 8;
    parameter int    ACC_W        = 32;
    parameter int    S            = 8;
    parameter int    MAX_M        = 64;
    parameter int    MAX_N        = 64;
    parameter int    MAX_K        = 64;
    parameter string MULT_TYPE    = "DSP";
    parameter int    MULT_TRUNC_L = 0;
    parameter int    MULT_BAM_B   = 0;

    // Workload (matches scripts/phase6/gen_layer.py)
    parameter int M_VAL = 64;
    parameter int N_VAL = 16;
    parameter int K_VAL = 36;

    // I/O paths
    parameter string MEM_DIR  = "sim/phase6";
    parameter string A_FILE   = {MEM_DIR, "/a.memh"};
    parameter string B_FILE   = {MEM_DIR, "/b.memh"};
    parameter string OUT_FILE = {MEM_DIR, "/c_dut.memh"};

    // Derived
    localparam int A_DEPTH   = (MAX_M * MAX_K) / S;
    localparam int B_DEPTH   = (MAX_K * MAX_N) / S;
    localparam int C_DEPTH   = (MAX_M * MAX_N) / S;
    localparam int A_DATA_W  = S * DATA_W;
    localparam int B_DATA_W  = S * DATA_W;
    localparam int C_DATA_W  = S * ACC_W;
    localparam int A_ADDR_W  = $clog2(A_DEPTH);
    localparam int B_ADDR_W  = $clog2(B_DEPTH);
    localparam int C_ADDR_W  = $clog2(C_DEPTH);

    localparam int M_TILES = (M_VAL + S - 1) / S;
    localparam int N_TILES = (N_VAL + S - 1) / S;
    localparam int A_USED  = K_VAL * M_TILES;
    localparam int B_USED  = K_VAL * N_TILES;
    localparam int C_USED  = M_VAL * N_TILES;

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic                       start;
    logic                       busy;
    logic                       done;
    logic [$clog2(MAX_M+1)-1:0] M_in;
    logic [$clog2(MAX_N+1)-1:0] N_in;
    logic [$clog2(MAX_K+1)-1:0] K_in;

    logic                  a_host_wr_en;
    logic [A_ADDR_W-1:0]   a_host_wr_addr;
    logic [A_DATA_W-1:0]   a_host_wr_data;

    logic                  b_host_wr_en;
    logic [B_ADDR_W-1:0]   b_host_wr_addr;
    logic [B_DATA_W-1:0]   b_host_wr_data;

    logic [C_ADDR_W-1:0]   c_host_rd_addr;
    logic [C_DATA_W-1:0]   c_host_rd_data;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    accelerator_top #(
        .DATA_W      (DATA_W),
        .ACC_W       (ACC_W),
        .S           (S),
        .MAX_M       (MAX_M),
        .MAX_N       (MAX_N),
        .MAX_K       (MAX_K),
        .MULT_TYPE   (MULT_TYPE),
        .MULT_TRUNC_L(MULT_TRUNC_L),
        .MULT_BAM_B  (MULT_BAM_B)
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

    // -------------------------------------------------------------------------
    // Local images of the .memh files
    // -------------------------------------------------------------------------
    logic [A_DATA_W-1:0] a_image [A_DEPTH];
    logic [B_DATA_W-1:0] b_image [B_DEPTH];
    logic [C_DATA_W-1:0] c_capture [C_DEPTH];

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        // Init signals
        rst_n          = 1'b0;
        start          = 1'b0;
        M_in           = '0;
        N_in           = '0;
        K_in           = '0;
        a_host_wr_en   = 1'b0;
        a_host_wr_addr = '0;
        a_host_wr_data = '0;
        b_host_wr_en   = 1'b0;
        b_host_wr_addr = '0;
        b_host_wr_data = '0;
        c_host_rd_addr = '0;
        for (int i = 0; i < C_DEPTH; i++) c_capture[i] = '0;

        $display("INFO: tb_layer  MULT_TYPE=%s  MULT_TRUNC_L=%0d  MULT_BAM_B=%0d",
                 MULT_TYPE, MULT_TRUNC_L, MULT_BAM_B);
        $display("INFO: workload  M=%0d N=%0d K=%0d  (M_TILES=%0d N_TILES=%0d)",
                 M_VAL, N_VAL, K_VAL, M_TILES, N_TILES);
        $display("INFO: reading %s", A_FILE);
        $readmemh(A_FILE, a_image);
        $display("INFO: reading %s", B_FILE);
        $readmemh(B_FILE, b_image);

        // Hold reset for a few cycles
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---------------------------------------------------------------------
        // Load A_BRAM via the host write port — one 64-bit word per cycle.
        // ---------------------------------------------------------------------
        $display("INFO: loading A_BRAM (%0d words)", A_USED);
        for (int addr = 0; addr < A_USED; addr++) begin
            a_host_wr_en   <= 1'b1;
            a_host_wr_addr <= A_ADDR_W'(addr);
            a_host_wr_data <= a_image[addr];
            @(posedge clk);
        end
        a_host_wr_en <= 1'b0;
        @(posedge clk);

        // ---------------------------------------------------------------------
        // Load B_BRAM
        // ---------------------------------------------------------------------
        $display("INFO: loading B_BRAM (%0d words)", B_USED);
        for (int addr = 0; addr < B_USED; addr++) begin
            b_host_wr_en   <= 1'b1;
            b_host_wr_addr <= B_ADDR_W'(addr);
            b_host_wr_data <= b_image[addr];
            @(posedge clk);
        end
        b_host_wr_en <= 1'b0;
        @(posedge clk);

        // ---------------------------------------------------------------------
        // Fire the matmul
        // ---------------------------------------------------------------------
        M_in  <= M_VAL[$clog2(MAX_M+1)-1:0];
        N_in  <= N_VAL[$clog2(MAX_N+1)-1:0];
        K_in  <= K_VAL[$clog2(MAX_K+1)-1:0];
        @(posedge clk);

        $display("INFO: pulsing start at t=%0t", $time);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        // Wait for done (with a sane timeout)
        begin
            int unsigned timeout;
            timeout = 0;
            while (!done) begin
                @(posedge clk);
                timeout++;
                if (timeout > 200000) begin
                    $display("ERROR: timeout waiting for done at t=%0t", $time);
                    $finish;
                end
            end
        end
        $display("INFO: done asserted at t=%0t (cycles=%0d)", $time, $time/10);

        // ---------------------------------------------------------------------
        // Read C_BRAM. The host read port is registered (1-cycle BRAM
        // latency). Drive addr, wait two posedges, then sample — robust
        // across simulators. 2 cycles/word is a rounding error vs the matmul.
        // ---------------------------------------------------------------------
        $display("INFO: reading C_BRAM (%0d words)", C_USED);
        for (int addr = 0; addr < C_USED; addr++) begin
            c_host_rd_addr <= C_ADDR_W'(addr);
            @(posedge clk);   // BRAM samples addr; registers mem[addr]
            @(posedge clk);   // rd_data has settled to mem[addr]
            c_capture[addr] = c_host_rd_data;
        end

        // ---------------------------------------------------------------------
        // Dump
        // ---------------------------------------------------------------------
        $display("INFO: writing %s", OUT_FILE);
        $writememh(OUT_FILE, c_capture, 0, C_DEPTH-1);

        $display("INFO: tb_layer DONE  MULT_TYPE=%s", MULT_TYPE);
        $finish;
    end

endmodule
