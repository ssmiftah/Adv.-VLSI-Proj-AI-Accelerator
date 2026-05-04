// =============================================================================
// mult_dsp.sv  —  Exact signed multiplier, DSP-target
// =============================================================================
//
// Plain `*` operator in a continuous assign. When this module is instantiated
// inline with `acc <= acc + p` in a clocked process, Vivado recognizes the
// MAC pattern and infers a DSP48E1 hard block per instance.
//
// Phase 4 baseline. All other multiplier variants share this same port shape.
// =============================================================================

`timescale 1ns/1ps

module mult_dsp #(
    parameter int DATA_W = 8,
    parameter int OUT_W  = 2 * DATA_W
)(
    input  logic signed [DATA_W-1:0]   a,
    input  logic signed [DATA_W-1:0]   b,
    output logic signed [OUT_W-1:0]    p
);

    // Pure combinational signed multiply.
    // Vivado's USE_DSP attribute on the upstream c_reg pulls this into a DSP48.
    assign p = a * b;

endmodule
