// =============================================================================
// systolic_array.sv  —  S × S Output-Stationary Systolic Array (INT8)
// =============================================================================

`timescale 1ns/1ps

module systolic_array #(
    parameter int    DATA_W       = 8,
    parameter int    ACC_W        = 32,
    parameter int    S            = 4,
    parameter string MULT_TYPE    = "DSP",
    parameter int    MULT_TRUNC_L = 0,
    parameter int    MULT_BAM_B   = 0
)(
    input  logic                                clk,
    input  logic                                rst_n,

    // Compute
    input  logic                                en,
    input  logic signed [S-1:0][DATA_W-1:0]     a_col,     // one column of A per cycle
    input  logic signed [S-1:0][DATA_W-1:0]     b_row,     // one row    of B per cycle

    // Per-column clear (between tiles)
    input  logic [S-1:0]                        clear_col,

    // Drain
    input  logic                                drain_en,
    output logic signed [S-1:0][ACC_W-1:0]      c_drain    // bottom-row drain outputs
);

    // -------------------------------------------------------------------------
    // Skewed inputs (outputs of the two skew buffers)
    // -------------------------------------------------------------------------
    logic signed [S-1:0][DATA_W-1:0]   a_skewed;
    logic signed [S-1:0][DATA_W-1:0]   b_skewed;

    // -------------------------------------------------------------------------
    // Skew buffer instances — both share clk/rst_n/en. The A buffer skews per
    // ROW (row r delayed by r cycles); the B buffer skews per COLUMN (col c
    // delayed by c cycles). They use the same module — the role just depends
    // on what we wire to data_in.
    // -------------------------------------------------------------------------
    skew_buffer #(.DATA_W(DATA_W), .S(S)) u_skew_a (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en),
        .data_in (a_col),
        .data_out(a_skewed)
    );

    skew_buffer #(.DATA_W(DATA_W), .S(S)) u_skew_b (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en),
        .data_in (b_row),
        .data_out(b_skewed)
    );

    // -------------------------------------------------------------------------
    // Inter-PE forwarding wires
    // -------------------------------------------------------------------------
    // a_wire[i][j] = PE_{i,j}'s a_out (registered). Goes right to PE_{i, j+1}.
    // b_wire[i][j] = PE_{i,j}'s b_out (registered). Goes down to PE_{i+1, j}.
    // c_drain_wire[i][j] = PE_{i,j}'s c_drain_out (combinational = c_reg).
    //                      Goes down to PE_{i+1, j} during drain.
    //
    // Packed 3D arrays for consistency with the packed-bus convention used at
    // module boundaries. Indexing is identical to the unpacked form
    // (a_wire[i][j] still yields a [DATA_W-1:0] scalar slice).
    // Phantom-edge wires: the last column of a_wire and the last row of
    // b_wire / c_drain_wire are written by the boundary PEs but never read
    // (data exits the array there). The lint_off below acknowledges that.
    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [S-1:0][S  :0][DATA_W-1:0]   a_wire;
    logic signed [S  :0][S-1:0][DATA_W-1:0]   b_wire;
    logic signed [S  :0][S-1:0][ACC_W-1:0]    c_drain_wire;
    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------------------------
    // The mesh — instantiate S×S PEs
    // -------------------------------------------------------------------------

    genvar k;
    generate
        for (k = 0; k < S; k++) begin: gen_a_edge
            assign a_wire[k][0] = a_skewed[k];  // left edge: from A skew buffer
        end
        for (k = 0; k < S; k++) begin: gen_b_edge
            assign b_wire[0][k] = b_skewed[k];  // top edge: from B skew buffer
            assign c_drain_wire[0][k] = '0;  // top edge has no drain input: feed 0
        end
    endgenerate


    genvar i, j;
    generate
        for (i = 0; i < S; i++) begin : gen_row
            for (j = 0; j < S; j++) begin : gen_col
                // -------------------------------------------------------------
                // PE instance — port mapping.
                // -------------------------------------------------------------
                pe_int8 #(
                    .DATA_W      (DATA_W),
                    .ACC_W       (ACC_W),
                    .MULT_TYPE   (MULT_TYPE),
                    .MULT_TRUNC_L(MULT_TRUNC_L),
                    .MULT_BAM_B  (MULT_BAM_B)
                ) u_pe (
                    .clk         (clk),
                    .rst_n       (rst_n),
                    .en          (en),
                    .clear_acc   (clear_col[j]),        // per-column clear
                    .drain_en    (drain_en),
                    .a_in        (a_wire[i][j]),        // from left neighbor (or skew buffer at j=0)
                    .b_in        (b_wire[i][j]),        // from top neighbor (or skew buffer at i=0)
                    .c_drain_in  (c_drain_wire[i][j]),  // from drain neighbor (or 0 at i=0)
                    .a_out       (a_wire[i][j+1]),      // rightward forwarding, with phantom boundary at j=S-1
                    .b_out       (b_wire[i+1][j]),      // downward forwarding, with phantom boundary at i=S-1
                    /* verilator lint_off PINCONNECTEMPTY */
                    .c_out       (),                    // unused at array level (drain via c_drain_out)
                    /* verilator lint_on PINCONNECTEMPTY */
                    .c_drain_out (c_drain_wire[i+1][j]) // downward drain forwarding, with phantom boundary at i=S-1
                );

            end
        end
    endgenerate

    generate
        for (j=0; j < S; j++) begin : gen_c_drain
            assign c_drain[j] = c_drain_wire[S][j];
        end
    endgenerate

endmodule

`default_nettype wire
