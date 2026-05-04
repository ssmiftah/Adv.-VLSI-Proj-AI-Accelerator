// =============================================================================
// mult_bam.sv  —  Approximate signed multiplier, Broken Array Multiplier (BAM)
// =============================================================================
//
// Implements the structural BAM(B) approximation: the lower B partial-product
// columns of the multiplier are entirely omitted. Equivalently:
//
//   a*b ≈ a_hi · b_hi · 2^(2B)
//
// where a_hi = a >> B (signed), a_lo = a[B-1:0] (unsigned), and similarly for b.
//
// The full expansion is:
//
//   a*b = (a_hi*b_hi)·2^(2B) + (a_hi*b_lo + a_lo*b_hi)·2^B + a_lo*b_lo
//                                               ↑  dropped by BAM  ↑
//
// EFFECT ON HARDWARE
//   Instead of an 8×8 multiplier we get a (DATA_W-B)×(DATA_W-B) multiplier
//   plus a fixed left-shift by 2B (free in fabric — just wire renumbering).
//   For B=2, the multiplier is 6×6 instead of 8×8: roughly half the partial
//   products and half the carry-chain length.
//
// ERROR
//   For DATA_W=8, B=2:  max |error per mul| ≈ 2 · 32 · 3 · 4 + 9 = 777
//   For DATA_W=8, B=4:  max |error per mul| ≈ 2 · 8  · 15 · 16 + 225 = 3825
//   Per K-element MAC: × K (no error cancellation in worst case).
//   Error sign depends on signs of operands (can be either positive or
//   negative, unlike truncation which is one-sided).
//
// PARAMETER B  (default 0 = exact)
//   B = 0   → identical to mult_lut (exact)
//   B = 2   → drop lower 2 input bits each, 6×6 multiplier
//   B = 4   → drop lower 4 input bits each, 4×4 multiplier
//   B ≥ DATA_W → degenerate to 0
//
// FORCED FABRIC
//   (* use_dsp = "no" *) on the truncated multiplier output keeps the
//   reduced multiplier in LUTs so we measure the real fabric saving.
// =============================================================================

`timescale 1ns/1ps

module mult_bam #(
    parameter int DATA_W = 8,
    parameter int OUT_W  = 2 * DATA_W,
    parameter int B      = 0           // # of low input bits dropped per operand
)(
    input  logic signed [DATA_W-1:0]   a,
    input  logic signed [DATA_W-1:0]   b,
    output logic signed [OUT_W-1:0]    p
);

    generate
        if (B == 0) begin : gen_exact
            // Exact multiply (identical to mult_lut), forced into fabric
            (* use_dsp = "no" *)
            logic signed [OUT_W-1:0] p_full;
            assign p_full = a * b;
            assign p = p_full;
        end
        else if (B >= DATA_W) begin : gen_zero
            // Pathological — multiplier is 0×0
            assign p = '0;
        end
        else begin : gen_bam
            // Take the upper (DATA_W-B) bits of each operand as a signed value.
            // Vivado will synthesize a signed (DATA_W-B)×(DATA_W-B) multiplier.
            localparam int HI_W      = DATA_W - B;
            localparam int HI_OUT_W  = 2 * HI_W;

            logic signed [HI_W-1:0]      a_hi;
            logic signed [HI_W-1:0]      b_hi;
            assign a_hi = a[DATA_W-1 : B];     // signed: includes original sign bit
            assign b_hi = b[DATA_W-1 : B];

            (* use_dsp = "no" *)
            logic signed [HI_OUT_W-1:0]  p_hi;
            assign p_hi = a_hi * b_hi;

            // Place the (HI_OUT_W)-bit upper product at bit position 2B of the
            // OUT_W-bit result. Sign-extend p_hi to OUT_W first, then shift —
            // shift fills the lower 2B bits with zeros, which is exactly the
            // "dropped low PPs = 0" assumption.
            logic signed [OUT_W-1:0]    p_ext;
            assign p_ext = OUT_W'(p_hi);   // sign-extend (signed cast)
            assign p     = p_ext <<< (2*B);
        end
    endgenerate

endmodule
