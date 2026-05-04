// =============================================================================
// mult_truncated.sv  —  Approximate multiplier: truncate the lowest L bits
// =============================================================================
//
// Computes the full signed product a * b, then forces the bottom L bits of the
// result to zero. The synthesizer can drop the partial-product columns that
// only feed those L bits, reducing the multiplier's logic.
//
// PARAMETER L  (default 0 = exact)
//   Number of low bits to truncate from the product.
//   L = 0   → identical to mult_lut (exact)
//   L = 2   → max abs error per multiply = 3  (per multiply, always ≥ 0)
//   L = 4   → max abs error per multiply = 15
//   L = 8   → keeps only the upper byte of the 16-bit product (heavy)
//
// SIGN BEHAVIOUR
//   Two's-complement truncation by zeroing the low bits always makes the
//   value MORE NEGATIVE (or unchanged) — i.e., the truncated value is
//   always ≤ the original. This produces a systematic negative bias when
//   accumulated across many multiplies.
//
//   Worst-case per multiply: |error| ≤ 2^L − 1
//   Worst-case per K-element MAC: |error| ≤ K · (2^L − 1)
//
// FORCED FABRIC
//   We mark the product (* use_dsp = "no" *) so Vivado builds the multiplier
//   in LUT fabric. The point of this variant is to measure the LUT/area
//   savings from removing low partial-product rows — doing it inside a DSP
//   would defeat the experiment (DSP48 always pays full multiplier cost
//   regardless of how many output bits we use).
// =============================================================================

`timescale 1ns/1ps

module mult_truncated #(
    parameter int DATA_W = 8,
    parameter int OUT_W  = 2 * DATA_W,
    parameter int L      = 0           // # of low bits to zero
)(
    input  logic signed [DATA_W-1:0]   a,
    input  logic signed [DATA_W-1:0]   b,
    output logic signed [OUT_W-1:0]    p
);

    (* use_dsp = "no" *)
    logic signed [OUT_W-1:0]   p_full;

    assign p_full = a * b;

    generate
        if (L == 0) begin : gen_exact
            // No truncation — pass through.
            assign p = p_full;
        end
        else if (L >= OUT_W) begin : gen_zero
            // Pathological: truncating everything → always 0.
            assign p = '0;
        end
        else begin : gen_trunc
            // Keep upper bits, zero the lowest L bits.
            assign p = {p_full[OUT_W-1 : L], {L{1'b0}}};
        end
    endgenerate

endmodule
