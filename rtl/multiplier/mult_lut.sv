// =============================================================================
// mult_lut.sv  —  Exact signed multiplier, forced into LUT fabric
// =============================================================================
//
// Same operation as mult_dsp (`*` operator), but with the (* use_dsp = "no" *)
// attribute on the product. Vivado will build this in LUTs + carry chains
// instead of using a DSP48E1.
//
// Useful as a comparison point: shows what an exact 8x8 multiplier costs in
// LUT/area/Fmax when DSPs are off the table (e.g., reserved for other uses, or
// on a part that doesn't have them).
//
// We expect this variant to be slower and use many more LUTs than mult_dsp,
// while still matching it bit-for-bit on outputs.
// =============================================================================

`timescale 1ns/1ps

module mult_lut #(
    parameter int DATA_W = 8,
    parameter int OUT_W  = 2 * DATA_W
)(
    input  logic signed [DATA_W-1:0]   a,
    input  logic signed [DATA_W-1:0]   b,
    output logic signed [OUT_W-1:0]    p
);

    // The (* use_dsp = "no" *) attribute on the wire that carries the product
    // tells Vivado: do NOT use a DSP for this multiplication. It will then
    // synthesize the multiplier as a partial-product tree in LUTs + CARRY4
    // chains.
    (* use_dsp = "no" *)
    logic signed [OUT_W-1:0]   p_lut;

    assign p_lut = a * b;
    assign p     = p_lut;

endmodule
