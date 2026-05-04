// =============================================================================
// tile_controller.sv  —  Tiling controller / address generator for matmul
// =============================================================================
//
// Wraps a systolic_array with the orchestration needed to compute an
// M × K · K × N matmul larger than the array's S × S compute footprint.
//
// WORKLOAD DIMENSIONS ARE RUNTIME INPUTS (M_in, N_in, K_in). They are
// latched at `start` and used until the matmul completes. This lets the
// same bitstream run different workloads (within the BRAM size limits set
// by MAX_M, MAX_N, MAX_K).
//
// EDGE-TILE HANDLING
//   The last tile in each axis may be partial (M % S, N % S, K % S != 0).
//     - Compute: stops the inner-K loop after K_in cycles, not K_PAD.
//     - Drain: gates C_BRAM write-enable so partial output rows aren't
//       overwritten with phantom-row data.
//   The padded tail of A_BRAM/B_BRAM is assumed zero-filled by the host
//   (so phantom-column reads contribute 0 in the array, harmless).
//
// FSM
//   IDLE  → TILE_BEGIN → COMPUTE → FLUSH → DRAIN → TILE_END → (TILE_BEGIN|DONE) → IDLE
//
// PIPELINE NOTE
//   BRAM has 1-cycle read latency. So the array sees a_col / b_row one
//   cycle after the controller issues the address. The FLUSH phase
//   (default 2*S + 2 cycles) absorbs the pipeline depth: skew buffer
//   (S-1) + inter-PE forwarding (S-1) + PE input register (1) +
//   BRAM-read (1) = 2S + 1 cycles minimum.
//
// ADDRESS LAYOUT (matches the BRAMs in accelerator_top.sv)
//   A_BRAM word at addr (k_global * M_TILES + tile_p) holds
//     [A[tile_p*S + 0..S-1][k_global]]   — one S-wide column of A
//   B_BRAM word at addr (k_global * N_TILES + tile_r) holds
//     [B[k_global][tile_r*S + 0..S-1]]    — one S-wide row of B
//   C_BRAM word at addr (output_row * N_TILES + tile_r) holds
//     [C[output_row][tile_r*S + 0..S-1]]  — one S-wide row of C
// =============================================================================

