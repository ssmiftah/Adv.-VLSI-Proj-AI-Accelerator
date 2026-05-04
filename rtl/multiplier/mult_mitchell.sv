// =============================================================================
// mult_mitchell.sv  —  Approximate signed multiplier, Mitchell log-domain
// =============================================================================
//
// Mitchell's algorithm (1962) approximates multiplication by transforming to
// the log domain via the cheap approximation log2(1 + x) ≈ x for x ∈ [0, 1).
//
// PIPELINE: combinational. Critical path:
//   leading-one detector (LOD) → barrel shifter (mantissa align) → adder →
//   priority/carry decision → barrel shifter (final align) → sign-apply
//
// ALGORITHM (UNSIGNED MAGNITUDES, then sign reapplied):
//   k_a = position of leading 1 in |a|     (range 0 .. DATA_W-1)
//   mag_a aligned so leading 1 sits at bit (DATA_W-1)
//   mantissa_a = aligned[DATA_W-2:0]       (Q0.(DATA_W-1) fraction = x_a)
//   sum_x = mantissa_a + mantissa_b        (DATA_W bits, MSB = carry)
//   carry = sum_x[DATA_W-1]                (= "x_a + x_b ≥ 1")
//   val   = carry ? sum_x : {1'b1, sum_x[DATA_W-2:0]}   (always leading 1 at bit DATA_W-1)
//   exp   = k_a + k_b + carry              (target bit position of leading 1 in result)
//   |result| = (val << exp) >> (DATA_W-1)
//   result = sign_a XOR sign_b ? -|result| : |result|
//
// Special case: |a| == 0 or |b| == 0  →  result = 0.
//
// ERROR
//   Per multiply: |error| ≤ ~0.111 · |a · b|, always biased to underestimate
//                 magnitude. Worst case for DATA_W=8 ≈ 1820 (= 0.111 · 128²).
//   Per K-element MAC: |error| ≤ K · max_per_mul_err.
//   For DATA_W=8, K=8: theoretical max ≈ 14,550.
//   In practice errors don't all align, MAE is much smaller.
//
// FORCED FABRIC
//   (* use_dsp = "no" *) on the result wire prevents Vivado from trying to
//   "help" by mapping any sub-operation to a DSP — defeats the experiment.
// =============================================================================

`timescale 1ns/1ps

module mult_mitchell #(
    parameter int DATA_W = 8,
    parameter int OUT_W  = 2 * DATA_W
)(
    input  logic signed [DATA_W-1:0]   a,
    input  logic signed [DATA_W-1:0]   b,
    output logic signed [OUT_W-1:0]    p
);

    localparam int K_W     = $clog2(DATA_W);          // # bits to encode 0..DATA_W-1
    localparam int EXP_W   = K_W + 1;                 // can hold k_a + k_b + carry
    localparam int INTER_W = OUT_W + DATA_W;          // safe width for (val << max_exp)

    // -------------------------------------------------------------------------
    // Sign extraction and magnitude
    // -------------------------------------------------------------------------
    logic                sign_a, sign_b, sign_result;
    logic [DATA_W-1:0]   mag_a, mag_b;

    assign sign_a      = a[DATA_W-1];
    assign sign_b      = b[DATA_W-1];
    assign sign_result = sign_a ^ sign_b;

    // -a in DATA_W-bit unsigned interpretation gives the magnitude (handles
    // -2^(DATA_W-1) gracefully — its "negation" is itself, which equals
    // 2^(DATA_W-1) when read as unsigned. Correct magnitude for that case.)
    assign mag_a = sign_a ? -a : a;
    assign mag_b = sign_b ? -b : b;

    // -------------------------------------------------------------------------
    // Leading-one detector — returns position of MSB; 0 for the all-zero input
    // -------------------------------------------------------------------------
    function automatic logic [K_W-1:0] lod(input logic [DATA_W-1:0] x);
        logic [K_W-1:0] result;
        result = '0;
        for (int i = 0; i < DATA_W; i++) begin
            if (x[i]) result = K_W'(i);
        end
        return result;
    endfunction

    logic [K_W-1:0] k_a, k_b;
    assign k_a = lod(mag_a);
    assign k_b = lod(mag_b);

    // -------------------------------------------------------------------------
    // Align mantissas — barrel-shift so leading 1 ends up at bit DATA_W-1
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0]   mag_a_aligned, mag_b_aligned;
    assign mag_a_aligned = mag_a << (K_W'(DATA_W-1) - k_a);
    assign mag_b_aligned = mag_b << (K_W'(DATA_W-1) - k_b);

    // Mantissa = bits BELOW the leading 1 (Q0.(DATA_W-1) fraction)
    logic [DATA_W-2:0]   mantissa_a, mantissa_b;
    assign mantissa_a = mag_a_aligned[DATA_W-2:0];
    assign mantissa_b = mag_b_aligned[DATA_W-2:0];

    // -------------------------------------------------------------------------
    // Sum mantissas — DATA_W bits (the MSB is the carry)
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0]   sum_x;
    logic                carry;
    assign sum_x = {1'b0, mantissa_a} + {1'b0, mantissa_b};
    assign carry = sum_x[DATA_W-1];

    // -------------------------------------------------------------------------
    // Build val (leading 1 always at bit DATA_W-1)
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0]   val;
    assign val = carry ? sum_x : {1'b1, sum_x[DATA_W-2:0]};

    // -------------------------------------------------------------------------
    // Exponent = k_a + k_b + carry
    // -------------------------------------------------------------------------
    logic [EXP_W-1:0]    exp_sum;
    assign exp_sum = {1'b0, k_a} + {1'b0, k_b} + EXP_W'(carry);

    // -------------------------------------------------------------------------
    // Final align: shift val so its bit (DATA_W-1) lands at bit `exp_sum`
    // |result| = (val << exp_sum) >> (DATA_W-1)
    // -------------------------------------------------------------------------
    logic [INTER_W-1:0]  shifted;
    assign shifted = {{(INTER_W - DATA_W){1'b0}}, val} << exp_sum;

    logic [OUT_W-1:0]    mitchell_unsigned;
    assign mitchell_unsigned = shifted[INTER_W - 1 : DATA_W - 1];

    // -------------------------------------------------------------------------
    // Zero short-circuit (LOD on 0 returns 0; without this guard we'd get
    // a non-zero result for 0-input cases)
    // -------------------------------------------------------------------------
    logic [OUT_W-1:0]    mag_result;
    assign mag_result = (mag_a == '0 || mag_b == '0) ? '0 : mitchell_unsigned;

    // -------------------------------------------------------------------------
    // Re-apply sign
    // -------------------------------------------------------------------------
    (* use_dsp = "no" *)
    logic signed [OUT_W-1:0] p_int;
    assign p_int = sign_result ? -$signed(mag_result) : $signed({1'b0, mag_result[OUT_W-2:0]});
    assign p     = p_int;

endmodule
