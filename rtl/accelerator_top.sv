// =============================================================================
// accelerator_top.sv  —  Integrated matmul accelerator
// =============================================================================
//
// Combines:
//   - 3 dual-port BRAMs (A, B, C operands)
//   - A tile_controller that orchestrates the matmul
//   - The S × S systolic_array (with the Phase 4 pluggable multiplier)
//
// The host (TB or, in Phase 6, an AXI/UART bridge) loads A and B into their
// BRAMs through the host-side write ports, asserts `start` with the workload
// dimensions on M_in/N_in/K_in, waits for `done`, then reads C from the C BRAM
// through its host-side read port.
//
// Two clock domains aren't needed in this project — the host uses the same
// clk as the array.
// =============================================================================

`timescale 1ns/1ps

module accelerator_top #(
    parameter int    DATA_W       = 8,
    parameter int    ACC_W        = 32,
    parameter int    S            = 8,
    parameter int    MAX_M        = 64,
    parameter int    MAX_N        = 64,
    parameter int    MAX_K        = 64,
    parameter string MULT_TYPE    = "DSP",
    parameter int    MULT_TRUNC_L = 0,
    parameter int    MULT_BAM_B   = 0,
    parameter string A_INIT_FILE  = "",
    parameter string B_INIT_FILE  = "",
    parameter string C_INIT_FILE  = ""
)(
    input  logic                                    clk,
    input  logic                                    rst_n,

    // Control
    input  logic                                    start,
    output logic                                    busy,
    output logic                                    done,
    input  logic [$clog2(MAX_M+1)-1:0]              M_in,
    input  logic [$clog2(MAX_N+1)-1:0]              N_in,
    input  logic [$clog2(MAX_K+1)-1:0]              K_in,

    // ─── Host-side A_BRAM write port ───
    input  logic                                    a_host_wr_en,
    input  logic [$clog2((MAX_M*MAX_K)/S)-1:0]      a_host_wr_addr,
    input  logic [S*DATA_W-1:0]                     a_host_wr_data,

    // ─── Host-side B_BRAM write port ───
    input  logic                                    b_host_wr_en,
    input  logic [$clog2((MAX_K*MAX_N)/S)-1:0]      b_host_wr_addr,
    input  logic [S*DATA_W-1:0]                     b_host_wr_data,

    // ─── Host-side C_BRAM read port ───
    input  logic [$clog2((MAX_M*MAX_N)/S)-1:0]      c_host_rd_addr,
    output logic [S*ACC_W-1:0]                      c_host_rd_data
);

    // -------------------------------------------------------------------------
    // BRAM widths and depths
    // -------------------------------------------------------------------------
    localparam int A_DATA_W  = S * DATA_W;
    localparam int B_DATA_W  = S * DATA_W;
    localparam int C_DATA_W  = S * ACC_W;

    localparam int A_DEPTH   = (MAX_M * MAX_K) / S;
    localparam int B_DEPTH   = (MAX_K * MAX_N) / S;
    localparam int C_DEPTH   = (MAX_M * MAX_N) / S;

    // -------------------------------------------------------------------------
    // Inter-block wires
    // -------------------------------------------------------------------------
    // Controller ↔ BRAMs
    logic [$clog2(A_DEPTH)-1:0]              ctrl_a_rd_addr;
    logic [A_DATA_W-1:0]                     a_rd_data_flat;
    logic signed [S-1:0][DATA_W-1:0]         a_rd_data_struct;

    logic [$clog2(B_DEPTH)-1:0]              ctrl_b_rd_addr;
    logic [B_DATA_W-1:0]                     b_rd_data_flat;
    logic signed [S-1:0][DATA_W-1:0]         b_rd_data_struct;

    logic                                    ctrl_c_wr_en;
    logic [$clog2(C_DEPTH)-1:0]              ctrl_c_wr_addr;
    logic signed [S-1:0][ACC_W-1:0]          ctrl_c_wr_data_struct;
    logic [C_DATA_W-1:0]                     ctrl_c_wr_data_flat;

    // Controller ↔ array
    logic                                    ctrl_array_en;
    logic                                    ctrl_array_drain_en;
    logic [S-1:0]                            ctrl_array_clear_col;
    logic signed [S-1:0][DATA_W-1:0]         ctrl_array_a_col;
    logic signed [S-1:0][DATA_W-1:0]         ctrl_array_b_row;
    logic signed [S-1:0][ACC_W-1:0]          array_c_drain;

    // Pack/unpack helpers — BRAM uses flat words, the controller and array
    // use packed-2D for indexing convenience.
    assign a_rd_data_struct      = a_rd_data_flat;
    assign b_rd_data_struct      = b_rd_data_flat;
    assign ctrl_c_wr_data_flat   = ctrl_c_wr_data_struct;

    // -------------------------------------------------------------------------
    // A_BRAM
    // -------------------------------------------------------------------------
    bram_2p #(
        .DATA_W   (A_DATA_W),
        .DEPTH    (A_DEPTH),
        .INIT_FILE(A_INIT_FILE)
    ) u_a_bram (
        .wr_clk  (clk),
        .wr_en   (a_host_wr_en),
        .wr_addr (a_host_wr_addr),
        .wr_data (a_host_wr_data),
        .rd_clk  (clk),
        .rd_addr (ctrl_a_rd_addr),
        .rd_data (a_rd_data_flat)
    );

    // -------------------------------------------------------------------------
    // B_BRAM
    // -------------------------------------------------------------------------
    bram_2p #(
        .DATA_W   (B_DATA_W),
        .DEPTH    (B_DEPTH),
        .INIT_FILE(B_INIT_FILE)
    ) u_b_bram (
        .wr_clk  (clk),
        .wr_en   (b_host_wr_en),
        .wr_addr (b_host_wr_addr),
        .wr_data (b_host_wr_data),
        .rd_clk  (clk),
        .rd_addr (ctrl_b_rd_addr),
        .rd_data (b_rd_data_flat)
    );

    // -------------------------------------------------------------------------
    // C_BRAM
    // -------------------------------------------------------------------------
    bram_2p #(
        .DATA_W   (C_DATA_W),
        .DEPTH    (C_DEPTH),
        .INIT_FILE(C_INIT_FILE)
    ) u_c_bram (
        .wr_clk  (clk),
        .wr_en   (ctrl_c_wr_en),
        .wr_addr (ctrl_c_wr_addr),
        .wr_data (ctrl_c_wr_data_flat),
        .rd_clk  (clk),
        .rd_addr (c_host_rd_addr),
        .rd_data (c_host_rd_data)
    );

    // -------------------------------------------------------------------------
    // Tile controller
    // -------------------------------------------------------------------------
    tile_controller #(
        .DATA_W   (DATA_W),
        .ACC_W    (ACC_W),
        .S        (S),
        .MAX_M    (MAX_M),
        .MAX_N    (MAX_N),
        .MAX_K    (MAX_K)
    ) u_ctrl (
        .clk             (clk),
        .rst_n           (rst_n),
        .start           (start),
        .busy            (busy),
        .done            (done),
        .M_in            (M_in),
        .N_in            (N_in),
        .K_in            (K_in),
        .a_rd_addr       (ctrl_a_rd_addr),
        .a_rd_data       (a_rd_data_struct),
        .b_rd_addr       (ctrl_b_rd_addr),
        .b_rd_data       (b_rd_data_struct),
        .c_wr_en         (ctrl_c_wr_en),
        .c_wr_addr       (ctrl_c_wr_addr),
        .c_wr_data       (ctrl_c_wr_data_struct),
        .array_en        (ctrl_array_en),
        .array_drain_en  (ctrl_array_drain_en),
        .array_clear_col (ctrl_array_clear_col),
        .array_a_col     (ctrl_array_a_col),
        .array_b_row     (ctrl_array_b_row),
        .array_c_drain   (array_c_drain)
    );

    // -------------------------------------------------------------------------
    // Systolic array (Phase 4 pluggable-multiplier version)
    // -------------------------------------------------------------------------
    systolic_array #(
        .DATA_W      (DATA_W),
        .ACC_W       (ACC_W),
        .S           (S),
        .MULT_TYPE   (MULT_TYPE),
        .MULT_TRUNC_L(MULT_TRUNC_L),
        .MULT_BAM_B  (MULT_BAM_B)
    ) u_array (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (ctrl_array_en),
        .a_col      (ctrl_array_a_col),
        .b_row      (ctrl_array_b_row),
        .clear_col  (ctrl_array_clear_col),
        .drain_en   (ctrl_array_drain_en),
        .c_drain    (array_c_drain)
    );

endmodule