`timescale 1ns/1ps

module tile_controller #(
    parameter int DATA_W    = 8,
    parameter int ACC_W     = 32,
    parameter int S         = 8,
    parameter int MAX_M     = 256,
    parameter int MAX_N     = 256,
    parameter int MAX_K     = 256,
    parameter int FLUSH_CYC = 2 * S + 2     // covers BRAM (1) + skew/forward/PE (2S+1)
)(
    input  logic                                       clk,
    input  logic                                       rst_n,

    // Control / handshake
    input  logic                                       start,
    output logic                                       busy,
    output logic                                       done,

    // Workload dimensions (registered at `start`)
    input  logic [$clog2(MAX_M+1)-1:0]                 M_in,
    input  logic [$clog2(MAX_N+1)-1:0]                 N_in,
    input  logic [$clog2(MAX_K+1)-1:0]                 K_in,

    // ─── A_BRAM ─── one S-wide column read per cycle
    output logic [$clog2((MAX_M*MAX_K)/S)-1:0]        a_rd_addr,
    input  logic signed [S-1:0][DATA_W-1:0]            a_rd_data,

    // ─── B_BRAM ─── one S-wide row read per cycle
    output logic [$clog2((MAX_K*MAX_N)/S)-1:0]        b_rd_addr,
    input  logic signed [S-1:0][DATA_W-1:0]            b_rd_data,

    // ─── C_BRAM ─── one S-wide row write per drain cycle
    output logic                                       c_wr_en,
    output logic [$clog2((MAX_M*MAX_N)/S)-1:0]        c_wr_addr,
    output logic signed [S-1:0][ACC_W-1:0]             c_wr_data,

    // ─── To/from systolic_array ───
    output logic                                       array_en,
    output logic                                       array_drain_en,
    output logic [S-1:0]                               array_clear_col,
    output logic signed [S-1:0][DATA_W-1:0]            array_a_col,
    output logic signed [S-1:0][DATA_W-1:0]            array_b_row,
    input  logic signed [S-1:0][ACC_W-1:0]             array_c_drain
);

    // -------------------------------------------------------------------------
    // Constants and derived widths
    // -------------------------------------------------------------------------
    localparam int LOG2_S       = $clog2(S);        // bit-shift amount = log2(S)
    localparam int M_TILES_W    = $clog2(MAX_M/S + 1);
    localparam int N_TILES_W    = $clog2(MAX_N/S + 1);
    localparam int K_BLOCKS_W   = $clog2(MAX_K/S + 1);
    localparam int K_W          = $clog2(MAX_K + 1);
    localparam int FLUSH_W      = $clog2(FLUSH_CYC + 1);
    localparam int DRAIN_W      = $clog2(S + 1);
    localparam int A_ADDR_W     = $clog2((MAX_M*MAX_K)/S);
    localparam int B_ADDR_W     = $clog2((MAX_K*MAX_N)/S);
    localparam int C_ADDR_W     = $clog2((MAX_M*MAX_N)/S);

    // -------------------------------------------------------------------------
    // FSM state
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE       = 3'd0,
        S_TILE_BEGIN = 3'd1,
        S_COMPUTE    = 3'd2,
        S_FLUSH      = 3'd3,
        S_DRAIN      = 3'd4,
        S_TILE_END   = 3'd5,
        S_DONE       = 3'd6
    } state_t;

    state_t state;

    // -------------------------------------------------------------------------
    // Registered workload dimensions (latched at start)
    // -------------------------------------------------------------------------
    logic [$clog2(MAX_M+1)-1:0]   M_reg;
    logic [$clog2(MAX_N+1)-1:0]   N_reg;
    logic [K_W-1:0]               K_reg;

    // Derived combinational from M_reg / N_reg / K_reg.
    // For S a power-of-two, ceiling-divide is a shift-add.
    logic [M_TILES_W-1:0]    M_TILES;
    logic [N_TILES_W-1:0]    N_TILES;
    logic [K_BLOCKS_W-1:0]   K_BLOCKS;
    logic [LOG2_S-1:0]       M_REM, N_REM, K_REM;

    assign M_TILES  = M_TILES_W'((M_reg + S - 1) >> LOG2_S);
    assign N_TILES  = N_TILES_W'((N_reg + S - 1) >> LOG2_S);
    assign K_BLOCKS = K_BLOCKS_W'((K_reg + S - 1) >> LOG2_S);
    assign M_REM    = M_reg[LOG2_S-1:0];
    assign N_REM    = N_reg[LOG2_S-1:0];
    assign K_REM    = K_reg[LOG2_S-1:0];

    // -------------------------------------------------------------------------
    // Counters
    // -------------------------------------------------------------------------
    logic [M_TILES_W-1:0]   tile_p;     // output tile-row    [0, M_TILES)
    logic [N_TILES_W-1:0]   tile_r;     // output tile-col    [0, N_TILES)
    logic [K_W-1:0]         k_global;   // inner-K element    [0, K_reg)
    logic [FLUSH_W-1:0]     flush_cnt;  // FLUSH cycle counter
    logic [DRAIN_W-1:0]     drain_cnt;  // DRAIN cycle counter

    // -------------------------------------------------------------------------
    // Last-tile flags + per-tile valid sizes (combinational from counters)
    // -------------------------------------------------------------------------
    logic last_p, last_r;
    logic [LOG2_S:0]   M_THIS, N_THIS;

    assign last_p = (tile_p == M_TILES_W'(M_TILES - 1));
    assign last_r = (tile_r == N_TILES_W'(N_TILES - 1));
    assign M_THIS = (last_p && (M_REM != 0)) ? {1'b0, M_REM} : (LOG2_S+1)'(S);
    assign N_THIS = (last_r && (N_REM != 0)) ? {1'b0, N_REM} : (LOG2_S+1)'(S);

    // -------------------------------------------------------------------------
    // FSM + counter updates
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            tile_p    <= '0;
            tile_r    <= '0;
            k_global  <= '0;
            flush_cnt <= '0;
            drain_cnt <= '0;
            M_reg     <= '0;
            N_reg     <= '0;
            K_reg     <= '0;
        end
        else begin
            case (state)

                // -------------------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        // Latch workload dimensions
                        M_reg     <= M_in;
                        N_reg     <= N_in;
                        K_reg     <= K_in;
                        // Reset tile pointers
                        tile_p    <= '0;
                        tile_r    <= '0;
                        state     <= S_TILE_BEGIN;
                    end
                end

                // -------------------------------------------------------------
                // Pulse clear_col=1 for one cycle (handled in output logic).
                // Reset the inner-K counter for the upcoming COMPUTE phase.
                S_TILE_BEGIN: begin
                    k_global  <= '0;
                    state     <= S_COMPUTE;
                end

                // -------------------------------------------------------------
                // Stream K_reg cycles of (a_col, b_row) addresses.
                // Edge-tile saving: K_reg can be < K_BLOCKS·S; we just stop
                // when k_global hits K_reg-1.
                S_COMPUTE: begin
                    if (k_global == K_reg - 1) begin
                        flush_cnt <= '0;
                        state     <= S_FLUSH;
                    end
                    else begin
                        k_global <= k_global + 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // Drive zeros on a_col/b_row so the array's pipeline drains
                // into c_reg. FLUSH_CYC must cover skew + forwarding + PE +
                // BRAM-read latency.
                S_FLUSH: begin
                    if (flush_cnt == FLUSH_W'(FLUSH_CYC - 1)) begin
                        drain_cnt <= '0;
                        state     <= S_DRAIN;
                    end
                    else begin
                        flush_cnt <= flush_cnt + 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // Assert drain_en for S cycles. Each cycle exposes one row of
                // c_reg on c_drain (bottom-up), which we capture into C_BRAM.
                S_DRAIN: begin
                    if (drain_cnt == DRAIN_W'(S - 1)) begin
                        state <= S_TILE_END;
                    end
                    else begin
                        drain_cnt <= drain_cnt + 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // Move to the next output tile (raster order: r increments
                // first, then p). When all tiles done, signal DONE.
                S_TILE_END: begin
                    if (last_r) begin
                        if (last_p) begin
                            state <= S_DONE;
                        end
                        else begin
                            tile_p <= tile_p + 1'b1;
                            tile_r <= '0;
                            state  <= S_TILE_BEGIN;
                        end
                    end
                    else begin
                        tile_r <= tile_r + 1'b1;
                        state  <= S_TILE_BEGIN;
                    end
                end

                // -------------------------------------------------------------
                S_DONE: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Track "compute_active was 1 last cycle" — used to gate the BRAM read
    // data into the array. The BRAM has 1-cycle read latency, so when state
    // entered COMPUTE at cycle T, the first valid a_rd_data appears at T+1.
    // We use compute_active_d1 to drive array_a_col / array_b_row.
    // -------------------------------------------------------------------------
    logic compute_active_d1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) compute_active_d1 <= 1'b0;
        else        compute_active_d1 <= (state == S_COMPUTE);
    end

    // -------------------------------------------------------------------------
    // BRAM addresses (combinational)
    //
    // Address layout chosen so that one BRAM word = one S-wide vector that
    // the array consumes per cycle. See header for the full mapping.
    //
    //   a_rd_addr = k_global * M_TILES + tile_p
    //   b_rd_addr = k_global * N_TILES + tile_r
    //   c_wr_addr = (tile_p * S + drain_row) * N_TILES + tile_r
    //             = output_row * N_TILES + tile_r,  output_row = tile_p*S + (S-1-drain_cnt)
    //
    // The multiplications are small (k_global is up to MAX_K, M_TILES up to
    // MAX_M/S). Vivado will use a few CARRY4s — well below the array's
    // critical path.
    // -------------------------------------------------------------------------
    logic [LOG2_S:0]   drain_row;
    assign drain_row = (LOG2_S+1)'(S - 1) - {1'b0, drain_cnt[LOG2_S-1:0]};

    assign a_rd_addr = A_ADDR_W'(k_global * M_TILES + tile_p);
    assign b_rd_addr = B_ADDR_W'(k_global * N_TILES + tile_r);
    assign c_wr_addr = C_ADDR_W'(((tile_p << LOG2_S) + drain_row) * N_TILES + tile_r);

    // -------------------------------------------------------------------------
    // Array inputs
    // -------------------------------------------------------------------------
    // clear_col is broadcast to all S columns during TILE_BEGIN.
    // (Phase 2's per-column infrastructure is unused here; we never need
    //  selective column clears in v1.)
    assign array_clear_col = (state == S_TILE_BEGIN) ? {S{1'b1}} : '0;

    // drain_en active only in DRAIN.
    assign array_drain_en  = (state == S_DRAIN);

    // array_en active during COMPUTE/FLUSH/DRAIN. During TILE_BEGIN we keep
    // en=0 so the input/forwarding registers don't update spuriously.
    // (clear_acc has higher priority than en in the PE, so clear still works.)
    assign array_en        = (state == S_COMPUTE) ||
                             (state == S_FLUSH)   ||
                             (state == S_DRAIN);

    // a_col / b_row come from BRAM read data when COMPUTE was active last
    // cycle (= the BRAM data corresponds to a recently-issued address).
    // Otherwise drive zeros so the array's skew/forwarding chains see no
    // garbage.
    assign array_a_col = compute_active_d1 ? a_rd_data : '0;
    assign array_b_row = compute_active_d1 ? b_rd_data : '0;

    // -------------------------------------------------------------------------
    // C_BRAM write
    // -------------------------------------------------------------------------
    // Capture one row of c_drain per drain cycle. Skip drain cycles whose
    // drain_row is in the padded region (drain_row >= M_THIS).
    // The N partial-tile case is handled by leaving padded C_BRAM cells as
    // their initial 0 (the TB ignores them anyway since they're outside the
    // logical M × N region).
    assign c_wr_en   = (state == S_DRAIN) && (drain_row < M_THIS);
    assign c_wr_data = array_c_drain;

    // -------------------------------------------------------------------------
    // Top-level handshake outputs
    // -------------------------------------------------------------------------
    assign busy = (state != S_IDLE) && (state != S_DONE);
    assign done = (state == S_DONE);

endmodule
